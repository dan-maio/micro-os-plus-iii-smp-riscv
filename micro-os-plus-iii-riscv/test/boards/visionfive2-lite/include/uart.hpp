/*
 * uart.hpp -- the VisionFive 2 Lite console: UART0 (DesignWare APB 8250).
 *
 *   jh7110.dtsi  uart0: serial@10000000 { compatible = "snps,dw-apb-uart";
 *                reg-shift = <2>; reg-io-width = <4>; }
 *   pins         GPIO5 = TX, GPIO6 = RX (the 40-pin header's debug UART),
 *                set up by the SPL / U-Boot, 115200 8N1
 *
 * Polled, blocking transmit. On a hardware image (HW_BUILD + SEMIHOST) every
 * write is ALSO sent over semihosting: hw.sh reads the verdict from
 * OpenOCD's log.
 *
 * Copyright (c) 2026 Dan. MIT license.
 */
#pragma once

#include <cstddef>
#include <cstdint>

// The board contract (micro-os-plus::test-support, board-contract.cpp).
#define PORT_BANNER_LONG "StarFive VisionFive 2 Lite (JH-7110S, SiFive U74, RV64GC)"
#define PORT_BANNER_SHORT "VisionFive 2 Lite"
#define PORT_BANNER_ISA "RV64GC"
#define PORT_BANNER_CPU "U74"

namespace uart
{
  // The divisor U-Boot programmed is kept; `baud` is accepted for the
  // contract only.
  void
  init (std::uint32_t baud);

  void
  put_char (char c);

  void
  write (const char* s);

  // Exactly n bytes; '\n' is sent as "\r\n".
  void
  write (const char* s, std::size_t n);
} // namespace uart
