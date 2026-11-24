/*
 * startup.cpp -- the C++ half of start-up (startup.S calls these).
 *
 * The kernel's own startup (micro-os-plus::iii-startup) is Cortex-M only, so
 * this port carries the two hooks it would have called, and the free-store
 * set-up that comes with them:
 *
 *   os_startup_initialize_hardware_early()   before the C++ constructors;
 *                                            the board quiets the hardware
 *                                            (timer disarmed, MSIP cleared)
 *   os_startup_initialize_hardware()         the board's peripherals, then
 *                                            the heap
 *
 * Both are weak: a test that needs a different start-up defines its own.
 *
 * Copyright (c) 2026 Dan. MIT license.
 */

#include <cstddef>
#include <cstdint>

#include <cmsis-plus/rtos/os.h>

#include <clint.hpp>
#if defined(RISCV_PFIC)
#include <pfic.hpp>
#endif
#include <riscv-board.hpp>

extern "C"
{
  extern char _Heap_Begin[];
  extern char _Heap_Limit[];

  void os_startup_initialize_free_store (void* heap_address,
                                         std::size_t heap_size_bytes);

  void __attribute__ ((weak)) os_startup_initialize_hardware_early (void);
  void __attribute__ ((weak)) os_startup_initialize_hardware (void);

  // cmsis_device.h declares it for the kernel's __ARM_EABI__ code; on RISC-V
  // the meaningful clock is the timebase.
  std::uint32_t SystemCoreClock = riscv_board::TIMEBASE_HZ;
}

// The static constructor / destructor runners. The kernel keeps them in its
// Cortex-M startup.cpp (micro-os-plus::iii-startup), which this port does not
// link; exit.c calls os_run_fini_array(), and startup.S calls
// os_run_init_array() where the kernel's own start-up does.
extern "C"
{
  extern void (*__preinit_array_start[]) (void) __attribute__ ((weak));
  extern void (*__preinit_array_end[]) (void) __attribute__ ((weak));
  extern void (*__init_array_start[]) (void) __attribute__ ((weak));
  extern void (*__init_array_end[]) (void) __attribute__ ((weak));
  extern void (*__fini_array_start[]) (void) __attribute__ ((weak));
  extern void (*__fini_array_end[]) (void) __attribute__ ((weak));

  void os_run_init_array (void);
  void os_run_fini_array (void);
}

void
os_run_init_array (void)
{
  const long npre = __preinit_array_end - __preinit_array_start;
  for (long i = 0; i < npre; i++)
    {
      __preinit_array_start[i]();
    }
  const long n = __init_array_end - __init_array_start;
  for (long i = 0; i < n; i++)
    {
      __init_array_start[i]();
    }
}

void
os_run_fini_array (void)
{
  const long n = __fini_array_end - __fini_array_start;
  for (long i = n; i > 0; i--)
    {
      __fini_array_start[i - 1]();
    }
}

void
os_startup_initialize_hardware_early (void)
{
  clint::timer_disarm ();
#if defined(RISCV_PFIC)
  // No MSIP on a QingKe board (CLINT_MSIP is not a register there: a store
  // to it hit flash address 0 and trapped, mcause 3 -- measured). Every
  // PFIC interrupt off and nothing pending instead; the port enables the
  // two it uses.
  for (unsigned i = 0; i < 8; ++i)
    {
      pfic::reg32 (pfic::IRER0 + 4u * i) = 0xFFFFFFFFu;
      pfic::reg32 (pfic::IPRR0 + 4u * i) = 0xFFFFFFFFu;
    }
#else
  clint::msip_clear ();
#endif
  riscv_board_initialize_early ();
}

void
os_startup_initialize_hardware (void)
{
  riscv_board_initialize ();

  os_startup_initialize_free_store (
      _Heap_Begin, static_cast<std::size_t> (_Heap_Limit - _Heap_Begin));
}
