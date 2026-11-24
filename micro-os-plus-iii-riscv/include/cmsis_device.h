/*
 * cmsis_device.h -- the kernel includes <cmsis_device.h> from code compiled
 * under __ARM_EABI__ (src/libc/stdlib/exit.c). A RISC-V hart has no CMSIS
 * core; this stub gives the few names that code reaches, as the AArch32 and
 * AArch64 ports' stubs do.
 *
 * Copyright (c) 2026 Dan. MIT license.
 */
#ifndef CMSIS_DEVICE_H_
#define CMSIS_DEVICE_H_

#ifdef __cplusplus
extern "C" {
#endif

#include <stdint.h>

static inline void
NVIC_SystemReset (void)
{
  for (;;)
    {
      __asm__ volatile("" ::: "memory");
    }
}

#define __NOP() __asm__ volatile("nop")
#define __BKPT(n) __asm__ volatile("ebreak")

// What Cortex-M code calls the NVIC. By default: software interrupt lines
// 0..31 on the machine software interrupt (src/soft-irq.cpp; a user of a
// line defines riscv_soft_irq_handler (unsigned line)). A board with an
// external interrupt controller overrides them on its own IRQ numbers (the
// Pico 2: Xh3irq, RP2350 IRQs, board header rp2350-irq.h).
typedef int IRQn_Type;

void NVIC_EnableIRQ (IRQn_Type irq);
void NVIC_DisableIRQ (IRQn_Type irq);
void NVIC_SetPendingIRQ (IRQn_Type irq);
void NVIC_ClearPendingIRQ (IRQn_Type irq);
void NVIC_SetPriority (IRQn_Type irq, uint32_t priority);

extern uint32_t SystemCoreClock;
static inline void
SystemCoreClockUpdate (void)
{
}

#ifdef __cplusplus
}
#endif

#endif /* CMSIS_DEVICE_H_ */
