/*
 * mmu.hpp -- RISC-V Sv39 page tables (identity map, 2 MiB leaves).
 *
 * The kernel runs in MACHINE mode, where satp does not translate the hart's
 * own accesses. The tables are still real: they translate every S/U-mode
 * access, and every M-mode load/store made with mstatus.MPRV=1 and
 * mstatus.MPP=S -- which is how mmu-test proves them on the board without
 * leaving M-mode (see access_translated()).
 *
 * The map is built from the board's region list (riscv-board.hpp,
 * riscv_board::MMU_REGIONS): DRAM read/write/execute, the MMIO windows
 * read/write. Cacheability is not a PTE property on these harts: the C906
 * takes it from its hard-wired PMA (unless MAEE extended attributes are
 * enabled, which this port does not do), QEMU ignores it.
 *
 * Derived from the cv1800 Eclipse project's mmu.c.
 *
 * Copyright (c) 2026 Dan. MIT license.
 */
#pragma once

#include <cstddef>
#include <cstdint>

namespace mmu
{
  inline constexpr std::uint64_t PTE_V = 1ULL << 0;
  inline constexpr std::uint64_t PTE_R = 1ULL << 1;
  inline constexpr std::uint64_t PTE_W = 1ULL << 2;
  inline constexpr std::uint64_t PTE_X = 1ULL << 3;
  inline constexpr std::uint64_t PTE_U = 1ULL << 4;
  inline constexpr std::uint64_t PTE_G = 1ULL << 5;
  inline constexpr std::uint64_t PTE_A = 1ULL << 6;
  inline constexpr std::uint64_t PTE_D = 1ULL << 7;

  // T-Head C906 extended attributes, PTE bits 63..59. They apply when
  // mxstatus.MAEE = 1 -- which the Duo's BL2 sets (mxstatus = 0xc0638000).
  // Values as the SDK's Linux uses them (arch/riscv/include/asm/
  // pgtable-bits.h, pgtable.h): RAM = Cacheable|Bufferable|Shareable,
  // I/O = Strong-order|Shareable. Left at 0, a RAM page is NON-cacheable:
  // translated accesses then bypass the D-cache that untranslated M-mode
  // accesses go through (measured: mmu-test failed on the Duo). On a
  // standard Sv39 hart these bits are reserved and must stay 0, so they
  // come from the board (riscv_board::PTE_ATTR_RAM / _DEV).
  inline constexpr std::uint64_t PTE_THEAD_SEC = 1ULL << 59;
  inline constexpr std::uint64_t PTE_THEAD_SH = 1ULL << 60;
  inline constexpr std::uint64_t PTE_THEAD_B = 1ULL << 61;
  inline constexpr std::uint64_t PTE_THEAD_C = 1ULL << 62;
  inline constexpr std::uint64_t PTE_THEAD_SO = 1ULL << 63;

  // The PPN field, bits 53..10.
  inline constexpr std::uint64_t PTE_PPN_MASK = ((1ULL << 44) - 1) << 10;

  // A and D are set up front: the C906 does not update them in hardware and
  // would page-fault on the first access instead. Board attributes are
  // added by the board's MMU_REGIONS (riscv-board.hpp).
  inline constexpr std::uint64_t FLAGS_RAM = PTE_R | PTE_W | PTE_X | PTE_A | PTE_D;
  inline constexpr std::uint64_t FLAGS_DEV = PTE_R | PTE_W | PTE_A | PTE_D;

  inline constexpr std::uint64_t PAGE_SIZE = 4096;
  inline constexpr std::uint64_t MEGAPAGE = 2ULL << 20; // 2 MiB leaf
  inline constexpr std::uint64_t SATP_SV39 = 8ULL << 60;

  struct region
  {
    std::uint64_t base; // 2 MiB aligned
    std::uint64_t size; // multiple of 2 MiB
    std::uint64_t flags;
  };

  // Build the identity map of the board's regions into the static table
  // arena and write satp (Sv39). Returns false if the arena is too small.
  bool
  init (void);

  // Add one more 2 MiB mapping va -> pa (used by mmu-test for an alias).
  bool
  map_2m (std::uint64_t va, std::uint64_t pa, std::uint64_t flags);

  // Software walk of the tables: the physical address va maps to, or ~0.
  std::uint64_t
  translate (std::uint64_t va);

  // satp as written by init().
  std::uint64_t
  satp (void);

  // Program PMP entry 0 as "everything, RWX" so that S-mode (and MPRV)
  // accesses are allowed at all. With no PMP entry an S-mode access faults.
  void
  pmp_allow_all (void);

  // Load / store one 64-bit word THROUGH THE PAGE TABLES, from M-mode:
  // mstatus.MPRV=1 with MPP=S makes the data access use satp. Interrupts
  // are masked around it.
  std::uint64_t
  load_translated (std::uint64_t va);
  void
  store_translated (std::uint64_t va, std::uint64_t value);
} // namespace mmu
