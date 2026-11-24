/*
 * riscv-board.hpp -- the port's board facts for QEMU's `virt` machine
 * (qemu-system-riscv64 -M virt), the stand-in a board's `qemu` image runs on.
 *
 * QEMU does not model the CV1800B. A board whose silicon it does not model
 * builds its emulated image against `virt` instead: the same port core and
 * the same tests, with the virt machine's CLINT, UART and RAM (the Cortex-M
 * port does the same for the pico2).
 *
 *   CLINT (SiFive ACLINT)  0x02000000, 64-bit MMIO, timebase 10 MHz
 *   PLIC                   0x0C000000
 *   NS16550A UART0         0x10000000
 *   RAM                    0x80000000, -m 128M
 *
 * Copyright (c) 2026 Dan. MIT license.
 */
#pragma once

#include <cstddef>
#include <cstdint>

#include <mmu.hpp>

namespace riscv_board
{
  inline constexpr std::uintptr_t CLINT_BASE = 0x02000000u;
  inline constexpr std::uintptr_t CLINT_MSIP = CLINT_BASE + 0x0000u;
  inline constexpr std::uintptr_t CLINT_MTIMECMP = CLINT_BASE + 0x4000u;
  inline constexpr std::uintptr_t CLINT_MTIME = CLINT_BASE + 0xBFF8u;
  // Per-hart register strides (a standard CLINT).
  inline constexpr std::uintptr_t CLINT_MTIMECMP_STRIDE = 8u;
  inline constexpr std::uintptr_t CLINT_MSIP_STRIDE = 4u;
  // A 64-bit store is two stores on RV32: write the halves in the safe order.
  inline constexpr bool MTIMECMP_SPLIT32 = (__riscv_xlen == 32);
  inline constexpr bool MTIME_READABLE = true;

  // The port's clock source: the time CSR (rdtime) where the hart has it,
  // else the platform timer's MMIO mtime. Here: QEMU implements the time CSR.
  inline constexpr bool TIME_CSR = true;

  inline constexpr std::uint32_t TIMEBASE_HZ = 10000000u;

  inline constexpr std::uintptr_t PLIC_BASE = 0x0C000000u;

  // Standard Sv39: no vendor PTE attributes (bits 63..54 must be 0).
  inline constexpr std::uint64_t FLAGS_RAM = mmu::FLAGS_RAM;
  inline constexpr std::uint64_t FLAGS_DEV = mmu::FLAGS_DEV;

  inline constexpr mmu::region MMU_REGIONS[] = {
    { 0x02000000u, 0x00200000u, FLAGS_DEV }, // CLINT
    { 0x0C000000u, 0x00400000u, FLAGS_DEV }, // PLIC
    { 0x10000000u, 0x00200000u, FLAGS_DEV }, // UART0 and friends
    { 0x80000000u, 0x08000000u, FLAGS_RAM }, // 128 MiB
  };
} // namespace riscv_board

extern "C"
{
  void riscv_board_initialize_early (void);
  void riscv_board_initialize (void);
  void riscv_board_console_write (const char* s, std::size_t n);
}
