/**
 * @file  semihosting.hpp
 * @brief ARM-protocol semihosting for the RISC-V port (RV64).
 *
 * The same API as the C++ AArch32 and AArch64 ports' semihosting.hpp --
 * write_char, write_str, write_buf, exit, exit_success, exit_failure,
 * report_result -- so a test written against it is written once. Only the
 * trap differs:
 *
 *   AArch64   HLT #0xF000,            op in x0, parameter in x1
 *   AArch32   SVC 0x123456 / HLT,     op in r0, parameter in r1
 *   RISC-V    slli x0,x0,0x1f         op in a0, parameter in a1, result a0
 *             ebreak
 *             srai x0,x0,7            (uncompressed, aligned, one page)
 *
 * OpenOCD (`arm semihosting enable` on a riscv target) and QEMU
 * (-semihosting-config enable=on) both recognise the sequence.
 *
 * Parameter blocks are made of XLEN-sized words. On RV64 SYS_EXIT takes a
 * TWO-field block { reason, exit_status }, exactly as on AArch64. On RV32 it
 * takes the reason itself in a1 and carries no status: 0 is reported as
 * ADP_Stopped_ApplicationExit, anything else as ADP_Stopped_RunTimeError-
 * Unknown -- OpenOCD exits 0 / 1 for them, QEMU likewise.
 *
 * A test ENDS with exit_success() / exit_failure() (directly, through
 * report_result(), through hw_result::ok/fail, or through _Exit()): that is
 * what stops the run -- OpenOCD reports "application exited with N", QEMU
 * exits with N. Nothing in this port parks the hart in `wfi` instead.
 *
 * Without a debugger the ebreak is an ordinary breakpoint exception. The
 * port's trap handler recognises the sequence, skips it and marks
 * semihosting absent (a0 = -1), so a semihosted build run bare does not
 * fault on its first character.
 */
#pragma once

#include <cstddef>
#include <cstdint>

extern "C"
{
  // Set by the trap handler the first time a semihosting call traps instead
  // of reaching a debugger. From then on calls return -1 at once.
  extern volatile bool riscv_semihosting_absent;
}

namespace semihosting
{
  enum op : long
  {
    SYS_WRITEC = 0x03,
    SYS_WRITE0 = 0x04,
    SYS_WRITE = 0x05,
    SYS_EXIT = 0x18,
  };

  // ADP_Stopped_ApplicationExit, ADP_Stopped_RunTimeErrorUnknown
  inline constexpr std::uint64_t ADP_STOPPED_APPLICATION_EXIT = 0x20026;
  inline constexpr std::uint64_t ADP_STOPPED_RUN_TIME_ERROR = 0x20023;

  // The trap: a0 = operation, a1 = parameter; returns a0.
  inline long __attribute__ ((noinline))
  call (long operation, const volatile void* arg) noexcept
  {
    if (riscv_semihosting_absent)
      {
        return -1;
      }
    register long a0 __asm__ ("a0") = operation;
    register const volatile void* a1 __asm__ ("a1") = arg;
    __asm__ volatile(".option push\n"
                     ".option norvc\n"
                     ".balign 16\n"
                     "slli x0, x0, 0x1f\n"
                     "ebreak\n"
                     "srai x0, x0, 7\n"
                     ".option pop\n"
                     : "+r"(a0)
                     : "r"(a1)
                     : "memory");
    return a0;
  }

  // False once a call has found no debugger behind it.
  inline bool
  attached (void) noexcept
  {
    return !riscv_semihosting_absent;
  }

  // SYS_WRITEC (0x03): write the single char pointed to by a1.
  inline void
  write_char (char c) noexcept
  {
    volatile char ch = c;
    call (SYS_WRITEC, &ch);
  }

  // SYS_WRITE0 (0x04): write the NUL-terminated string pointed to by a1.
  inline void
  write_str (const char* s) noexcept
  {
    call (SYS_WRITE0, s);
  }

  // SYS_WRITE (0x05): write len bytes from buf to the console handle (1), so
  // the buffer need not be NUL-terminated. a1 points to { handle, buf, len }.
  inline void
  write_buf (const char* buf, std::size_t len) noexcept
  {
    volatile std::uintptr_t block[3]
        = { 1, reinterpret_cast<std::uintptr_t> (buf), len };
    call (SYS_WRITE, block);
  }

  // SYS_EXIT (0x18): stop the run and report a status to the host (see the
  // RV32/RV64 difference above). Does not return under a debugger/emulator;
  // without one, spins (never `wfi`).
  [[noreturn]] inline void
  exit (std::uint64_t reason, std::uint64_t status) noexcept
  {
#if __riscv_xlen == 64
    volatile std::uint64_t block[2] = { reason, status };
    call (SYS_EXIT, block);
#else
    if (reason == ADP_STOPPED_APPLICATION_EXIT && status != 0)
      {
        reason = ADP_STOPPED_RUN_TIME_ERROR;
      }
    call (SYS_EXIT, reinterpret_cast<const volatile void*> (
                        static_cast<std::uintptr_t> (reason)));
#endif
    for (;;)
      {
        __asm__ volatile("" ::: "memory");
      }
  }

  [[noreturn]] inline void
  exit_success () noexcept
  {
    exit (ADP_STOPPED_APPLICATION_EXIT, 0);
  }

  [[noreturn]] inline void
  exit_failure () noexcept
  {
    exit (ADP_STOPPED_APPLICATION_EXIT, 1);
  }

  // The verdict-and-stop used by a hardware test, as in the C++ ports: print
  // the RESULT line on the semihosting channel (that is what reaches the
  // OpenOCD log the runner reads), then SYS_EXIT, which stops the run.
  [[noreturn]] inline void
  report_result (bool pass) noexcept
  {
    if (pass)
      {
        write_str ("\nRESULT: PASS\n");
        exit_success ();
      }
    else
      {
        write_str ("\nRESULT: FAIL\n");
        exit_failure ();
      }
  }
} // namespace semihosting
