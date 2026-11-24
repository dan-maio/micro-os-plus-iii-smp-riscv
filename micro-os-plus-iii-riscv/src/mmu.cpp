/*
 * mmu.cpp -- Sv39 identity map for the RISC-V port (see mmu.hpp).
 *
 * Derived from the cv1800 Eclipse project's mmu.c: 2 MiB leaves in a bump
 * allocated arena. The arena here is a static, page-aligned array, so the
 * tables never collide with the heap or a stack.
 *
 * Copyright (c) 2026 Dan. MIT license.
 */

#include <cstdint>

// Sv39 is an RV64 scheme; an RV32 hart (Hazard3) has no MMU at all.
#if __riscv_xlen == 64

#include <mmu.hpp>
#include <riscv-board.hpp>
#include <riscv-csr.hpp>

namespace
{
  constexpr unsigned ENTRIES = 512;
  constexpr unsigned ARENA_PAGES = 16; // 1 root + up to 15 second levels

  alignas (4096) std::uint64_t arena[ARENA_PAGES][ENTRIES];
  unsigned arena_used = 0;
  std::uint64_t satp_value = 0;

  std::uint64_t*
  alloc_table (void)
  {
    if (arena_used >= ARENA_PAGES)
      {
        return nullptr;
      }
    std::uint64_t* t = arena[arena_used++];
    for (unsigned i = 0; i < ENTRIES; ++i)
      {
        t[i] = 0;
      }
    return t;
  }

  std::uint64_t*
  root (void)
  {
    return arena[0];
  }

  constexpr unsigned
  vpn2 (std::uint64_t va)
  {
    return static_cast<unsigned> ((va >> 30) & 0x1FF);
  }

  constexpr unsigned
  vpn1 (std::uint64_t va)
  {
    return static_cast<unsigned> ((va >> 21) & 0x1FF);
  }

  std::uint64_t*
  table_of (std::uint64_t pte)
  {
    return reinterpret_cast<std::uint64_t*> (((pte & mmu::PTE_PPN_MASK) >> 10) << 12);
  }
} // namespace

namespace mmu
{
  bool
  map_2m (std::uint64_t va, std::uint64_t pa, std::uint64_t flags)
  {
    std::uint64_t& l2 = root ()[vpn2 (va)];
    if (!(l2 & PTE_V))
      {
        std::uint64_t* t = alloc_table ();
        if (t == nullptr)
          {
            return false;
          }
        // A pointer to the next level: V set, R/W/X clear.
        l2 = ((reinterpret_cast<std::uint64_t> (t) >> 12) << 10) | PTE_V;
      }
    else if (l2 & (PTE_R | PTE_W | PTE_X))
      {
        return false; // already a 1 GiB leaf
      }
    table_of (l2)[vpn1 (va)] = ((pa >> 12) << 10) | flags | PTE_V;
    __asm__ volatile("sfence.vma zero, zero" ::: "memory");
    return true;
  }

  bool
  init (void)
  {
    arena_used = 0;
    if (alloc_table () == nullptr) // the root
      {
        return false;
      }

    for (const region& r : riscv_board::MMU_REGIONS)
      {
        for (std::uint64_t off = 0; off < r.size; off += MEGAPAGE)
          {
            if (!map_2m (r.base + off, r.base + off, r.flags))
              {
                return false;
              }
          }
      }

    satp_value = SATP_SV39 | (reinterpret_cast<std::uint64_t> (root ()) >> 12);
    RISCV_CSR_WRITE (satp, satp_value);
    __asm__ volatile("sfence.vma zero, zero" ::: "memory");
    return true;
  }

  std::uint64_t
  satp (void)
  {
    return satp_value;
  }

  std::uint64_t
  translate (std::uint64_t va)
  {
    const std::uint64_t l2 = root ()[vpn2 (va)];
    if (!(l2 & PTE_V))
      {
        return ~0ULL;
      }
    if (l2 & (PTE_R | PTE_W | PTE_X))
      {
        return (((l2 & mmu::PTE_PPN_MASK) >> 10) << 12) + (va & ((1ULL << 30) - 1));
      }
    const std::uint64_t l1 = table_of (l2)[vpn1 (va)];
    if (!(l1 & PTE_V))
      {
        return ~0ULL;
      }
    return (((l1 & mmu::PTE_PPN_MASK) >> 10) << 12) + (va & (MEGAPAGE - 1));
  }

  void
  pmp_allow_all (void)
  {
    // Entry 0: NAPOT over the whole address space, R/W/X, not locked.
    RISCV_CSR_WRITE (pmpaddr0, ~0ULL >> 10);
    RISCV_CSR_WRITE (pmpcfg0, 0x1F); // A=NAPOT(3<<3) | X | W | R
    __asm__ volatile("sfence.vma zero, zero" ::: "memory");
  }

  // The translated accesses. Between `csrs mstatus, MPRV` and `csrc` the
  // ONLY data access must be the one we mean: the asm takes its operands in
  // registers and touches no stack.
  std::uint64_t
  load_translated (std::uint64_t va)
  {
    std::uint64_t v;
    const std::uint64_t prev = riscv::csr::mstatus_clear_mie ();
    const std::uint64_t mprv = riscv::csr::MSTATUS_MPRV;
    const std::uint64_t mpp_mask = riscv::csr::MSTATUS_MPP_MASK;
    const std::uint64_t mpp_s = riscv::csr::MSTATUS_MPP_S;
    __asm__ volatile("csrc mstatus, %[mask]\n\t"
                     "csrs mstatus, %[s]\n\t"
                     "csrs mstatus, %[mprv]\n\t"
                     "ld   %[v], 0(%[va])\n\t"
                     "csrc mstatus, %[mprv]\n\t"
                     "csrs mstatus, %[mask]\n\t" // back to MPP=M
                     : [v] "=&r"(v)
                     : [va] "r"(va), [mask] "r"(mpp_mask), [s] "r"(mpp_s),
                       [mprv] "r"(mprv)
                     : "memory");
    if (prev)
      {
        riscv::csr::mstatus_set_mie ();
      }
    return v;
  }

  void
  store_translated (std::uint64_t va, std::uint64_t value)
  {
    const std::uint64_t prev = riscv::csr::mstatus_clear_mie ();
    const std::uint64_t mprv = riscv::csr::MSTATUS_MPRV;
    const std::uint64_t mpp_mask = riscv::csr::MSTATUS_MPP_MASK;
    const std::uint64_t mpp_s = riscv::csr::MSTATUS_MPP_S;
    __asm__ volatile("csrc mstatus, %[mask]\n\t"
                     "csrs mstatus, %[s]\n\t"
                     "csrs mstatus, %[mprv]\n\t"
                     "sd   %[v], 0(%[va])\n\t"
                     "csrc mstatus, %[mprv]\n\t"
                     "csrs mstatus, %[mask]\n\t"
                     :
                     : [v] "r"(value), [va] "r"(va), [mask] "r"(mpp_mask),
                       [s] "r"(mpp_s), [mprv] "r"(mprv)
                     : "memory");
    if (prev)
      {
        riscv::csr::mstatus_set_mie ();
      }
  }
} // namespace mmu

#endif // __riscv_xlen == 64
