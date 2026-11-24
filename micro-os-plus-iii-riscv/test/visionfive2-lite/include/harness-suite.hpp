/*
 * harness-suite.hpp -- the verdict wrapper every harness suite on this
 * board shares (test/visionfive2-lite/<suite>/harness-suite.cpp).
 *
 * The suite is linked with -Wl,--wrap=os_main, so the kernel's call to
 * os_main() lands here. On this board the wrapper first starts CPUs 1..3
 * (vf2_smp_start(), src/smp-autostart.cpp: every suite runs with OS_NCPU = 4
 * and the kernel's SMP scheduler, on all four U74), then runs the suite,
 * prints RESULT on the console (which a hardware image also copies to
 * semihosting, uart.cpp), and ends the run through the semihosting
 * SYS_EXIT. Not by returning: the kernel's trampoline would call exit(),
 * which runs the static destructors while the suite may still have threads
 * blocked on its objects (the AArch32 port observed exactly that hang).
 *
 * Copyright (c) 2026 Dan. MIT license.
 */
#pragma once

#include <cstdio>

#include <hw_result.hpp>
#include <uart.hpp>
#include <vf2-smp-start.hpp>

#define UOS_HARNESS_SUITE_VERDICT(name)                                       \
  extern "C" int __real_os_main (int argc, char* argv[]);                     \
  extern "C" int __wrap_os_main (int argc, char* argv[]);                     \
  extern "C" int __wrap_os_main (int argc, char* argv[])                      \
  {                                                                           \
    uart::init (115200);                                                      \
    vf2_smp_start ();                                                         \
    const int code = __real_os_main (argc, argv);                             \
    std::fflush (stdout);                                                     \
    char b[96];                                                               \
    std::snprintf (b, sizeof (b), "\nRESULT: %s (%s, code %d)\n",             \
                   code == 0 ? "PASS" : "FAIL", name, code);                  \
    uart::write (b);                                                          \
    if (code == 0)                                                            \
      {                                                                       \
        hw_result::ok ();                                                     \
      }                                                                       \
    hw_result::fail ();                                                       \
    return code;                                                              \
  }
