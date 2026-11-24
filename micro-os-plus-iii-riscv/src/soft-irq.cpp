/*
 * soft-irq.cpp -- software interrupt lines on the machine software interrupt.
 *
 * A RISC-V hart has no NVIC; its one software-triggered interrupt is CLINT
 * MSIP (the port switches threads with ecall, not with MSIP). Lines 0..31
 * are multiplexed onto it: NVIC_SetPendingIRQ(n) marks line n and raises
 * MSIP; the MSIP trap (trap.cpp) runs every pending, enabled line's handler
 * IN HANDLER MODE -- interrupts masked, riscv_trap_nesting != 0, so the RTOS
 * ISR-safe calls behave as they do in any interrupt -- and on the way out
 * switches threads, if a handler made one due.
 *
 * These NVIC_* are WEAK: a board with a real external interrupt controller
 * (the RP2350's Hazard3 Xh3irq, test/boards/pico2/src/irq.cpp) supplies
 * strong ones on its own IRQ numbers instead.
 *
 * The NVIC names are what Cortex-M code calls (the CMSIS-RTOS validator
 * raises "IRQ 0" this way, cmsis_device.h declares them). A user of a line
 * defines riscv_soft_irq_handler(); the validator's board glue does
 * (test/milkv-duo/cmsis-os-validator/harness-suite.cpp).
 *
 * Copyright (c) 2026 Dan. MIT license.
 */

#include <cstdint>

// A QingKe board (RISCV_PFIC) has no CLINT MSIP: its software interrupt is
// the PFIC's, used for the context switch, and its NVIC_* are the board's
// (on PFIC interrupts). Nothing here then.
#if !defined(RISCV_PFIC)

#include <clint.hpp>
#include <cmsis_device.h>
#include <riscv-csr.hpp>
#include <riscv-amo.hpp>
#include <riscv-hart.hpp>

extern "C"
{
  // Changed with AMOs: kept where AMOs work (riscv-amo.hpp).
  volatile std::uint32_t riscv_soft_irq_enabled RISCV_AMO_BSS = 0;
  volatile std::uint32_t riscv_soft_irq_pending RISCV_AMO_BSS = 0;

  void __attribute__ ((weak)) riscv_soft_irq_handler (unsigned line)
  {
    (void) line;
  }

  void riscv_soft_irq_dispatch (void);
}

namespace
{
  inline std::uint32_t
  bit (IRQn_Type n)
  {
    return (n >= 0 && n < 32) ? (1u << static_cast<unsigned> (n)) : 0u;
  }
} // namespace

// Enabling a line DISCARDS a request left pending while it was disabled,
// the semantics the Raspberry Pi ports give their Mailbox-1 stand-in for the
// same validator. It matters: TC_MailFromThreadToISR enables the line before
// it empties the mail queue, and the previous case's periodic timer may have
// raised the line after that case disabled it. Delivering the stale request
// at enable ran the new case's ISR on the old case's mail.
void __attribute__ ((weak))
NVIC_EnableIRQ (IRQn_Type n)
{
  __atomic_fetch_and (&riscv_soft_irq_pending, ~bit (n), __ATOMIC_SEQ_CST);
  __atomic_fetch_or (&riscv_soft_irq_enabled, bit (n), __ATOMIC_SEQ_CST);
}

void __attribute__ ((weak))
NVIC_DisableIRQ (IRQn_Type n)
{
  __atomic_fetch_and (&riscv_soft_irq_enabled, ~bit (n), __ATOMIC_SEQ_CST);
}

void __attribute__ ((weak))
NVIC_SetPendingIRQ (IRQn_Type n)
{
  __atomic_fetch_or (&riscv_soft_irq_pending, bit (n), __ATOMIC_SEQ_CST);
  if (riscv_soft_irq_enabled & bit (n))
    {
      clint::msip_set ();
      // On Cortex-M the handler of an enabled line has run before the
      // instruction after the request (interrupts enabled, after a barrier).
      // The CLINT write is posted and the C906 takes MSIP some cycles
      // later, so from a thread with interrupts enabled wait for the
      // dispatcher to have taken the line. (Masked or in a handler: it runs
      // when interrupts are unmasked / the trap returns, as on Cortex-M.)
      if ((RISCV_CSR_READ (mstatus) & riscv::csr::MSTATUS_MIE) != 0)
        {
          (void) clint::msip_read ();
          while ((__atomic_load_n (&riscv_soft_irq_pending, __ATOMIC_ACQUIRE)
                  & riscv_soft_irq_enabled & bit (n))
                 != 0)
            {
            }
        }
    }
}

void __attribute__ ((weak))
NVIC_ClearPendingIRQ (IRQn_Type n)
{
  __atomic_fetch_and (&riscv_soft_irq_pending, ~bit (n), __ATOMIC_SEQ_CST);
}

// Called from the MSIP trap, interrupts masked.
void
riscv_soft_irq_dispatch (void)
{
  for (;;)
    {
      const std::uint32_t ready = riscv_soft_irq_pending & riscv_soft_irq_enabled;
      if (ready == 0)
        {
          return;
        }
      const unsigned line = static_cast<unsigned> (__builtin_ctz (ready));
      __atomic_fetch_and (&riscv_soft_irq_pending, ~(1u << line),
                          __ATOMIC_SEQ_CST);
      riscv_soft_irq_handler (line);
    }
}

// Priorities do not exist on the software lines (all equal, served in line
// order). A board with a real interrupt controller replaces this.
void __attribute__ ((weak))
NVIC_SetPriority (IRQn_Type n, std::uint32_t priority)
{
  (void) n;
  (void) priority;
}

#endif // !RISCV_PFIC
