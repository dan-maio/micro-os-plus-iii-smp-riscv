/*
 * riscv-amo.hpp -- where the objects the port changes with atomic
 * instructions (AMO, LR/SC) are placed.
 *
 * Not every memory takes an AMO: on the RP2350 an amoswap to the QSPI PSRAM
 * window (0x11000000) faults (mcause 7, measured), while SRAM takes them. A
 * board that moves .data/.bss to such memory (the WeAct RP2350B with
 * linker-psram.ld) must keep these objects behind. They go to sections
 * named .data.amo / .bss.amo: an ordinary linker script folds those into
 * .data / .bss with everything else (*(.data .data.*)), and linker-psram.ld
 * places them in SRAM.
 *
 * Copyright (c) 2026 Dan. MIT license.
 */
#pragma once

// An initialized object.
#define RISCV_AMO_DATA __attribute__ ((section (".data.amo")))
// A zero-initialized object.
#define RISCV_AMO_BSS __attribute__ ((section (".bss.amo")))
