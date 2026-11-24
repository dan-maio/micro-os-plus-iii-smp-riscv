/*
 * multicore.hpp -- start the second hart, QEMU virt.
 *
 * With -bios none QEMU starts every hart at the image entry; the port parks
 * the ones other than 0 (startup.S) and this releases hart 1 into `entry`
 * on `stack_top` -- the job the RP2350 boot ROM's FIFO handshake does on the
 * real board.
 *
 * Copyright (c) 2026 Dan. MIT license.
 */
#pragma once

#include <cstdint>

#include <riscv-smp.hpp>

namespace multicore
{
  inline void
  launch_core1 (void (*entry) (void), std::uintptr_t stack_top)
  {
    riscv_smp_release_hart (1, entry, stack_top);
  }
} // namespace multicore
