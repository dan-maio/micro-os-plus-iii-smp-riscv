#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# hw-reset.sh -- reset the Milk-V Duo over JTAG (watchdog) and wait for it to
# boot again.
#
#     test/boards/milkv-duo/hw-reset.sh [wait-seconds]
#
# 1. OpenOCD runs reset.cfg: BL2's own watchdog-reset sequence (TOP WDT,
#    ~166 ms). The attach is retried up to 4 times: with this probe, an
#    attach that follows another OpenOCD session sometimes reads a garbage
#    scan chain (IR capture 0x0003, dtmcontrol 0) and the next one works.
# 2. Wait for the reboot through the boot ROM, the SD card's minimal fip and
#    OpenSBI -- default 4 s, kept within 3..5.
# 3. Verify: attach (again with retries) and read the hart -- it must be
#    examinable. Its pc and privilege are printed.
#
# Exit: 0 reset and board back, 1 could not reach the reset, 2 the board did
#       not come back (power-cycle it).
#
# Env:  OPENOCD=<path>   a specific OpenOCD
# -----------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WAIT="${1:-4}"
if (( WAIT < 3 )); then WAIT=3; fi
if (( WAIT > 5 )); then WAIT=5; fi
TRIES=4

OCD="${OPENOCD:-$(ls -d "$HOME"/.local/xPacks/@xpack-dev-tools/openocd/*/.content/bin/openocd 2>/dev/null | sort -V | tail -1)}"
OCD="${OCD:-openocd}"
SCRIPTS_ARG=()
if [[ "$OCD" == *"/xPacks/"* ]]; then
  SCRIPTS_ARG=(-s "$(dirname "$(dirname "$OCD")")/openocd/scripts")
fi

armed=0
for (( t = 1; t <= TRIES; t++ )); do
  out="$("$OCD" "${SCRIPTS_ARG[@]}" -f "$HERE/openocd.cfg" -f "$HERE/reset.cfg" 2>&1)"
  if grep -q "watchdog armed" <<<"$out"; then
    armed=1
    break
  fi
done
if (( ! armed )); then
  echo "reset: could not attach to arm the watchdog ($TRIES tries):" >&2
  grep -E "Error" <<<"$out" | tail -3 >&2
  exit 1
fi

echo "reset: watchdog armed (attach $t); waiting ${WAIT}s for the Duo to boot"
sleep "$WAIT"

for (( t = 1; t <= TRIES; t++ )); do
  out="$("$OCD" "${SCRIPTS_ARG[@]}" -f "$HERE/openocd.cfg" \
          -c init -c halt \
          -c 'echo "hart pc=[lindex [get_reg pc] 1] priv=[lindex [get_reg priv] 1]"' \
          -c resume -c shutdown 2>&1)"
  if grep -q "^hart pc=" <<<"$out"; then
    echo "reset: board back -- $(grep '^hart pc=' <<<"$out")"
    exit 0
  fi
done

echo "reset: the board did not come back (no hart after ${WAIT}s, $TRIES attaches)." >&2
echo "       Power-cycle the Duo." >&2
exit 2
