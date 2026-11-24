/*
 * semihosting-exit.cpp -- strong _Exit(): end the run through semihosting
 * SYS_EXIT, so std::exit() reports a real exit code.
 *
 *   QEMU      SYS_EXIT ends the emulator with the code; CTest reads it.
 *   hardware  OpenOCD, attached with semihosting enabled, sees the exit.
 *   neither   the trap handler finds no debugger (semihosting.hpp) and the
 *             hart spins.
 *
 * The AArch32, AArch64 and Cortex-M ports carry the same file.
 *
 * Copyright (c) 2026 Dan. MIT license.
 */

#include <cstdint>

#include <semihosting.hpp>

extern "C" void _Exit (int code) __attribute__ ((noreturn));

// A board without a debugger (the MangoPi MQ-Pro runs under xfel) ends the
// run its own way: write the verdict where the host can read it after the
// reset, then reset.  Weak, so every other board keeps the semihosting path.
extern "C" void riscv_board_exit (int code) __attribute__ ((weak));

extern "C" void
_Exit (int code)
{
  if (riscv_board_exit != nullptr)
    {
      riscv_board_exit (code);
    }
#if defined(SEMIHOST)
  if (code == 0)
    {
      semihosting::exit_success ();
    }
  semihosting::exit (semihosting::ADP_STOPPED_APPLICATION_EXIT,
                     static_cast<std::uint64_t> (static_cast<std::int64_t> (code)));
#else
  (void) code;
  for (;;)
    {
      __asm__ volatile("" ::: "memory");
    }
#endif
}
