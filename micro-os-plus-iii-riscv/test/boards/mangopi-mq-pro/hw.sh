#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# hw.sh -- run one MangoPi MQ-Pro test on the board, over xfel only.
#
#     test/boards/mangopi-mq-pro/hw.sh            list the tests
#     test/boards/mangopi-mq-pro/hw.sh <app>      run one test
#
# The board must be in FEL mode: unplug the USB-C OTG cable, remove the
# microSD card, plug it back in.  xfel initializes DDR, writes the flat image
# at 0x40000000 and jumps to it.
#
# UART0 (PB8/PB9) is LEFT ENTIRELY TO THE USER: this script never opens,
# configures or reads the serial port.  The test's console output goes there
# for you to watch with your own terminal.
#
# The verdict is exchanged through the battery-backed RTC general-purpose
# registers, which survive the reset and are readable over FEL:
#
#     RTC GP_DATA3 (0x0709010c) = 0x4d515052 ("MQPR")
#     RTC GP_DATA4 (0x07090110) = 0 PASS, 1 FAIL, 2 SKIP
#
# Every test ends with a reset to FEL: hw_result::ok/fail, a returning
# os_main (through the port's _Exit hook), and a trap (through the port's
# fault hook) all call riscv_board_test_finish(), which records the verdict
# and watchdog-resets the SoC.  This script additionally issues an explicit
# `xfel reset` before and after each test, so every run starts and ends from
# a clean FEL state.
#
# Exit: 0 PASS (or SKIP), 1 FAIL, 2 no such test / not in FEL / bad reset,
#       3 TIMEOUT (the test did not reset), 4 xfel error,
#       5 the test reset but left no/invalid RTC verdict.
#
# Env:  BUILD=<dir>    the CMake build directory (default: test/build)
#       SECS=<n>      per-test timeout (default: 180)
#       NORESET=1     do not reset before the run: the board is already in FEL
#                     (the BROM boots an inserted microSD card after a reset,
#                     so a card-present test is started with NORESET=1 after
#                     putting the board in FEL from the card's own image)
# -----------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
BUILD="${BUILD:-$ROOT/test/build}"
SECS="${SECS:-180}"

RESULT_MAGIC=0x4d515052
RESULT_REG=0x0709010C
RESULT_CODE=0x07090110

# The console log the test kept in RAM (see boards/<board>/include/blackbox.hpp):
# magic 'BBLG', then length, then the text.  Read back over xfel -- the UART is
# never opened.
BLACKBOX_BASE=0x58000000
BLACKBOX_MAX=65536
# xfel takes plain addresses, so compute the header fields here.
BLACKBOX_LEN_ADDR="$(printf '0x%08x' $((BLACKBOX_BASE + 4)))"
BLACKBOX_TEXT_ADDR="$(printf '0x%08x' $((BLACKBOX_BASE + 16)))"

wait_fel () {
  local n="${1:-60}"
  local i
  for ((i = 0; i < n; ++i)); do
    if timeout 1 xfel version >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.2
  done
  return 1
}

