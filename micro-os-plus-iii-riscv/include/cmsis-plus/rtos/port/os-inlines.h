/*
 * This file is part of the µOS++ project (https://micro-os-plus.github.io/).
 * Copyright (c) Liviu Ionescu. All rights reserved.
 * Copyright (c) 2026 Dan. All rights reserved.
 *
 * Permission to use, copy, modify, and/or distribute this software
 * for any purpose is hereby granted, under the terms of the MIT license.
 */

/*
 * os-inlines.h -- the inline half of the RISC-V port (RV64, M-mode).
 *
 * Critical sections are mstatus.MIE: `csrrci` clears it and returns the old
 * value in one instruction, so enter() is atomic with respect to interrupts
 * without a read-modify-write window. "In handler mode" is the trap nesting
 * count kept by the trap entry, because RISC-V has no IPSR equivalent.
 *
 * On a WCH QingKe board (RISCV_PFIC, include/pfic.hpp) the critical section
 * is the PFIC threshold instead -- BASEPRI: interrupts of the priority-0x00
 * group keep running -- and a thread's switch request is the software
 * interrupt, taken as soon as the threshold allows it.
 */

#ifndef CMSIS_PLUS_RTOS_PORT_OS_INLINES_H_
#define CMSIS_PLUS_RTOS_PORT_OS_INLINES_H_

#if defined(OS_USE_OS_APP_CONFIG_H)
#include <cmsis-plus/os-app-config.h>
#endif

#include <cmsis-plus/rtos/os-c-decls.h>

#ifdef __cplusplus

#include <cmsis-plus/diag/trace.h>
#include <riscv-csr.hpp>
#include <riscv-hart.hpp>
#include <riscv-board.hpp>
#include <clint.hpp>
#if defined(RISCV_PFIC)
#include <pfic.hpp>
#if defined(OS_USE_SMP_SCHEDULER)
#error "RISCV_PFIC: the QingKe PFIC path is single-hart"
#endif
#endif

extern "C"
{
  // rdtime value at the last system tick (src/rtos/os-core.cpp).
  extern volatile uint64_t riscv_port_last_tick;
  // Per hart: a context switch requested by a thread while mstatus.MIE was
  // clear (src/rtos/os-core.cpp); done when the critical section ends.
  extern volatile bool riscv_port_yield_deferred[];
  void riscv_port_deferred_yield (void);
#if defined(OS_USE_SMP_SCHEDULER)
  // The recursive kernel spinlock (os-core.cpp); call with MIE clear.
  void riscv_smp_klock_acquire (void);
  void riscv_smp_klock_release (void);
#endif
}

namespace os
{
  namespace rtos
  {
    namespace port
    {
      namespace scheduler
      {
        inline void __attribute__ ((always_inline))
        greeting (void)
        {
          // PORT_GREETING names the board; board.cmake defines it.
          trace::printf ("Scheduler: " PORT_GREETING
                         ", RV%u M-mode, %u hart%s, preemptive, %u Hz tick, "
#if defined(RISCV_PFIC)
                         "PFIC SWI switch, nesting\n",
#else
                         "ecall switch\n",
#endif
                         static_cast<unsigned> (riscv::XLEN),
                         static_cast<unsigned> (OS_NCPU),
                         (OS_NCPU > 1) ? "s (SMP)" : "",
                         static_cast<unsigned> (OS_INTEGER_SYSTICK_FREQUENCY_HZ));
          trace::printf ("Timebase: %u Hz\n",
                         static_cast<unsigned> (riscv_board::TIMEBASE_HZ));
        }

        inline port::scheduler::state_t __attribute__ ((always_inline))
        lock (void)
        {
          return locked (state::locked);
        }

        inline port::scheduler::state_t __attribute__ ((always_inline))
        unlock (void)
        {
          return locked (state::unlocked);
        }

        inline bool __attribute__ ((always_inline))
        locked (void)
        {
#if defined(OS_USE_SMP_SCHEDULER)
          // Masked, so the thread cannot move to another hart between
          // reading the hart id and reading that hart's lock state.
          const riscv::reg_t s = riscv::csr::mstatus_clear_mie ();
          const bool v = lock_state[riscv::this_hart ()] != state::unlocked;
          if (s)
            {
              riscv::csr::mstatus_set_mie ();
            }
          return v;
#else
          return lock_state != state::unlocked;
#endif
        }

        // The idle thread does NOT sleep in `wfi`: it returns at once and
        // the idle loop spins, preempted by the tick and by MSIP. On the
        // C906 a hart in `wfi` was measured not taking a pending, enabled
        // machine-timer interrupt (mos-test1 stopped after 25 ms, the hart
        // on the instruction after `wfi`, mip.MTIP=1, mie.MTIE=1,
        // mstatus.MIE=1). A spin costs power, not correctness.
        inline void __attribute__ ((always_inline))
        wait_for_interrupt (void)
        {
          __asm__ volatile("" ::: "memory");
        }
      } /* namespace scheduler */

      namespace interrupts
      {
        inline bool __attribute__ ((always_inline))
        in_handler_mode (void)
        {
          return riscv::in_trap ();
        }

        inline bool
        is_priority_valid (void)
        {
          return true;
        }

