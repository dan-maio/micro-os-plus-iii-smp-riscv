/*
 * This file is part of the µOS++ project (https://micro-os-plus.github.io/).
 * Copyright (c) Liviu Ionescu. All rights reserved.
 * Copyright (c) 2026 Dan. All rights reserved.
 *
 * Permission to use, copy, modify, and/or distribute this software
 * for any purpose is hereby granted, under the terms of the MIT license.
 */

/*
 * os-decls.h -- the C++ half of the RISC-V port contract.
 *
 * Single hart, the shape of the upstream Cortex-M port: one scheduler lock
 * state, the context is the saved stack pointer (the registers themselves
 * are on the thread's stack, see port_ctx.hpp). The shared SMP declarations
 * (micro-os-plus::port-smp-decls) are NOT used: this port has no kernel
 * spinlock and no per-CPU arrays.
 */

#ifndef CMSIS_PLUS_RTOS_PORT_OS_DECLS_H_
#define CMSIS_PLUS_RTOS_PORT_OS_DECLS_H_

#if defined(OS_USE_OS_APP_CONFIG_H)
#include <cmsis-plus/os-app-config.h>
#endif

#include <cmsis-plus/rtos/port/os-c-decls.h>

#if !defined(OS_INTEGER_SYSTICK_FREQUENCY_HZ)
#define OS_INTEGER_SYSTICK_FREQUENCY_HZ (1000)
#endif

// A trap frame is 528 bytes (31 GPRs, mepc, mstatus, fcsr, 32 FPRs); the
// minimum leaves room for one frame and a modest call depth.
#if !defined(OS_INTEGER_RTOS_MIN_STACK_SIZE_BYTES)
#define OS_INTEGER_RTOS_MIN_STACK_SIZE_BYTES (2048)
#endif

#if !defined(OS_INTEGER_RTOS_DEFAULT_STACK_SIZE_BYTES)
#define OS_INTEGER_RTOS_DEFAULT_STACK_SIZE_BYTES (8192)
#endif

#if !defined(OS_INTEGER_RTOS_MAIN_STACK_SIZE_BYTES)
#define OS_INTEGER_RTOS_MAIN_STACK_SIZE_BYTES \
  (OS_INTEGER_RTOS_DEFAULT_STACK_SIZE_BYTES)
#endif

#if !defined(OS_INTEGER_RTOS_IDLE_STACK_SIZE_BYTES)
#define OS_INTEGER_RTOS_IDLE_STACK_SIZE_BYTES \
  (OS_INTEGER_RTOS_DEFAULT_STACK_SIZE_BYTES)
#endif

#include <signal.h>
#include <sys/time.h>

#ifdef __cplusplus

#include <cstdint>
#include <cstddef>

namespace os
{
  namespace rtos
  {
    namespace port
    {
      namespace stack
      {
        using element_t = os_port_thread_stack_element_t;
        using allocation_element_t = os_port_thread_stack_allocation_element_t;

        constexpr std::size_t min_size_bytes
            = OS_INTEGER_RTOS_MIN_STACK_SIZE_BYTES;
        constexpr std::size_t default_size_bytes
            = OS_INTEGER_RTOS_DEFAULT_STACK_SIZE_BYTES;
        constexpr element_t magic = OS_INTEGER_RTOS_STACK_FILL_MAGIC;
      } /* namespace stack */

      namespace interrupts
      {
        using state_t = os_port_irq_state_t;

        namespace state
        {
          constexpr state_t init = 0;
        } /* namespace state */
      } /* namespace interrupts */

      namespace scheduler
      {
        using state_t = os_port_scheduler_state_t;

        namespace state
        {
          constexpr state_t locked = true;
          constexpr state_t unlocked = false;
          constexpr state_t init = unlocked;
        } /* namespace state */

#if defined(OS_USE_SMP_SCHEDULER)
        // Per hart: the scheduler lock is per CPU, like current_thread_[].
        extern volatile state_t lock_state[OS_NCPU];
        // The kernel spinlock (os-core.cpp).
        extern os_port_smp_klock_t smp_klock;
#else
        extern state_t lock_state;
#endif
      } /* namespace scheduler */

      using thread_context_t = struct context_s
      {
        // The registers are saved on the thread's own stack by the trap
        // entry (src/trap.S); only the stack pointer is kept here.
        stack::element_t* stack_ptr;
      };

    } /* namespace port */
  } /* namespace rtos */
} /* namespace os */

#endif /* __cplusplus */

#endif /* CMSIS_PLUS_RTOS_PORT_OS_DECLS_H_ */
