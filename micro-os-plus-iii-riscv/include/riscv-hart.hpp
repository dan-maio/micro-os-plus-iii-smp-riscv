/*
 * riscv-hart.hpp -- which hart is this, and is it inside a trap.
 *
 * A hart is identified by its CPU index, mhartid - RISCV_HART_BASE, 0..OS_NCPU-1
 * (port_ctx.hpp; the base is 0 except on the JH-7110S; the board guarantees it: the
 * QEMU virt machine and the RP2350's Hazard3 cores number them that way). On
 * a single-hart build the answer is the constant 0 and no CSR is read.
 *
 * "Inside a trap" is the per-hart nesting count kept by trap.S. A handler may
 * run with mstatus.MIE set (a board with nested external interrupts, the
 * Pico 2's Xh3irq dispatcher, re-enables it), so on SMP the count is read
 * with MIE briefly cleared: the code cannot move to another hart between
 * reading the hart id and reading that hart's count.
 *
 * Copyright (c) 2026 Dan. MIT license.
 */
#pragma once

#include <cstdint>

#include <port_ctx.hpp>
#include <riscv-csr.hpp>

extern "C"
{
  // Per-hart trap nesting depth, maintained by riscv_trap_entry (trap.S).
  extern volatile std::uint32_t riscv_trap_nesting[];
}

namespace riscv
{
  inline unsigned __attribute__ ((always_inline))
  this_hart (void)
  {
#if defined(OS_NCPU) && (OS_NCPU > 1)
    reg_t v;
    __asm__ volatile("csrr %0, mhartid" : "=r"(v));
    // The CPU index: mhartid - RISCV_HART_BASE (port_ctx.hpp).
    return static_cast<unsigned> (v - RISCV_HART_BASE);
#else
    return 0;
#endif
  }

  inline bool __attribute__ ((always_inline))
  in_trap (void)
  {
#if defined(OS_NCPU) && (OS_NCPU > 1)
    const reg_t s = csr::mstatus_clear_mie ();
    const bool v = riscv_trap_nesting[this_hart ()] != 0;
    if (s)
      {
        csr::mstatus_set_mie ();
      }
    return v;
#else
    return riscv_trap_nesting[0] != 0;
#endif
  }
} // namespace riscv
