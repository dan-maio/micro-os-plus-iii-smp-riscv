// The harness suite "cmsis-os-validator" (ARM's CMSIS-RTOS v1 validator).
//
// Its sources are not here: they live in the kernel's harness
// (tests/sources/cmsis-os-validator) and the arm-cmsis-rtos-validator xPack,
// named by board_test_libs() in test/ch32v307-evt/tests.cmake. This directory
// gives the application its name and its verdict (harness-suite.hpp).
//
// The validator is Cortex-M code: it raises "NVIC IRQ 0" with
// NVIC_SetPendingIRQ() to call the RTOS from an interrupt. On the CH32V307
// that is PFIC interrupt 16 (the board's NVIC_*, src/irq.cpp), at the
// kernel-aware priority 0x40, in handler mode; its handler (WWDG_IRQHandler
// below) is the validator's DEF_IRQHandler(), which calls the test case's
// TST_IRQHandler -- what the window-watchdog vector does on the STM32.
//
// The validator also probes the Cortex-M DWT cycle counter (0xE0001000,
// RV_WaitFunc.c, StartCortexCycleCounter). Where nothing is mapped there
// the load faults (on the CH32V307: to be measured). As the AArch32 port maps a page that
// reads "no cycle counter", this image answers the same through the port's
// exception hook: a load from the DWT window returns DWT_CTRL.NOCYCCNT (and
// 0 for anything else there), a store is ignored. The validator then skips
// its cycle-count measurements, as on a Cortex-M without a DWT counter.

#include <cstdint>

#include <harness-suite.hpp>
#include <port_ctx.hpp>

extern "C" void DEF_IRQHandler (void);

namespace
{
  constexpr std::uint64_t DWT_BASE = 0xE0001000u;
  constexpr std::uint64_t DWT_END = 0xE0001010u;
  constexpr std::uint64_t DWT_CTRL_NOCYCCNT = 1u << 25;

  // Emulate the faulting load/store at mepc. Returns false if it is not a
  // plain integer load or store this glue understands.
  bool
  emulate_dwt (ctx_t* frame, std::uint64_t addr, bool is_load)
  {
    const std::uint64_t pc = frame->x[0];
    const std::uint16_t lo = *reinterpret_cast<const std::uint16_t*> (pc);
    unsigned len;
    unsigned rd = 0;

    if ((lo & 3u) == 3u)
      {
        const std::uint32_t insn = *reinterpret_cast<const std::uint32_t*> (pc);
        len = 4;
        const unsigned opcode = insn & 0x7Fu;
        if (is_load && opcode != 0x03u) // LOAD
          {
            return false;
          }
        if (!is_load && opcode != 0x23u) // STORE
          {
            return false;
          }
        rd = (insn >> 7) & 0x1Fu;
      }
    else
      {
        len = 2;
        const unsigned op = lo & 3u;
        const unsigned funct3 = (lo >> 13) & 7u;
        if (op != 0u)
          {
            return false;
          }
        if (is_load && funct3 != 2u && funct3 != 3u) // c.lw / c.ld
          {
            return false;
          }
        if (!is_load && funct3 != 6u && funct3 != 7u) // c.sw / c.sd
          {
            return false;
          }
        rd = 8u + ((lo >> 2) & 7u);
      }

    if (is_load && rd != 0)
      {
        frame->x[rd] = (addr == DWT_BASE) ? DWT_CTRL_NOCYCCNT : 0u;
      }
    frame->x[0] = pc + len;
    return true;
  }
} // namespace

namespace
{
  // A register's value at the trap: x0 is 0, sp is not in the frame (it is
  // the frame address plus the frame size), the others are.
  std::uint64_t
  reg_at_trap (const ctx_t* frame, unsigned r)
  {
    if (r == 0)
      {
        return 0;
      }
    if (r == 2)
      {
        return reinterpret_cast<std::uintptr_t> (frame) + ctx_size_bytes;
      }
    return frame->x[r];
  }

  // The address the load/store at mepc accessed, decoded from the
  // instruction: Hazard3 hardwires mtval to zero (RP2350 datasheet, RVCSR
  // MTVAL), so the port cannot be told. Plain integer loads/stores only.
  bool
  decode_address (const ctx_t* frame, std::uint64_t& addr)
  {
    const std::uint64_t pc = frame->x[0];
    const std::uint16_t lo = *reinterpret_cast<const std::uint16_t*> (pc);
    if ((lo & 3u) == 3u)
      {
        const std::uint32_t insn = *reinterpret_cast<const std::uint32_t*> (pc);
        const unsigned opcode = insn & 0x7Fu;
        const unsigned rs1 = (insn >> 15) & 0x1Fu;
        std::int32_t imm;
        if (opcode == 0x03u) // LOAD: I-type
          {
            imm = static_cast<std::int32_t> (insn) >> 20;
          }
        else if (opcode == 0x23u) // STORE: S-type
          {
            imm = (static_cast<std::int32_t> (insn & 0xFE000000u) >> 20)
                  | static_cast<std::int32_t> ((insn >> 7) & 0x1Fu);
          }
        else
          {
            return false;
          }
        addr = reg_at_trap (frame, rs1) + static_cast<std::int64_t> (imm);
        return true;
      }
    const unsigned op = lo & 3u;
    const unsigned funct3 = (lo >> 13) & 7u;
    if (op != 0u)
      {
        return false;
      }
    const unsigned rs1 = 8u + ((lo >> 7) & 7u);
    std::uint64_t imm;
    if (funct3 == 2u || funct3 == 6u) // c.lw / c.sw
      {
        imm = (((lo >> 10) & 7u) << 3) | (((lo >> 6) & 1u) << 2)
              | (((lo >> 5) & 1u) << 6);
      }
    else if (funct3 == 3u || funct3 == 7u) // c.ld / c.sd (RV64)
      {
        imm = (((lo >> 10) & 7u) << 3) | (((lo >> 5) & 3u) << 6);
      }
    else
      {
        return false;
      }
    addr = reg_at_trap (frame, rs1) + imm;
    return true;
  }
} // namespace

extern "C" bool
riscv_trap_exception_hook (ctx_t* frame, std::uint64_t mcause,
                           std::uint64_t mtval)
{
  // 5 = load access fault, 7 = store/AMO access fault.
  if (mcause != 5 && mcause != 7)
    {
      return false;
    }
  std::uint64_t addr = mtval;
  if (addr == 0 && !decode_address (frame, addr))
    {
      return false;
    }
  if (addr >= DWT_BASE && addr < DWT_END)
    {
      return emulate_dwt (frame, addr, mcause == 5);
    }
  return false;
}

// The validator's "IRQ 0" (NVIC_SetPendingIRQ(0), board src/irq.cpp) is
// PFIC interrupt 16, WCH's WWDG vector: the watchdog itself stays off.
extern "C" void
WWDG_IRQHandler (void)
{
  DEF_IRQHandler ();
}

UOS_HARNESS_SUITE_VERDICT ("cmsis-os-validator")
