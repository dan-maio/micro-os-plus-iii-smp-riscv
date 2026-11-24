#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# hw.sh -- run one of the VisionFive 2 Lite's tests on the board, over JTAG.
#
#     test/boards/visionfive2-lite/hw.sh            list the tests
#     test/boards/visionfive2-lite/hw.sh <app>      load it into DDR and run it
#
# THE BOARD MUST BE AT THE U-BOOT PROMPT (stop autoboot): the SPL has trained
# the DDR and U-Boot has set up UART0. Nothing is written to flash or SD; the
# test goes into DDR only (0x40200000, linker.ld) and runs there.
#
# The session, OpenOCD only (no GDB, nothing redirected):
#   init
#   (HW_RESET=1: reset halt; sleep 3000 -- every hart reset and halted)
#   halt                       all four U74; the ones the image does not drive
#                              stay debug-halted
#   load_image <elf>           into DDR at 0x40200000
#   for each hart the image drives (1, or 1..4 for an SMP image):
#     reg priv 3; pc riscv_board_park, resume, 100 ms, halt; semihosting on
#                              every hart is left stopped by a plain halt
#                              request. Measured: a hart left stopped on the
#                              previous run's semihosting exit ebreak
#                              (dcsr.cause 1) never halted on its ebreaks in
#                              the next run -- every run after a PASS hung,
#                              every run after a hang passed.
#   SMP image (riscv_secondary_boot present, NCPU from its size): clear the
#     release slots, start harts 2..NCPU at _start (the port parks them)
#   reg pc <_start>, resume    hart 1 runs the test
#
# Wiring (40-pin header): TMS 35, TCK 37, TDI 38, TDO 40, GND 39 (JTAG);
#         UART0 TX GPIO5 pin 8, RX GPIO6 pin 10 (115200 8N1), the console.
#
# A test ends with its semihosting exit() (SYS_EXIT): with no GDB connected
# OpenOCD exits with the test's exit code, which is checked against the
# RESULT line.
#
# An ELF older than any port/board/test source is refused (exit 2).
#
# Exit: 0 PASS, 1 FAIL, 2 no such test / stale build, 3 TIMEOUT,
#       4 OPENOCD DIED, 5 NO EXIT (RESULT printed, no semihosting exit).
#
# Probe: the DAPLink (0d28:0204, jh7110_daplink.cfg) or the Raspberry Pi
#        "JTAG probe on Pico" (2e8a:000c, jh7110_picoprobe.cfg), whichever is
#        plugged in (the DAPLink if both are). The JTAG probe on Pico is
#        selected by its serial number, read from sysfs by its USB product
#        name: the Pico 2's Debug Probe has the same VID:PID.
#
# Env:  BUILD=<dir>      the CMake build directory  (default: test/build-vf2)
#       OPENOCD=<path>   a specific OpenOCD
#       VF2_PROBE=daplink|picoprobe   force the probe (default: detected)
# -----------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
BUILD="${BUILD:-$ROOT/test/build-vf2}"

