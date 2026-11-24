#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# qemu.sh -- run the Milk-V Duo's tests emulated.
#
#     test/boards/milkv-duo/qemu.sh            run every test, one at a time
#     test/boards/milkv-duo/qemu.sh <app>      run one
#
# QEMU does not model the CV1800B: the `qemu` image of each test is built
# against QEMU's virt machine (tests.cmake), RV64GC, 128 MiB, no firmware --
# the image is the reset vector. The console is UART0 on stdio, semihosting
# is on (the verdict ends the run through SYS_EXIT).
#
# Verdict: the exit code AND the RESULT line must agree.
#
# Env:  BUILD=<dir>   the CMake build directory   (default: test/build)
#       QEMU=<path>   a specific qemu-system-riscv64
#       SECS=<n>      per-test timeout             (default: 120)
# -----------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
BUILD="${BUILD:-$ROOT/test/build}"
SECS="${SECS:-120}"

QBIN="$(ls -d "$HOME"/.local/xPacks/@xpack-dev-tools/qemu-riscv/*/.content/bin 2>/dev/null | sort -V | tail -1)"
READELF="$(ls -d "$HOME"/.local/xPacks/@xpack-dev-tools/riscv-none-elf-gcc/*/.content/bin/riscv-none-elf-readelf 2>/dev/null | sort -V | tail -1)"
READELF="${READELF:-riscv-none-elf-readelf}"
NM="${READELF%readelf}nm"

LOGS="$BUILD/.qemu-logs"; mkdir -p "$LOGS"

run_one () {
  local app="$1"
  # The harness build names images *.elf; the port's own build does not.
  local elf="$BUILD/test/${app}-qemu.elf"
  [[ -f "$elf" ]] || elf="$BUILD/test/${app}-qemu"
  if [[ ! -f "$elf" ]]; then
    echo "qemu.sh: no such image: $elf (build first)" >&2
    return 2
  fi
  local log="$LOGS/${app}.log"
  echo "== QEMU virt (${BOARD:-mangopi-mq-pro} tests) : $app =="
  # The image says which hart it is for: ELF32 -> an RV32 hart without an
  # FPU and with the Hazard3 extensions; ELF64 -> RV64GC.
  local q cpu
  if "$READELF" -h "$elf" | grep 'Class:.*ELF32' > /dev/null; then
    q="${QEMU:-${QBIN:+$QBIN/}qemu-system-riscv32}"
    cpu="rv32,f=false,d=false,zfa=false,zba=true,zbb=true,zbs=true,zbkb=true,zcb=true,zcmp=true"
  else
    q="${QEMU:-${QBIN:+$QBIN/}qemu-system-riscv64}"
    cpu="rv64"
  fi
  # An SMP image (it carries the secondary-hart park, startup.S) runs on as
  # many harts as it was built for (riscv_secondary_boot is 3 XLEN words
  # per hart); any other image on one -- with more, its other harts would
  # run the start-up too.
  # (No `grep -q` on these pipes: with pipefail, grep -q exiting at the first
  # match kills the producer with SIGPIPE and the test reads as false --
  # intermittently, depending on whether nm had finished. Measured: SMP
  # images were started with -smp 1 in 3 runs of 5.)
  local smp=1
  if "$NM" "$elf" 2>/dev/null | grep ' riscv_secondary_park$' > /dev/null; then
    local words sz
    sz="$("$NM" -S "$elf" | awk '$4 == "riscv_secondary_boot" { print $2 }')"
    if "$READELF" -h "$elf" | grep 'Class:.*ELF32' > /dev/null; then words=12; else words=24; fi
    smp=$(( 16#${sz:-0} / words ))
    (( smp >= 1 )) || smp=2
  fi
  timeout "$SECS" "$q" -M virt -cpu "$cpu" -smp "$smp" -m 128M -nographic \
    -bios none -kernel "$elf" \
    -semihosting-config enable=on,target=native \
    -monitor none -serial stdio 2>&1 | tee "$log"
  local rc=${PIPESTATUS[0]}
  if [[ $rc -eq 124 ]]; then
    echo "$app: TIMEOUT after ${SECS}s"
    return 3
  fi
  if [[ $rc -eq 0 ]] && grep -q 'RESULT: PASS' "$log"; then
    echo "$app: PASS"
    return 0
  fi
  # A test that does not apply to this hart (mmu-test on RV32) says so and
  # exits 0: not a failure. CTest shows it as skipped (SKIP_RETURN_CODE 77).
  if [[ $rc -eq 0 ]] && grep -q 'RESULT: SKIP' "$log"; then
    echo "$app: SKIP"
    return 77
  fi
  echo "$app: FAIL (exit $rc, see $log)"
  return 1
}

if [[ $# -ge 1 ]]; then
  run_one "$1"
  exit $?
fi

fails=0 n=0
for elf in "$BUILD"/test/*-qemu.elf "$BUILD"/test/*-qemu; do
  [[ -e "$elf" ]] || continue
  app="$(basename "$(basename "$elf" .elf)" -qemu)"
  n=$((n + 1))
  run_one "$app"; r=$?
  if [[ $r -ne 0 && $r -ne 77 ]]; then fails=$((fails + 1)); fi
done
[[ $n -gt 0 ]] || { echo "no *-qemu images in $BUILD/test (build first)" >&2; exit 2; }
echo "== $((n - fails))/$n passed =="
[[ $fails -eq 0 ]]
