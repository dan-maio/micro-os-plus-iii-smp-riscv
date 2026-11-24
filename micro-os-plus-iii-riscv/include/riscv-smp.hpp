/*
 * riscv-smp.hpp -- the SMP entry points of the RISC-V port (src/rtos/os-core.cpp),
 * for tests and board code. The names are the RP2350 Cortex-M port's, so its
 * SMP tests port with their launch sequence unchanged:
 *
 *   create the secondary's idle thread "idle1", register it in
 *   os_idle_thread_core[1], then
 *   multicore::launch_core1 (port_smp_secondary_start, port_core1_stack_top ());
 *   port_smp_core0_ipi_enable ();
 *
 * Copyright (c) 2026 Dan. MIT license.
 */
#pragma once

#include <cstdint>

extern "C"
{
  unsigned port_cpu_id (void);
  void port_smp_ipi (unsigned cpu);
  void port_smp_secondary_start (void);
  std::uintptr_t port_core1_stack_top (void);
  // The boot stack of secondary CPU 1..OS_NCPU-1 (0 otherwise).
  std::uintptr_t port_secondary_stack_top (unsigned cpu);
  void port_smp_core0_ipi_enable (void);
  // Boards whose harts all enter at _start (QEMU virt): release one.
  void riscv_smp_release_hart (unsigned hart, void (*entry) (void),
                               std::uintptr_t stack_top);
}
