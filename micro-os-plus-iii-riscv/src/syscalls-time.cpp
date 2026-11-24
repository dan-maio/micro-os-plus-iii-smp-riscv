/*
 * syscalls-time.cpp -- the newlib system calls that newlib's RISC-V libgloss
 * would otherwise provide.
 *
 * libgloss's RISC-V stubs (sys_gettimeofday.o, sys_open.o, ...) issue an
 * `ecall` to a proxy kernel. In machine mode with no proxy kernel underneath
 * that is an exception (mcause 11), so the first gettimeofday() of a harness
 * suite (mutex-stress) stopped the run. Every call libgloss offers is
 * defined here, weak, so none of its objects is ever pulled in:
 *
 *   time    _gettimeofday, _times  from rdtime (the board's timebase): time
 *                                  since the hart started, as there is no RTC
 *   files   _open, _stat, _link, _unlink, ...  fail with ENOENT / ENOSYS;
 *                                  the kernel's POSIX I/O layer
 *                                  (micro-os-plus::iii-posix-io) replaces
 *                                  them with strong definitions where a test
 *                                  links it
 *   procs   _fork, _execve, _wait  fail (ENOSYS)
 *
 * The console calls (_write, _read, _close, _lseek, _fstat, _isatty, _kill,
 * _getpid) are in syscalls.c.
 *
 * Copyright (c) 2026 Dan. MIT license.
 */

#include <cerrno>
#include <cstdint>

#include <sys/stat.h>
#include <sys/time.h>
#include <sys/times.h>
#include <time.h>
#include <unistd.h>

#include <riscv-board.hpp>
#include <riscv-csr.hpp>
#include <clint.hpp>

#define RISCV_WEAK extern "C" __attribute__ ((weak))

RISCV_WEAK int
_gettimeofday (struct timeval* tv, void* tz)
{
  (void) tz;
  if (tv != nullptr)
    {
      const std::uint64_t t = clint::now ();
      const std::uint64_t hz = riscv_board::TIMEBASE_HZ;
      tv->tv_sec = static_cast<time_t> (t / hz);
      tv->tv_usec = static_cast<suseconds_t> ((t % hz) * 1000000ULL / hz);
    }
  return 0;
}

RISCV_WEAK clock_t
_times (struct tms* buf)
{
  // times() counts in clock ticks of CLOCKS_PER_SEC (newlib's _SC_CLK_TCK).
  const std::uint64_t t = clint::now ();
  const clock_t c = static_cast<clock_t> (
      t / (riscv_board::TIMEBASE_HZ / static_cast<std::uint64_t> (CLOCKS_PER_SEC)));
  if (buf != nullptr)
    {
      buf->tms_utime = c;
      buf->tms_stime = 0;
      buf->tms_cutime = 0;
      buf->tms_cstime = 0;
    }
  return c;
}

RISCV_WEAK int
_open (const char* path, int flags, ...)
{
  (void) path;
  (void) flags;
  errno = ENOENT;
  return -1;
}

RISCV_WEAK int
_openat (int dirfd, const char* path, int flags, ...)
{
  (void) dirfd;
  (void) path;
  (void) flags;
  errno = ENOENT;
  return -1;
}

RISCV_WEAK int
_stat (const char* path, struct stat* st)
{
  (void) path;
  (void) st;
  errno = ENOENT;
  return -1;
}

RISCV_WEAK int
_lstat (const char* path, struct stat* st)
{
  (void) path;
  (void) st;
  errno = ENOENT;
  return -1;
}

RISCV_WEAK int
_fstatat (int dirfd, const char* path, struct stat* st, int flags)
{
  (void) dirfd;
  (void) path;
  (void) st;
  (void) flags;
  errno = ENOENT;
  return -1;
}

RISCV_WEAK int
_access (const char* path, int mode)
{
  (void) path;
  (void) mode;
  errno = ENOENT;
  return -1;
}

RISCV_WEAK int
_faccessat (int dirfd, const char* path, int mode, int flags)
{
  (void) dirfd;
  (void) path;
  (void) mode;
  (void) flags;
  errno = ENOENT;
  return -1;
}

RISCV_WEAK int
_link (const char* from, const char* to)
{
  (void) from;
  (void) to;
  errno = ENOSYS;
  return -1;
}

RISCV_WEAK int
_unlink (const char* path)
{
  (void) path;
  errno = ENOENT;
  return -1;
}

RISCV_WEAK int
_chdir (const char* path)
{
  (void) path;
  errno = ENOSYS;
  return -1;
}

RISCV_WEAK char*
_getcwd (char* buf, size_t size)
{
  (void) buf;
  (void) size;
  errno = ENOSYS;
  return nullptr;
}

RISCV_WEAK int
_chmod (const char* path, mode_t mode)
{
  (void) path;
  (void) mode;
  errno = ENOSYS;
  return -1;
}

RISCV_WEAK int
_chown (const char* path, uid_t owner, gid_t group)
{
  (void) path;
  (void) owner;
  (void) group;
  errno = ENOSYS;
  return -1;
}

RISCV_WEAK int
_utime (const char* path, const void* times)
{
  (void) path;
  (void) times;
  errno = ENOSYS;
  return -1;
}

RISCV_WEAK int
_fork (void)
{
  errno = ENOSYS;
  return -1;
}

RISCV_WEAK int
_execve (const char* path, char* const argv[], char* const envp[])
{
  (void) path;
  (void) argv;
  (void) envp;
  errno = ENOSYS;
  return -1;
}

RISCV_WEAK int
_wait (int* status)
{
  (void) status;
  errno = ENOSYS;
  return -1;
}

RISCV_WEAK long
_sysconf (int name)
{
  (void) name;
  errno = EINVAL;
  return -1;
}