list_tests () {
  echo "tests built for visionfive2-lite:"
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
SECS="${2:-600}"

ELF="$BUILD/test/${APP}-hwd"
if [[ ! -f "$ELF" ]]; then
  echo "hw.sh: no such test: $APP" >&2
  list_tests >&2
  exit 2
fi

# Never run a stale image: an ELF older than any port or board source, or
# than its own test's sources, is refused (it happened: a fix was "tested"
# on the board with an old build). Another test's edit does not count.
STALE="$(find "$ROOT/src" "$ROOT/include" "$HERE" \
  "$ROOT/test/visionfive2-lite/$APP" "$ROOT/test/visionfive2-lite/include" "$ROOT/test/visionfive2-lite/src" \
  -type f -newer "$(readlink -f "$ELF")" \( -name '*.cpp' -o -name '*.c' -o -name '*.S' -o -name '*.h' -o -name '*.hpp' -o -name '*.ld' \) 2>/dev/null | head -3)"
if [[ -n "$STALE" ]]; then
  echo "hw.sh: $ELF is older than its sources -- rebuild first:" >&2
  echo "$STALE" | sed 's/^/  /' >&2
  exit 2
fi

# The entry point, from the ELF header.
NM="$(ls -d "$HOME"/.local/xPacks/@xpack-dev-tools/riscv-none-elf-gcc/*/.content/bin/riscv-none-elf-readelf 2>/dev/null | sort -V | tail -1)"
NM="${NM:-riscv-none-elf-readelf}"
ENTRY="$("$NM" -h "$ELF" | awk '/Entry point address/ { print $4 }')"
# The port's "no debugger" flag (src/trap.cpp), read back if a run times out.
ABSENT="$("${NM%readelf}nm" "$ELF" | awk '/ riscv_semihosting_absent$/ { print "0x" $1 }')"
# Where harts 2..4 wait while the test runs on hart 1 (src/board.cpp).
PARK="$("${NM%readelf}nm" "$ELF" | awk '/ riscv_board_park$/ { print "0x" $1 }')"
[[ -n "$PARK" ]] || { echo "hw.sh: no riscv_board_park in $ELF -- rebuild" >&2; exit 2; }

# How many U74 harts the image drives: an SMP image has the port's release
# slots, riscv_secondary_boot[OS_NCPU] of 3 XLEN words (startup.S).
read -r SLOTS SLOTS_SIZE < <("${NM%readelf}nm" -S "$ELF" | awk '/ riscv_secondary_boot$/ { print "0x" $1, "0x" $2 }')
NCPU=1
if [[ -n "${SLOTS:-}" ]]; then
  NCPU=$(( SLOTS_SIZE / 24 ))
fi
HARTS=""; for (( h = 1; h <= NCPU; h++ )); do HARTS="$HARTS $h"; done
SECONDARIES=""; for (( h = 2; h <= NCPU; h++ )); do SECONDARIES="$SECONDARIES $h"; done

# Machine interrupts are switched off (mie = 0, mstatus.MIE = 0) before any
# hart is resumed. Measured 2026-11-07: a hart halted in the middle of the
# previous test keeps its interrupt enables, and its CLINT timer is long
# overdue -- resumed on riscv_board_park it took the interrupt at once and
# ran the NEW image's trap handler and tick before _start, every run; in
# some runs that left the kernel lock smp_klock held by CPU 0 (.data is not
# re-initialised for a RAM image), and CPUs 1..3 then waited for it forever
# ("CPU n NOT RUNNING", smp-test2 workers with 0 beats). A hart that is not
# on the park after the 100 ms is reported in the log.
#
# After the load, for every hart the image drives: M-mode, a short run on
# riscv_board_park, a plain halt (so no hart starts from a state left by the
# previous session's semihosting ebreak -- see the header), semihosting on.
# SMP: the release slots are cleared (the DDR keeps the previous run's, and
# a stale magic would release a hart before CPU 0 has set it up), harts
# 2..NCPU start at _start, where the port parks them, then hart 1.
START_ARGS=()
for h in $HARTS; do
  START_ARGS+=(-c "targets jh7110.cpu$h" -c "reg priv 3" \
               -c "reg mie 0" \
               -c "reg mstatus [format 0x%x [expr {[dict get [get_reg mstatus] mstatus] & ~0x8}]]" \
               -c "reg pc $PARK" -c "resume" -c "sleep 100" -c "halt" \
               -c "if {[dict get [get_reg pc] pc] != $PARK} { echo \"HW.SH PARK FAILED cpu$h: pc=[dict get [get_reg pc] pc] mcause=[dict get [get_reg mcause] mcause]\" }" \
               -c "arm semihosting enable")
done
if (( NCPU > 1 )); then
  START_ARGS+=(-c "targets jh7110.cpu1" \
               -c "write_memory $SLOTS 64 [lrepeat $(( SLOTS_SIZE / 8 )) 0]")
  for h in $SECONDARIES; do
    START_ARGS+=(-c "targets jh7110.cpu$h" -c "reg pc $ENTRY" -c "resume")
  done
fi
START_ARGS+=(-c "targets jh7110.cpu1" -c "reg pc $ENTRY" -c "resume")

OCD="${OPENOCD:-$(ls -d "$HOME"/.local/xPacks/@xpack-dev-tools/openocd/*/.content/bin/openocd 2>/dev/null | sort -V | tail -1)}"
OCD="${OCD:-openocd}"
SCRIPTS_ARG=()
if [[ "$OCD" == *"/xPacks/"* ]]; then
  SCRIPTS_ARG=(-s "$(dirname "$(dirname "$OCD")")/openocd/scripts")
fi

# The probe (see the header).
usb_present () {
  local d
  for d in /sys/bus/usb/devices/*; do
    [[ -f "$d/idVendor" && "$(cat "$d/idVendor")" == "$1" && "$(cat "$d/idProduct")" == "$2" ]] && return 0
  done
  return 1
}
picoprobe_serial () {
  local d
  for d in /sys/bus/usb/devices/*; do
    [[ -f "$d/idVendor" && "$(cat "$d/idVendor")" == 2e8a && "$(cat "$d/idProduct")" == 000c ]] || continue
    [[ "$(cat "$d/product" 2>/dev/null)" == "JTAG probe on Pico"* ]] && { cat "$d/serial"; return; }
  done
}
PROBE="${VF2_PROBE:-}"
if [[ -z "$PROBE" ]]; then
  if usb_present 0d28 0204; then
    PROBE=daplink
  elif [[ -n "$(picoprobe_serial)" ]]; then
    PROBE=picoprobe
  else
    PROBE=daplink
  fi
fi
case "$PROBE" in
  daplink|picoprobe) ;;
  *) echo "hw.sh: VF2_PROBE must be daplink or picoprobe, not '$PROBE'" >&2; exit 2 ;;
esac
PROBE_CFG="$HERE/jh7110_$PROBE.cfg"
if [[ "$PROBE" == picoprobe && -z "${PICOPROBE_SERIAL:-}" ]]; then
  PICOPROBE_SERIAL="$(picoprobe_serial)"
  export PICOPROBE_SERIAL
fi

LOGS="$BUILD/.hw-logs"; mkdir -p "$LOGS"
LOG="$LOGS/${APP}.log"
rm -f "$LOG"

echo "== VisionFive 2 Lite : $APP (entry $ENTRY, $NCPU hart(s):$HARTS, probe $PROBE${PICOPROBE_SERIAL:+ $PICOPROBE_SERIAL}) =="

# The attach is retried, as in the Milk-V Duo's runner (where a probe's
# second attach read a garbage scan chain every other time). A failed attach
# is recognised in the log before the core is examined, and OpenOCD is
# restarted at once rather than left to time out.
ATTACH_TRIES=3
# How long a test that printed its RESULT gets to reach its semihosting exit.
EXIT_WAIT=20
attach_failed () {
  grep -qE 'Examination failed|dtmcontrol is 0|Target not examined|load_image.*failed|Failed to write memory' "$LOG" 2>/dev/null \
    && ! grep -q 'Examined RISC-V core' "$LOG" 2>/dev/null
}

# HW_RESET=1: `reset halt; sleep 3000` before the load (the default is a
# plain halt). Measured 2026-11-06: after `reset halt` hart 1 was sometimes
# found stopped by an ebreak of its own (dcsr.cause 1 before the load), and
# in exactly those runs the debug module never reported a semihosting halt.
RESET_ARGS=()
if [[ "${HW_RESET:-0}" == 1 ]]; then
  RESET_ARGS=(-c "reset halt" -c "sleep 3000")
fi

waited=0 rc=2
for (( attempt = 1; attempt <= ATTACH_TRIES; attempt++ )); do
  rm -f "$LOG"
  "$OCD" "${SCRIPTS_ARG[@]}" \
    -f "$PROBE_CFG" \
    -c "init" \
    "${RESET_ARGS[@]}" \
    -c "foreach n {2 3 4 1} { targets jh7110.cpu\$n; halt }" \
    -c "load_image \"$ELF\" 0 elf" \
    "${START_ARGS[@]}" \
    > >(tee "$LOG") 2>&1 &
  OCD_PID=$!


  waited=0 rc=2 retry=0
  while (( waited < SECS )); do
    # The end of a test is its semihosting exit (hw_result::ok/fail, the
    # suites' wrapper, the port's fault report all end in SYS_EXIT). With no
    # GDB connected -- this script runs OpenOCD alone -- OpenOCD handles
    # SYS_EXIT by calling exit(code) itself (semihosting_common.c): OpenOCD
    # terminates with the test's exit code and prints nothing. The RESULT
    # line comes just before it; an OpenOCD that ends without one is checked
    # for a failed attach first, below.
    if grep -q 'RESULT: \(PASS\|FAIL\)' "$LOG" 2>/dev/null; then
      # Give the program time to reach its exit; do NOT cut it short: a
      # session killed mid-semihosting leaves the hart debug-halted on the
      # ebreak and the debug module mid-conversation.
      for (( x = 0; x < EXIT_WAIT; x++ )); do
        kill -0 "$OCD_PID" 2>/dev/null || break
        sleep 1
      done
      break
    fi
    if attach_failed; then retry=1; break; fi
    if ! kill -0 "$OCD_PID" 2>/dev/null; then rc=4; break; fi
    sleep 1; waited=$((waited + 1))
  done

  # A clean OpenOCD shutdown (SIGTERM), never a SIGKILL mid-transaction.
  stopped_by_us=0
  if kill -0 "$OCD_PID" 2>/dev/null; then
    stopped_by_us=1
    # Before stopping a run that is still going, ask the live OpenOCD (Tcl
    # port 6666, commands end with 0x1a) where hart 1 is, so a hang can be
    # located afterwards: the answer goes into the log.
    if [[ -z "$(grep -m1 'RESULT: \(PASS\|FAIL\)' "$LOG" 2>/dev/null)" ]]; then
      {
        exec 3<>/dev/tcp/127.0.0.1/6666 &&
        printf 'targets jh7110.cpu1; halt; set r ""; foreach n {pc mcause mepc mtval ra sp mstatus dcsr} { append r " $n=[dict get [get_reg $n] $n]" }; append r " semihosting_absent=[read_memory '"$ABSENT"' 8 1]"; echo "HW.SH TIMEOUT STATE:$r"\x1a' >&3 &&
        timeout 15 head -c 1 <&3 >/dev/null
        exec 3<&- 3>&-
      } 2>/dev/null
      sleep 1
    fi
    kill -TERM "$OCD_PID" 2>/dev/null
    for (( x = 0; x < 5; x++ )); do
      kill -0 "$OCD_PID" 2>/dev/null || break
      sleep 1
    done
    kill -0 "$OCD_PID" 2>/dev/null && kill -KILL "$OCD_PID" 2>/dev/null
  fi
  wait "$OCD_PID" 2>/dev/null
  ocd_status=$?
  sleep 1   # let tee (the log) catch up with what OpenOCD wrote last

  if (( retry )) || { [[ $rc -eq 4 ]] && attach_failed; }; then
    if (( attempt < ATTACH_TRIES )); then
      echo "-- attach $attempt failed (scan chain), retrying"
      rc=2
      continue
    fi
    rc=4
  fi
  break
done

# The verdict. OpenOCD's console is block-buffered on a pipe, so it is read
# only now, after OpenOCD has gone. Both halves count: the RESULT line and
# the semihosting exit code -- OpenOCD's own exit status when it ended by
# itself (SYS_EXIT, no GDB), or the "application exited ..." line OpenOCD
# prints instead when a GDB is connected.
exit_code=""
if (( ! stopped_by_us )) && grep -q 'RESULT: \(PASS\|FAIL\)' "$LOG" 2>/dev/null; then
  exit_code="$ocd_status"
elif grep -q 'application exited normally' "$LOG" 2>/dev/null; then
  exit_code=0
elif grep -q 'application exited with' "$LOG" 2>/dev/null; then
  exit_code="$(grep -oE 'application exited with -?[0-9]+' "$LOG" | tail -1 | grep -oE -- '-?[0-9]+$')"
fi
result=""
grep -q 'RESULT: PASS' "$LOG" 2>/dev/null && result=PASS
grep -q 'RESULT: FAIL' "$LOG" 2>/dev/null && result=FAIL

if [[ -n "$result" ]]; then
  if [[ -z "$exit_code" ]]; then
    rc=5                                    # verdict printed, never exited
  elif [[ "$result" == PASS && "$exit_code" == 0 ]]; then
    rc=0
  else
    rc=1
  fi
elif [[ -n "$exit_code" ]]; then
  rc=1                                      # exited without a RESULT line
elif [[ $rc -eq 2 ]]; then
  rc=3
fi

# Keep every run's log (the next run of the same test would overwrite it),
# and show where a timed-out run was stopped.
cp -f "$LOG" "$LOGS/${APP}-$(date +%Y%m%d-%H%M%S).log" 2>/dev/null
grep -h 'HW.SH TIMEOUT STATE' "$LOG" 2>/dev/null | tail -1

printf '\n%-24s ' "$APP"
case "$rc" in
  0) echo "PASS  (exit 0, ${waited}s)" ;;
  1) echo "FAIL  (RESULT ${result:-none}, exit ${exit_code:-none}; see $LOG)" ;;
  4) echo "OPENOCD DIED  (see $LOG)" ;;
  5) echo "NO EXIT  (RESULT $result but no semihosting exit; see $LOG)" ;;
  *) echo "TIMEOUT after ${SECS}s  (see $LOG)" ; rc=3 ;;
esac
# 0 PASS, 1 FAIL, 2 no such test, 3 TIMEOUT, 4 OPENOCD DIED, 5 NO EXIT
# (hw-all.sh tells them apart; CTest only needs zero / non-zero).
exit "$rc"