        // Single hart: mstatus.MIE is the whole critical section. SMP: MIE
        // masks this hart, and the recursive kernel spinlock keeps the other
        // hart(s) out of the kernel's data, as SIO spinlock 0 does in the
        // RP2350 Cortex-M port.
#if defined(RISCV_PFIC)
        // BASEPRI: raise the PFIC threshold to the kernel's level (never
        // lower it -- a section inside a more restrictive one keeps that
        // one's); return the threshold to restore. An interrupt that comes
        // between the read and the write restores what it changes.
        inline rtos::interrupts::state_t __attribute__ ((always_inline))
        critical_section::enter (void)
        {
          const std::uint32_t t = pfic::threshold ();
          if (t == 0u || t > pfic::KERNEL_THRESHOLD)
            {
              pfic::set_threshold (pfic::KERNEL_THRESHOLD);
            }
          return t;
        }

        // Restore the threshold. A switch asked for inside the section is a
        // pending software interrupt, taken as soon as the threshold lets
        // it; a thread waits for it here, so it does not run on past the
        // section before it is switched out (what DSB/ISB after the BASEPRI
        // write do on Cortex-M).
        inline void __attribute__ ((always_inline))
        critical_section::exit (rtos::interrupts::state_t state)
        {
          pfic::set_threshold (static_cast<std::uint32_t> (state));
          if (state == 0u && !riscv::in_trap ()
              && (RISCV_CSR_READ (mstatus) & riscv::csr::MSTATUS_MIE) != 0)
            {
              while (pfic::is_pending (pfic::IRQ_SWI))
                {
                }
            }
        }

        inline rtos::interrupts::state_t __attribute__ ((always_inline))
        uncritical_section::enter (void)
        {
          const std::uint32_t t = pfic::threshold ();
          pfic::set_threshold (0u);
          return t;
        }

        inline void __attribute__ ((always_inline))
        uncritical_section::exit (rtos::interrupts::state_t state)
        {
          pfic::set_threshold (static_cast<std::uint32_t> (state));
        }
#else
        inline rtos::interrupts::state_t __attribute__ ((always_inline))
        critical_section::enter (void)
        {
          const riscv::reg_t s = riscv::csr::mstatus_clear_mie ();
#if defined(OS_USE_SMP_SCHEDULER)
          riscv_smp_klock_acquire ();
#endif
          return s;
        }

        inline void __attribute__ ((always_inline))
        critical_section::exit (rtos::interrupts::state_t state)
        {
#if defined(OS_USE_SMP_SCHEDULER)
          riscv_smp_klock_release ();
#endif
          if (state & riscv::csr::MSTATUS_MIE)
            {
              // Read the flag while still masked (the hart cannot change
              // under the read), then unmask.
              const bool deferred
                  = riscv_port_yield_deferred[riscv::this_hart ()];
              riscv::csr::mstatus_set_mie ();
              // What PRIMASK clearing does for a pending PendSV on
              // Cortex-M: a switch asked for inside the section happens now.
              if (deferred)
                {
                  riscv_port_deferred_yield ();
                }
            }
        }

        inline rtos::interrupts::state_t __attribute__ ((always_inline))
        uncritical_section::enter (void)
        {
          return riscv::csr::mstatus_set_mie ();
        }

        inline void __attribute__ ((always_inline))
        uncritical_section::exit (rtos::interrupts::state_t state)
        {
          if (!(state & riscv::csr::MSTATUS_MIE))
            {
              riscv::csr::mstatus_clear_mie ();
            }
        }
#endif
      } /* namespace interrupts */

      namespace this_thread
      {
        inline void __attribute__ ((always_inline))
        prepare_suspend (void)
        {
        }
      } /* namespace this_thread */

      inline void __attribute__ ((always_inline))
      clock_highres::start (void)
      {
      }

      // The high resolution clock is derived from the tick count plus the
      // cycles since the last tick, the way the upstream Cortex-M port does
      // it; the cycles are rdtime ticks.
      inline constexpr bool __attribute__ ((always_inline))
      clock_highres::has_hardware_counter (void) noexcept
      {
        return false;
      }

      inline uint64_t __attribute__ ((always_inline))
      clock_highres::hardware_counter (void) noexcept
      {
        return 0;
      }

      inline uint32_t __attribute__ ((always_inline))
      clock_highres::input_clock_frequency_hz (void)
      {
        return riscv_board::TIMEBASE_HZ;
      }

      inline uint32_t __attribute__ ((always_inline))
      clock_highres::cycles_per_tick (void)
      {
        return riscv_board::TIMEBASE_HZ / OS_INTEGER_SYSTICK_FREQUENCY_HZ;
      }

      inline uint32_t __attribute__ ((always_inline))
      clock_highres::cycles_since_tick (void)
      {
        const uint64_t now = clint::now ();
        const uint64_t since = now - riscv_port_last_tick;
        const uint32_t per = cycles_per_tick ();
        return (since >= per) ? (per - 1) : static_cast<uint32_t> (since);
      }

    } /* namespace port */
  } /* namespace rtos */
} /* namespace os */

#endif /* __cplusplus */

#endif /* CMSIS_PLUS_RTOS_PORT_OS_INLINES_H_ */