list_tests () {
  echo "tests built for mangopi-mq-pro:"
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
if [[ $# -ge 2 ]]; then
  SECS="$2"
fi

ELF="$BUILD/test/${APP}-hwd"
if [[ ! -f "$ELF" ]]; then
  echo "hw.sh: no such test: $APP" >&2
  list_tests >&2
  exit 2
fi

# Never run a stale image.
STALE="$(find "$ROOT/src" "$ROOT/include" "$HERE" \
  "$ROOT/test/mangopi-mq-pro/$APP" "$ROOT/test/mangopi-mq-pro/include" \
  -type f -newer "$(readlink -f "$ELF")" \
  \( -name '*.cpp' -o -name '*.c' -o -name '*.S' -o -name '*.h' \
     -o -name '*.hpp' -o -name '*.ld' \) 2>/dev/null | head -3)"
if [[ -n "$STALE" ]]; then
  echo "hw.sh: $ELF is older than its sources -- rebuild first:" >&2
  echo "$STALE" | sed 's/^/  /' >&2
  exit 2
fi

command -v xfel >/dev/null 2>&1 || { echo "hw.sh: xfel not found" >&2; exit 2; }

# FEL must answer.
if ! timeout 5 xfel version >/dev/null 2>&1; then
  cat >&2 <<EOF
hw.sh: the board is not in FEL.

  Unplug the USB-C OTG cable, remove the microSD card, plug it back into
  the OTG port, then retry.  A test that is still running never returns to
  the boot ROM by itself; with no boot media the BROM comes back in FEL.
EOF
  exit 2
fi

# Every test starts from a clean, xfel-reset system -- unless NORESET=1, for a
# board that must keep its microSD card (the BROM would boot it instead).
if [[ "${NORESET:-0}" != "1" ]]; then
  timeout 5 xfel reset >/dev/null 2>&1 || true
  if ! wait_fel 60; then
    echo "hw.sh: the board did not come back to FEL after xfel reset" >&2
    echo "       (is the microSD card removed? use NORESET=1 to keep it)" >&2
    exit 2
  fi
fi

# Invalidate the verdict before the run.  After xfel reset, in case the BROM
# clears the RTC registers.
xfel write32 "$RESULT_REG" 0 >/dev/null 2>&1 || true
xfel write32 "$RESULT_CODE" 0 >/dev/null 2>&1 || true

# The toolchain's objcopy/readelf.
TOOL="$(ls -d "$HOME"/.local/xPacks/@xpack-dev-tools/riscv-none-elf-gcc/*/.content/bin 2>/dev/null | sort -V | tail -1)"
OBJCOPY="${TOOL:+$TOOL/}riscv-none-elf-objcopy"
READELF="${TOOL:+$TOOL/}riscv-none-elf-readelf"
command -v "$OBJCOPY" >/dev/null 2>&1 || OBJCOPY=riscv-none-elf-objcopy
command -v "$READELF" >/dev/null 2>&1 || READELF=riscv-none-elf-readelf

LOGS="$BUILD/.hw-logs"
mkdir -p "$LOGS"
BIN="$LOGS/${APP}.bin"
rm -f "$BIN"

ENTRY="$("$READELF" -h "$ELF" | awk '/Entry point address/ { print $4 }')"
"$OBJCOPY" -O binary "$ELF" "$BIN" || { echo "hw.sh: objcopy failed" >&2; exit 4; }

echo "== MangoPi MQ-Pro : $APP (entry $ENTRY; UART untouched) =="

xfel ddr d1 || { echo "hw.sh: xfel ddr failed" >&2; exit 4; }
xfel write 0x40000000 "$BIN" || { echo "hw.sh: xfel write failed" >&2; exit 4; }

timeout 5 xfel exec "$ENTRY"
exec_rc=$?
if [[ $exec_rc -ne 0 && $exec_rc -ne 124 ]]; then
  echo "hw.sh: xfel exec returned $exec_rc" >&2
fi

# The test resets to FEL itself (PASS, FAIL, return or trap).  Wait for it.
fel=0
start=$SECONDS
while (( SECONDS - start < SECS )); do
  if timeout 1 xfel version >/dev/null 2>&1; then
    fel=1
    break
  fi
  sleep 0.5
done

if (( ! fel )); then
  printf '%-24s TIMEOUT after %ss -- the test did not reset.\n' "$APP" "$SECS"
  printf '                         Power-cycle the board (SD out) and retry.\n'
  exit 3
fi

magic="$(xfel read32 "$RESULT_REG" 2>/dev/null | tr -d '\r' | awk '{print $NF}')"
code="$(xfel read32 "$RESULT_CODE" 2>/dev/null | tr -d '\r' | awk '{print $NF}')"

# Dump the RAM console log, if the board kept one.  DDR must be initialised
# again: the test's reset took the controller down with it.
LOG_TEXT=""
if xfel ddr d1 >/dev/null 2>&1; then
  bb_magic="$(xfel read32 "$BLACKBOX_BASE" 2>/dev/null | tr -d '\r' | awk '{print $NF}')"
  if [[ -n "$bb_magic" ]] && (( bb_magic == 0x42424C47 )); then
    # The text is NUL-terminated as it is written, so cutting at the first NUL
    # gives the whole log even if the header's length word is still dirty in
    # the D-cache at reset time.
    bb_file="$(mktemp)"
    if xfel read "$BLACKBOX_TEXT_ADDR" "$BLACKBOX_MAX" "$bb_file" >/dev/null 2>&1; then
      LOG_TEXT="$(python3 - "$bb_file" <<'PYEOF'
import sys
data = open(sys.argv[1], "rb").read()
end = data.find(b"\0")
if end < 0:
    end = len(data)
sys.stdout.write(data[:end].decode("utf-8", "replace").replace("\r", ""))
PYEOF
)"
    fi
    rm -f "$bb_file"
    LOG_TEXT="${LOG_TEXT:-[blackbox: empty]}"
  else
    LOG_TEXT="[blackbox: no log (DDR did not keep it, or the image did not write one)]"
  fi
fi

# Leave a clean FEL for the next test.
timeout 5 xfel reset >/dev/null 2>&1 || true
if ! wait_fel 60; then
  echo "hw.sh: warning: no FEL after the final xfel reset" >&2
fi

rc=0
result=""
if [[ -z "$magic" || -z "$code" ]]; then
  rc=5
  result="NO RTC RESULT"
else
  magic=$((magic))
  code=$((code))
  if (( magic != RESULT_MAGIC )); then
    rc=5
    result="BAD RTC MAGIC"
  elif (( code == 0 )); then
    rc=0
    result=PASS
  elif (( code == 1 )); then
    rc=1
    result=FAIL
  elif (( code == 2 )); then
    rc=0
    result=SKIP
  else
    rc=1
    result="FAIL (code $code)"
  fi
fi

printf '%-24s %-20s\n' "$APP" "$result"
if [[ -n "${LOG_TEXT:-}" ]]; then
  echo "---- console log (from RAM, read over xfel) ----"
  printf '%s\n' "$LOG_TEXT"
  echo "---- end of log ----"
fi
exit "$rc"
