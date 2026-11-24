/*
 * uart.cpp -- QEMU virt NS16550A at 0x10000000 (byte registers).
 *
 * Copyright (c) 2026 Dan. MIT license.
 */

#include <cstddef>
#include <cstdint>

#include <uart.hpp>

namespace
{
  constexpr std::uintptr_t BASE = 0x10000000u;

  inline volatile std::uint8_t&
  reg (unsigned off)
  {
    return *reinterpret_cast<volatile std::uint8_t*> (BASE + off);
  }

  void
  raw_put (char c)
  {
    while ((reg (5) & 0x20) == 0) // LSR.THRE
      {
      }
    reg (0) = static_cast<std::uint8_t> (c);
  }
} // namespace

namespace uart
{
  void
  init (std::uint32_t baud)
  {
    (void) baud;
    reg (3) = 0x03; // 8N1
    reg (2) = 0x07; // FIFOs
  }

  void
  put_char (char c)
  {
    raw_put (c);
  }

  void
  write (const char* s)
  {
    while (*s != '\0')
      {
        if (*s == '\n')
          {
            raw_put ('\r');
          }
        raw_put (*s++);
      }
  }

  void
  write (const char* s, std::size_t n)
  {
    for (std::size_t i = 0; i < n; ++i)
      {
        if (s[i] == '\n')
          {
            raw_put ('\r');
          }
        raw_put (s[i]);
      }
  }
} // namespace uart

extern "C" void
riscv_board_console_write (const char* s, std::size_t n)
{
  uart::write (s, n);
}
