/*
 * runtime.cpp -- the RISC-V port without the kernel: what a bare-metal probe
 * (BOARD_TEST_NO_KERNEL, micro-os-plus::riscv-bare) links besides startup.S
 * and trap.S.
 *
 * Such a test runs BEFORE any scheduler does (smp-test0 proves the second
 * core starts; see the kernel's uos-app.cmake), so nothing here knows about
 * threads: start-up hooks that only bring the board up, the static
 * constructors, and a trap dispatcher that understands semihosting, the
 * application's exception hook, the board's external interrupts and the
 * fault report -- the kernel build's trap.cpp minus the timer tick and the
 * context switch. The timer and the software interrupt stay disabled.
 *
 * Copyright (c) 2026 Dan. MIT license.
 */

#include <cstddef>
#include <cstdint>

#include <port_ctx.hpp>
#include <riscv-board.hpp>
#include <riscv-csr.hpp>
#include <riscv-hart.hpp>
#include <semihosting.hpp>

extern "C"
{
  // The interrupt stack (the board's linker script) -- hart 0 only here.
  extern std::uintptr_t __irq_stack_top[];
  // trap.S reads it on the outermost trap.
  std::uintptr_t* riscv_irq_stack_top[1] = { __irq_stack_top };

  volatile bool riscv_semihosting_absent = false;

  extern void (*__preinit_array_start[]) (void) __attribute__ ((weak));
  extern void (*__preinit_array_end[]) (void) __attribute__ ((weak));
  extern void (*__init_array_start[]) (void) __attribute__ ((weak));
  extern void (*__init_array_end[]) (void) __attribute__ ((weak));

  void os_startup_initialize_hardware_early (void);
  void os_startup_initialize_hardware (void);
  void os_run_init_array (void);
  void* riscv_trap_dispatch (ctx_t* frame);
  void _exit (int code) __attribute__ ((noreturn));

  void __attribute__ ((weak)) riscv_board_external_interrupt (void)
  {
  }

  bool __attribute__ ((weak))
  riscv_trap_exception_hook (ctx_t* frame, std::uint64_t mcause,
                             std::uint64_t mtval)
  {
    (void) frame;
    (void) mcause;
    (void) mtval;
    return false;
  }

  // Before the constructors: interrupts off, then the board (clocks, ...).
  void
  os_startup_initialize_hardware_early (void)
  {
    RISCV_CSR_WRITE (mie, 0);
    riscv_board_initialize_early ();
  }

  // After the constructors: the board's peripherals (the console). No free
  // store: there is no kernel to give it to.
  void
  os_startup_initialize_hardware (void)
  {
    riscv_board_initialize ();
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

  // newlib's exit() ends here: the semihosting exit, as with the kernel.
  void
  _exit (int code)
  {
    if (code == 0)
      {
        semihosting::exit_success ();
      }
    semihosting::exit_failure ();
  }
}

namespace
{
  void
  raw (const char* s)
  {
    std::size_t n = 0;
    while (s[n] != '\0')
      {
        ++n;
      }
    riscv_board_console_write (s, n);
  }

  bool
  is_semihosting_trap (std::uint64_t pc)
  {
    if ((pc & 3) != 0)
      {
        return false;
      }
    const auto* p = reinterpret_cast<const std::uint32_t*> (pc);
    return p[-1] == 0x01f01013u && p[0] == 0x00100073u && p[1] == 0x40705013u;
  }

  [[noreturn]] void
  fault (ctx_t* frame, std::uint64_t mcause)
  {
    char b[128];
    std::size_t n = 0;
    auto put = [&] (const char* t) {
      while (*t != '\0' && n < sizeof (b) - 1)
        {
          b[n++] = *t++;
        }
    };
    auto hex = [&] (std::uint64_t v) {
      put ("0x");
      for (int i = 0; i < 16 && n < sizeof (b) - 1; ++i)
        {
          const unsigned d = static_cast<unsigned> ((v >> (60 - 4 * i)) & 0xF);
          b[n++] = static_cast<char> (d < 10 ? '0' + d : 'a' + d - 10);
        }
    };
    put ("\n!!! RISC-V trap (bare): mcause=");
    hex (mcause);
    put (" mepc=");
    hex (frame->x[0]);
    put (" ra=");
    hex (frame->x[CTX_RA]);
    put ("\n");
    b[n] = '\0';
    raw (b);
    semihosting::write_str (b);
    raw ("RESULT: FAIL (trap)\n");
    semihosting::write_str ("RESULT: FAIL (trap)\n");
    semihosting::exit_failure ();
  }
} // namespace

void*
riscv_trap_dispatch (ctx_t* frame)
{
  const riscv::reg_t mcause = RISCV_CSR_READ (mcause);

  if (mcause & riscv::csr::MCAUSE_INTERRUPT)
    {
      switch (mcause & 0xFFF)
        {
        case riscv::csr::IRQ_M_EXT:
          riscv_board_external_interrupt ();
          return frame;
        default:
          // No tick and no software interrupt without a kernel: mask it.
          RISCV_CSR_CLEAR (mie, riscv::reg_t (1) << (mcause & 0xFFF));
          return frame;
        }
    }

  if (mcause == riscv::csr::EXC_BREAKPOINT && is_semihosting_trap (frame->x[0]))
    {
      riscv_semihosting_absent = true;
      frame->x[CTX_A0] = static_cast<ctx_reg_t> (-1);
      frame->x[0] += 8;
      return frame;
    }

  if (riscv_trap_exception_hook (frame, mcause, RISCV_CSR_READ (mtval)))
    {
      return frame;
    }

  fault (frame, mcause);
}
