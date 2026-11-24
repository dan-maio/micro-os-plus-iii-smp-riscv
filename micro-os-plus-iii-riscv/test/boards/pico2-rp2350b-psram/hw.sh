#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# hw.sh -- run one of the WeAct RP2350B (16 MB flash, 8 MB PSRAM, Hazard3)
# tests on the board. The Pico 2's hw.sh, with this board's probe and flash:
#   probe   c251:f001 (CMSIS-DAP), 1000 kHz -- the Cortex-M board's settings;
#   flash   FLASHSIZE 16 MB (the default 4 MB silently truncates);
#   ports   GDB/telnet/TCL disabled, so it runs beside the Pico 2's session;
#   Arm     if the RISC-V cores cannot be examined (an Arm image in flash),
#           the image is first programmed through the Arm view; the boot ROM
#           then switches both cores to Hazard3 on the reset.
#
#     test/boards/pico2-rp2350b-psram/hw.sh            list the tests
#     test/boards/pico2-rp2350b-psram/hw.sh <app>      program it and run it
#
# Probe: this board's own CMSIS-DAP probe (SWD), selected by VID:PID
# c251:f001 -- the Pico 2's Debug Probe (2e8a:000c) and the Milk-V Duo's
# Sipeed (d6e7:3507) may be connected too; nothing is shared). OpenOCD: the Raspberry
# Pi build (~/.pico-sdk/openocd/0.12.0+dev) with target/rp2350-riscv.cfg --
# the xPack OpenOCD cannot reach the RP2350's RISC-V debug module over the Arm
# DAP (its riscv target rejects -dap; measured). OpenOCD only, no GDB.
#
# The session, as the Cortex-M pico2 board's hw.sh does it:
#   init, reset init           both harts halted; reset-init runs the boot
#                              ROM's flash set-up (rom_api_call FC)
#   program <elf> verify       into flash (the image carries the RISC-V
#                              IMAGE_DEF block)
#   reset init                 boot ROM again, harts halted
#   arm semihosting enable     on both harts: the RESULT line and SYS_EXIT
#   resume                     both (one SMP group); core 1 resumes in the boot
#                              ROM's launch loop, where the test's FIFO
#                              handshake finds it
#
# The board must be in RISC-V mode (ARCHSEL = 3) for rp2350-riscv.cfg to find
# the harts: any RISC-V image in flash leaves it so after a reset. A board
# still running an Arm image is switched once by programming a RISC-V image
# through the Arm view (target/rp2350.cfg), as was done at bring-up.
#
# Verdict: the RESULT line and the semihosting exit. With no GDB attached,
# OpenOCD ends itself on SYS_EXIT with the test's exit code (32-bit form:
# ApplicationExit -> 0, RunTimeErrorUnknown -> 1). Same codes as the Milk-V
# Duo's hw.sh: 0 PASS, 1 FAIL, 2 no such test / stale build, 3 TIMEOUT,
# 4 OPENOCD DIED, 5 NO EXIT.
#
# Env:  BUILD=<dir>      the CMake build directory  (default: test/build)
#       OPENOCD=<path>   a specific OpenOCD (one with RISC-V-over-DAP)
#       SPEED=<kHz>      SWD clock (default 1000)
# -----------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
BUILD="${BUILD:-$ROOT/test/build}"

