#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# wait-power-cycle.sh -- ask for a hand power-cycle of the Milk-V Duo, detect
# that it happened, then wait for the board to boot.
#
#     test/boards/milkv-duo/wait-power-cycle.sh [why]
#
# After a stuck run the board is reset ELECTRICALLY, by hand (unplug/replug
# the Duo's USB-C, or pin 30 RUN to 3V3). This script:
#
#   1. prints the request;
#   2. detects the power-up: the minimal fip's BL2 (built with USB_PULL=y,
#      as the current one is) enumerates on the PC as 3346:1000 "USB Com
#      Port" for ~3 s on every boot. If that device is present when the
#      script starts, it waits for it to go away first, so only a NEW
#      appearance counts;
#   3. waits POWERUP_WAIT seconds (default 8, kept within 5..10) for the boot
#      to finish (BL2: clocks, DDR, UART4, JTAG pinmux; OpenSBI parks the
#      hart) before anything attaches.
#
# Env:  POWERUP_WAIT=<s>   wait after the power-up is seen (5..10, default 8)
#       DETECT_SECS=<s>    how long to wait for the power-cycle (default 600)
#       DETECT=usb|none    usb: detect 3346:1000 (default); none: a fip built
#                          with USB_PULL=n is not visible on USB -- then the
#                          script waits for ENTER on a terminal instead
#
# Exit: 0 power-cycle seen and wait done, 1 not seen within DETECT_SECS.
# -----------------------------------------------------------------------------
set -uo pipefail

WHY="${1:-}"
POWERUP_WAIT="${POWERUP_WAIT:-8}"
if (( POWERUP_WAIT < 5 )); then POWERUP_WAIT=5; fi
if (( POWERUP_WAIT > 10 )); then POWERUP_WAIT=10; fi
DETECT_SECS="${DETECT_SECS:-600}"
DETECT="${DETECT:-usb}"

duo_on_usb () {
  lsusb -d 3346:1000 >/dev/null 2>&1
}

echo
echo "************************************************************"
echo "  POWER-CYCLE THE MILK-V DUO NOW (unplug/replug its USB-C)"
[[ -n "$WHY" ]] && echo "  reason: $WHY"
echo "************************************************************"

if [[ "$DETECT" == "none" ]]; then
  if [[ -t 0 ]]; then
    read -r -p "  press ENTER after the power-cycle... " _
  else
    echo "wait-power-cycle.sh: DETECT=none needs a terminal" >&2
    exit 1
  fi
else
  t0=$(date +%s)
  # Only a new appearance counts: if the BL2 device is there now, let it go.
  while duo_on_usb; do
    (( $(date +%s) - t0 > DETECT_SECS )) && break
    sleep 0.5
  done
  while ! duo_on_usb; do
    if (( $(date +%s) - t0 > DETECT_SECS )); then
      echo "wait-power-cycle.sh: no power-up seen in ${DETECT_SECS}s" >&2
      exit 1
    fi
    sleep 0.5
  done
  echo "  power-up seen (BL2 on USB as 3346:1000)"
fi

echo "  waiting ${POWERUP_WAIT}s for the Duo to boot..."
sleep "$POWERUP_WAIT"
echo "  board ready"
exit 0
