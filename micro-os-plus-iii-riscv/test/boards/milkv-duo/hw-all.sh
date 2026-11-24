#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# hw-all.sh -- run the Milk-V Duo's hardware (hwd) tests one after another.
#
#     test/boards/milkv-duo/hw-all.sh                 every built *-hwd test
#     test/boards/milkv-duo/hw-all.sh mos-test1 ...   only these, in this order
#
# Each test is one hw.sh session: OpenOCD halts the hart, loads the test into
# DDR and runs it to its RESULT line and its semihosting exit().
#
# RESET selects what happens between tests:
#
#   manual (default)  The board is reset ELECTRICALLY, BY HAND, after every
#                     test that did not end cleanly (TIMEOUT, NO EXIT,
#                     OPENOCD DIED): the script asks for the power-cycle,
#                     detects it (wait-power-cycle.sh: BL2's USB device
#                     3346:1000 appears) and waits POWERUP_WAIT s (5..10,
#                     default 8) for the boot before the next test. After a
#                     clean test it only pauses GAP seconds.
#   wdt               BL2's watchdog reset over JTAG before every test
#                     (hw-reset.sh). Measured: it brought the board back when
#                     the hart was parked in OpenSBI, NOT after a stuck test.
#   0                 no reset; a test that did not end cleanly stops the run.
#
# Before the first test, the Duo must have been freshly powered (booted from
# its SD card with the minimal fip.bin, see hw.sh).
#
# Env:  BUILD=<dir>       the build directory (default: test/build; under the
#                         harness: tests/build/<config>/platform-bin/port-tests)
#       GAP=<seconds>     pause between clean tests, 3..5 (default 4)
#       RESET=manual|wdt|0   see above (default manual)
#       POWERUP_WAIT=<s>  wait after a hand power-cycle, 5..10 (default 8)
#       SECS=<seconds>    per-test timeout (default 600)
#       KEEP_GOING=1      carry on after a TIMEOUT / OPENOCD DIED
#       OPENOCD=<path>    a specific OpenOCD (passed to hw.sh)
#
# Output: one line per test, a summary, and the logs in $BUILD/.hw-logs/.
# Exit:   0 if every test passed.
# -----------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
export BUILD="${BUILD:-$ROOT/test/build}"

GAP="${GAP:-4}"
if (( GAP < 3 )); then GAP=3; fi
if (( GAP > 5 )); then GAP=5; fi
SECS="${SECS:-600}"
KEEP_GOING="${KEEP_GOING:-0}"
RESET="${RESET:-manual}"
[[ "$RESET" == "1" ]] && RESET=wdt

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

case "$RESET" in
  manual) echo "== Milk-V Duo: ${#TESTS[@]} hwd test(s); hand power-cycle after a stuck test, ${GAP}s between clean ones ==" ;;
  wdt)    echo "== Milk-V Duo: ${#TESTS[@]} hwd test(s), watchdog reset + ${GAP}s boot before each ==" ;;
  *)      echo "== Milk-V Duo: ${#TESTS[@]} hwd test(s), ${GAP}s between tests (no reset) ==" ;;
esac
echo "   build: $BUILD"
echo

pass=0 fail=0 n=0
results=()
fresh=1   # the board is freshly booted: no pause needed before the next test
start_all=$(date +%s)

for i in "${!TESTS[@]}"; do
  app="${TESTS[$i]}"
  n=$((n + 1))

  if [[ "$RESET" == "wdt" ]]; then
    if ! bash "$HERE/hw-reset.sh" "$GAP"; then
      results+=("$(printf '%2d/%-2d %-22s %-16s' "$n" "${#TESTS[@]}" "$app" "RESET FAILED")")
      echo "${results[-1]}"
      fail=$((fail + 1))
      echo "hw-all.sh: the reset could not attach; power-cycle the Duo." >&2
      break
    fi
  elif (( ! fresh )); then
    sleep "$GAP"   # after a clean test only
  fi
  fresh=0

  t0=$(date +%s)
  bash "$HERE/hw.sh" "$app" "$SECS"
  rc=$?

  dt=$(( $(date +%s) - t0 ))
  case "$rc" in
    0) verdict="PASS" ; pass=$((pass + 1)) ;;
    1) verdict="FAIL" ; fail=$((fail + 1)) ;;
    2) verdict="MISSING" ; fail=$((fail + 1)) ;;
    3) verdict="TIMEOUT" ; fail=$((fail + 1)) ;;
    5) verdict="NO EXIT" ; fail=$((fail + 1)) ;;
    *) verdict="OPENOCD DIED" ; fail=$((fail + 1)) ;;
  esac
  results+=("$(printf '%2d/%-2d %-22s %-16s %4ss' "$n" "${#TESTS[@]}" "$app" "$verdict" "$dt")")
  echo "${results[-1]}"

  # A test that did not end cleanly leaves the board in an unknown state.
  if [[ $rc -eq 3 || $rc -eq 4 || $rc -eq 5 ]]; then
    if [[ "$RESET" == "manual" ]]; then
      if (( i + 1 < ${#TESTS[@]} )); then
        if ! bash "$HERE/wait-power-cycle.sh" "$app: $verdict"; then
          echo "hw-all.sh: no power-cycle seen; stopping." >&2
          break
        fi
        fresh=1    # freshly booted: no GAP pause before the next test
        continue
      fi
    elif [[ "$RESET" != "wdt" && "$KEEP_GOING" != "1" ]]; then
      echo
      echo "hw-all.sh: $app did not end cleanly; stopping (KEEP_GOING=1 to continue)."
      echo "           Power-cycle the Duo before re-running."
      break
    fi
  fi

done

total=$(( $(date +%s) - start_all ))
{
  echo "Milk-V Duo hwd run $(date '+%Y-%m-%d %H:%M:%S'), reset=${RESET}, gap ${GAP}s, build $BUILD"
  printf '%s\n' "${results[@]}"
  echo "== $pass passed, $fail failed, of $n run (${#TESTS[@]} requested), ${total}s =="
} | tee "$SUMMARY" | tail -1
echo "summary: $SUMMARY"

[[ $fail -eq 0 && $n -eq ${#TESTS[@]} ]]
