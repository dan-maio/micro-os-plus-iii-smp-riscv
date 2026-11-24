/*
 * This file is part of the µOS++ project (https://micro-os-plus.github.io/).
 * Copyright (c) Liviu Ionescu. All rights reserved.
 * Copyright (c) 2026 Dan. All rights reserved.
 *
 * Permission to use, copy, modify, and/or distribute this software
 * for any purpose is hereby granted, under the terms of the MIT license.
 */

/*
 * os-c-decls.h -- the C half of the RISC-V port contract (RV64, M-mode).
 *
 * Everything width-dependent lives here: RV64 has 64-bit registers, so the
 * stack element, the saved stack pointer and the interrupt state (a copy of
 * mstatus.MIE) are XLEN bits wide.
 */

#ifndef CMSIS_PLUS_RTOS_PORT_OS_C_DECLS_H_
#define CMSIS_PLUS_RTOS_PORT_OS_C_DECLS_H_

#include <stdint.h>
#include <stdbool.h>

#if !defined(__riscv) || (__riscv_xlen != 64 && __riscv_xlen != 32)
#error "The micro-os-plus-iii-riscv port is for RV64 or RV32 harts."
#endif

typedef uint64_t os_port_clock_timestamp_t;
typedef uint32_t os_port_clock_duration_t;
typedef uint64_t os_port_clock_offset_t;

typedef bool os_port_scheduler_state_t;

/* The saved mstatus.MIE bit (bit 3), 0 or 8: one XLEN register. */
typedef uintptr_t os_port_irq_state_t;

/* One XLEN register slot. */
typedef uintptr_t os_port_thread_stack_element_t;
/* The psABI wants 16-byte stack alignment; context::create() aligns the top.
   The allocation element keeps stacks at least 8-byte aligned on RV32 too. */
typedef uint64_t os_port_thread_stack_allocation_element_t;

typedef struct
{
  os_port_thread_stack_element_t* stack_ptr;
} os_port_thread_context_t;

/* OS_NCPU is a BOARD fact (test/boards/<board>/board.cmake -> NCPU) and has
 * no default here: a board that does not say how many CPUs it has does not
 * compile. The Milk-V Duo runs µOS++ on its one main C906 hart (OS_NCPU=1;
 * its "little" C906 is not driven by this port); the Pico 2 runs it on both
 * Hazard3 harts (OS_NCPU=2, OS_USE_SMP_SCHEDULER); the VisionFive 2 Lite on
 * its four U74 harts (mhartid 1..4). A hart is identified by its CPU index,
 * mhartid - RISCV_HART_BASE (port_ctx.hpp), which must be 0..OS_NCPU-1. */
#ifndef OS_NCPU
#error "OS_NCPU is a board fact: set UOS_BOARD_NCPU in test/boards/<board>/board.cmake."
#endif
#if (OS_NCPU > 1) && !defined(OS_USE_SMP_SCHEDULER)
#error "OS_NCPU > 1 needs OS_USE_SMP_SCHEDULER (uos_add_app defines both)."
#endif
#if (OS_NCPU < 1) || (OS_NCPU > 8)
#error "The RISC-V port supports 1..8 harts."
#endif

#if defined(OS_USE_SMP_SCHEDULER)
/* The recursive kernel spinlock: `word` is taken with an AMO swap (the A
   extension; on the RP2350 the global monitor makes AMOs atomic across both
   cores), `owner` is the holding hart, `depth` the nesting. */
typedef struct
{
  volatile uint32_t word;
  volatile uint32_t owner;
  volatile uint32_t depth;
} os_port_smp_klock_t;
#define SMP_NO_OWNER 0xFFFFFFFFu
/* The cross-hart "reschedule" interrupt (the kernel's board contract asks a
   multi-CPU board for it): on RISC-V it is the machine software interrupt,
   mcause code 3, raised in the target hart's MSIP (CLINT msip[hart]; on the
   RP2350, SIO RISCV_SOFTIRQ). */
#define OS_SMP_IPI_SGI 3
#endif

#if __riscv_xlen == 64
#define OS_INTEGER_RTOS_STACK_FILL_MAGIC (0xEFBEADDEEFBEADDEULL)
#else
#define OS_INTEGER_RTOS_STACK_FILL_MAGIC (0xEFBEADDEu)
#endif

#define OS_HAS_INTERRUPTS_STACK

#endif /* CMSIS_PLUS_RTOS_PORT_OS_C_DECLS_H_ */
