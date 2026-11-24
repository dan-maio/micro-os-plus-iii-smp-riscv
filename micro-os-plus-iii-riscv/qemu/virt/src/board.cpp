/*
 * board.cpp -- QEMU virt start-up hooks.
 *
 * Copyright (c) 2026 Dan. MIT license.
 */

#include <riscv-board.hpp>
#include <uart.hpp>

extern "C" void
riscv_board_initialize_early (void)
{
}

extern "C" void
riscv_board_initialize (void)
{
  uart::init (115200);
}
