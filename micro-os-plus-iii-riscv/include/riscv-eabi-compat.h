/*
 * riscv-eabi-compat.h -- force-included into every C/C++ file of the port
 * (CMakeLists.txt: -include).
 *
 * WHY __ARM_EABI__ ON RISC-V. The kernel uses __ARM_EABI__ as its name for
 * "an embedded target with no OS underneath": its malloc/free, exit/atexit,
 * _sbrk, the C++ runtime hooks (cxx.cpp), the free-store set-up and
 * trace.cpp are all compiled only under it. The AArch64 port defines it for
 * the same reason (test/CMakeLists.txt there). It changes nothing in the
 * RISC-V toolchain's own headers (no newlib or libstdc++ header tests it --
 * checked against riscv-none-elf-gcc 15.2.0).
 *
 * What it does turn on that is Arm-specific is one literal instruction,
 * `bkpt 0` in trace_dbg_bkpt() (cmsis-plus/diag/trace.h). The assembler
 * macro below makes `bkpt` mean `ebreak`, the way the AArch64 port's
 * cmsis_device.h makes it mean `brk 0`.
 *
 * Copyright (c) 2026 Dan. MIT license.
 */
#ifndef RISCV_EABI_COMPAT_H_
#define RISCV_EABI_COMPAT_H_

#if defined(__riscv)
__asm__ (".macro bkpt val\n ebreak\n .endm");
#endif

#endif /* RISCV_EABI_COMPAT_H_ */
