/*
 * port_ctx.hpp -- the saved-context frame the RISC-V trap entry builds.
 *
 * Shared by src/trap.S (which writes and reads it by offset) and by
 * src/rtos/os-core.cpp (which builds the first frame of every thread). The
 * offsets below are the ones trap.S uses; the static_asserts keep the two
 * from drifting apart.
 *
 * Every trap saves the full integer register file -- and the floating-point
 * one, on a hart with an FPU -- on the stack it interrupted. A context switch is therefore "return from the trap
 * on a different stack": the scheduler only swaps the saved stack pointer.
 *
 * Copyright (c) 2026 Dan. MIT license.
 */
#pragma once

#if !defined(__ASSEMBLER__)
#include <cstddef>
#include <cstdint>
#endif

// Byte offsets, also used by the assembler (trap.S includes this header
// under __ASSEMBLER__ for the numbers only). One slot per integer register,
// XLEN bytes each; the FP block exists only when the compiler targets an FPU
// (__riscv_flen: 64 on the C906, absent on Hazard3).
#define PORT_REGBYTES (__riscv_xlen / 8)
#define PORT_CTX_X(n) ((n) * PORT_REGBYTES) // x1..x31 at their index; x0 slot = mepc
#define PORT_CTX_MEPC 0
#define PORT_CTX_MSTATUS (32 * PORT_REGBYTES)

#if defined(__riscv_flen)
#define PORT_FLENBYTES (__riscv_flen / 8)
#define PORT_CTX_FCSR (33 * PORT_REGBYTES)
// f0..f31 start on an FLEN boundary after fcsr.
#define PORT_CTX_F0                                                           \
  (((34 * PORT_REGBYTES) + PORT_FLENBYTES - 1) / PORT_FLENBYTES * PORT_FLENBYTES)
#define PORT_CTX_F(n) (PORT_CTX_F0 + (n) * PORT_FLENBYTES)
#define PORT_CTX_END (PORT_CTX_F0 + 32 * PORT_FLENBYTES)
#else
#define PORT_CTX_END (33 * PORT_REGBYTES)
#endif

// The frame keeps the stack 16-byte aligned (psABI, RV32 and RV64).
#define PORT_CTX_SIZE ((PORT_CTX_END + 15) / 16 * 16)

// The "go" word of a secondary hart's release slot (startup.S).
#define RISCV_SECONDARY_MAGIC 0x53504D47 /* "GMPS" */

// The mhartid of µOS++'s CPU 0. CPU n is mhartid RISCV_HART_BASE + n
// everywhere the port turns a hart id into an index (riscv-hart.hpp,
// trap.S, startup.S). 0 on QEMU virt, the Pico 2 and the Duo; 1 on the
// JH-7110S, whose hart 0 is the S7 monitor core and whose U74 are 1..4
// (a board define, test/boards/visionfive2-lite/board.cmake). A hart below
// the base or at/above base + OS_NCPU stays parked.
#if !defined(RISCV_HART_BASE)
#define RISCV_HART_BASE 0
#endif

#if defined(__ASSEMBLER__)
// Register-sized load/store for trap.S and startup.S.
#if __riscv_xlen == 64
#define REG_S sd
#define REG_L ld
#else
#define REG_S sw
#define REG_L lw
#endif
#if defined(__riscv_flen) && __riscv_flen == 64
#define FREG_S fsd
#define FREG_L fld
#elif defined(__riscv_flen)
#define FREG_S fsw
#define FREG_L flw
#endif
#endif

#if !defined(__ASSEMBLER__)

#if __riscv_xlen == 64
using ctx_reg_t = std::uint64_t;
#else
using ctx_reg_t = std::uint32_t;
#endif

struct ctx_t
{
  // x[0] holds mepc (x0 is hard-wired zero and needs no slot); x[2], the
  // stack pointer, is implicit -- it is the frame address plus the frame size.
  ctx_reg_t x[32];
  ctx_reg_t mstatus;
#if defined(__riscv_flen)
  ctx_reg_t fcsr;
#if __riscv_flen == 64
  alignas (8) std::uint64_t f[32];
#else
  std::uint32_t f[32];
#endif
#endif
} __attribute__ ((aligned (16)));

static_assert (offsetof (ctx_t, mstatus) == PORT_CTX_MSTATUS);
#if defined(__riscv_flen)
static_assert (offsetof (ctx_t, fcsr) == PORT_CTX_FCSR);
static_assert (offsetof (ctx_t, f) == PORT_CTX_F (0));
#endif
static_assert (sizeof (ctx_t) == PORT_CTX_SIZE);
static_assert ((PORT_CTX_SIZE % 16) == 0, "the psABI wants 16-byte stacks");

inline constexpr std::size_t ctx_size_bytes = sizeof (ctx_t);

// Register numbers used when building a frame.
inline constexpr unsigned CTX_RA = 1;
inline constexpr unsigned CTX_GP = 3;
inline constexpr unsigned CTX_TP = 4;
inline constexpr unsigned CTX_A0 = 10;
inline constexpr unsigned CTX_A1 = 11;
inline constexpr unsigned CTX_A7 = 17;

// a7 of the port's own ecall (os-core.cpp riscv_port_yield): "switch
// threads". Any other ecall is an application's (riscv_trap_exception_hook).
inline constexpr ctx_reg_t RISCV_PORT_YIELD_ECALL = 0x554F5359u; // "YSOU"

#endif
