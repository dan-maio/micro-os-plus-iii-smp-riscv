/*
 * harness-suite.hpp -- the verdict wrapper every harness suite on this
 * board shares (test/mangopi-mq-pro/<suite>/harness-suite.cpp).
 *
 * Run the suite, print RESULT on the console (which a hardware image also
 * copies to semihosting, uart.cpp), and end the run through the semihosting
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

#define UOS_HARNESS_SUITE_VERDICT(name)                                       \
  extern "C" int __real_os_main (int argc, char* argv[]);                     \
  extern "C" int __wrap_os_main (int argc, char* argv[]);                     \
  extern "C" int __wrap_os_main (int argc, char* argv[])                      \
  {                                                                           \
    uart::init (115200);                                                      \
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
