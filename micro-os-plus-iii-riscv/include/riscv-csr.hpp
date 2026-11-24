/*
 * riscv-csr.hpp -- machine-mode CSR access for the RISC-V port.
 *
 * Copyright (c) 2026 Dan. MIT license.
 */
#pragma once

#include <cstdint>

namespace riscv
{
  // One XLEN-wide register: 64 bits on RV64 (the C906), 32 on RV32 (Hazard3).
#if __riscv_xlen == 64
  using reg_t = std::uint64_t;
#else
  using reg_t = std::uint32_t;
#endif
  inline constexpr unsigned XLEN = __riscv_xlen;

  namespace csr
  {
    // mstatus
    inline constexpr reg_t MSTATUS_MIE = 1u << 3;
    inline constexpr reg_t MSTATUS_MPIE = 1u << 7;
    inline constexpr reg_t MSTATUS_MPP_M = 3u << 11;
    inline constexpr reg_t MSTATUS_MPP_S = 1u << 11;
    inline constexpr reg_t MSTATUS_MPP_MASK = 3u << 11;
    inline constexpr reg_t MSTATUS_FS_INITIAL = 1u << 13;
    inline constexpr reg_t MSTATUS_FS_MASK = 3u << 13;
    inline constexpr reg_t MSTATUS_MPRV = 1u << 17;

    // mie / mip
    inline constexpr reg_t MIE_MSIE = 1u << 3;
    inline constexpr reg_t MIE_MTIE = 1u << 7;
    inline constexpr reg_t MIE_MEIE = 1u << 11;

    // mcause: the interrupt flag is the top bit of XLEN.
    inline constexpr reg_t MCAUSE_INTERRUPT = reg_t (1) << (XLEN - 1);
    inline constexpr reg_t IRQ_M_SOFT = 3;
    inline constexpr reg_t IRQ_M_TIMER = 7;
    inline constexpr reg_t IRQ_M_EXT = 11;
    inline constexpr reg_t EXC_ILLEGAL = 2;
    inline constexpr reg_t EXC_BREAKPOINT = 3;
    inline constexpr reg_t EXC_ECALL_M = 11;

#define RISCV_CSR_READ(name)                                                  \
  ({                                                                          \
    ::riscv::reg_t _v;                                                        \
    __asm__ volatile("csrr %0, " #name : "=r"(_v)::"memory");                 \
    _v;                                                                       \
  })
#define RISCV_CSR_WRITE(name, v)                                              \
  __asm__ volatile("csrw " #name ", %0" ::"r"((::riscv::reg_t) (v)) : "memory")
#define RISCV_CSR_SET(name, v)                                                \
  __asm__ volatile("csrs " #name ", %0" ::"r"((::riscv::reg_t) (v)) : "memory")
#define RISCV_CSR_CLEAR(name, v)                                              \
  __asm__ volatile("csrc " #name ", %0" ::"r"((::riscv::reg_t) (v)) : "memory")

    // Clear mstatus.MIE and return the previous MIE bit (0 or MSTATUS_MIE).
    inline reg_t __attribute__ ((always_inline))
    mstatus_clear_mie (void)
    {
      reg_t v;
      __asm__ volatile("csrrci %0, mstatus, 8" : "=r"(v)::"memory");
      return v & MSTATUS_MIE;
    }

    // Set mstatus.MIE and return the previous MIE bit.
    inline reg_t __attribute__ ((always_inline))
    mstatus_set_mie (void)
    {
      reg_t v;
      __asm__ volatile("csrrsi %0, mstatus, 8" : "=r"(v)::"memory");
      return v & MSTATUS_MIE;
    }

    // The platform timer (time CSR), always 64 bits. On RV32 it is two
    // CSRs; the high half is read before and after the low one, and the
    // read repeats if a carry went into the high half in between.
    inline std::uint64_t __attribute__ ((always_inline))
    rdtime (void)
    {
#if __riscv_xlen == 64
      std::uint64_t v;
      __asm__ volatile("rdtime %0" : "=r"(v));
      return v;
#else
      std::uint32_t hi, lo, hi2;
      do
        {
          __asm__ volatile("rdtimeh %0" : "=r"(hi));
          __asm__ volatile("rdtime %0" : "=r"(lo));
          __asm__ volatile("rdtimeh %0" : "=r"(hi2));
        }
      while (hi != hi2);
      return (static_cast<std::uint64_t> (hi) << 32) | lo;
#endif
    }

    inline std::uint64_t __attribute__ ((always_inline))
    rdcycle (void)
    {
#if __riscv_xlen == 64
      std::uint64_t v;
      __asm__ volatile("rdcycle %0" : "=r"(v));
      return v;
#else
      std::uint32_t hi, lo, hi2;
      do
        {
          __asm__ volatile("rdcycleh %0" : "=r"(hi));
          __asm__ volatile("rdcycle %0" : "=r"(lo));
          __asm__ volatile("rdcycleh %0" : "=r"(hi2));
        }
      while (hi != hi2);
      return (static_cast<std::uint64_t> (hi) << 32) | lo;
#endif
    }
  } // namespace csr
} // namespace riscv
