/*
 * board.hpp -- QEMU virt definitions, matching the names a board's
 * board.hpp gives its tests.
 *
 * Copyright (c) 2026 Dan. MIT license.
 */
#pragma once

#include <cstdint>

namespace board
{
  inline constexpr std::uint32_t UART_BAUD = 115200U;

  inline constexpr std::uintptr_t SCRATCH_BASE = 0x87000000u;
  inline constexpr std::uintptr_t SCRATCH_SIZE = 0x00800000u;

  inline constexpr std::uint32_t CPU_HZ_NOMINAL = 0U; // not meaningful
} // namespace board
