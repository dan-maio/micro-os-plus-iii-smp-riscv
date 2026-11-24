#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# hw-all.sh -- run the MangoPi MQ-Pro hardware tests one after another.
#
#     test/boards/mangopi-mq-pro/hw-all.sh                 every built *-hwd
#     test/boards/mangopi-mq-pro/hw-all.sh smp_test0 ...   only these
#
# Each test is one hw.sh session: xfel loads it at 0x40000000, it runs, and
# it resets the SoC back into FEL with the D1 watchdog (hw_result.hpp).  The
# verdict is read from the RTC GP_DATA3/4 registers over xfel; the UART is
# never opened.  The board must have no microSD card: with no boot media the
# BROM falls back to FEL after that reset.  There is no JTAG and no manual
# reset between tests.
#
# For manual, one-at-a-time runs (wait for confirmation between tests), call
# hw.sh directly instead of this script.
#
# Env:  BUILD=<dir>      build directory (default: test/build)
#       SECS=<seconds>   per-test timeout (default: 120)
#       KEEP_GOING=1     continue after a TIMEOUT / missing reset
#
# Exit: 0 if every test passed.
# -----------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
export BUILD="${BUILD:-$ROOT/test/build}"
SECS="${SECS:-120}"
KEEP_GOING="${KEEP_GOING:-0}"

if [[ $# -gt 0 ]]; then
  TESTS=("$@")
else
  TESTS=()
  for e in "$BUILD"/test/*-hwd; do
    [[ -e "$e" ]] || continue
    TESTS+=("$(basename "$e" -hwd)")
  done
fi

if [[ ${#TESTS[@]} -eq 0 ]]; then
  echo "hw-all.sh: no *-hwd images in $BUILD/test (build first)" >&2
  exit 2
fi

SUMMARY="$BUILD/.hw-logs/hw-all-$(date +%Y%m%d-%H%M%S).txt"
mkdir -p "$BUILD/.hw-logs"

echo "== MangoPi MQ-Pro: ${#TESTS[@]} hwd test(s), xfel only, no SD =="
echo "   build: $BUILD"
echo

pass=0 fail=0 n=0
results=()
start_all=$(date +%s)

for i in "${!TESTS[@]}"; do
  app="${TESTS[$i]}"
  n=$((n + 1))
  t0=$(date +%s)
  bash "$HERE/hw.sh" "$app" "$SECS"
  rc=$?
  dt=$(( $(date +%s) - t0 ))

  case "$rc" in
    0) verdict="PASS" ; pass=$((pass + 1)) ;;
    1) verdict="FAIL" ; fail=$((fail + 1)) ;;
    2) verdict="MISSING" ; fail=$((fail + 1)) ;;
    3) verdict="TIMEOUT" ; fail=$((fail + 1)) ;;
    4) verdict="XFEL ERROR" ; fail=$((fail + 1)) ;;
    5) verdict="NO RESET" ; fail=$((fail + 1)) ;;
    *) verdict="ERROR" ; fail=$((fail + 1)) ;;
  esac
  results+=("$(printf '%2d/%-2d %-24s %-14s %4ss' "$n" "${#TESTS[@]}" "$app" "$verdict" "$dt")")
  echo "${results[-1]}"

  # A test that did not end cleanly may leave the board outside FEL; stop
  # unless the caller asked to carry on.
  if [[ $rc -eq 3 || $rc -eq 4 || $rc -eq 5 ]]; then
    if [[ "$KEEP_GOING" != "1" ]]; then
      echo
      echo "hw-all.sh: $app did not end cleanly; stopping."
      echo "           Unplug USB-C, remove the SD card, plug it back into OTG,"
      echo "           then rerun with KEEP_GOING=1 to continue."
      break
    fi
  fi
done

total=$(( $(date +%s) - start_all ))
{
  echo "MangoPi MQ-Pro hwd run $(date '+%Y-%m-%d %H:%M:%S'), build $BUILD"
  printf '%s\n' "${results[@]}"
  echo "== $pass passed, $fail failed, of $n run (${#TESTS[@]} requested), ${total}s =="
} | tee "$SUMMARY" | tail -1
echo "summary: $SUMMARY"

[[ $fail -eq 0 && $n -eq ${#TESTS[@]} ]]
