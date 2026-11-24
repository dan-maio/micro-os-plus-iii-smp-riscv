# ARM vs RISC-V for RTOS Porting: Single-Core and SMP

Nov 6, 2026 · Dan

## Purpose and scope

Porting a real-time kernel from ARM to RISC-V is mostly a job of replacing things the ARM hardware does for you with a few dozen lines of your own code, and of learning which RISC-V parts behave differently from the specification you read. This document explains those differences in plain English, first for a single core and then for several cores (SMP), with code you can compare side by side.

It is written for someone who knows one of the two architectures and has to write or debug the low-level half of an RTOS on the other: start-up code, the trap or exception entry, the tick, the context switch, critical sections, spinlocks and the start of the other cores.

The comparison covers:

| Side | Profiles and parts covered |
| --- | --- |
| ARM | Cortex-M (ARMv7-M, ARMv8-M, e.g. the RP2350's Cortex-M33), Cortex-A in AArch32 (ARMv7-A) and AArch64 (ARMv8-A) |
| RISC-V | Machine mode on three real cores: T-Head C906 (Milk-V Duo, RV64GC), Hazard3 (Raspberry Pi RP2350, RV32IMAC, two cores), SiFive U74 (StarFive JH-7110S on the VisionFive 2 Lite, RV64GC, four cores) |

The RISC-V examples come from the µOS++ III RISC-V port (`micro-os-plus-iii-riscv`), which runs the same kernel as the existing Cortex-M, AArch32 and AArch64 ports. Where this document says *measured*, the behaviour was observed on the board during that port, not taken from a manual. ARM examples are the standard idioms of each profile; they are written to show the shape of the code, not copied from one specific port.

## The big picture

ARM gives an RTOS a lot of machinery in hardware and in a few fixed standards; RISC-V gives it a small, clean base and leaves the rest to the platform and to software. Almost every difference in the sections below follows from that one fact.

**ARM is one company's architecture, sold in profiles.** A Cortex-M part always has the NVIC, SysTick, the same vector table layout and the same automatic register stacking on interrupt entry. A Cortex-A part always has the Generic Timer and, in practice, a GIC. Once you have ported an RTOS to one Cortex-M, the next Cortex-M is mostly a matter of clocks and pins.

**RISC-V is an open instruction set built from extensions.** The letters in a name such as `rv64imafdc_zicsr_zifencei_zba_zbb` say exactly what the core can execute: I (integer base), M (multiply/divide), A (atomics), F and D (single and double floating point), C (16-bit compressed instructions), and so on. The privileged specification defines machine, supervisor and user modes and a handful of control registers (CSRs). Everything outside the core — the timer, the interrupt controller, how other cores are started — is defined by separate platform specifications (CLINT, PLIC, ACLINT, AIA) that vendors may follow, follow partly, or replace.

What that means in practice for a porter:

- **You write more of the low level yourself.** There is no hardware register stacking, no PendSV and no vectored priority controller in the base architecture. The trap entry, the frame layout and the context switch are your code.
- **Your code is simpler to reason about.** One trap entry, one frame format, one way to return (`mret`). There are no banked registers, no special return values in the link register and no lazy-stacking state machine.
- **The board matters more than the core.** On the three RISC-V boards in this port, the timer behaved three different ways: the C906 cannot read `mtime` and needs split 32-bit compare writes; Hazard3 has no `time` CSR; the U74 has no `time` CSR either, and its hart numbering starts at 1. None of this is visible in the ISA name.
- **Measure, then trust.** Several things that the specification allows to vary did vary: misaligned loads work on the C906 and trap on the U74; atomics work in SRAM and fault in the RP2350's PSRAM. The port keeps each of these as a named board fact rather than an assumption.

## Privilege levels and execution modes

A bare-metal RTOS runs at the most privileged level that has no firmware above it: privileged Thread/Handler mode on Cortex-M, EL1 (or EL3 with no secure firmware) on AArch64, and machine mode (M-mode) on RISC-V.

|  | Cortex-M | Cortex-A AArch32 | AArch64 | RISC-V |
| --- | --- | --- | --- | --- |
| Levels | Thread mode and Handler mode, each privileged or not | USR, SYS, SVC, IRQ, FIQ, ABT, UND (+ MON, HYP) | EL0 user, EL1 OS, EL2 hypervisor, EL3 secure monitor | U user, S supervisor, M machine (+ hypervisor extension) |
| Where an RTOS usually runs | privileged Thread, interrupts in Handler | SVC or SYS | EL1 | M (S if firmware such as OpenSBI stays resident) |
| Stack pointers | two: MSP (handlers) and PSP (threads) | one banked SP per mode | SP\_EL0 and SP\_ELx | one `sp` (x2); a handler switches it in software |
| Mode of the trap handler | Handler mode, always on MSP | the exception's own mode | the target EL | always M-mode (unless delegated to S) |
| Return from exception | load `EXC_RETURN` into PC | `SUBS PC, LR, #4` / `RFE` | `ERET` | `mret` |

Two plain consequences:

- **Cortex-M gives you two stacks for free.** Threads run on PSP, interrupts run on MSP, and the hardware switches between them. On RISC-V the trap arrives on whatever stack the interrupted code was using; the trap entry must decide whether to switch to an interrupt stack. The µOS++ port does that on the outermost trap only, using a per-hart nesting counter.
- **AArch32 banks registers per mode; RISC-V banks none.** An IRQ on ARMv7-A arrives with its own SP and LR. On RISC-V every general register is shared, so the entry code must save the ones it needs before touching them. The only free scratch register is the CSR `mscratch`.

How the RISC-V port enters M-mode on a board where firmware ran first: OpenOCD halts the hart and sets its privilege before the program starts.

```text
# hw.sh session, Milk-V Duo and VisionFive 2 Lite: the payload was running in
# S-mode under OpenSBI; the RTOS runs in M-mode.
halt
reg priv 3          # 3 = machine mode (0 user, 1 supervisor)
load_image test.elf 0 elf
resume 0x40200000
```

On a Cortex-M the equivalent decision is made by the reset: the core starts privileged in Thread mode on MSP, and the RTOS moves threads to PSP itself.

```c
// Cortex-M: run threads on PSP, still privileged (CONTROL.SPSEL = 1).
__set_PSP((uint32_t)first_thread_stack_top);
__set_CONTROL(__get_CONTROL() | CONTROL_SPSEL_Msk);
__ISB();
```

## Registers and calling conventions

The register files are similar in size, but RISC-V has no special registers in the general set: the program counter, the status word and the link register are not "registers you push" the way they are on ARM.

|  | ARMv7-M / AArch32 | AArch64 | RISC-V (RV32/RV64) |
| --- | --- | --- | --- |
| General registers | r0–r12, sp (r13), lr (r14), pc (r15) | x0–x30, sp, xzr | x0–x31; x0 is always zero |
| Arguments / return | r0–r3 / r0–r1 | x0–x7 / x0–x1 | a0–a7 / a0–a1 |
| Callee-saved | r4–r11 | x19–x28 (+ fp x29) | s0–s11 |
| Caller-saved temporaries | r0–r3, r12 | x0–x18 | t0–t6, a0–a7 |
| Return address | lr | x30 | ra (x1) |
| Status word | xPSR / CPSR, readable as a register | PSTATE (NZCV, DAIF …) | none in the GPRs: flags do not exist; state is in CSRs (`mstatus`) |
| Stack alignment at calls | 8 bytes (AAPCS) | 16 bytes | 16 bytes (psABI, RV32 and RV64) |
| Special pointers | none | none (x18 platform register) | gp (x3) global pointer, tp (x4) thread pointer |

Three differences that bite when porting:

- **No condition flags.** RISC-V compares inside the branch (`beq`, `bltu`) or with `slt`. Nothing in a context switch needs to save flags, because there are none.
- **The global pointer must be set up with relaxation off.** The linker uses `gp` to reach small data in one instruction. If the instruction that loads `gp` is itself relaxed against `gp`, it loads garbage. Every RISC-V start-up file has this guard:

```asm
    .option push
    .option norelax
    la      gp, __global_pointer$
    .option pop
```

- **The frame you save is bigger and fully in software.** The µOS++ RISC-V trap frame holds the return PC (`mepc`) in the slot of x0 (which never needs saving), x1–x31, `mstatus`, and with an FPU `fcsr` plus f0–f31. On RV64 with the D extension that is 528 bytes. A Cortex-M frame is 8 words stacked by hardware plus 8 more (r4–r11) pushed by PendSV.

```c
// include/port_ctx.hpp (RISC-V port): one slot per register, XLEN bytes each.
#define PORT_REGBYTES (__riscv_xlen / 8)
#define PORT_CTX_X(n) ((n) * PORT_REGBYTES) // x1..x31 at their index; x0 slot = mepc
#define PORT_CTX_MEPC 0
#define PORT_CTX_MSTATUS (32 * PORT_REGBYTES)
#if defined(__riscv_flen)
#define PORT_CTX_FCSR (33 * PORT_REGBYTES)
#define PORT_CTX_F(n) (PORT_CTX_F0 + (n) * (__riscv_flen / 8))
#endif
#define PORT_CTX_SIZE ((PORT_CTX_END + 15) / 16 * 16) // keeps sp 16-byte aligned
```

## Exceptions and interrupts: getting in and out

On Cortex-M the hardware picks the handler, saves half the registers and calls a normal C function; on RISC-V the hardware only records why it trapped and jumps to one address, and software does everything else.

### What the hardware does on entry

| Step | Cortex-M | AArch64 | RISC-V M-mode |
| --- | --- | --- | --- |
| Choose the handler | vector table indexed by exception number (`VTOR`) | `VBAR_ELx` + one of 16 slots of 0x80 bytes (sync / IRQ / FIQ / SError × 4 origins) | `mtvec`: one address (direct mode), or base + 4 × cause for interrupts only (vectored mode) |
| Save registers | pushes r0–r3, r12, lr, pc, xPSR (8 words) and, with lazy FP, s0–s15 + FPSCR | none | none |
| Save return address | stacked pc | `ELR_ELx` | `mepc` |
| Save status | stacked xPSR | `SPSR_ELx` | `mstatus.MPIE` ← MIE, `mstatus.MPP` ← old privilege |
| Mask interrupts | by priority: only higher priorities can preempt | sets PSTATE.DAIF | clears `mstatus.MIE` |
| Say why | IPSR = exception number; CFSR/HFSR for faults | `ESR_ELx`, `FAR_ELx` | `mcause` (top bit = interrupt, rest = code), `mtval` (bad address or instruction) |
| Return | `bx lr` with `EXC_RETURN` (0xFFFFFFFx) in lr | `eret` | `mret` |

Because Cortex-M stacks the caller-saved registers in hardware, an interrupt handler on Cortex-M is a plain C function placed in the vector table:

```c
// Cortex-M: the hardware saved r0-r3, r12, lr, pc, xPSR before this runs.
void SysTick_Handler(void) { os_systick_handler(); }

__attribute__((section(".isr_vector")))
const void* vectors[] = { &__stack_top, Reset_Handler, NMI_Handler,
                          HardFault_Handler, /* ... */ SysTick_Handler };
```

On RISC-V there is one entry for everything — every interrupt and every exception — and it must save the registers before it may call C. This is the start of the µOS++ entry (`src/trap.S`), shortened:

```asm
riscv_trap_entry:
    addi    sp, sp, -PORT_CTX_SIZE      # room for the whole frame
    REG_S   x1,  PORT_CTX_X(1)(sp)      # ra
    REG_S   x3,  PORT_CTX_X(3)(sp)      # gp ... and so on for x4..x31
    REG_S   x31, PORT_CTX_X(31)(sp)
    csrr    t0, mepc                    # where the trap happened
    REG_S   t0, PORT_CTX_MEPC(sp)
    csrr    t0, mstatus                 # MPIE/MPP: the state to return to
    REG_S   t0, PORT_CTX_MSTATUS(sp)
#if defined(__riscv_flen)
    frcsr   t0                          # with an FPU: fcsr and f0..f31 too
    REG_S   t0, PORT_CTX_FCSR(sp)
    FREG_S  f0, PORT_CTX_F(0)(sp)       # ... f1..f31
#endif
    mv      a0, sp                      # a0 = the frame
    # count this hart's nesting; on the outermost trap, switch to the
    # hart's interrupt stack
    call    riscv_trap_dispatch         # C++: reads mcause, decides
    mv      sp, a0                      # a0 = frame to resume (maybe another thread's)
    # ... restore mstatus, mepc, FP and x1..x31 from that frame
    mret
```

The dispatcher in C++ then sorts the cause, which is what the vector table does in hardware on ARM:

```cpp
// src/trap.cpp (shape of it)
if (mcause & INTERRUPT_BIT) {
  switch (mcause & 0xFF) {
    case 7:  riscv_port_tick();          break; // machine timer
    case 3:  riscv_port_ipi_received();  break; // machine software interrupt
    case 11: board_external_irq();       break; // PLIC / vendor controller
  }
} else if (mcause == 11 && frame->x[A7] == RISCV_PORT_YIELD_ECALL) {
  frame->x[0] += 4;                              // step over the ecall
  return switch_stacks(frame);                   // the context switch
} else if (mcause == 3 && is_semihosting_trap(frame->x[0])) {
  // no debugger behind a semihosting ebreak: return -1, step over it
} else {
  fault(frame, mcause);                          // report and stop
}
```

Things that are free on ARM and must be written on RISC-V:

- **Return address adjustment.** An exception (`ecall`, `ebreak`, illegal instruction) leaves `mepc` pointing *at* the instruction. To continue after it, software adds 4 (or 2 for a compressed instruction). The semihosting sequence is three 4-byte instructions, so the port adds 8 to skip `ebreak` and the `srai` after it.
- **Nesting.** Cortex-M nests interrupts by priority automatically. RISC-V clears `mstatus.MIE` on entry; a handler that wants to be preempted must set it again itself, after saving `mepc` and `mstatus`. The port's Milk-V Duo dispatcher does exactly that around each PLIC handler.
- **Knowing you are in an interrupt.** Cortex-M reads IPSR. RISC-V has no such register, so the port keeps a per-hart counter (`riscv_trap_nesting[]`) incremented and decremented by the entry code.

## Interrupt controllers

ARM's interrupt controllers do priorities and nesting for you; the standard RISC-V ones give each hart three interrupt lines (software, timer, external) and leave priority handling for external sources to a separate controller that you drive by hand.

|  | NVIC (Cortex-M) | GIC (Cortex-A) | RISC-V CLINT + PLIC |
| --- | --- | --- | --- |
| What the core sees | one vector per source | one IRQ line (plus FIQ) | three lines per hart: MSIP (software), MTIP (timer), MEIP (external), enabled in `mie` |
| Priorities | 2–8 bits per source, preemption automatic | per source; running priority tracked by the CPU interface | PLIC: per-source priority and a per-context threshold; no preemption by itself |
| Which source fired | the vector itself | read `ICC_IAR1_EL1` (GICv3) / `GICC_IAR` (GICv2) | read the PLIC claim register of the hart's context |
| End of interrupt | automatic on return | write `ICC_EOIR1_EL1` / `GICC_EOIR` | write the same ID back to the claim/complete register |
| Nesting | hardware, by priority | possible, with software help | software only: raise the threshold, set `mstatus.MIE`, run the handler, clear it, complete |
| Inter-processor interrupts | not applicable (single core), vendor FIFO on RP2350 | SGIs 0–15 | write 1 to the target hart's MSIP word in the CLINT |

A *context* in PLIC language is one privilege mode of one hart. On the JH-7110S the contexts are numbered in device-tree order: context 0 is hart 0's M-mode (the S7 monitor core has no S-mode), then M and S for each U74, so U74 hart *h*'s M-mode context is 2*h* − 1. Getting this number wrong silently enables or masks another core's interrupts.

A nested PLIC dispatcher on RISC-V, as the Milk-V Duo port does it (`test/boards/milkv-duo/src/irq.cpp`, simplified). The PLIC register offsets are the standard ones:

```cpp
constexpr uintptr_t PLIC = 0x70000000;               // board fact
constexpr unsigned CTX = 0;                          // hart 0, M-mode
volatile uint32_t& threshold = reg(PLIC + 0x200000 + 0x1000 * CTX);
volatile uint32_t& claim     = reg(PLIC + 0x200004 + 0x1000 * CTX);

void board_external_irq() {
  uint32_t id = claim;                     // which source, and mark it in service
  uint32_t old = threshold;
  threshold = priority_of(id);             // only higher priorities may preempt
  RISCV_CSR_CLEAR(mie, MIE_MTIE | MIE_MSIE); // keep the tick and IPI below every IRQ
  RISCV_CSR_SET(mstatus, MSTATUS_MIE);     // allow preemption from now on
  handlers[id]();
  RISCV_CSR_CLEAR(mstatus, MSTATUS_MIE);
  RISCV_CSR_SET(mie, MIE_MTIE | MIE_MSIE);
  threshold = old;
  claim = id;                              // complete
}
```

The same on a GIC, where the CPU interface tracks the running priority itself:

```c
// AArch64, GICv3: acknowledge, handle, end of interrupt.
uint64_t iar = read_sysreg(ICC_IAR1_EL1);
uint32_t id = iar & 0xFFFFFF;
if (id < 1020) {
  local_irq_enable();      // optional nesting: the GIC already masks lower priorities
  handlers[id]();
  local_irq_disable();
  write_sysreg(iar, ICC_EOIR1_EL1);
}
```

Vendor controllers change the picture again. The RP2350's Hazard3 cores do not have a PLIC; they implement a vendor extension (Xh3irq) with CSRs that give the highest-priority pending external interrupt and support preemption in a way closer to the NVIC. The µOS++ Pico 2 board uses it for nested interrupts. The T-Head C906 on the Milk-V Duo uses a standard PLIC, driven by the dispatcher above.

Plain rule for a porter: on RISC-V, *the tick and the inter-processor interrupt are not external interrupts*. They come from the CLINT (or ACLINT) on their own `mie` bits, outside the PLIC's priority scheme. If an external handler re-enables MIE, it must also mask MTIE and MSIE, or the tick will preempt a high-priority device handler.

## The system tick

ARM ticks with a reload counter (SysTick) or a per-core compare register (Generic Timer); RISC-V ticks with a free-running 64-bit counter (`mtime`) and one 64-bit compare register per hart (`mtimecmp`), and the RTOS must move the compare value forward itself on every tick.

|  | SysTick (Cortex-M) | Generic Timer (Cortex-A) | RISC-V CLINT |
| --- | --- | --- | --- |
| Counter | 24-bit, counts down, reloads by itself | 64-bit system count `CNTPCT`, shared | 64-bit `mtime`, shared by all harts |
| Compare | the reload value | per core: `CNTP_CVAL` (absolute) or `CNTP_TVAL` (relative) | per hart: `mtimecmp[h]` (absolute) |
| Periodic by itself | yes | no, rewrite the compare | no, rewrite the compare |
| Interrupt | exception 15 | a PPI on the GIC (30, non-secure physical) | MTIP, a dedicated `mie` bit |
| Reading the time | `SYST_CVR` (24 bits, wraps fast) | `mrs x0, CNTPCT_EL0` | `rdtime` (the `time` CSR) or a load from `mtime` over MMIO |

On Cortex-M, starting a 1 kHz tick is two lines and the hardware repeats it:

```c
SysTick->LOAD = SystemCoreClock / 1000 - 1;
SysTick->VAL  = 0;
SysTick->CTRL = SysTick_CTRL_CLKSOURCE_Msk | SysTick_CTRL_TICKINT_Msk
              | SysTick_CTRL_ENABLE_Msk;
```

On RISC-V the handler advances the deadline every time. In plain form:

```c
// One tick: move this hart's compare value one period forward.
void machine_timer_handler(void) {
  next_tick[hart] += period;            // period = TIMEBASE_HZ / 1000
  mtimecmp_write(next_tick[hart], hart);
  os_systick_handler();
}
```

That is the specification. The three boards then differed in ways the specification allows:

| Board | Timebase | `time` CSR | `mtime` over MMIO | `mtimecmp` writes |
| --- | --- | --- | --- | --- |
| Milk-V Duo (C906) | 25 MHz | yes, used | **load access fault** (measured, also as 32-bit loads) | **two 32-bit halves** (device tree: `clint,has-no-64bit-mmio`) |
| Pico 2 (Hazard3) | 1 MHz (SIO platform timer) | **not implemented** | yes, used | 32-bit halves (RV32) |
| VisionFive 2 Lite (U74) | 4 MHz | not listed in the U7 manual | yes, used (64-bit) | 64-bit |

The port therefore takes the clock source from the board (`TIME_CSR`, `MTIME_READABLE`, `MTIMECMP_SPLIT32`) instead of assuming one. The split write is the subtle part: a compare register written half at a time can briefly hold a value lower than both the old and the new deadline, which fires a spurious interrupt. The safe order sets the high half to all ones first:

```cpp
// include/clint.hpp
if constexpr (riscv_board::MTIMECMP_SPLIT32) {
  reg32(a + 4) = 0xFFFFFFFFu;                         // never too early
  reg32(a)     = static_cast<uint32_t>(value);
  reg32(a + 4) = static_cast<uint32_t>(value >> 32);
} else {
  *reinterpret_cast<volatile uint64_t*>(a) = value;
}
```

**Missed ticks.** A debugger halt (every semihosting call halts the hart), a long critical section or a slow handler can let several periods pass. SysTick simply loses them. Because `mtime` keeps running, a RISC-V tick can see how far behind it is and catch up. The µOS++ port counts the owed periods, performs N − 1 bare clock increments and then one normal tick, so timeouts are checked once against the advanced clock instead of N times in a burst:

```cpp
// src/rtos/os-core.cpp (shape of riscv_port_tick)
const uint64_t now = clint::now();
uint64_t due = 0;
if (next_tick[h] <= now) {
  due = (now - next_tick[h]) / tick_period + 1;
  next_tick[h] += due * tick_period;
}
tick_write(h);
for (uint64_t i = 1; i < due; ++i) {
  sysclock.internal_increment_count();   // bare: no timeout checks
  hrclock.internal_increment_count();
}
os_systick_handler();                    // one real tick
```

Measured with clock-catchup on the VisionFive 2 Lite: one second of masked busy-waiting, then sleeps; sysclock 1500 ms against `mtime` 1499 ms.

## Context switching

Cortex-M switches threads in PendSV, a software-triggered exception at the lowest priority that the hardware delays until every other handler has finished; RISC-V has no such exception, so the µOS++ port switches through a synchronous `ecall` from the thread itself, and on the way out of the outermost trap when an interrupt made another thread ready.

### Cortex-M: PendSV

The kernel sets a pending bit; the switch runs when no other exception is active. The hardware has already stacked r0–r3, r12, lr, pc and xPSR on the thread's PSP, so PendSV only saves r4–r11 (and the high FP registers if the thread used the FPU):

```asm
@ Cortex-M4F PendSV handler, the classic shape
PendSV_Handler:
    mrs     r0, psp
    tst     lr, #0x10            @ EXC_RETURN bit 4 = 0: FP frame in use
    it      eq
    vstmdbeq r0!, {s16-s31}
    stmdb   r0!, {r4-r11, lr}    @ the rest of the outgoing context
    bl      os_switch_stacks     @ r0 = old sp in, new sp out
    ldmia   r0!, {r4-r11, lr}
    tst     lr, #0x10
    it      eq
    vldmiaeq r0!, {s16-s31}
    msr     psp, r0
    bx      lr                   @ hardware unstacks the rest
```

```c
// Asking for a switch from anywhere, thread or interrupt:
SCB->ICSR = SCB_ICSR_PENDSVSET_Msk;
__DSB(); __ISB();
```

### RISC-V: ecall from the thread, switch on trap exit

The port's mapping, from the header of `src/rtos/os-core.cpp`:

| Cortex-M | RISC-V port |
| --- | --- |
| SysTick | machine timer (CLINT `mtimecmp` against the time counter) |
| PRIMASK | `mstatus.MIE` |
| PendSV from a thread | `ecall` with a7 = the port's marker |
| PendSV from an interrupt | a flag; the switch happens on the way out of the outermost trap |
| hardware-stacked half frame + r4–r11 | the full frame built by `trap.S` |
| IPSR != 0 | `riscv_trap_nesting[hart] != 0` |

A thread that blocks calls `reschedule()`, which executes an `ecall`:

```cpp
// src/rtos/os-core.cpp
void riscv_port_yield(void) {
  register ctx_reg_t a7 __asm__("a7") = RISCV_PORT_YIELD_ECALL; // "YSOU"
  __asm__ volatile("ecall" : "+r"(a7) : : "memory");
}
```

The trap entry saves the whole frame, the dispatcher sees `mcause == 11` with the marker in a7, steps `mepc` past the `ecall`, and asks the scheduler for the next thread. `switch_stacks()` stores the outgoing frame pointer in the thread object and returns the incoming thread's saved frame; `trap.S` restores from that frame and executes `mret`, which lands in the other thread.

```cpp
// src/trap.cpp
if (mcause == EXC_ECALL_M && frame->x[CTX_A7] == RISCV_PORT_YIELD_ECALL
    && riscv_trap_nesting[riscv::this_hart()] == 1) {
  frame->x[0] += 4;          // resume after the ecall when switched back in
  frame->x[CTX_A7] = 0;      // consume the marker
  return os::rtos::port::scheduler::switch_stacks(
      reinterpret_cast<os::rtos::port::stack::element_t*>(frame));
}
```

Why not use the machine software interrupt (MSIP) as a "PendSV"? The port tried that first. Writing MSIP is a posted store to the CLINT; on the C906 the interrupt arrives some cycles later (on QEMU, at once). A thread that had just marked itself suspended ran a few more instructions past `reschedule()` and removed its own wake-up before the interrupt was taken. This was measured on the Milk-V Duo. An `ecall` is a synchronous, precise exception: the trap is taken *at* that instruction, so nothing runs after it. MSIP is now used only for inter-processor interrupts and the port's software interrupt lines.

What each side saves, in plain numbers:

|  | Cortex-M4F | RISC-V RV64GC (µOS++) |
| --- | --- | --- |
| Saved by hardware | 8 words (+ 18 with an FP frame) | 0 |
| Saved by software | 9 words (r4–r11, lr) (+ 16 FP) | 31 registers + `mepc` + `mstatus` + `fcsr` + 32 FP registers |
| Frame size | 68 bytes without FP, 204 with | 528 bytes |

The RISC-V frame is bigger because the port saves everything on every trap and does not track which registers a thread actually changed. That keeps the code short and the frame format single.

## Critical sections and interrupt masking

On a single core both architectures protect a short critical section the same way — turn interrupts off, remember whether they were on, put them back — but Cortex-M can also mask *by priority*, which plain RISC-V cannot.

|  | Cortex-M | AArch64 | RISC-V M-mode |
| --- | --- | --- | --- |
| All interrupts off | `cpsid i` (PRIMASK = 1) | `msr daifset, #2` | `csrci mstatus, 8` (MIE = 0) |
| Read and clear in one instruction | no (`mrs` then `cpsid`) | no | yes: `csrrci t0, mstatus, 8` returns the old value |
| Mask only lower priorities | `BASEPRI` (ARMv7-M and later) | GIC priority mask `ICC_PMR_EL1` | PLIC threshold for external sources only; nothing for the tick or IPI except clearing their `mie` bits |
| One source class | NVIC enable bits | GIC enables, DAIF bits per class | `mie.MTIE`, `mie.MSIE`, `mie.MEIE` |

The usual save/restore pattern, side by side:

```c
// Cortex-M
static inline uint32_t irq_save(void) {
  uint32_t primask = __get_PRIMASK();
  __disable_irq();
  return primask;
}
static inline void irq_restore(uint32_t primask) { __set_PRIMASK(primask); }
```

```cpp
// RISC-V (include/riscv-csr.hpp in the port): one atomic CSR instruction each.
inline reg_t mstatus_clear_mie(void) {
  reg_t v;
  __asm__ volatile("csrrci %0, mstatus, 8" : "=r"(v)::"memory");
  return v & MSTATUS_MIE;           // non-zero if interrupts were on
}
inline reg_t mstatus_set_mie(void) {
  reg_t v;
  __asm__ volatile("csrrsi %0, mstatus, 8" : "=r"(v)::"memory");
  return v & MSTATUS_MIE;           // the previous MIE bit
}
```

The `"memory"` clobber matters on both: without it the compiler may move loads and stores across the mask, outside the critical section.

**A deferred switch.** On Cortex-M, a PendSV requested inside a critical section simply waits: the moment PRIMASK is cleared, the pending exception is taken. RISC-V has no pending exception to wait, so the port remembers the request and performs the switch itself when the critical section ends and MIE is set again:

```cpp
// src/rtos/os-core.cpp
void riscv_port_deferred_yield(void) {
  if (os::rtos::interrupts::in_handler_mode() || os::rtos::scheduler::locked()
      || (RISCV_CSR_READ(mstatus) & riscv::csr::MSTATUS_MIE) == 0)
    return;                       // still cannot switch
  riscv_port_yield();             // the ecall
}
```

**On SMP, masking is not enough.** Turning interrupts off on one core does nothing to the others. Both architectures add a spinlock around the kernel's critical sections on multi-core builds; see *SMP part 2*.

## Memory protection and translation

ARM attaches memory type (cacheable, device, shareable) to its protection and translation entries; base RISC-V does not — memory type comes from fixed platform attributes (PMAs) — and RISC-V machine mode is never translated by the MMU at all.

|  | Cortex-M | Cortex-A | RISC-V |
| --- | --- | --- | --- |
| Protection without translation | MPU: 8 or 16 regions (base/size, or base/limit on ARMv8-M) | — | PMP: up to 16 (or 64) entries, TOR or NAPOT ranges, R/W/X per entry |
| Translation | none | MMU: ARMv7 short/long descriptors, AArch64 4/16/64 KiB granules, up to 4 levels | Sv32 (RV32), Sv39 / Sv48 / Sv57 (RV64): 4 KiB pages, 2 MiB and 1 GiB leaves at higher levels |
| Who is translated | — | EL0 and EL1 (EL2/EL3 by their own tables) | S and U mode only; **M-mode is never translated** |
| Memory type in the entry | MPU attributes (TEX/C/B, or MAIR index on v8-M) | AttrIndx into `MAIR_ELx` | none in base Sv39; Svpbmt adds 2 bits; T-Head C906 uses vendor bits 59–63 |
| Accessed/dirty bits | — | hardware or software managed | A and D may be updated by hardware or must be set by software (the C906 faults instead of setting them) |

**An RTOS in M-mode can still use the MMU.** The µOS++ port builds a real Sv39 identity map, and its `mmu-test` proves the tables translate by making M-mode loads and stores *as if* they came from S-mode: with `mstatus.MPRV = 1` and `mstatus.MPP = S`, data accesses go through `satp`.

```cpp
// src/mmu.cpp: one translated load from M-mode.
__asm__ volatile("csrc mstatus, %[mask]\n\t"   // clear MPP
                 "csrs mstatus, %[s]\n\t"      // MPP = S
                 "csrs mstatus, %[mprv]\n\t"   // MPRV = 1: loads/stores translated
                 "ld   %[v], 0(%[va])\n\t"
                 "csrc mstatus, %[mprv]\n\t"
                 "csrs mstatus, %[mask]\n\t"   // back to MPP = M
                 : [v] "=&r"(v)
                 : [va] "r"(va), [mask] "r"(mpp_mask), [s] "r"(mpp_s), [mprv] "r"(mprv)
                 : "memory");
```

Between setting and clearing MPRV the only data access must be the one you mean, so the sequence is one `asm` block with its operands in registers. A PMP entry that allows S-mode access is also needed, because MPRV accesses are checked by PMP as S-mode accesses (`mmu::pmp_allow_all()` sets one NAPOT entry over the whole space).

A 2 MiB Sv39 leaf, as the port writes it:

```cpp
// PTE = physical page number << 10 | flags | V
inline constexpr uint64_t FLAGS_RAM = PTE_R | PTE_W | PTE_X | PTE_A | PTE_D;
inline constexpr uint64_t FLAGS_DEV = PTE_R | PTE_W | PTE_A | PTE_D;
table_of(l2)[vpn1(va)] = ((pa >> 12) << 10) | flags | PTE_V;
RISCV_CSR_WRITE(satp, (8ULL << 60) | (root_pa >> 12));   // mode 8 = Sv39
__asm__ volatile("sfence.vma zero, zero" ::: "memory");
```

The AArch64 equivalent of the attribute part lives in a separate register:

```c
// AArch64: memory types are indexes into MAIR_EL1.
write_sysreg(0xFF /* idx0: normal WB */ | (0x00ULL << 8) /* idx1: Device-nGnRnE */,
             MAIR_EL1);
#define PTE_NORMAL (1ULL << 10 /* AF */ | (3ULL << 8) /* inner shareable */ | (0 << 2))
#define PTE_DEVICE (1ULL << 10 | (1 << 2) /* AttrIndx 1 */ | (1ULL << 54) /* UXN */)
```

Three board differences met during the port (the first one measured):

- **T-Head attribute bits.** The Milk-V Duo's boot loader turns on the C906's extended page attributes (`mxstatus.MAEE`). With MAEE on, a RAM page whose bits 59–63 are 0 is *non-cacheable*. Translated accesses then bypassed the data cache that untranslated M-mode accesses went through, and `mmu-test` failed until the board's RAM regions carried Cacheable | Bufferable | Shareable. On a standard Sv39 core (the U74) those bits are reserved and must be 0, so they are a board fact in `riscv-board.hpp`.
- **Mapped vs unmapped test addresses.** `0x40000000` is unmapped on the Duo (DDR starts at `0x80000000`) and is DDR on the JH-7110S, so the VisionFive 2 copy of `mmu-test` uses `0x80000000` for its alias.
- **PMP left by firmware.** OpenSBI configures PMP entries to protect itself from S-mode. They do not restrict M-mode unless locked, which is why an RTOS that takes over in M-mode can overwrite OpenSBI's memory, and why MPRV-translated accesses need their own PMP entry.

## Floating point, extensions and misaligned accesses

Both architectures can avoid saving floating-point registers for threads that never use them, but they do it differently: Cortex-M with *lazy stacking* in hardware, RISC-V with a software-visible state field (`mstatus.FS`) that the trap handler reads.

|  | Cortex-M4F / M7 / M33 | AArch64 | RISC-V F/D |
| --- | --- | --- | --- |
| Registers | s0–s31 (single) or d0–d15 (M7 double), FPSCR | v0–v31 (128-bit), FPCR/FPSR | f0–f31 (32 or 64-bit), `fcsr` |
| Turn on | `CPACR` CP10/CP11 = full access | `CPACR_EL1.FPEN` | `mstatus.FS` = Initial (01) |
| Know if it was used | `EXC_RETURN` bit 4, `CONTROL.FPCA` | trap on first use (FPEN = 0) | `mstatus.FS`: Off / Initial / Clean / Dirty |
| Save on exception | lazy: space reserved, registers saved only if the handler uses the FPU | software | software |

Turning the FPU on:

```c
// Cortex-M4F/M7/M33
SCB->CPACR |= (3UL << 20) | (3UL << 22);   // CP10, CP11 full access
__DSB(); __ISB();
```

```asm
# RISC-V (src/startup.S): FS = Initial, clean rounding state.
    li      t0, (3 << 13)
    csrc    mstatus, t0
    li      t0, (1 << 13)
    csrs    mstatus, t0
    fscsr   zero
```

The µOS++ port takes the simple road: with an FPU, `FS` is never Off, and every trap saves `fcsr` and f0–f31. A preemptive switch can land in the middle of any floating-point sequence, so this is always correct. A future optimisation could skip the save when `FS` reads Clean.

**An SMP pitfall found on the U74.** The RISC-V port originally enabled the FPU in `_start` *after* the secondary harts had already branched off to their park loop. On the Pico 2 (no FPU) and QEMU rv32 that never mattered. On the four-core U74 it would have: the first trap on a secondary hart executes `fsd` to save f0, and with `FS = Off` that is an illegal instruction. The fix moved the FPU set-up before the hart check, so every hart enables its own FPU. On a multi-core Cortex-M the same rule applies: CPACR is a per-core register, so each core's start-up code must enable its own FPU.

### Extensions decide what the compiler may emit

On ARM, `-mcpu=cortex-m33` implies everything that core has. On RISC-V you list the extensions, and the list must match the core, or the build silently uses an instruction the core lacks:

| Board | `-march` used in the port | Notes |
| --- | --- | --- |
| Milk-V Duo (C906) | `rv64imafdc_zicsr_zifencei` | `-mtune=thead-c906` |
| Pico 2 (Hazard3) | `rv32ima_zicsr_zifencei_zba_zbb_zbs_zbkb_zca_zcb_zcmp` | no F/D: floating point is software |
| VisionFive 2 Lite (U74) | `rv64imafdc_zicsr_zifencei_zba_zbb` | `-mtune=sifive-7-series` |

### Misaligned accesses

Cortex-M3 and later handle unaligned single loads and stores to normal memory in hardware (not `LDRD`, `LDM`, or device memory); Cortex-A does too when alignment checking is off. RISC-V allows a core to do them in hardware, slowly, or to trap so that software emulates them. The port met both:

- **C906:** misaligned 64-bit loads and stores work in hardware (measured; `mmu-test` step 5 passes on the Duo).
- **U74:** "misaligned accesses are not supported in hardware and result in a trap to support software emulation" (SiFive U7 manual, data memory system). In M-mode with your own trap handler there is no emulator behind it, so the VisionFive 2 copy of `mmu-test` skips that step. Portable code should not rely on misaligned access on RISC-V.

## Atomics and memory ordering

Both architectures offer a load-reserved/store-conditional pair, but RISC-V also has single-instruction atomic memory operations (AMOs) in its base A extension, and it expresses ordering with `aq`/`rl` bits on the atomic instruction or with one general `fence`, where ARM has three barrier instructions.

|  | ARMv7-M / ARMv7-A | AArch64 | RISC-V A extension |
| --- | --- | --- | --- |
| Reserve / conditional | `LDREX` / `STREX` | `LDXR` / `STXR`, with acquire/release forms `LDAXR` / `STLXR` | `lr.w` / `sc.w` (`.d` on RV64), with `.aq` / `.rl` |
| Single-instruction atomics | none (ARMv6-M has no exclusives at all) | LSE (ARMv8.1): `SWP`, `CAS`, `LDADD` … | AMOs: `amoswap`, `amoadd`, `amoand`, `amoor`, `amoxor`, `amomin/max` |
| Barriers | `DMB`, `DSB`, `ISB` | `DMB`, `DSB`, `ISB` (+ domains: `ish`, `osh` …) | `fence pred, succ` (e.g. `fence rw, rw`), `fence.i` for instruction fetch |
| Recent split | — | — | Zaamo (AMOs only) and Zalrsc (LR/SC only); toolchains name multilibs after them |

The same spinlock, as each compiler emits it from `__atomic_exchange_n(&lock, 1, __ATOMIC_ACQUIRE)`:

```asm
@ ARMv7-M: a retry loop
1:  ldrex   r1, [r0]
    strex   r2, r3, [r0]       @ r3 = 1
    cmp     r2, #0
    bne     1b
    dmb                        @ acquire
```

```asm
# RISC-V: one instruction, acquire ordering built in
    li          t1, 1
    amoswap.w.aq t0, t1, (a0)  # t0 = old value
```

The µOS++ RISC-V kernel lock, recursive per hart, taken with interrupts masked on the calling hart:

```cpp
// src/rtos/os-core.cpp
void riscv_smp_klock_acquire(void) {
  const unsigned h = riscv::this_hart();
  if (smp_klock.owner == h) { smp_klock.depth = smp_klock.depth + 1; return; }
  while (__atomic_exchange_n(&smp_klock.word, 1u, __ATOMIC_ACQUIRE) != 0)
    while (__atomic_load_n(&smp_klock.word, __ATOMIC_RELAXED) != 0) {}
  smp_klock.owner = h;
  smp_klock.depth = 1;
}

void riscv_smp_klock_release(void) {
  if (smp_klock.owner != riscv::this_hart() || smp_klock.depth == 0) return;
  if (--smp_klock.depth == 0) {
    smp_klock.owner = SMP_NO_OWNER;
    __atomic_store_n(&smp_klock.word, 0u, __ATOMIC_RELEASE);
  }
}
```

The inner relaxed-load loop spins on a plain read, so the waiting hart does not keep the cache line busy with failed swaps.

### Where atomics do not work

An atomic instruction needs memory that supports it, and that is a platform property on both architectures:

- **RP2350 QSPI PSRAM (RISC-V):** an `amoswap.w` to the PSRAM window faulted with `mcause` 7 (store/AMO access fault), measured on the WeAct RP2350B. The port places every object it changes with atomics in sections `.data.amo` / `.bss.amo`, which the PSRAM linker script keeps in SRAM:

```cpp
// include/riscv-amo.hpp
#define RISCV_AMO_DATA __attribute__((section(".data.amo")))
#define RISCV_AMO_BSS  __attribute__((section(".bss.amo")))
```

- **RP2350 Cortex-M33:** the Cortex-M Pico 2 port notes that `LDREX`/`STREX` were only exclusive per core on this chip, so its barrier used the SIO hardware spinlocks instead. The RISC-V side uses AMOs, which the RP2350 implements atomically across both Hazard3 cores.

### Ordering with devices

RISC-V `fence` names what must be ordered: `r` and `w` for memory, `i` and `o` for device input and output. The port uses `fence o, i` after raising another hart's software interrupt, so that a later read of the device cannot overtake the write:

```cpp
// include/clint.hpp
inline void msip_set(unsigned hart) {
  reg32(msip_addr(hart)) = 1;
  __asm__ volatile("fence o, i" ::: "memory");
}
```

The ARM equivalent is a `DSB` (completion) where a `DMB` (ordering) is not enough. Instruction fetch is the other case: after writing code into memory (a debugger load, a loader), ARM needs cache maintenance plus `ISB`; RISC-V needs `fence.i` on each hart that will execute it, which is why the port's `_start` runs `fence.i` on every hart.

## SMP part 1: identifying and starting cores

On ARM, secondary cores are usually held off by firmware or a boot ROM until the OS asks for them (PSCI on Cortex-A, a FIFO handshake on the RP2350); on RISC-V without firmware, every hart typically starts running the same reset code at once, and the OS must park all but one of them itself.

### Which core am I?

|  | Cortex-A | RP2350 (both cores) | RISC-V |
| --- | --- | --- | --- |
| Register | `MPIDR_EL1`: affinity fields Aff0–Aff3 (core, cluster …) | SIO `CPUID` register (0 or 1) | `mhartid` CSR |
| Guarantees | unique per core; hierarchical, not dense | 0 and 1 | unique per hart, **not** guaranteed to start at 0 or to be dense; only one hart is guaranteed to be 0 |
| Usual mapping to a CPU index | from Aff0/Aff1 by a board table | the value itself | `mhartid` itself on QEMU virt, Pico 2, Duo; `mhartid − 1` on the JH-7110S |

The JH-7110S is the clear example: its hart 0 is an S7 monitor core (rv64imac, no MMU), and the four application U74 cores are harts 1–4. An RTOS that uses `mhartid` as an array index would index its per-CPU arrays at 1..4, out of bounds for `OS_NCPU = 4`. The µOS++ port adds one board constant and uses it everywhere a hart id becomes an index:

```cpp
// include/port_ctx.hpp: 0 on every board but the JH-7110S (board.cmake: RISCV_HART_BASE=1)
#if !defined(RISCV_HART_BASE)
#define RISCV_HART_BASE 0
#endif

// include/riscv-hart.hpp
inline unsigned this_hart(void) {
#if OS_NCPU > 1
  reg_t v;
  __asm__ volatile("csrr %0, mhartid" : "=r"(v));
  return static_cast<unsigned>(v - RISCV_HART_BASE);   // the CPU index
#else
  return 0;
#endif
}
```

The CLINT, on the other hand, is indexed by the real hart id, so the board offsets its per-hart register bases instead: CPU *n* uses the `msip` and `mtimecmp` of hart *n* + 1.

```cpp
// test/boards/visionfive2-lite/include/riscv-board.hpp
inline constexpr unsigned BOOT_HART = RISCV_HART_BASE;               // 1
inline constexpr uintptr_t CLINT_MSIP     = 0x02000000 + BOOT_HART * 4;
inline constexpr uintptr_t CLINT_MTIMECMP = 0x02004000 + BOOT_HART * 8;
```

### Starting the other cores

|  | Cortex-A with firmware | RP2350 | RISC-V, this port |
| --- | --- | --- | --- |
| Where secondaries wait | in firmware (EL3), powered or held | in the boot ROM | in the RTOS's own `_start`, in a park loop |
| How the OS starts one | PSCI `CPU_ON(mpidr, entry, context)` via `SMC`/`HVC` | push {0, 0, 1, vector table, sp, entry} through the SIO FIFO, with a reset of core 1 first | write the entry and stack into the hart's release slot, then a "magic" word |
| What the new core gets | a clean EL, entry address, one argument | its vector table, stack pointer and entry | its own stack, `gp` and `mtvec` already set by `_start` |

The RISC-V park loop, from `src/startup.S` (shortened). Each hart computes its CPU index, finds its slot `{magic, entry, sp}` and spins until CPU 0 writes the magic:

```asm
riscv_secondary_park:
    csrr    t0, mhartid
    addi    t0, t0, -RISCV_HART_BASE   # CPU index; below the base it wraps
    li      t1, OS_NCPU
    bgeu    t0, t1, 9f                 # not driven by this build: park forever
    li      t1, (3 * PORT_REGBYTES)
    mul     t0, t0, t1
    la      t1, riscv_secondary_boot
    add     t0, t0, t1                 # this CPU's slot
    li      t2, RISCV_SECONDARY_MAGIC
1:  REG_L   t1, 0(t0)
    bne     t1, t2, 1b                 # wait for the go word
    fence   r, r
    REG_L   sp, (2 * PORT_REGBYTES)(t0)
    REG_L   t1, PORT_REGBYTES(t0)
    fence.i
    jr      t1
9:  j       9b                         # never wfi in this port
```

And the release, on CPU 0. The entry and stack are written first and the magic last, with release ordering, so a hart that sees the magic also sees the rest:

```cpp
// src/rtos/os-core.cpp
void riscv_smp_release_hart(unsigned hart, void (*entry)(void), uintptr_t stack_top) {
  if (hart == 0 || hart >= OS_NCPU) return;
  uintptr_t* slot = &riscv_secondary_boot[3 * hart];
  slot[2] = stack_top & ~uintptr_t(15);
  slot[1] = reinterpret_cast<uintptr_t>(entry);
  __atomic_store_n(&slot[0], uintptr_t(RISCV_SECONDARY_MAGIC), __ATOMIC_RELEASE);
}
```

Two things went wrong or nearly wrong on real hardware, and both are worth knowing:

- **The release slots live in `.bss`, and DDR keeps its contents across debugger loads.** CPU 0 zeroes `.bss` only after it starts, while the secondaries are already spinning on their slots. A slot left holding the magic from the previous run would release a hart into a stale entry address. On QEMU, RAM starts zeroed, so this never shows. The VisionFive 2 runner clears the slots through OpenOCD before it starts any hart.
- **Per-hart initialisation must happen before the park.** Anything the secondaries need later and cannot do after the release (the FPU enable, `fence.i`, `mtvec`, `gp`) is done in `_start` before the hart check. See *Floating point*.

On the VisionFive 2 Lite, the four-core `smp-test2` shows the result directly: every worker line reports `cpu=n mhartid=n+1`, and every worker ran all 8 of its beats on its own hart.

## SMP part 2: inter-processor interrupts, locks and per-core state

An SMP kernel needs four things from the hardware: a way to poke another core, an atomic lock, a tick on every core, and a cheap way for a core to find its own data. ARM and RISC-V provide the first three very differently, and RISC-V has no hardware help for the fourth beyond `mhartid` and the `tp` register.

### Poking another core

|  | Cortex-A + GIC | RP2350 (both architectures) | RISC-V CLINT |
| --- | --- | --- | --- |
| Mechanism | Software Generated Interrupt (SGI 0–15) | SIO inter-core FIFO interrupt (Cortex-M); SIO `RISCV_SOFTIRQ` register (Hazard3) | write 1 to the target hart's `msip` word |
| Arrives as | a GIC interrupt like any other | an NVIC interrupt / the machine software interrupt | MSIP (`mcause` = interrupt 3) |
| Cleared by | acknowledge + EOI | reading the FIFO / writing the clear bit | the receiver writes 0 to its own `msip` |
| Low-power wait | `WFE` + `SEV` | `WFE` + `SEV` (Cortex-M) | `wfi`, or `wrs.nto` with the Zawrs extension; the µOS++ port never sleeps |

Raising a reschedule on another core, side by side:

```c
// AArch64, GICv3: SGI 1 to the core with Aff0 = cpu in this cluster.
write_sysreg((1ULL << 24) /* INTID 1 */ | (1ULL << cpu) /* target list */,
             ICC_SGI1R_EL1);
__asm__ volatile("isb");
```

```cpp
// RISC-V port: src/rtos/os-core.cpp
void port_smp_ipi(unsigned cpu) {
  if (cpu >= OS_NCPU || cpu == riscv::this_hart()) return;
  clint::msip_set(cpu);      // reg32(CLINT_MSIP + 4 * cpu) = 1; fence o, i
}
```

The RP2350's Hazard3 cores are not wired to a CLINT `msip`; they share one SIO register where writing `1 << h` sets core *h*'s software interrupt and `1 << (8 + h)` clears it. The port selects that with a board define (`RISCV_BOARD_SOFTIRQ_SIO`), so the kernel code calling `msip_set()` is the same on both.

### The tick on every core

On Cortex-A each core has its own Generic Timer compare register; on RISC-V each hart has its own `mtimecmp`. In both cases only one core should advance the RTOS clock. In the µOS++ RISC-V port, hart 0 ticks the clock and runs the timeouts; the other harts' ticks only reschedule, so they pick up threads that hart 0 has made ready. This mirrors the RP2350 Cortex-M port, where core 1's SysTick only reschedules.

### Per-core state and idle threads

The kernel keeps one "current thread" per core and one idle thread per core. In the µOS++ kernel the idle thread of CPU *n* is named `idle<n>` and registered in `os_idle_thread_core[n]` before that CPU is released; a thread with that identity can only run on its own core. Starting CPUs 1–3 on the VisionFive 2 Lite:

```cpp
// test/visionfive2-lite/smp-test2/main.cpp
for (unsigned c = 1; c < OS_NCPU; ++c) {
  thread::attributes attr = thread::initializer;
  attr.th_stack_address = idle_stacks[c];
  attr.th_stack_size_bytes = sizeof(idle_stacks[c]);
  std::snprintf(idle_names[c], sizeof(idle_names[c]), "idle%u", c);
  os::rtos::scheduler::os_idle_thread_core[c] =
      new thread(idle_names[c], secondary_idle_func, nullptr, attr);
}
for (unsigned c = 1; c < OS_NCPU; ++c)
  multicore::launch_core(c, port_smp_secondary_start, port_secondary_stack_top(c));
port_smp_core0_ipi_enable();
```

### The affinity pitfall (measured)

Pinning a thread to a core with `cpu_affinity()` *after* creating it leaves a window. A thread is ready the moment it is constructed, with the default "any core" affinity, and an idle core may pick it up and keep running it there. In the first four-core run of `smp-mat-test` on the VisionFive 2 Lite, the solver meant for core 0 ran on mhartid 4, and the solvers for cores 1 and 2 both ran on mhartid 2. The answer was still correct; the parallelism was not what the test claimed. The fix is the same on ARM and RISC-V — the thread pins itself first thing and yields until it is on its core:

```cpp
this_thread::thread().cpu_affinity(1u << core_id);
while (port_cpu_id() != static_cast<unsigned>(core_id))
  this_thread::yield();
```

With that, each solver recorded its own `mhartid` and the run showed c0..c3 on harts 1..4: parallel block solve 15.9 ms against 60.3 ms for the classical solve on one core (N = 240, B = 30), a 3.80× speedup, identical results.

## Debug and semihosting

ARM debug goes through CoreSight (a debug access port reached over SWD or JTAG) and halts a core on a `BKPT`; RISC-V debug goes through a Debug Module reached over JTAG, and halts a hart on an `ebreak` only when the debugger has set a bit in the hart's `dcsr`. Semihosting rides on those breakpoints on both.

|  | Cortex-M | AArch64 | RISC-V |
| --- | --- | --- | --- |
| Transport | SWD (2 wires) or JTAG | SWD or JTAG via CoreSight | JTAG to the Debug Transport Module, then the Debug Module (DMI) |
| Halt on a breakpoint instruction | always (`BKPT`) | `HLT` / `BRK` | only if `dcsr.ebreakm` (M-mode), `ebreaks`, `ebreaku` is set; otherwise `ebreak` is an ordinary exception (`mcause` 3) |
| Read registers while halted | core debug registers | external debug interface | abstract commands, or code in the program buffer that the hart executes |
| Semihosting trap | `BKPT 0xAB` | `HLT 0xF000` | `slli x0, x0, 0x1f` / `ebreak` / `srai x0, x0, 7` |
| Operation, argument, result | r0, r1, r0 | w0/x0, x1, x0 | a0, a1, a0 |

The RISC-V semihosting call is three instructions so that a debugger can recognise it by the two no-op shifts around the `ebreak`, and so that it is never confused with a real breakpoint:

```cpp
// include/semihosting.hpp
inline long __attribute__((noinline)) call(long operation, const volatile void* arg) noexcept {
  if (riscv_semihosting_absent) return -1;
  register long a0 __asm__("a0") = operation;
  register const volatile void* a1 __asm__("a1") = arg;
  __asm__ volatile(".option push\n"
                   ".option norvc\n"        // all three must be 4-byte instructions
                   ".balign 16\n"
                   "slli x0, x0, 0x1f\n"
                   "ebreak\n"
                   "srai x0, x0, 7\n"
                   ".option pop\n"
                   : "+r"(a0) : "r"(a1) : "memory");
  return a0;
}
```

Without a debugger, the `ebreak` traps to the port's own handler, which recognises the sequence, returns −1 in a0, skips 8 bytes and sets `riscv_semihosting_absent`, so later calls return at once. A Cortex-M `BKPT` with no debugger attached escalates to a HardFault instead, and needs a fault handler that does the same recognition.

### Measured on the VisionFive 2 Lite with a DAPLink

The board's debug behaviour accounted for most of the work on that board, and none of it is in the RISC-V specifications:

| Observation | Consequence |
| --- | --- |
| The probe is CMSIS-DAP v1 over USB HID: about 1.2 ms per debug-module word | 3.3 KiB/s loads and about 0.8 s per semihosting call; JTAG clock 2, 4 or 10 MHz made no difference |
| `SYS_WRITE0` makes OpenOCD read the string one byte per round trip | the console copy uses `SYS_WRITE` (buffer + length, one bulk read) |
| A hart left halted on the *previous* session's semihosting exit `ebreak` (`dcsr.cause` 1) did not halt on its `ebreak`s in the next session, although `dcsr.ebreakm` read 1 | runs strictly alternated PASS and hang; the runner now runs each hart briefly on a park loop and stops it with a halt request before starting the test: 4 of 4 back-to-back passes |
| With `target smp`, OpenOCD's semihosting handler resumed one hart of four and the program's registers were wrong after the first call | the configuration uses four independent targets |
| In an SMP target group, `resume <address>` sends every hart to that address | three harts ran the test at once (the UART showed each character three times); the runner sets each hart's `pc` and resumes without an address |

The resulting OpenOCD session for a four-hart test, as `hw.sh` drives it:

```text
init
foreach n {2 3 4 1} { targets jh7110.cpu$n; halt }
load_image smp-test2.elf 0 elf
# for each hart 1..4:
targets jh7110.cpuN; reg priv 3; reg pc <riscv_board_park>; resume; sleep 100; halt
arm semihosting enable
# clear the release slots (DDR keeps the previous run's)
targets jh7110.cpu1; write_memory <riscv_secondary_boot> 64 [lrepeat 12 0]
# harts 2..4 to _start (they park), then hart 1
targets jh7110.cpu2; reg pc 0x40200000; resume
targets jh7110.cpu3; reg pc 0x40200000; resume
targets jh7110.cpu4; reg pc 0x40200000; resume
targets jh7110.cpu1; reg pc 0x40200000; resume
```

The equivalent for a Cortex-M is four commands (`reset halt`, `load_image`, `arm semihosting enable`, `resume`), because the core resets into a known state and the vector table gives the debugger the entry point and stack.

## Boot and start-up code

A Cortex-M is ready to run C almost from reset, because the hardware loads the stack pointer and the entry address from the first two words of the vector table; a RISC-V hart starts at an implementation-defined address with no stack, no trap vector and no global pointer, and the first instructions must set all three before anything else.

| Step | Cortex-M | AArch64 (EL1, after firmware) | RISC-V M-mode |
| --- | --- | --- | --- |
| Initial stack pointer | loaded by hardware from vector word 0 | set by code | set by code |
| Entry address | vector word 1 | given by firmware (PSCI, boot loader) | reset vector (vendor) or the debugger's `pc` |
| Trap vector | `VTOR` reset value (0 or as boot ROM set it) | `VBAR_EL1` set by code | `mtvec` set by code |
| Global pointer | — | — | `gp`, with relaxation off |
| Interrupts at entry | enabled (PRIMASK = 0) | masked (DAIF) by firmware convention | whatever the previous owner left: `mstatus.MIE`, `mie`, pending `mip` bits |
| Caches and MMU | off or as the ROM left them | usually off; turned on by the OS | as the boot loader left them (the Duo's BL2 sets `mxstatus`) |

The Cortex-M version, in C:

```c
extern uint32_t __stack_top, __data_load, __data_start, __data_end, __bss_start, __bss_end;

void Reset_Handler(void) {
  // sp is already __stack_top: the hardware loaded it from the vector table.
  memcpy(&__data_start, &__data_load, (size_t)((char*)&__data_end - (char*)&__data_start));
  memset(&__bss_start, 0, (size_t)((char*)&__bss_end - (char*)&__bss_start));
  SystemInit();
  __libc_init_array();
  main();
}
```

The RISC-V version must be assembly at least until the stack exists. The µOS++ `_start` (`src/startup.S`), shortened:

```asm
_start:
    csrci   mstatus, 8              # interrupts off: distrust whoever ran before
    csrw    mie, zero               # every source off
    la      t0, riscv_trap_entry
    csrw    mtvec, t0               # our trap vector (direct mode)
    .option push
    .option norelax
    la      gp, __global_pointer$
    .option pop
    mv      tp, zero
    li      t0, (1 << 17)
    csrc    mstatus, t0             # MPRV off
#if defined(__riscv_flen)
    li      t0, (3 << 13)
    csrc    mstatus, t0
    li      t0, (1 << 13)
    csrs    mstatus, t0             # FPU on, on every hart
    fscsr   zero
#endif
    fence.i                         # the debugger just wrote the image
#if OS_NCPU > 1
    csrr    t0, mhartid
    li      t1, RISCV_HART_BASE
    bne     t0, t1, riscv_secondary_park
#endif
    la      sp, __stack_top         # only CPU 0 gets here
    call    riscv_board_initialize_memory   # external RAM before .data/.bss
    # copy .data if its load address differs, zero .bss
    call    os_startup_initialize_hardware_early
    call    os_startup_initialize_hardware
    call    os_run_init_array
    call    main
```

Points a porter should take away:

- **Distrust the previous owner.** On the Duo and the VisionFive 2 the image is loaded into DDR while OpenSBI and U-Boot have already run. Their interrupt enables, PLIC thresholds and pending software interrupts can still be set. The start-up code clears `mie` and `mstatus.MIE`, and the board's early hook masks every PLIC context it may share.
- **`fence.i` after loading code.** A debugger load writes through the data side; the instruction cache can still hold the old bytes. ARM needs the same idea (cache maintenance + `ISB`) but a Cortex-M with no cache does not.
- **External memory before `.data` and `.bss`.** A board whose data lives in external RAM brings it up first, on the boot stack. On the RP2350B with PSRAM, `riscv_board_initialize_memory()` initialises the QSPI PSRAM before `.data` is copied into it.
- **No `wfi` in parking loops.** The port parks harts with a plain jump to itself. That is a rule of this project, not of the architecture: a `wfi` resumes only on an enabled, pending interrupt, and the port keeps parked harts free of that dependency.

## Building and running: compilers, QEMU and OpenOCD

On ARM you name the core and the compiler knows the rest; on RISC-V you name the ISA string, the ABI and the code model, and the choice of library (multilib) follows from them. Running is similar on both under QEMU, and differs a lot on hardware, where every RISC-V board needed its own OpenOCD session.

### Toolchains used by the µOS++ ports

| Architecture | Compiler (xPack builds) | Triplet | Notes |
| --- | --- | --- | --- |
| Cortex-M, AArch32 | `arm-none-eabi-gcc` 15.2.1 | `arm-none-eabi` | Thumb for Cortex-M; ARM or Thumb for Cortex-A |
| AArch64 | `aarch64-none-elf-gcc` | `aarch64-none-elf` |  |
| RISC-V (RV32 and RV64) | `riscv-none-elf-gcc` 15.2.0 | `riscv-none-elf` | one compiler for both widths; the width comes from `-march` |

Each port has a CMake toolchain file (`cmake/toolchains/riscv-none-elf.cmake` on RISC-V) that finds the xPack compiler and includes the kernel's common bare-metal settings.

### Compiler flags per board

| Board | Core | Flags |
| --- | --- | --- |
| Nucleo-F411RE | Cortex-M4F | `-mcpu=cortex-m4 -mthumb -mfloat-abi=hard -mfpu=fpv4-sp-d16` |
| Pico 2 (ARM side) | Cortex-M33 | `-mcpu=cortex-m33 -mthumb -mfloat-abi=hard -mfpu=fpv5-sp-d16` |
| Raspberry Pi 4B | Cortex-A72, AArch64 | `-mcpu=cortex-a72` |
| Luckfox Lyra | Cortex-A7, AArch32 | `-mcpu=cortex-a7 -mfloat-abi=hard -mfpu=neon-vfpv4` |
| Milk-V Duo | C906, RV64GC | `-march=rv64imafdc_zicsr_zifencei -mabi=lp64d -mcmodel=medany -mtune=thead-c906` |
| Pico 2 (RISC-V side) | Hazard3, RV32 | `-march=rv32ima_zicsr_zifencei_zba_zbb_zbs_zbkb_zca_zcb_zcmp -mabi=ilp32`, linked with `-march=rv32imc_zicsr_zifencei` |
| VisionFive 2 Lite | U74, RV64GC | `-march=rv64imafdc_zicsr_zifencei_zba_zbb -mabi=lp64d -mcmodel=medany -mtune=sifive-7-series` |

What each RISC-V flag means, in plain words:

- **`-march`** — the instructions the compiler may use. `zicsr` (CSR instructions) and `zifencei` (`fence.i`) are separate extensions since the 2019 ISA split and must be listed.
- **`-mabi`** — how arguments are passed. `lp64d` passes doubles in FP registers (needs D); `ilp32` passes everything in integer registers (no FPU). It must match the libraries.
- **`-mcmodel`** — how far code may address. `medlow` assumes everything is within ±2 GiB of address 0; `medany` within ±2 GiB of the code itself. Images loaded at `0x80050000` (Duo) or `0x40200000` (VisionFive 2) use `medany`.
- **`-mtune`** — scheduling only; it never changes which instructions are allowed.

The ARM equivalents are `-mcpu` (core, implies the instruction set and tuning), `-mthumb`, `-mfpu` (which FPU) and `-mfloat-abi` (`soft`, `softfp`, `hard`).

### Multilibs: the trap nobody warns you about

The C library is prebuilt for a list of ISA/ABI combinations. GCC picks the closest one to your `-march`, and on RISC-V "closest" can be much slower than you expect. Check it before trusting a benchmark:

```sh
riscv-none-elf-gcc -march=rv64imafdc_zicsr_zifencei_zba_zbb -mabi=lp64d -print-multi-directory
# rv64imafdc_zicsr_zaamo_zalrsc/lp64d   (the same as the Duo's: Zba/Zbb change nothing here)
```

Measured on the Pico 2: with the full Hazard3 `-march`, GCC picked an `rv32ia` library with no M extension, so every multiply in the C library called `__mulsi3`. Adding a link-only `-march=rv32imc_zicsr_zifencei` selected the `rv32imc` library, and the parallel solver in `smp-mat-test` went from about 50 s to 14.4 s. ARM toolchains have the same mechanism (`-print-multi-directory` works there too), but the Cortex-M libraries match `-mcpu`/`-mfpu` combinations closely enough that this rarely bites.

### Configuring and building

```sh
# RISC-V port, one board per build directory
cmake -S . -B test/build-vf2 -G Ninja \
      -D CMAKE_TOOLCHAIN_FILE=cmake/toolchains/riscv-none-elf.cmake \
      -D BOARD=visionfive2-lite
cmake --build test/build-vf2

# the same for the Duo (the default board) and the Pico 2
cmake -S . -B test/build       -G Ninja -D CMAKE_TOOLCHAIN_FILE=cmake/toolchains/riscv-none-elf.cmake
cmake -S . -B test/build-pico2 -G Ninja -D CMAKE_TOOLCHAIN_FILE=cmake/toolchains/riscv-none-elf.cmake -D BOARD=pico2
```

Each test produces a `-hwd` image (hardware, OpenOCD) and, where QEMU can stand in for the board, a `-qemu` image. `ctest -L qemu` runs the emulated set; `test/boards/<board>/hw.sh <test>` runs one test on the board.

### QEMU

| Target | Machine | Command line (shape) |
| --- | --- | --- |
| Cortex-M3 (Pico, kernel tests only) | `mps2-an385` | `qemu-system-arm -M mps2-an385 -cpu cortex-m3 -semihosting ...` |
| Cortex-M33 (Pico 2 ARM side) | `mps2-an505` | `qemu-system-arm -M mps2-an505 ...` |
| AArch64 / AArch32 Raspberry Pi | `raspi4b`, `raspi3b` | `qemu-system-aarch64 -M raspi4b -smp 4 ...` |
| RV64 (stand-in for the Duo) | `virt` | see below, `-cpu rv64` |
| RV32 (stand-in for the Pico 2) | `virt` | see below, `-cpu rv32,...` |

The RISC-V command used by the port's `qemu.sh`:

```sh
qemu-system-riscv64 -M virt -cpu rv64 -smp 1 -m 128M -nographic \
    -bios none -kernel smp_test0-qemu.elf \
    -semihosting-config enable=on,target=native

# Pico 2 stand-in: RV32 with the Hazard3 extensions and no FPU, 2 harts
qemu-system-riscv32 -M virt -smp 2 -m 128M -nographic -bios none \
    -cpu rv32,f=false,d=false,zfa=false,zba=true,zbb=true,zbs=true,zbkb=true,zcb=true,zcmp=true \
    -kernel smp-test2-qemu.elf -semihosting-config enable=on,target=native
```

`-bios none` matters on RISC-V: without it QEMU loads OpenSBI and starts the image in S-mode, while the RTOS expects M-mode. With `-bios none` every hart starts at the ELF entry, which is exactly the situation the port's park loop is written for. The script derives `-smp` from the size of `riscv_secondary_boot` in the ELF, so an SMP image always gets as many harts as it was built for.

### OpenOCD on hardware

On ARM, OpenOCD ships a target file for most chips and a session is a handful of commands. On the three RISC-V boards each needed its own configuration and session order.

| Board | Probe | Config essentials | Session |
| --- | --- | --- | --- |
| Nucleo-F411RE | ST-LINK | `source [find board/st_nucleo_f4.cfg]`, `reset_config connect_assert_srst` | `init`, `reset halt`, `program`, `arm semihosting enable`, `reset run` |
| Pico 2, ARM | CMSIS-DAP | `interface/cmsis-dap.cfg`, `set USE_CORE { cm0 cm1 }`, `target/rp2350.cfg` | `init`, `reset init`, `program … verify`, `reset init`, then semihosting + `resume` on `rp2350.cm1` and `rp2350.cm0` |
| Pico 2, RISC-V | Raspberry Pi Debug Probe | `interface/cmsis-dap.cfg`, `target/rp2350-riscv.cfg` (the Raspberry Pi build of OpenOCD) | `reset init`, `load_image`, semihosting on `rp2350.rv1` and `rp2350.rv0`, `reg pc`, `resume` |
| Milk-V Duo | Sipeed RV-Debugger (CMSIS-DAP v2) | `cmsis-dap vid_pid 0xd6e7 0x3507`, `adapter speed 1000`, `jtag newtap cv1800b cpu -irlen 5 -expected-id 0x10000b6f`, `riscv set_mem_access progbuf`, `reset_config none` | `halt`, `reg priv 3`, `load_image`, semihosting, `resume <entry>`; attach retried (every other attach read a bad chain) |
| VisionFive 2 Lite | DAPLink (CMSIS-DAP v1, HID) | two TAPs (`-irlen 5`), four independent targets `jh7110.cpu1..4` (`-coreid 1..4`), no `target smp` | see *Debug and semihosting*: park-then-halt per hart, clear release slots, start harts 2..4, then 1 |

The Duo's target file, which is typical of what a RISC-V board needs written by hand:

```tcl
adapter driver cmsis-dap
cmsis-dap vid_pid 0xd6e7 0x3507
adapter speed 1000                 # 4 MHz read garbage over jumper wires
transport select jtag
set _CHIPNAME cv1800b
jtag newtap $_CHIPNAME cpu -irlen 5 -expected-id 0x10000b6f   # read from the board
target create $_CHIPNAME.cpu0 riscv -chain-position $_CHIPNAME.cpu -coreid 0
$_CHIPNAME.cpu0 configure -work-area-phys 0x83FF0000 -work-area-size 0x10000
riscv set_mem_access progbuf       # write through the hart's D-cache
reset_config none                  # no reset line on the header
```

Two plain lessons from these sessions:

- **A RISC-V debugger writes memory through the hart or around it.** `progbuf` access executes loads and stores on the hart, so they go through its data cache; system-bus access goes around it. The Duo uses `progbuf` so that what the hart reads after a load is what was written. A Cortex-M debugger writes through the bus matrix and, on cacheless cores, the question does not arise.
- **The verdict comes back through semihosting.** Every test ends with a semihosting `exit()`. With no GDB connected, OpenOCD exits with the test's exit code, which the runner checks against the `RESULT` line it saw. That works identically for the ARM and RISC-V ports; only the trap instruction differs.

## Summary and porting checklist

The short version: everything ARM gives an RTOS in hardware, the RISC-V port implements in about a dozen small, explicit pieces, and every one of them depends on a board fact that must be checked on the board.

| Topic | ARM (Cortex-M unless noted) | RISC-V M-mode | Where it lives in the RISC-V port |
| --- | --- | --- | --- |
| Trap entry | vector table, 8 registers stacked by hardware | one `mtvec` entry, everything saved by software | `src/trap.S`, `src/trap.cpp` |
| Interrupt stack | MSP, automatic | switched by software on the outermost trap | `trap.S`, `riscv_irq_stack_top[]` |
| "In an interrupt?" | IPSR | per-hart nesting counter | `riscv_trap_nesting[]` |
| Priorities and nesting | NVIC, automatic | PLIC threshold + MIE by hand, or a vendor controller | board `irq.cpp` |
| Tick | SysTick, self-reloading | `mtimecmp` rewritten every tick, catch-up after halts | `riscv_port_tick()` |
| Context switch | PendSV | `ecall` from threads, switch on trap exit | `riscv_port_yield()`, `switch_stacks()` |
| Critical section | PRIMASK / BASEPRI | `csrrci mstatus, 8` | `riscv-csr.hpp` |
| FPU state | lazy stacking, `EXC_RETURN` | `mstatus.FS`, saved on every trap | `trap.S` |
| Memory protection | MPU | PMP; Sv39 for S/U, M via MPRV | `src/mmu.cpp` |
| Atomics | LDREX/STREX | AMOs and LR/SC, not in every memory | `riscv-amo.hpp` |
| Core id | `MPIDR` (Cortex-A) | `mhartid`, maybe offset | `RISCV_HART_BASE`, `riscv-hart.hpp` |
| Starting cores | PSCI / boot ROM | park loop + release slot | `startup.S`, `riscv_smp_release_hart()` |
| IPI | GIC SGI | CLINT `msip` (or vendor register) | `clint.hpp`, `port_smp_ipi()` |
| Semihosting | `BKPT 0xAB` | `slli`/`ebreak`/`srai` + `dcsr.ebreakm` | `semihosting.hpp` |

### Checklist for a new RISC-V board

- [ ] Which ISA string exactly? Build with it and check `-print-multi-directory`.
- [ ] Timebase frequency, CLINT address, and whether `mtimecmp` takes 64-bit writes.
- [ ] Does the hart implement the `time` CSR? Can M-mode read `mtime`? Measure both.
- [ ] Hart ids of the cores you will use; is hart 0 one of them?
- [ ] PLIC (or vendor controller) base and the M-mode context number of every hart you use.
- [ ] Misaligned accesses: hardware, or trap?
- [ ] Which memories accept AMOs and LR/SC?
- [ ] Page-table attribute bits: standard Sv39, Svpbmt, or vendor bits (T-Head MAEE)?
- [ ] What did the previous boot stage leave enabled: `mie`, PLIC enables, pending software interrupts, PMP?
- [ ] Debug: IDCODE and IR length read from the board; `progbuf` or system-bus memory access; how the probe handles semihosting and multi-hart sessions.
- [ ] For SMP: the FPU, `mtvec`, `gp` and `fence.i` set on every hart before the park; release slots cleared before the harts start; threads pin themselves before they work.