list_tests () {
  echo "tests built for pico2-rp2350b-psram:"
  for e in "$BUILD"/test/*-hwd; do
    [[ -e "$e" ]] || { echo "  (none -- build first)"; return; }
    echo "  $(basename "$e" -hwd)"
  done
}

APP="${1:-}"
if [[ -z "$APP" || "$APP" == "list" ]]; then
  list_tests
  exit 0
fi
SECS="${2:-300}"

ELF="$BUILD/test/${APP}-hwd"
[[ -f "$ELF" ]] || ELF="$BUILD/test/${APP}-hwd.elf"
if [[ ! -f "$ELF" ]]; then
  echo "hw.sh: no such test: $APP" >&2
  list_tests >&2
  exit 2
fi
ELF="$(readlink -f "$ELF")"

# Never run a stale image: an ELF older than any port or board source, or
# than its own test's sources (another test's edit does not make it stale).
STALE="$(find "$ROOT/src" "$ROOT/include" "$HERE" \
  "$ROOT/test/pico2-rp2350b-psram/$APP" "$ROOT/test/pico2-rp2350b-psram/include" \
  "$ROOT/test/boards/pico2" \
  -type f -newer "$ELF" \( -name '*.cpp' -o -name '*.c' -o -name '*.S' -o -name '*.h' -o -name '*.hpp' -o -name '*.ld' \) 2>/dev/null | head -3)"
if [[ -n "$STALE" ]]; then
  echo "hw.sh: $ELF is older than its sources -- rebuild first:" >&2
  echo "$STALE" | sed 's/^/  /' >&2
  exit 2
fi

# The pico-sdk VS Code extension installs it under ~/.pico-sdk; on this
# machine that home is also mounted from another disk, so look in both.
PICO_OCD_DIR="$(ls -d "$HOME"/.pico-sdk/openocd/* \
  /run/media/*/*/home/"$(id -un)"/.pico-sdk/openocd/* 2>/dev/null | sort -V | tail -1)"
OCD="${OPENOCD:-${PICO_OCD_DIR:+$PICO_OCD_DIR/openocd}}"
if [[ -z "$OCD" || ! -x "$OCD" ]]; then
  echo "hw.sh: no Raspberry Pi OpenOCD (~/.pico-sdk/openocd/*/openocd); set OPENOCD" >&2
  exit 4
fi
SCRIPTS="$(dirname "$OCD")/scripts"
SPEED="${SPEED:-1000}"
PROBE=(-f interface/cmsis-dap.cfg -c "cmsis-dap vid_pid 0xc251 0xf001"
       -c "adapter speed $SPEED" -c "set FLASHSIZE 0x1000000"
       -c "gdb port disabled" -c "telnet port disabled" -c "tcl port disabled")

# Flash or RAM: an image whose entry is in SRAM (a `-ram` test, linker-
# ram.ld) is loaded into RAM over the debugger and started there; nothing is
# written to flash. Any other image is programmed into flash and booted.
READELF="$(ls -d "$HOME"/.local/xPacks/@xpack-dev-tools/riscv-none-elf-gcc/*/.content/bin/riscv-none-elf-readelf 2>/dev/null | sort -V | tail -1)"
READELF="${READELF:-riscv-none-elf-readelf}"
ENTRY="$("$READELF" -h "$ELF" | awk '/Entry point address/ { print $4 }')"
if [[ "$ENTRY" == 0x2* ]]; then
  MODE=ram
  SESSION=(
    -c "init"
    -c "reset init"
    # verify_image runs a checksum algorithm in the work area: keep it in the
    # image's NOLOAD heap, never over the loaded sections.
    -c "rp2350.rv0 configure -work-area-phys 0x20078000 -work-area-size 0x8000"
    -c "load_image \"$ELF\""
    -c "verify_image \"$ELF\""
    -c "targets rp2350.rv1"
    -c "arm semihosting enable"
    -c "targets rp2350.rv0"
    -c "arm semihosting enable"
    -c "reg pc $ENTRY"
    -c "resume"
  )
else
  MODE=flash
  SESSION=(
    -c "init"
    -c "reset init"
    -c "program \"$ELF\" verify"
    -c "reset init"
    -c "targets rp2350.rv1"
    -c "arm semihosting enable"
    -c "targets rp2350.rv0"
    -c "arm semihosting enable"
    -c "resume"
  )
fi

LOGS="$BUILD/.hw-logs"; mkdir -p "$LOGS"
LOG="$LOGS/${APP}.log"
rm -f "$LOG"

echo "== WeAct RP2350B (RISC-V) : $APP ($MODE, entry $ENTRY) =="

# Arm or RISC-V? Examine the RISC-V cores; if they are not there, program the
# image through the Arm view first (the boot ROM switches on the reset).
if ! "$OCD" -s "$SCRIPTS" "${PROBE[@]}" -f target/rp2350-riscv.cfg \
       -c "init" -c "shutdown" 2>&1 | grep -q "Examined RISC-V core"; then
  echo "-- RISC-V cores not present: programming through the Arm view to switch"
  "$OCD" -s "$SCRIPTS" "${PROBE[@]}" -f target/rp2350.cfg \
    -c "init" -c "reset init" -c "program \"$ELF\" verify" -c "reset run" \
    -c "shutdown" > "$LOGS/${APP}.armswitch.log" 2>&1
  sleep 1
