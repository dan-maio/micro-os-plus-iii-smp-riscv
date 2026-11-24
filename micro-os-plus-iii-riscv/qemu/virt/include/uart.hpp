/*
 * uart.hpp -- QEMU virt console: NS16550A UART0 at 0x10000000 (-serial).
 *
 * The same interface as a board's uart.hpp, so a board's tests compile
 * unchanged for the emulated image.
 *
 * Copyright (c) 2026 Dan. MIT license.
 */
#pragma once

#include <cstddef>
#include <cstdint>

#if __riscv_xlen == 64
#define PORT_BANNER_LONG "QEMU virt (RV64GC)"
#else
#define PORT_BANNER_LONG "QEMU virt (RV32IMAC, Hazard3 code)"
#endif
#define PORT_BANNER_SHORT "QEMU virt"
#if __riscv_xlen == 64
#define PORT_BANNER_ISA "RV64GC"
#define PORT_BANNER_CPU "rv64"
#else
#define PORT_BANNER_ISA "RV32IMAC"
#define PORT_BANNER_CPU "rv32"
#endif

namespace uart
{
  void
  init (std::uint32_t baud);

  void
  put_char (char c);

  void
  write (const char* s);

  void
  write (const char* s, std::size_t n);
} // namespace uart
