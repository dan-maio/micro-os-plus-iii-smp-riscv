#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# qemu.sh -- run the WeAct RP2350B (Hazard3) tests on QEMU virt.
#
# QEMU does not model the RP2350. The `qemu` images link the port against the
# RV32 virt stand-in (micro-os-plus::riscv-qemu-virt32: Hazard3 code, no FPU)
# and run on qemu-system-riscv32 -- with two harts for an SMP image. The
# runner is the Milk-V Duo's, which picks the emulator, the CPU model and the
# hart count from the image itself.
# -----------------------------------------------------------------------------
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export BOARD="${BOARD:-pico2-rp2350b-psram}"
exec "$HERE/../milkv-duo/qemu.sh" "$@"