fi

"$OCD" -s "$SCRIPTS" "${PROBE[@]}" \
  -f target/rp2350-riscv.cfg \
  "${SESSION[@]}" \
  > >(tee "$LOG") 2>&1 &
OCD_PID=$!

# The USB device tests need the PC's half (they pass when the host sends
# Escape): usb-host.py waits for the device to enumerate on this PC and plays
# it. The Pico 2's own micro-USB must be connected to the PC.
HOST_PID=""
HOST_LOG="$LOGS/${APP}.host.log"
# HOST_HELPER=0: do not start it (you play the host side yourself).
case "${HOST_HELPER:-1}:$APP" in
  0:*) ;;
  *:smp-test-usb-cdc-acm) python3 -I "$HERE/usb-host.py" cdc "$SECS" > "$HOST_LOG" 2>&1 & HOST_PID=$! ;;
  *:smp-test-usb-hid)   python3 -I "$HERE/usb-host.py" hid "$SECS" > "$HOST_LOG" 2>&1 & HOST_PID=$! ;;
esac

EXIT_WAIT=20
waited=0 rc=2
while (( waited < SECS )); do
  # SYS_EXIT ends OpenOCD itself (no GDB); the RESULT line comes just before.
  if grep -q 'RESULT: \(PASS\|FAIL\|SKIP\)' "$LOG" 2>/dev/null; then
    for (( x = 0; x < EXIT_WAIT; x++ )); do
      kill -0 "$OCD_PID" 2>/dev/null || break
      sleep 1
    done
    break
  fi
  if ! kill -0 "$OCD_PID" 2>/dev/null; then rc=4; break; fi
  sleep 1; waited=$((waited + 1))
done

stopped_by_us=0
if kill -0 "$OCD_PID" 2>/dev/null; then
  stopped_by_us=1
  kill -TERM "$OCD_PID" 2>/dev/null
  for (( x = 0; x < 5; x++ )); do
    kill -0 "$OCD_PID" 2>/dev/null || break
    sleep 1
  done
  kill -0 "$OCD_PID" 2>/dev/null && kill -KILL "$OCD_PID" 2>/dev/null
fi
wait "$OCD_PID" 2>/dev/null
ocd_status=$?
sleep 1 # let tee (the log) catch up
if [[ -n "$HOST_PID" ]]; then
  kill "$HOST_PID" 2>/dev/null
  wait "$HOST_PID" 2>/dev/null
  sed 's/^/  /' "$HOST_LOG"
fi

exit_code=""
if (( ! stopped_by_us )) && grep -q 'RESULT: \(PASS\|FAIL\|SKIP\)' "$LOG" 2>/dev/null; then
  exit_code="$ocd_status"
elif grep -q 'application exited normally' "$LOG" 2>/dev/null; then
  exit_code=0
elif grep -q 'application exited with' "$LOG" 2>/dev/null; then
  exit_code="$(grep -oE 'application exited with -?[0-9]+' "$LOG" | tail -1 | grep -oE -- '-?[0-9]+$')"
fi
result=""
grep -q 'RESULT: PASS' "$LOG" 2>/dev/null && result=PASS
grep -q 'RESULT: SKIP' "$LOG" 2>/dev/null && result=SKIP
grep -q 'RESULT: FAIL' "$LOG" 2>/dev/null && result=FAIL

if [[ -n "$result" ]]; then
  if [[ -z "$exit_code" ]]; then
    rc=5
  elif [[ "$result" != FAIL && "$exit_code" == 0 ]]; then
    rc=0
  else
    rc=1
  fi
elif [[ -n "$exit_code" ]]; then
  rc=1
elif [[ $rc -eq 2 ]]; then
  rc=3
fi

printf '\n%-24s ' "$APP"
case "$rc" in
  0) echo "${result}  (exit 0, ${waited}s)" ;;
  1) echo "FAIL  (RESULT ${result:-none}, exit ${exit_code:-none}; see $LOG)" ;;
  4) echo "OPENOCD DIED  (see $LOG)" ;;
  5) echo "NO EXIT  (RESULT $result but no semihosting exit; see $LOG)" ;;
  *) echo "TIMEOUT after ${SECS}s  (see $LOG)" ; rc=3 ;;
esac
exit "$rc"
