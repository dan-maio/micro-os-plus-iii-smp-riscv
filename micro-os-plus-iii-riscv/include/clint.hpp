/*
 * clint.hpp -- the core-local interruptor: machine timer and machine software
 * interrupt of hart 0.
 *
 * The addresses and the timebase are board facts (riscv-board.hpp). What is
 * an ISA fact is how they are used:
 *
 *   MTIP   the system tick. mtimecmp is compared against the platform timer,
 *          which the hart reads with `rdtime`.
 *   MSIP   the context-switch request -- the RISC-V stand-in for Cortex-M's
 *          PendSV. reschedule() raises it; the trap it causes runs the switch
 *          with interrupts masked, after any timer trap has returned.
 *
 * The Milk-V Duo's CLINT (T-Head C906) cannot be written with a 64-bit store
 * (the bus splits it and the comparator sees a torn value) and its mtime
 * register is not readable. The board says so with MTIMECMP_SPLIT32, and the
 * time comes from `rdtime`, which reads the same counter.
 *
 * Copyright (c) 2026 Dan. MIT license.
 */
#pragma once

#include <cstdint>

#include <riscv-board.hpp>
#include <riscv-csr.hpp>
#include <riscv-hart.hpp>

namespace clint
{
  inline volatile std::uint32_t&
  reg32 (std::uintptr_t addr)
  {
    return *reinterpret_cast<volatile std::uint32_t*> (addr);
  }

  // Per-hart registers: base + hart * stride (riscv-board.hpp). A standard
  // CLINT has an mtimecmp every 8 bytes and an msip word every 4.
  inline std::uintptr_t
  mtimecmp_addr (unsigned hart)
  {
    return riscv_board::CLINT_MTIMECMP
           + hart * riscv_board::CLINT_MTIMECMP_STRIDE;
  }

  inline std::uintptr_t
  msip_addr (unsigned hart)
  {
    return riscv_board::CLINT_MSIP + hart * riscv_board::CLINT_MSIP_STRIDE;
  }

  inline void
  mtimecmp_write (std::uint64_t value, unsigned hart = riscv::this_hart ())
  {
    const std::uintptr_t a = mtimecmp_addr (hart);
    if constexpr (riscv_board::MTIMECMP_SPLIT32)
      {
        // HI to all-ones first, so the comparator never sees a value lower
        // than both the old and the new one while the halves change.
        reg32 (a + 4) = 0xFFFFFFFFu;
        reg32 (a) = static_cast<std::uint32_t> (value);
        reg32 (a + 4) = static_cast<std::uint32_t> (value >> 32);
      }
    else
      {
        *reinterpret_cast<volatile std::uint64_t*> (a) = value;
      }
  }

  inline void
  timer_disarm (unsigned hart = riscv::this_hart ())
  {
    mtimecmp_write (~0ULL, hart);
  }

  // The machine software interrupt of `hart` (default: this one). Raising
  // another hart's is the inter-processor interrupt.
#if defined(RISCV_BOARD_SOFTIRQ_SIO)
  // RP2350: one SIO register for all cores, RISCV_SOFTIRQ: write 1 << h to
  // set core h's MSIP, 1 << (8 + h) to clear it; reading bit h gives the
  // flag (datasheet, SIO RISCV_SOFTIRQ). Both cores may write it at once.
  inline void
  msip_set (unsigned hart = riscv::this_hart ())
  {
    reg32 (riscv_board::CLINT_MSIP) = 1u << hart;
    __asm__ volatile("fence o, i" ::: "memory");
  }

  inline std::uint32_t
  msip_read (unsigned hart = riscv::this_hart ())
  {
    __asm__ volatile("fence o, i" ::: "memory");
    return (reg32 (riscv_board::CLINT_MSIP) >> hart) & 1u;
  }

  inline void
  msip_clear (unsigned hart = riscv::this_hart ())
  {
    reg32 (riscv_board::CLINT_MSIP) = 1u << (8u + hart);
    __asm__ volatile("fence o, i" ::: "memory");
  }
#else
  inline void
  msip_set (unsigned hart = riscv::this_hart ())
  {
    reg32 (msip_addr (hart)) = 1;
    __asm__ volatile("fence o, i" ::: "memory");
  }

  // Read MSIP back: a load from the device completes only after the earlier
  // store to it has, so this waits out a posted write.
  inline std::uint32_t
  msip_read (unsigned hart = riscv::this_hart ())
  {
    __asm__ volatile("fence o, i" ::: "memory");
    return reg32 (msip_addr (hart));
  }

  inline void
  msip_clear (unsigned hart = riscv::this_hart ())
  {
    reg32 (msip_addr (hart)) = 0;
    __asm__ volatile("fence o, i" ::: "memory");
  }
#endif

  // mtime_read() is below; now() needs it on harts without the time CSR.
  inline std::uint64_t mtime_read (void);

  // The port's clock: the time CSR where the hart implements it, else the
  // platform timer's mtime over MMIO (riscv_board::TIME_CSR). Hazard3 does
  // not implement time/timeh (RP2350 datasheet, MCOUNTEREN.TM).
  inline std::uint64_t
  now (void)
  {
    if constexpr (riscv_board::TIME_CSR)
      {
        return riscv::csr::rdtime ();
      }
    else
      {
        return mtime_read ();
      }
  }

  // The CLINT's own mtime, where the board implements it
  // (riscv_board::MTIME_READABLE). On the Milk-V Duo's C906 it does not: any
  // load from it is an access fault, 32-bit halves included -- measured on
  // the board, as the cv1800 Eclipse project had found. Never called there.
  inline std::uint64_t
  mtime_read (void)
  {
    if constexpr (riscv_board::MTIMECMP_SPLIT32)
      {
        std::uint32_t hi, lo, hi2;
        do
          {
            hi = reg32 (riscv_board::CLINT_MTIME + 4);
            lo = reg32 (riscv_board::CLINT_MTIME);
            hi2 = reg32 (riscv_board::CLINT_MTIME + 4);
          }
        while (hi != hi2);
        return (static_cast<std::uint64_t> (hi) << 32) | lo;
      }
    else
      {
        return *reinterpret_cast<volatile std::uint64_t*> (
            riscv_board::CLINT_MTIME);
      }
  }

  // mtime - rdtime. mtimecmp is compared against mtime, the port counts in
  // rdtime, so a deadline is written as (rdtime deadline + offset). Measured
  // where mtime can be read (QEMU: a few ticks of sampling skew). Where it
  // cannot (the C906), mtimecmp compares against the same system counter
  // rdtime reads, so the offset is 0; clock-test checks the resulting tick
  // against rdtime independently.
  inline std::int64_t
  measure_offset (void)
  {
    if constexpr (!riscv_board::MTIME_READABLE || !riscv_board::TIME_CSR)
      {
        // Not readable, or the clock IS mtime: same counter, no offset.
        return 0;
      }
    const std::uint64_t t0 = now ();
    const std::uint64_t m = mtime_read ();
    const std::uint64_t t1 = now ();
    return static_cast<std::int64_t> (m - (t0 + (t1 - t0) / 2));
  }
} // namespace clint
