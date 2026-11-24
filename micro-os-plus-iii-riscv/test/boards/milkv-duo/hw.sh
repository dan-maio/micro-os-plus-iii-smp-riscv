#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# hw.sh -- run one of the Milk-V Duo's tests on the board, over JTAG.
#
#     test/boards/milkv-duo/hw.sh            list the tests
#     test/boards/milkv-duo/hw.sh <app>      load it into DDR and run it
#
# THE BOARD MUST ALREADY BE BOOTED from its SD card with the minimal fip.bin
# (milkv-duo (opensbi)/output/fip.bin): it is what brings up the clocks, the
# DDR, UART4 and the JTAG pinmux, then OpenSBI parks the hart. Nothing is
# written to the SD card; the test goes into DDR only.
#
# The session, OpenOCD only (no GDB, nothing redirected):
#   init, halt                 stop the parked hart
#   reg priv 3                 the payload ran in S-mode; µOS++ runs in M-mode
#   load_image <elf>           into DDR at 0x80050000 (through the D-cache)
#   arm semihosting enable     the test's output and its SYS_EXIT verdict
#   resume <_start>
#
# There is no reset line on the header. Each test restarts the hart at
# _start, which re-initialises everything a previous test touched, so tests
# can run back to back (hw-all.sh); power-cycle only if one wedges the hart.
#
# Wiring: TDI pin 1, TDO pin 2, TMS pin 16, TCK pin 17, GND pin 18 (JTAG);
#         UART4 TX pin 4, RX pin 5 (115200 8N1) for the console.
#
# A test ends with its semihosting exit() (SYS_EXIT). With no GDB connected
# OpenOCD handles SYS_EXIT by calling exit(code) itself, silently
# (semihosting_common.c): OpenOCD's exit status IS the test's exit code. (With
# a GDB connected it prints "application exited with N" instead; both are
# read.) The code is checked against the RESULT line. After a clean exit the
# hart stays debug-halted on the exit ebreak; the next session attaches to it.
#
# An ELF older than any port/board/test source is refused (exit 2).
#
# Exit: 0 PASS, 1 FAIL, 2 no such test / stale build, 3 TIMEOUT,
#       4 OPENOCD DIED, 5 NO EXIT (RESULT printed, no semihosting exit).
#
# Env:  BUILD=<dir>      the CMake build directory  (default: test/build)
#       OPENOCD=<path>   a specific OpenOCD (one that drives the C906)
# -----------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
BUILD="${BUILD:-$ROOT/test/build}"

list_tests () {
  echo "tests built for milkv-duo:"
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
  "$ROOT/test/milkv-duo/$APP" "$ROOT/test/milkv-duo/include" "$ROOT/test/milkv-duo/src" \
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

OCD="${OPENOCD:-$(ls -d "$HOME"/.local/xPacks/@xpack-dev-tools/openocd/*/.content/bin/openocd 2>/dev/null | sort -V | tail -1)}"
OCD="${OCD:-openocd}"
SCRIPTS_ARG=()
if [[ "$OCD" == *"/xPacks/"* ]]; then
  SCRIPTS_ARG=(-s "$(dirname "$(dirname "$OCD")")/openocd/scripts")
fi

LOGS="$BUILD/.hw-logs"; mkdir -p "$LOGS"
LOG="$LOGS/${APP}.log"
rm -f "$LOG"

echo "== Milk-V Duo : $APP (entry $ENTRY) =="

# The attach is retried. With this probe, an attach that follows another
# OpenOCD session reads a garbage scan chain (IR capture 0x0003, dtmcontrol
# 0) every other time, and the next attach works -- measured on the board,
# with the cv1800 Eclipse cfg as well. A failed attach is recognised in the
# log before the core is examined, and OpenOCD is restarted at once rather
# than left to time out.
ATTACH_TRIES=3
# How long a test that printed its RESULT gets to reach its semihosting exit.
EXIT_WAIT=20
attach_failed () {
  grep -qE 'Examination failed|dtmcontrol is 0|Target not examined|load_image.*failed|Failed to write memory' "$LOG" 2>/dev/null \
    && ! grep -q 'Examined RISC-V core' "$LOG" 2>/dev/null
}

waited=0 rc=2
for (( attempt = 1; attempt <= ATTACH_TRIES; attempt++ )); do
  rm -f "$LOG"
  "$OCD" "${SCRIPTS_ARG[@]}" \
    -f "$HERE/openocd.cfg" \
    -c "init" \
    -c "halt" \
    -c "reg priv 3" \
    -c "load_image \"$ELF\" 0 elf" \
    -c "arm semihosting enable" \
    -c "resume $ENTRY" \
    > >(tee "$LOG") 2>&1 &
  OCD_PID=$!

  HOST_PID=""
  HOST_LOG="$LOGS/${APP}.host.log"

  waited=0 rc=2 retry=0
  while (( waited < SECS )); do
    # The USB device tests need the PC's half (they pass when the host sends
    # Escape): start usb-host.py only once the new image has booted and
    # finished tusb_init(), so it never opens a stale /dev/ttyACM* left by a
    # previous run while OpenOCD is still downloading the ELF over JTAG.
    if [[ -z "$HOST_PID" ]] && grep -q '\[usb\] tusb_init done' "$LOG" 2>/dev/null; then
      case "${HOST_HELPER:-1}:$APP" in
        0:*) ;;
        *:smp-test-usb-cdc-acm) python3 -I "$ROOT/test/boards/pico2/usb-host.py" cdc "$SECS" > "$HOST_LOG" 2>&1 & HOST_PID=$! ;;
        *:smp-test-usb-hid)     python3 -I "$ROOT/test/boards/pico2/usb-host.py" hid "$SECS" > "$HOST_LOG" 2>&1 & HOST_PID=$! ;;
      esac
    fi
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
  if [[ -n "$HOST_PID" ]]; then
    kill "$HOST_PID" 2>/dev/null
    wait "$HOST_PID" 2>/dev/null
    (( retry )) || sed 's/^/  /' "$HOST_LOG"
  fi

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
