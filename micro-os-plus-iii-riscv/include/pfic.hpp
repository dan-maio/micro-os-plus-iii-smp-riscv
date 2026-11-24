/*
 * pfic.hpp -- the WCH QingKe V4 interrupt controller (PFIC) as the port uses
 * it: the Cortex-M model on RISC-V. Used when the board defines RISCV_PFIC
 * (the CH32V307, test/boards/ch32v307-evt).
 *
 * The QingKe V4 has no CLINT and no machine timer/software interrupt: every
 * interrupt goes through the PFIC (QingKeV4 Processor Manual V1.5, ch. 3),
 * with priorities and hardware nesting, and mstatus.MIE is NOT cleared on a
 * trap. The port maps it the way the Cortex-M port uses the NVIC:
 *
 *   PendSV     the software interrupt, PFIC interrupt 14, lowest priority:
 *              the ONLY place threads are switched. It runs when no other
 *              interrupt is active, so a switch never leaves another
 *              interrupt half-done in the PFIC's active state.
 *   SysTick    the QingKe SysTick (interrupt 12): a 64-bit up-counter and a
 *              64-bit compare, used exactly as CLINT mtime/mtimecmp
 *              (riscv-board.hpp maps them; clint.hpp drives them).
 *   BASEPRI    PFIC_ITHRESDR: an interrupt whose priority value is >= the
 *              threshold stays pending; 0 = no threshold. A critical
 *              section sets KERNEL_THRESHOLD, so the priority-0x00 group
 *              keeps running -- it must not call the kernel.
 *   nesting    INTSYSCR = INESTEN | PMTCFG 0b10: 4 preemption levels
 *              (priority bits [7:6]), HPE (hardware register stacking) off.
 *              Measured: a nested interrupt leaves the preempted one's mepc,
 *              mcause and mstatus intact.
 *
 * Copyright (c) 2026 Dan. MIT license.
 */
#pragma once

#include <cstdint>

namespace pfic
{
  inline volatile std::uint32_t&
  reg32 (std::uintptr_t a)
  {
    return *reinterpret_cast<volatile std::uint32_t*> (a);
  }

  inline constexpr std::uintptr_t IPR0 = 0xE000E020u;     // pending status
  inline constexpr std::uintptr_t ITHRESDR = 0xE000E040u; // threshold
  inline constexpr std::uintptr_t GISR = 0xE000E04Cu;     // global status
  inline constexpr std::uintptr_t IENR0 = 0xE000E100u;    // enable set
  inline constexpr std::uintptr_t IRER0 = 0xE000E180u;    // enable clear
  inline constexpr std::uintptr_t IPSR0 = 0xE000E200u;    // pending set
  inline constexpr std::uintptr_t IPRR0 = 0xE000E280u;    // pending clear
  inline constexpr std::uintptr_t IACTR0 = 0xE000E300u;   // active status
  inline constexpr std::uintptr_t IPRIOR0 = 0xE000E400u;  // priority bytes

  inline constexpr unsigned IRQ_SYSTICK = 12;
  inline constexpr unsigned IRQ_SWI = 14;

  // INTSYSCR (CSR 0x804): INESTEN (bit 1) | PMTCFG = 0b10 (bits [3:2]).
  inline constexpr unsigned CSR_INTSYSCR = 0x804;
  inline constexpr std::uint32_t INTSYSCR_NEST4 = 0x0Au;

  // Priorities (smaller = more urgent; bits [7:6] preempt).
  inline constexpr std::uint8_t PRIO_ZERO_LATENCY = 0x00; // never masked
  inline constexpr std::uint8_t PRIO_KERNEL_HIGH = 0x40;
  inline constexpr std::uint8_t PRIO_SYSTICK = 0x80;
  inline constexpr std::uint8_t PRIO_SWI = 0xC0; // lowest: the PendSV
  // What a critical section masks: everything from 0x40 down.
  inline constexpr std::uint32_t KERNEL_THRESHOLD = 0x40u;

  // SysTick control (QingKe V4 manual, ch. 5).
  inline constexpr std::uintptr_t STK_CTLR = 0xE000F000u;
  inline constexpr std::uintptr_t STK_SR = 0xE000F004u;
  inline constexpr std::uint32_t STK_STE = 1u << 0;
  inline constexpr std::uint32_t STK_STIE = 1u << 1;
  inline constexpr std::uint32_t STK_STCLK_HCLK = 1u << 2;

  inline void
  enable (unsigned irq)
  {
    reg32 (IENR0 + 4u * (irq / 32u)) = 1u << (irq % 32u);
  }

  inline void
  disable (unsigned irq)
  {
    reg32 (IRER0 + 4u * (irq / 32u)) = 1u << (irq % 32u);
  }

  inline void
  set_pending (unsigned irq)
  {
    reg32 (IPSR0 + 4u * (irq / 32u)) = 1u << (irq % 32u);
  }

  inline void
  clear_pending (unsigned irq)
  {
    reg32 (IPRR0 + 4u * (irq / 32u)) = 1u << (irq % 32u);
  }

  inline bool
  is_pending (unsigned irq)
  {
    return (reg32 (IPR0 + 4u * (irq / 32u)) >> (irq % 32u)) & 1u;
  }

  inline void
  set_priority (unsigned irq, std::uint8_t prio)
  {
    *reinterpret_cast<volatile std::uint8_t*> (IPRIOR0 + irq) = prio;
  }

  inline std::uint32_t
  threshold (void)
  {
    return reg32 (ITHRESDR);
  }

  // The manual: after masking through a PFIC register or a CSR, a fence.i
  // synchronises the core with the new interrupt-enable state.
  inline void
  set_threshold (std::uint32_t t)
  {
    reg32 (ITHRESDR) = t;
    __asm__ volatile("fence.i" ::: "memory");
  }
} // namespace pfic
