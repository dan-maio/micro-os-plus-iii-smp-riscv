#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# hw.sh -- run one of the CH32V307V-EVT-R1 tests on the board.
#
#     test/boards/ch32v307-evt/hw.sh            list the tests
#     test/boards/ch32v307-evt/hw.sh <app>      program it into flash and run it
#
# Probe: the EVT's on-board WCH-LinkE (1a86:8010), RISC-V mode, two-wire
# SDI. OpenOCD: the WCH (MounRiver) fork, mrs-wch-riscv-221010, with one
# patch: its wlink driver knew probe types 1-4 only, and this LinkE
# (firmware 2.10) reports 0x12 -- accepted as type 2, as the newer
# mrs-wch-riscv-230824 wlinke driver does. OpenOCD only, no GDB.
#
# The session:
#   init, reset halt
#   flash write_image erase <elf>
#                              the image is linked at the flash's 0x00000000
#                              alias (where the core starts), and that is
#                              where this OpenOCD's wch_riscv bank is
#                              (flash banks: 0x00000000, measured). The
#                              erase is the whole chip (the WCH driver has no
#                              sector erase).
#   dump_image + cmp           the flash read back and compared, segment by
#                              segment, with the ELF's LOAD file bytes on the
#                              PC (verify_image needs a work area, and the
#                              config's 0x80000000 is not RAM on this chip;
#                              gaps between segments stay erased)
#   reset halt, arm semihosting enable, resume
#
# Two traps of this OpenOCD (measured):
#   - in WCH mode every target_write_memory below 0x20000000 is treated as
#     flash data and copied into a 256-byte buffer without a bounds check
#     (riscv-013.c write_flash_data): never load_image anything there;
#     flash goes through flash write_image only.
#   - its SYS_CLOCK is OpenOCD's own CPU time (clock()); SYS_TIME is wall
#     time.
#
# Verdict: the RESULT line and the semihosting exit. OpenOCD ends itself on
# SYS_EXIT with the test's exit code. Exit codes as the other boards' hw.sh:
# 0 PASS, 1 FAIL, 2 no such test / stale build, 3 TIMEOUT, 4 OPENOCD DIED,
# 5 NO EXIT, 6 FLASH READBACK DIFFERS.
#
# Env:  BUILD=<dir>      the CMake build directory (default: test/build-ch32v307)
#       OPENOCD=<path>   the WCH OpenOCD (default ~/.local/openocd-wch/bin/openocd)
# -----------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
BUILD="${BUILD:-$ROOT/test/build-ch32v307}"
BOARD_TESTS="$ROOT/test/ch32v307-evt"

