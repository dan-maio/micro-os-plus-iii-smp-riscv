/*
 * trace.cpp -- os::trace output for the RISC-V port.
 *
 * The board console (riscv_board_console_write) is the trace channel, the
 * way the AArch32 port sends trace to its UART. On a hardware image the
 * board console also copies each chunk to semihosting (see the board's
 * uart.cpp), so the OpenOCD log the runner greps sees it too.
 *
 * Copyright (c) 2026 Dan. MIT license.
 */

#include <cstddef>
#include <sys/types.h>

#include <cmsis-plus/diag/trace.h>

#include <riscv-board.hpp>

namespace os
{
  namespace trace
  {
    void
    initialize (void)
    {
    }

    ssize_t
    write (const void* buf, std::size_t nbyte)
    {
      riscv_board_console_write (static_cast<const char*> (buf), nbyte);
      return static_cast<ssize_t> (nbyte);
    }
  } // namespace trace
} // namespace os
