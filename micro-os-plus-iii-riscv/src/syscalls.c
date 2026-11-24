/*
 * syscalls.c -- minimal newlib/OS glue for the RISC-V port.
 *
 * The same set the Cortex-M port keeps in test/boards/shared/syscalls.c:
 * the kernel's exit.c calls os_terminate() and os_goodbye(), and newlib may
 * reference a handful of _xxx stubs. Output goes through the board console
 * (stdout/stderr) so printf() works; there is no file system.
 *
 * Every function is weak: a test or a board may replace any of them.
 *
 * Copyright (c) 2026 Dan. MIT license.
 */

#include <errno.h>
#include <stddef.h>
#include <sys/stat.h>
#include <sys/types.h>

extern void riscv_board_console_write (const char* s, size_t n);

void __attribute__ ((weak))
os_goodbye (void)
{
}

void __attribute__ ((noreturn, weak))
os_terminate (int code)
{
  (void) code;
  for (;;)
    {
      __asm__ volatile("" ::: "memory");
    }
}

int __attribute__ ((weak))
_write (int fd, const char* buf, int len)
{
  if (fd == 1 || fd == 2)
    {
      riscv_board_console_write (buf, (size_t) len);
      return len;
    }
  errno = EBADF;
  return -1;
}

int __attribute__ ((weak))
_read (int fd, char* buf, int len)
{
  (void) fd;
  (void) buf;
  (void) len;
  return 0;
}

int __attribute__ ((weak))
_close (int fd)
{
  (void) fd;
  errno = EBADF;
  return -1;
}

off_t __attribute__ ((weak))
_lseek (int fd, off_t pos, int whence)
{
  (void) fd;
  (void) pos;
  (void) whence;
  return 0;
}

int __attribute__ ((weak))
_fstat (int fd, struct stat* st)
{
  (void) fd;
  st->st_mode = S_IFCHR;
  return 0;
}

int __attribute__ ((weak))
_isatty (int fd)
{
  (void) fd;
  return 1;
}

int __attribute__ ((weak))
_kill (int pid, int sig)
{
  (void) pid;
  (void) sig;
  errno = EINVAL;
  return -1;
}

int __attribute__ ((weak))
_getpid (void)
{
  return 1;
}
