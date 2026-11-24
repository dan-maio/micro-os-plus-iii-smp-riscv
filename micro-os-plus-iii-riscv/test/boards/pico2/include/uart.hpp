/*
 * uart.hpp -- the Pico 2 console: UART0 (PL011) on GPIO0 (TX) / GPIO1 (RX),
 * 115200 8N1 -- the Raspberry Pi Debug Probe's UART pins.
 *
 * Copyright (c) 2026 Dan. MIT license.
 */
#pragma once

#include <cstddef>
#include <cstdint>

#define PORT_BANNER_LONG "Raspberry Pi Pico 2 (RP2350, 2x Hazard3 RV32)"
#define PORT_BANNER_SHORT "Pico 2"
#define PORT_BANNER_ISA "RV32IMAC"
#define PORT_BANNER_CPU "Hazard3"

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

  // One received byte, or -1 when the RX FIFO is empty (never blocks).
  int
  get_char (void);
} // namespace uart