list_tests () {
  echo "tests built for ch32v307-evt:"
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

# The port sources the image links: a kernel-free image (BOARD_TEST_NO_KERNEL,
# no os_systick_handler) has only startup.S, trap.S and src/bare/ of src/.
NM="$(ls -d "$HOME"/.local/xPacks/@xpack-dev-tools/riscv-none-elf-gcc/*/.content/bin/riscv-none-elf-nm 2>/dev/null | sort -V | tail -1)"
PORT_SRC=("$ROOT/src")
if ! "${NM:-riscv-none-elf-nm}" "$ELF" 2>/dev/null | grep -q " os_systick_handler$"; then
  PORT_SRC=("$ROOT/src/startup.S" "$ROOT/src/trap.S" "$ROOT/src/bare")
fi
STALE="$(find "${PORT_SRC[@]}" "$ROOT/include" "$HERE" \
  "$BOARD_TESTS/$APP" "$BOARD_TESTS/include" "$BOARD_TESTS/src" \
  -type f -newer "$ELF" \( -name '*.cpp' -o -name '*.c' -o -name '*.S' -o -name '*.h' -o -name '*.hpp' -o -name '*.ld' \) 2>/dev/null | head -3)"
if [[ -n "$STALE" ]]; then
  echo "hw.sh: $ELF is older than its sources -- rebuild first:" >&2
  echo "$STALE" | sed 's/^/  /' >&2
  exit 2
fi

OCD="${OPENOCD:-$HOME/.local/openocd-wch/bin/openocd}"
if [[ ! -x "$OCD" ]]; then
  echo "hw.sh: no WCH OpenOCD at $OCD; set OPENOCD" >&2
  exit 4
fi
# The scripts of the installed WCH OpenOCD (interface/wlink.cfg,
# target/wch-riscv.cfg), also when OPENOCD points at a build tree.
SCRIPTS="${OPENOCD_SCRIPTS:-$HOME/.local/openocd-wch/share/openocd/scripts}"

TOOLBIN="$(ls -d "$HOME"/.local/xPacks/@xpack-dev-tools/riscv-none-elf-gcc/*/.content/bin 2>/dev/null | sort -V | tail -1)"
OBJCOPY="${TOOLBIN:+$TOOLBIN/}riscv-none-elf-objcopy"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
READELF="${TOOLBIN:+$TOOLBIN/}riscv-none-elf-readelf"
# What goes to flash: the LOAD segments' FILE bytes at their load addresses
# (the code, then .data's initial values). flash write_image writes exactly
# those; a gap between segments, or the memory-only tail of a segment, is
# not written and keeps the erased value, so the read-back compare checks
# each segment's file bytes and nothing else.
SEGS="$("$READELF" -lW "$ELF" | awk '$1 == "LOAD" && strtonum($5) > 0 && strtonum($4) < 0x20000000 { print $2, $4, $5 }')"
[[ -n "$SEGS" ]] || { echo "hw.sh: no flash segments in $ELF" >&2; exit 2; }
SIZE=0
while read -r off paddr filesz; do
  end=$(( paddr + filesz ))
  (( end > SIZE )) && SIZE=$end
done <<< "$SEGS"

echo "hw.sh: $APP -> flash ($SIZE bytes), OpenOCD $OCD"

# 1. program and read back (no run yet)
"$OCD" -s "$SCRIPTS" -f interface/wlink.cfg -f target/wch-riscv.cfg \
  -c "init" -c "reset halt" \
  -c "flash write_image erase \"$ELF\"" \
  -c "dump_image \"$WORK/back.bin\" 0x00000000 $SIZE" \
  -c "shutdown" > "$WORK/program.log" 2>&1
rc=$?
if [[ $rc -ne 0 ]]; then
  cat "$WORK/program.log" >&2
  echo "hw.sh: OPENOCD DIED while programming (rc=$rc)" >&2
  exit 4
fi
# Compare every flash segment with the read-back; 0 = identical.
compare_segments () {
  while read -r off paddr filesz; do
    dd if="$ELF" of="$WORK/seg.bin" bs=1 skip=$(( off )) count=$(( filesz )) status=none
    dd if="$WORK/back.bin" of="$WORK/seg.back" bs=1 skip=$(( paddr )) count=$(( filesz )) status=none
    if ! cmp -s "$WORK/seg.bin" "$WORK/seg.back"; then
      printf 'hw.sh: read-back differs in the segment at 0x%x (%d bytes): %d byte(s)\n' \
        $(( paddr )) $(( filesz )) "$(cmp -l "$WORK/seg.bin" "$WORK/seg.back" | wc -l)" >&2
      cmp -l "$WORK/seg.bin" "$WORK/seg.back" | head -3 >&2
      return 1
    fi
  done <<< "$SEGS"
  return 0
}
if ! compare_segments; then
  # Measured once (rtos-apis, 186 KB): one byte differed, and two new
  # read-backs of the same flash were identical to the image -- a read
  # error over the link, not a bad write. Read once more before failing.
  echo "hw.sh: reading the flash back a second time" >&2
  "$OCD" -s "$SCRIPTS" -f interface/wlink.cfg -f target/wch-riscv.cfg \
    -c "init" -c "halt" -c "dump_image \"$WORK/back.bin\" 0x00000000 $SIZE" \
    -c "shutdown" > "$WORK/readback.log" 2>&1
  if ! compare_segments; then
    echo "hw.sh: FLASH READBACK DIFFERS" >&2
    exit 6
  fi
  echo "hw.sh: second read-back identical (the first one was a read error)" >&2
fi
echo "hw.sh: flash programmed and read back identical"

# 2. run from reset with semihosting; OpenOCD ends on the test's SYS_EXIT
timeout "$SECS" "$OCD" -s "$SCRIPTS" -f interface/wlink.cfg -f target/wch-riscv.cfg \
  -c "init" -c "reset halt" -c "arm semihosting enable" -c "resume" \
  2>&1 | tee "$WORK/run.log" | grep -v "^Info \|^Warn \|^Open On-Chip\|^Licensed\|^For bug\|^\s*http\|^\[wch-rv\|^$\|semihosting is enabled"
rc=${PIPESTATUS[0]}

case $rc in
  0) echo "hw.sh: $APP PASS"; exit 0 ;;
  1) echo "hw.sh: $APP FAIL"; exit 1 ;;
  124) echo "hw.sh: $APP TIMEOUT after ${SECS}s"; exit 3 ;;
  *)
    if grep -q "RESULT:" "$WORK/run.log"; then
      echo "hw.sh: $APP NO EXIT (rc=$rc)"; exit 5
    fi
    echo "hw.sh: $APP OPENOCD DIED (rc=$rc)"; exit 4 ;;
esac
