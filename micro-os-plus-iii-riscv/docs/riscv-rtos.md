# RISC-V RTOS Internals

*Interrupts, tick, atomics, critical sections, scheduling and preemption in the
µOS++ III RISC-V port (RV32/RV64, single-hart and SMP)*

This document explains how the two folders of this workspace implement the
parts of an RTOS that the hardware usually provides on ARM:

- `micro-os-plus-iii/` — the portable µOS++ III kernel (scheduler, threads,
  clocks, mutexes, semaphores, lists);
- `micro-os-plus-iii-riscv/` — the RISC-V port: trap entry, tick, context
  switch, critical sections, SMP glue and the board facts.

It answers, in order: how interrupts and the tick (the SysTick equivalent)
work; how atomics, critical sections and the other protection mechanisms are
built; how the scheduler works; how preemption happens; and what changes
between RV32 and RV64. It also lists the standards that are used and the
places where real silicon departs from them.

The document describes the code as it is, not an idealised design. Where a
decision exists because something was **measured** on a board, that is said
explicitly.

---

## 1. The one-page answer

| Cortex-M concept | RISC-V equivalent in this port | Where |
|---|---|---|
| SysTick | machine timer: CLINT `mtimecmp` compared with `rdtime`/`mtime` | `include/clint.hpp`, `src/rtos/os-core.cpp` |
| `SysTick_Handler` | trap with `mcause` = interrupt 7 (`MTIP`) | `src/trap.cpp` |
| PRIMASK | `mstatus.MIE` (bit 3) | `include/riscv-csr.hpp` |
| `__disable_irq()` / `__enable_irq()` | `csrci mstatus, 8` / `csrsi mstatus, 8`; `csrrci` reads and clears atomically | `include/riscv-csr.hpp` |
| PendSV from a thread | `ecall` with the marker `"YSOU"` in `a7` | `src/rtos/os-core.cpp` |
| PendSV from an ISR | a per-hart "switch pending" flag; the switch happens on the way out of the outermost trap | `src/trap.cpp`, `src/rtos/os-core.cpp` |
| Hardware register stacking + r4–r11 | full frame built by `trap.S` (all GPRs, `mepc`, `mstatus`, FP state) | `src/trap.S`, `include/port_ctx.hpp` |
| `IPSR != 0` | `riscv_trap_nesting[hart] != 0` | `src/trap.S`, `include/riscv-hart.hpp` |
| NVIC | board controller: CLINT MSIP + PLIC, Hazard3 Xh3irq, or WCH PFIC | `src/soft-irq.cpp`, board `irq.cpp`, `include/pfic.hpp` |
| `LDREX`/`STREX` | A extension: `lr.w`/`sc.w`, or one-instruction AMOs (`amoswap.w.aq`) | `include/riscv-amo.hpp`, `src/rtos/os-core.cpp` |
| `DMB`/`DSB`/`ISB` | `fence`, `fence.i` | `include/clint.hpp`, `src/startup.S` |
| `MPIDR`/`SIO_CPUID` | `mhartid` minus a board base | `include/riscv-hart.hpp`, `include/port_ctx.hpp` |
| SGI / FIFO IPI | write the target hart's MSIP word | `src/rtos/os-core.cpp` |

Two facts dominate the design:

1. **RISC-V gives the RTOS almost nothing in hardware.** There is one trap
   vector, no automatic register save, no PendSV, no priority controller in
   the base ISA, and no standard way to start secondary harts. Nearly all of
   the "RTOS plumbing" is software in this port.
2. **Everything outside the core is platform-defined.** The timer is a CLINT
   (or ACLINT) on most boards, but not on the WCH part; the external
   interrupt controller may be a PLIC, a vendor unit, or the WCH PFIC. The
   port keeps each of these as a named board fact instead of assuming one.

---

## 2. Plain-English orientation

If the rest of this document feels like a wall of acronyms, read this section
first. It explains the ideas in everyday language. The glossary at the end
defines every term precisely and points back to the section that uses it.

### 2.1 What an RTOS is doing

A normal operating system tries to keep many programs running and to be fair
to all of them. A **real-time operating system** (RTOS) has a narrower job:
it runs a fixed set of small programs — **threads** or **tasks** — and it
must be able to guarantee that the important one runs within a deadline.

To do that, the RTOS needs four abilities:

1. **Start and stop threads.** Save exactly where a thread was, put another
   thread's saved state back, and continue. This is a **context switch**.
2. **Know when time has passed.** A regular timer interrupt (the **tick**)
   gives the RTOS a heartbeat so it can wake sleeping threads, expire
   timeouts and decide whether someone more important should run.
3. **Protect shared data.** If an interrupt or another thread can change the
   same list or counter halfway through an update, the result is garbage.
   Short "do not disturb" windows — **critical sections** — prevent that.
4. **Share the CPU between cores** when there is more than one, without two
   cores touching the same kernel data at once. That is the **SMP** part.

Everything else in this document is the low-level machinery that makes those
four abilities work on RISC-V.

### 2.2 Interrupts: the hardware tapping you on the shoulder

A thread runs instructions one after another. An **interrupt** is a signal
from hardware that says "stop what you are doing and deal with me now". A
timer, a UART receiving a byte, or another CPU wanting attention can all
raise one.

On ARM Cortex-M, the hardware is unusually helpful: it has a table of
handlers, it saves some registers for you, and it picks the right handler by
number. RISC-V does much less. It has **one** entry address for every
interrupt and every error. The CPU jumps there, writes down *why* it jumped
(in a register called `mcause`) and *where* it was (in `mepc`), and expects
software to do the rest.

So this port's first job is a piece of assembly (`trap.S`) that:

- saves every register the interrupted code was using, on that code's own
  stack, so nothing is lost;
- switches to a separate **interrupt stack**, so a deep interrupt handler
  cannot overflow the thread's stack;
- calls a C++ function that looks at `mcause` and decides what happened;
- restores the registers and executes `mret` ("return from trap").

An **exception** is the same mechanism for errors and deliberate system
calls: an illegal instruction, a bad memory access, or the `ecall`
instruction a thread uses to ask the kernel to switch threads. RISC-V uses
one word, **trap**, for "interrupt or exception".

### 2.3 The tick: a heartbeat

A **tick** is a periodic timer interrupt. On Cortex-M it is usually the
SysTick timer: a counter counts down, reloads itself, and raises an interrupt
every millisecond. RISC-V usually has something slightly different: one
free-running counter shared by all cores, plus one **compare register per
core**. When the counter reaches the compare value, that core gets an
interrupt. The catch is that the compare register does **not** reload itself:
software must add one period and write the next deadline every time.

"One millisecond" is not magic. The period is
`timebase_frequency / tick_frequency`; with a 1 kHz tick and a 25 MHz
timebase, one tick is 25 000 counter steps. If the handler is late, the port
notices how many whole periods have passed and catches up, rather than
silently losing time.

### 2.4 Context switch: swapping the desk, not the worker

A **context** is everything a thread needs to continue: its registers, its
stack pointer, and its floating-point state. A **context switch** saves that
state somewhere and loads another thread's state.

This port does something elegantly simple: every trap already saves the
complete register set on the current stack. A context switch is therefore
just "return from the trap using a different saved stack pointer". The
scheduler stores the outgoing thread's stack pointer in its thread object
and returns the incoming thread's stack pointer; the assembly restores from
that second frame and `mret`s. No special "switch" instruction is needed.

### 2.5 Preemption: taking the CPU away

**Preemption** means the scheduler can stop a running thread without its
cooperation, because something more important became ready. The usual cause
is the tick: a sleeping thread's timeout expires, or a timer callback wakes a
higher-priority thread.

The port is careful about *where* the switch happens. It never switches in
the middle of an interrupt handler, and never inside a critical section.
From an interrupt, it only sets a "switch needed" flag; the actual switch is
made on the way out of the outermost trap, when the handler has finished and
the stack is about to be restored. This is the same idea as ARM's
"tail-chaining", without needing a second interrupt.

A thread can also give up the CPU voluntarily: when it waits for a semaphore,
sleeps, or calls `yield()`, it asks the kernel to switch with an `ecall`.
That path is synchronous and immediate.

### 2.6 Critical sections: "do not disturb"

A **critical section** is a short region of code that must not be
interrupted by anything that could touch the same data. The simplest
implementation is "turn interrupts off, do the work, turn them back on".

On RISC-V the "turn off" is one instruction: `csrrci mstatus, 8` both reads
the old interrupt-enable bit and clears it, atomically. Keeping the old value
lets nested sections restore the correct state: if interrupts were already
off when the section started, they stay off when it ends.

If a thread asks for a switch while interrupts are off, the request is not
lost. The kernel remembers it, and performs the switch at the moment the
critical section ends and interrupts are enabled again. This is the
equivalent of ARM's pending PendSV exception.

### 2.7 Atomics: all-or-nothing operations

An **atomic** operation is one that cannot be split: no other core or
interrupt can see it half-done. "Add one to this counter" is normally three
steps (read, add, write); an atomic add is one indivisible step.

RISC-V's **A extension** provides two ways to do this:

- **AMOs** — single instructions such as `amoswap` ("swap these two values,
  atomically"); and
- **LR/SC** — `lr` reserves a memory location, `sc` writes it only if nobody
  else touched it in between.

The port uses AMOs for its locks and for the software-interrupt bitmap. It
also uses **fences**, which are ordering instructions: they do not make an
operation atomic, they tell the CPU "finish this memory access before you
start that one". `fence.i` is a special one for instruction fetch.

### 2.8 SMP: several workers, one workshop

**SMP** (symmetric multiprocessing) means several identical cores run the
same kernel and share the same memory. Each core is called a **hart** in
RISC-V ("hardware thread"). Several new problems appear:

- Turning interrupts off on one core does nothing to the others, so a
  **spinlock** is needed: a core keeps trying to grab a small word until it
  succeeds. The others wait (spin) until it is released.
- Two cores must not run the same thread. The port uses a **publish/claim**
  protocol: a thread's saved stack pointer is published when it is switched
  out, and cleared when another core claims it.
- A core may need to wake another core. That is an **IPI**
  (inter-processor interrupt), delivered here by writing the target hart's
  software-interrupt bit.
- Each core needs its own idle thread, its own interrupt stack, its own
  "switch pending" flag, and a way to know which threads it is allowed to
  run (**affinity**).

### 2.9 How to read the rest of this document

- Sections 3–5 describe the platform and interrupts.
- Section 6 is the tick.
- Sections 7–8 are the scheduler and preemption.
- Section 9 is protection (critical sections, locks).
- Section 10 is atomics and memory ordering.
- Section 11 compares RV32 and RV64.
- Sections 12–14 are walk-throughs, measured quirks, and practical advice.
- Section 15 classifies every test board as standard RISC-V or vendor-specific.
- Section 17 is the glossary. Terms there are in **bold** the first time they
  matter in the main text.

## 3. Source map

| File | Role |
|---|---|
| `include/cmsis-plus/rtos/port/os-c-decls.h` | C half of the port contract: XLEN-wide types, `os_port_irq_state_t`, the SMP lock type, `OS_NCPU` checks |
| `include/cmsis-plus/rtos/port/os-decls.h` | C++ half: scheduler state, context type (a saved stack pointer), stack sizes |
| `include/cmsis-plus/rtos/port/os-inlines.h` | the actual inline mechanisms: critical sections, scheduler lock, `in_handler_mode`, high-resolution clock |
| `include/port_ctx.hpp` | trap-frame layout shared by `trap.S` and C++; register offsets; `RISCV_HART_BASE`; `ecall` marker |
| `include/riscv-csr.hpp` | CSR access, `mstatus` bits, `rdtime`/`rdcycle` for RV32 and RV64 |
| `include/riscv-hart.hpp` | `this_hart()`, `in_trap()` |
| `include/clint.hpp` | `mtime`/`mtimecmp`/`msip`, split-32 writes, clock source selection |
| `include/pfic.hpp` | WCH QingKe PFIC: priorities, threshold (BASEPRI), pend/enable, SysTick |
| `include/riscv-amo.hpp` | places atomically-updated objects where AMOs work |
| `include/riscv-smp.hpp` | SMP entry points used by boards and tests |
| `src/trap.S` | the single trap entry: frame, nesting counter, interrupt stack, restore, `mret` |
| `src/trap.cpp` | `mcause` dispatcher, semihosting, fault report, switch on trap exit |
| `src/rtos/os-core.cpp` | tick, yield, deferred yield, scheduler lock, `switch_stacks`, SMP startup |
| `src/soft-irq.cpp` | NVIC-like software interrupt lines multiplexed on MSIP |
| `src/startup.S`, `src/startup.cpp` | reset entry, secondary-hart park, start-up hooks |
| `micro-os-plus-iii/src/rtos/os-clocks.cpp` | `os_systick_handler()`: clocks, timeouts, reschedule |
| `micro-os-plus-iii/src/rtos/os-core.cpp` | `internal_switch_threads()`, ready-list selection |
| `micro-os-plus-iii/src/rtos/internal/os-lists.cpp` | priority-ordered ready list |
| `micro-os-plus-iii/include/cmsis-plus/rtos/os-sched.h` | scheduler API, `critical_section`, `uncritical_section`, `kernel_*` classes |

Deeper background on ARM-vs-RISC-V differences is in
`docs/arm-vs-riscv.md`; board facts and test status are in `README.md`.

---

## 4. Execution model and standards used

The port runs in **machine mode (M-mode)** on every board. No SBI or
firmware stays resident. The kernel and the threads are all M-mode code; a
trap is always taken to M-mode.

### 4.1 Standards that are used

| Standard | What the port uses |
|---|---|
| RISC-V Unprivileged ISA | `I`, `M`, `A`, `F`, `D`, `C` where present; `Zicsr` and `Zifencei` (CSR and `fence.i` instructions); the `Zba`/`Zbb` extensions are left to the compiler |
| RISC-V Privileged Architecture | CSRs: `mstatus`, `mie`, `mip`, `mcause`, `mepc`, `mtval`, `mtvec`, `mhartid`, `misa`, `satp`; M-mode trap/`mret`; PMP is not programmed |
| RISC-V psABI | `lp64d` (RV64 with D), `ilp32f` (RV32 with F), `ilp32` (RV32 soft float); 16-byte stack alignment at every call boundary |
| CLINT / ACLINT platform convention | per-hart `msip` (4 bytes apart), per-hart `mtimecmp` (8 bytes apart), shared `mtime`; not all boards implement all of it |
| RISC-V PLIC specification | claim/complete, per-source priority, per-context threshold (Milk-V Duo, QEMU virt, VisionFive 2 Lite) |
| RISC-V Debug specification + semihosting | `ebreak` caught by the debugger; `SYS_EXIT` and `SYS_WRITE0` through the slli/ebreak/srai sequence |
| Vendor documents | Hazard3 Xh3irq CSRs (RP2350), WCH QingKe V4 PFIC and SysTick (CH32V307), T-Head C906 quirks (Milk-V Duo) |

### 4.2 Standards that are deliberately *not* assumed

- **One timer layout.** Milk-V Duo's C906 cannot read `mtime` over MMIO and
  requires two 32-bit writes to `mtimecmp`; Hazard3 has no `time` CSR; the
  U74 has no `time` CSR either and numbers its application harts 1..4.
- **One external interrupt controller.** There is a PLIC, a vendor Xh3irq,
  and the WCH PFIC. Board code supplies the dispatcher.
- **A standard secondary-hart start.** QEMU virt starts every hart at
  `_start`; the RP2350 boot ROM starts core 1 through an SIO FIFO handshake;
  the JH-7110S starts harts from a loader. The port provides a release slot
  for the first case, board code handles the others.
- **`wfi` as an idle instruction.** The C906 was measured not taking an
  enabled, pending machine-timer interrupt while in `wfi`, so the port's idle
  loop spins.

### 4.3 XLEN is a compile-time parameter

`__riscv_xlen` selects the width of almost everything:

```cpp
// include/riscv-csr.hpp
#if __riscv_xlen == 64
  using reg_t = std::uint64_t;
#else
  using reg_t = std::uint32_t;
#endif
inline constexpr unsigned XLEN = __riscv_xlen;
```

There is no runtime RV32/RV64 abstraction: a build is one or the other, and
the board's `-march`/`-mabi` fixes it (`test/boards/*/board.cmake`).

---

## 5. Interrupts

**In plain English.** An interrupt is the hardware asking the CPU to stop
for a moment and do something else. On RISC-V every interrupt and every
error arrives at the same door, and the CPU saves nothing for you. This
section describes the software that builds the doorway, saves what was in
use, works out what happened, handles it, and puts everything back exactly
as it was.

### 5.1 One trap entry for everything

`mtvec` is set in direct mode (`startup.S` writes `riscv_trap_entry` into
`mtvec`; the entry is 64-byte aligned). There is no vector table: every
interrupt and every exception enters the same code.

```
_start:
    csrci   mstatus, 8          # interrupts off
    csrw    mie, zero           # every source off
    la      t0, riscv_trap_entry
    csrw    mtvec, t0           # direct mode
    ...
```

`trap.S` then does what the hardware does not:

1. **Build a frame on the interrupted stack.** `sp -= PORT_CTX_SIZE`, then
   store `x1`, `x3`..`x31`, `mepc`, `mstatus`, and — when the build has an
   FPU (`__riscv_flen`) — `fcsr` and `f0`..`f31`.
2. **Reload `gp`** with `__global_pointer$` and `norelax`, so the C
   dispatcher's gp-relative accesses are safe even if the interrupted code
   had a broken `gp`.
3. **Count nesting per hart** in `riscv_trap_nesting[]` (a `.bss` array with
   one 32-bit word per CPU).
4. **On the outermost trap only**, move `sp` to that hart's interrupt stack
   (`riscv_irq_stack_top[hart]`). The frame stays where it was built, on the
   thread's stack; the dispatcher and everything it calls run on a stack of
   their own.
5. **Call `riscv_trap_dispatch(frame)`**.
6. **Restore from the frame the dispatcher returns.** That may be the same
   frame, or another thread's; restoring from a different frame *is* the
   context switch.
7. **`mret`**, which reloads `mstatus` (including `MIE` from `MPIE`) and
   jumps to `mepc`.

The frame layout lives in `port_ctx.hpp` and is checked by `static_assert`s:

| XLEN / FPU | Frame contents | Size |
|---|---|---|
| RV64 + D (C906, U74) | 32 GPR slots (`x0` holds `mepc`), `mstatus`, `fcsr`, `f0`–`f31` | **528 bytes** |
| RV32, no FPU (Hazard3) | 32 GPR slots, `mstatus` | **144 bytes** |
| RV32 + F (QingKe V4F) | 32 GPR slots, `mstatus`, `fcsr`, `f0`–`f31` | 272 bytes |

The frame is always a multiple of 16 bytes, preserving the psABI stack
alignment.

### 5.2 Order of operations on trap exit (a subtle race, fixed)

`trap.S` moves `sp` to the returned frame **before** decrementing the
nesting count:

```asm
    mv      sp, a0
    # ... compute hart index, load nesting, subtract one, store ...
```

This matters on boards where interrupts nest in hardware (the WCH PFIC):
an interrupt taken between the two would otherwise see nesting 0 while `sp`
still pointed at the interrupt stack, build its frame near the top, and then
reset `sp` to that top for its own dispatcher — over its own frame. With the
order above, a nested trap builds below the current frame, as any first-level
trap does.

### 5.3 Interrupt causes and dispatch

`trap.cpp` reads `mcause`. The top bit says interrupt vs exception; the low
12 bits are the code (masked because the C906 sets vendor bits above the
code).

| `mcause` | Meaning | Action |
|---|---|---|
| `0x8000…0003` | machine software interrupt (`MSIP`) | clear MSIP, run software IRQ lines, then the SMP IPI hook |
| `0x8000…0007` | machine timer interrupt (`MTIP`) | `riscv_port_tick()` |
| `0x8000…000B` | machine external interrupt (`MEIP`) | `riscv_board_external_interrupt()` |
| `EXC_ECALL_M` (11) with `a7 == "YSOU"` | port's yield | `switch_stacks()` |
| `EXC_BREAKPOINT` (3) at a semihosting sequence | no debugger | return −1, skip the `ebreak` and `srai` |
| anything else | fault | `fault()`: raw UART report, optional semihosting, board exit, stop |

`riscv_trap_exception_hook()` is a weak hook a test can implement to handle
its own exceptions (`exc-test` uses it for illegal instructions and
misaligned/access faults).

### 5.4 Interrupt masking and nesting

On standard RISC-V the hardware clears `mstatus.MIE` on trap entry and
restores `MPIE` on `mret`. Therefore, unless a handler deliberately sets
`MIE` again, **interrupts do not nest**; a trap taken inside a handler is an
exception (nesting count 2) and never switches threads.

Two board families re-enable `MIE` inside handlers and therefore do nest:

- **PLIC boards (Duo, VF2 Lite, QEMU).** The board dispatcher raises the PLIC
  threshold to the claimed source's priority, masks `MTIE` and `MSIE`, sets
  `MIE`, calls the device handler, then reverses the sequence and completes
  the claim. Only higher-priority PLIC sources can preempt; the tick and IPI
  stay out.
- **Hazard3 Xh3irq (Pico 2).** `meicontext` is saved with CLEARTS; for each
  `meinext` the dispatcher uses UPDATE to raise the preemption threshold to
  that IRQ's priority, sets `MIE`, calls the handler, clears `MIE`, and
  restores the context. A higher-priority IRQ preempts a running handler.

On both, `riscv_trap_nesting[hart]` counts the depth, `in_handler_mode()` is
true throughout, and only the **outermost** trap can switch threads.

The **WCH PFIC** is different again: it nests in hardware and **does not
clear `mstatus.MIE` on entry**. Its dispatcher relies on the PFIC's own
priority groups and threshold; `riscv_trap_nesting` is the interrupt depth.
Because a switch must not leave another interrupt half-done in the PFIC's
active state, the only place threads switch is interrupt 14, the lowest
priority (the "PendSV" slot).

### 5.5 External interrupt controllers, in practice

**PLIC (Milk-V Duo, VisionFive 2 Lite, QEMU virt).**
A context is one privilege mode of one hart. On the JH-7110S the contexts are
in device-tree order: hart 0 M-mode is context 0 (the S7 has no S-mode),
then M and S for each U74, so U74 hart *h*'s M-mode context is `2*h − 1`.
The dispatcher loops on the claim register until it reads 0. An unhandled
source is disabled, then completed, so it cannot storm.

```cpp
// test/boards/milkv-duo/src/irq.cpp (simplified)
for (;;) {
  id = claim; if (id == 0) break;
  old = threshold;
  threshold = priority[id];          // only higher priorities preempt
  csrrc mie, (MTIE | MSIE);          // keep tick and IPI out
  csrsi mstatus, 8;                  // allow nesting
  handler[id]();
  csrci mstatus, 8;
  csrs mie, saved;
  complete = id;
  threshold = old;
}
```

**Hazard3 Xh3irq (Pico 2).** Vendor CSRs replace the NVIC: `meiea` enables,
`meipa` pends, `meifa` forces, `meipra` sets priority, `meinext` names the
highest-priority pending enabled IRQ. `NVIC_SetPriority(n, p)` maps to
`meipra = 15 - p`, because ARM and Hazard3 order priorities in opposite
directions. Handlers use Cortex-M names (`UART0_IRQ_Handler`, …), which is
what lets CMSIS-style code and the validator work unchanged.

**WCH PFIC (CH32V307).** Interrupt 12 is SysTick, 14 is the software
interrupt (PendSV), 16+ are peripherals. Priorities: `0x00` zero-latency
(never masked), `0x40` kernel-aware, `0x80` SysTick, `0xC0` the switch.
`INTSYSCR = 0x0A` enables nesting with four preemption levels and no
hardware register stacking.

### 5.6 Software interrupts and the NVIC stand-in

A RISC-V hart has one software-triggered interrupt, MSIP. The port
multiplexes 32 "NVIC lines" onto it (`src/soft-irq.cpp`):

```cpp
NVIC_SetPendingIRQ(n):
    pending |= 1 << n;          // AMO (amoor.w)
    if (enabled & (1 << n)) {
        clint::msip_set();      // posted store + fence o,i
        if (MIE) wait until the line has been handled;
    }
```

The MSIP trap clears MSIP, runs every pending+enabled line in handler mode,
then returns. Two details matter:

- **Enabling a line discards a pending request** left over from when it was
  disabled. This is the semantics the Raspberry Pi ports give their mailbox
  stand-in, and it fixes a real validator failure: `TC_MailFromThreadToISR`
  enables a line before emptying the mail queue, and a stale periodic-timer
  request would otherwise run the new case's ISR on the old case's mail.
- **From a thread with `MIE` set, the request waits until the handler has
  run** (a read of MSIP flushes the posted write, then a loop on the pending
  bit). On Cortex-M the handler has run before the next instruction; the
  C906's MSIP is posted and arrives some cycles later, so the wait preserves
  the observable semantics.

On the PFIC board this file compiles out: PFIC interrupts are the board's
`NVIC_*`, and interrupt 14 is used by the scheduler.

### 5.7 The SMP inter-processor interrupt

`port_smp_ipi(cpu)` writes the target hart's MSIP word. The target takes
`mcause` 3, clears its own MSIP, runs any software IRQ lines, and calls
`riscv_port_ipi_received()`, which reschedules that hart. This is how a
thread woken on hart 0 reaches a core that is allowed to run it, without
waiting for that core's next tick.

The RP2350 has no CLINT MSIP; the port selects
`RISCV_BOARD_SOFTIRQ_SIO`, where one SIO register sets bit *h* to raise core
*h*'s software interrupt and bit `8+h` to clear it. The kernel code calling
`msip_set()` is the same.

### 5.8 Startup and the interrupt stack

`startup.S` distrusts the state left by the loader: interrupts off, `mie`
zero, its own `mtvec`, `gp`, `tp`, `fence.i`, FPU enabled if present, then
`.data`/`.bss` and the C++ constructors. On SMP, harts other than CPU 0 jump
to `riscv_secondary_park` and spin on a release slot before that.

The interrupt stack is a linker-script region (`__irq_stack_bottom`,
`__irq_stack_top`). It is registered in `scheduler::start()`, not as a
static constructor, because the stack object's constructor could otherwise
reset an earlier `set()`. Secondary harts get 8 KiB static interrupt stacks
in `os-core.cpp`.

---

## 6. The tick (the SysTick equivalent)

**In plain English.** A tick is a regular heartbeat. Every time it beats,
the RTOS moves its clock forward, checks whether any sleep or timeout has
expired, and decides whether a different thread should run. On RISC-V the
heartbeat is produced by comparing a free-running counter with a per-core
deadline; the deadline does not repeat itself, so the handler must set the
next one every beat.

### 6.1 The hardware

RISC-V's usual tick is a free-running counter plus **one compare register
per hart**, not a reloading down-counter:

| | SysTick (Cortex-M) | RISC-V CLINT |
|---|---|---|
| Counter | 24-bit, counts down, reloads itself | 64-bit `mtime`, shared by all harts |
| Compare | `LOAD` reload value | per hart: `mtimecmp[h]`, absolute |
| Periodic by itself | yes | **no — software rewrites it every tick** |
| Interrupt | exception 15 | `MTIP`, a dedicated `mie` bit |
| Read time | `SYST_CVR` | `rdtime` (`time` CSR) or an MMIO load of `mtime` |

The port's `clock_systick::start()` computes the period once:

```cpp
constexpr std::uint64_t tick_period =
    riscv_board::TIMEBASE_HZ / OS_INTEGER_SYSTICK_FREQUENCY_HZ;
```

`OS_INTEGER_SYSTICK_FREQUENCY_HZ` defaults to 1000 in
`port/os-decls.h`; the boards' timebases divide it exactly (25 MHz / 1 kHz =
25000, 4 MHz → 4000, 1 MHz → 1000, 144 MHz → 144000, QEMU 10 MHz → 10000).

### 6.2 Starting the tick on a hart

```cpp
void clock_systick::start(void) {
  riscv_port_clint_offset = clint::measure_offset(); // mtime - rdtime
  tick_start_this_hart();
}
```

`tick_start_this_hart()`:

1. `next_tick[hart] = clint::now()` — this hart's grid starts now;
2. `riscv_port_tick_rearm()` — adds one period and writes the comparator;
3. enables `mie.MTIE` (or, on the PFIC, enables interrupt 12 and sets its
   priority).

Every hart has its own `next_tick[]` and its own comparator. On SMP each
secondary hart calls the same function in `port_smp_secondary_start()`.

The comparator write goes through `clint::mtimecmp_write()`, which is one of
the places where boards differ:

```cpp
if constexpr (riscv_board::MTIMECMP_SPLIT32) {
    reg32(a + 4) = 0xFFFFFFFFu;   // high half all ones first
    reg32(a)     = uint32_t(value);
    reg32(a + 4) = uint32_t(value >> 32);
} else {
    *reinterpret_cast<volatile uint64_t*>(a) = value;
}
```

Writing the high half to all ones first guarantees that the comparator never
briefly holds a value lower than both the old and the new deadline, which
would fire a spurious tick. The C906 needs this because a 64-bit store is
split by the bus; RV32 needs it because a 64-bit store is two instructions
anyway.

The C906 also cannot read `mtime` at all (any load faults, 32-bit halves
included). There the clock is `rdtime`, which reads the same counter the
comparator uses, so `measure_offset()` returns 0. Hazard3 has no `time` CSR
at all, so it reads the SIO platform timer over MMIO. The board header
selects the source with `TIME_CSR`, `MTIME_READABLE` and
`MTIMECMP_SPLIT32`.

### 6.3 The tick handler

`riscv_port_tick()` runs in the machine-timer trap with interrupts masked
(except on the PFIC, where the dispatcher may be preempted by a more urgent
interrupt; the tick itself is designed to tolerate that).

Its shape:

```cpp
now = clint::now();
due = 0;
if (next_tick[h] <= now) {
    due = (now - next_tick[h]) / tick_period + 1;  // whole periods missed
    next_tick[h] += due * tick_period;
}
tick_write(h);                 // comparator moved before the handler

if (due == 0) return;          // early or spurious: nothing owed

if (h == 0) {
    riscv_port_last_tick = next_tick[h] - tick_period; // HR clock base
    for (i = 1; i < due; ++i) {                        // N-1 bare increments
        sysclock.internal_increment_count();
        hrclock.internal_increment_count();
    }
    os_systick_handler();      // one real tick: timers, timeouts, reschedule
} else {
    scheduler::reschedule();   // secondary: only pick up work
}
riscv_port_tick_guard();
```

Four behaviours are deliberate and were each forced by a measurement:

1. **The comparator is moved before the handler, on a fixed grid.**
   `next_tick[h]` is never re-based on "now"; time owed stays owed.
2. **Missed ticks are caught up.** A debugger halt (every semihosting call
   halts the hart for a JTAG round trip), a long critical section or a slow
   handler can let several periods pass. The port computes how many whole
   periods are owed, performs `N-1` bare increments of `sysclock` and
   `hrclock`, then runs **one** ordinary `os_systick_handler()`. Timeouts and
   timers are therefore checked once against the advanced clock: every
   expired timeout fires, and a periodic timer fires once, not `N` times in
   a burst. (The kernel's simulated RTC, a per-tick countdown inside
   `os_systick_handler()`, still loses halted time.)
3. **The guard after the handler.** If the handler itself ran past the grid
   deadline, the next comparator is set to `now + one period` **without
   moving the grid**. Without this, `rtos-apis`'s 1-tick periodic timer,
   whose callback prints to the UART, kept the C906 in the tick trap for
   ever: the next tick was already pending before `mret`.
4. **Only hart 0 advances the RTOS clock.** Secondary harts' ticks only
   reschedule. This is the same division of labour as the RP2350 Cortex-M
   port, where core 1's SysTick only reschedules.

The PFIC version adds one board fix. The QingKe SysTick **latches** its
count-flag and the PFIC latches the pending bit; a comparator that was
passed while a handler ran stays pending even after `mtimecmp` is moved
ahead. `tick_write_at()` therefore clears `STK_SR` and the PFIC pending bit
**after** writing the new comparator, then re-pends interrupt 12 in software
if the counter has already reached the deadline. This gives the latched
timer the behaviour of the level-sensitive CLINT timer. Without it, SysTick
re-entered back to back and the software interrupt (the switch) never ran.

### 6.4 What the tick drives in the kernel

`os_systick_handler()` (in the kernel, `src/rtos/os-clocks.cpp`):

1. increments `sysclock` and `hrclock` inside an interrupts critical
   section;
2. calls `sysclock.internal_check_timestamps()` and
   `hrclock.internal_check_timestamps()` — this wakes sleeping threads and
   expires timers, which links them back into the ready list;
3. on this port (`OS_USE_RTOS_PORT_SCHEDULER` is **not** defined) calls
   `port::scheduler::reschedule()` at the end.

The high-resolution clock is derived, not a free-running cycle counter:
`clock_highres::has_hardware_counter()` is false; `cycles_since_tick()` is
`clint::now() - riscv_port_last_tick`, capped at one period. That keeps
`hrclock` consistent with the tick grid even after a catch-up.

### 6.5 Tick facts per board

| Board | Timebase | `time` CSR | `mtime` MMIO | `mtimecmp` write | tick source |
|---|---|---|---|---|---|
| Milk-V Duo (C906) | 25 MHz | yes | **faults** | two 32-bit halves | CLINT MTIP |
| Pico 2 / RP2350B (Hazard3) | 1 MHz | **no** | yes (SIO timer) | halves (RV32) | SIO MTIMECMP |
| VisionFive 2 Lite (U74) | 4 MHz | no | yes (64-bit) | 64-bit | CLINT MTIP |
| QEMU virt | 10 MHz | yes | yes | 64-bit (RV64) | CLINT MTIP |
| CH32V307 (QingKe) | 144 MHz | no | PFIC SysTick | 64-bit compare | PFIC IRQ 12 |

---

## 7. Context switching and the scheduler

**In plain English.** A context switch means putting one thread's work aside
and picking up another's exactly where it left off. The scheduler is the
part that decides *which* thread runs next. This port makes the switch by
returning from a trap on a different saved stack — the outgoing thread's
registers are already safely on its own stack, so only the stack pointer has
to change.

### 7.1 Three ways a switch is requested

The port's header comment in `src/rtos/os-core.cpp` is the contract:

| Situation | What happens |
|---|---|
| A **thread** blocks or yields | `reschedule()` executes `ecall` with `a7 = "YSOU"`. An exception is precise and synchronous: the trap is taken *at* the instruction, so the thread cannot run one more instruction before it is saved. |
| A **trap** makes a thread due (tick, ISR post) | `reschedule()` only sets `riscv_port_pending[hart]`. The switch is made on the way out of the **outermost** trap. No second interrupt. |
| Asked with **`MIE` clear** (inside a critical section) | `riscv_port_yield_deferred[hart] = true`; `critical_section::exit()` performs the switch when it sets `MIE` again. |
| **Scheduler locked** | Nothing; unlocking performs the pending switch. |

The ecall path:

```cpp
void riscv_port_yield(void) {
  register ctx_reg_t a7 __asm__("a7") = RISCV_PORT_YIELD_ECALL; // "YSOU"
  __asm__ volatile("ecall" : "+r"(a7) : : "memory");
}
```

`trap.cpp` recognises it, advances `mepc` by 4 (the `ecall` is 4 bytes),
consumes the marker (so an application's later `ecall` is not mistaken for a
yield), and calls `switch_stacks()`.

**Why not MSIP as PendSV?** The first version did. A CLINT MSIP write is a
posted store: QEMU takes the interrupt on the next instruction, the C906
some cycles later. A thread that had just marked itself suspended ran past
`reschedule()`, removed its own wake-up node, and was switched out for ever.
This was measured with GDB on the Duo. An `ecall` has no such window. MSIP
is now used only for software IRQ lines and IPIs.

### 7.2 What `switch_stacks()` does

On a single hart:

```cpp
stack::element_t* switch_stacks(stack::element_t* sp) {
  riscv_port_pending[0] = false;
  riscv_port_yield_deferred[0] = false;
  thread* old_thread = scheduler::current_thread_;
  old_thread->context_.port_.stack_ptr = sp;   // publish the outgoing frame
  scheduler::internal_switch_threads();        // re-link old, pick next
  return scheduler::current_thread_->context_.port_.stack_ptr;
}
```

The kernel's `internal_switch_threads()` re-links the outgoing thread into
the ready list if it is still `running`, then picks the highest-priority
ready thread (or the idle thread). The returned pointer is the incoming
thread's saved `sp`; `trap.S` restores from it and `mret`s. The outgoing
thread resumes after its `ecall` (or after the interrupted instruction) when
it is switched back in.

On SMP the same function adds the kernel spinlock and the publish/claim
protocol described in section 8.4.

### 7.3 The ready list and the scheduling policy

- The ready list is **priority ordered**, higher numeric value first
  (`ready_threads_list::link` in `src/rtos/internal/os-lists.cpp`).
- Threads of **equal priority** are linked at the tail of their priority
  group. A running thread that is re-linked goes to the tail too, so equal
  priorities round-robin in FIFO order.
- `internal_switch_threads()` takes the head of the ready list, marks it
  running, and makes it `current_thread_`.
- The idle thread is the fallback. On SMP there is one idle thread per core
  (`os_idle_thread_core[n]`, named `idle0`, `idle1`, …), and an idle thread
  can only run on its own core.
- Threads have states (`initializing`, `ready`, `running`, `suspended`,
  `terminated`). A suspended thread is in no ready list; `internal_link_node`
  removes it from ready and links it into the object's waiting list.

### 7.4 Starting the scheduler (what a board or application calls)

```cpp
os::rtos::scheduler::initialize();  // clears MIE
// create threads, register idle1..idleN for the secondary cores
os::rtos::scheduler::start();       // does not return
```

`port::scheduler::start()`:

1. clears `MIE`;
2. registers the interrupt stack (`__irq_stack_bottom`/`top`) and initialises
   its guard pattern;
3. creates a static `fake_thread` and points `current_thread_` at it, so the
   boot context has somewhere to be saved;
4. on SMP: sets each secondary's interrupt-stack top, resets per-hart lock
   state and pending flags, registers `idle0`;
5. enables the switch mechanism — `MSIE` + MSIP clear on CLINT boards, or
   PFIC interrupt 14 with its priority and threshold — and performs the
   first switch with the same `ecall`/software-interrupt path;
6. loops for ever (the boot context is never resumed).

The first real thread's frame is built by `port::context::create()`:

- stack top aligned down to 16 bytes, then `sp -= frame size`;
- frame zeroed; registers `x5`..`x31` filled with `0xCCCCCCCC00000000 | i`
  so a thread that reads an uninitialised register sees recognisable
  garbage;
- `mepc = func`, `a0 = args`, `ra = 0` (a return faults at 0), `gp =
  __global_pointer$`, `tp = 0`;
- `mstatus = MPP_M | MPIE` (resume in M-mode with interrupts enabled after
  `mret`), plus `FS = Initial` and `fcsr = 0` when there is an FPU.

### 7.5 Secondary harts

There are two launch models, both behind the same API
(`include/riscv-smp.hpp`, names shared with the RP2350 Cortex-M port):

- **Every hart enters `_start`** (QEMU virt, and any board whose loader
  starts them): non-zero harts wait in `riscv_secondary_park`, spinning on a
  slot `{magic, entry, sp}` until `riscv_smp_release_hart()` writes the
  entry and stack first and the magic last with release ordering.
- **A board-specific launcher** (RP2350 boot ROM FIFO, JH-7110S loader):
  board code calls `port_smp_secondary_start` on the new hart.

Either way, the secondary runs `port_smp_secondary_start()`: clear `MIE`,
install a per-hart fake thread, clear its MSIP, enable `MSIE`, start its own
tick, and `ecall` into its first thread (normally `idleN`).

A stale release slot in DDR is a real hazard: `.bss` is zeroed by CPU 0
*after* the secondaries are already spinning, and DDR keeps its contents
across debugger loads. The VisionFive 2 runner clears the slots through
OpenOCD before starting any hart.

---

## 8. Preemption

**In plain English.** Preemption is the scheduler taking the CPU away from a
running thread because something more urgent is ready. The danger is doing
that at a bad moment — in the middle of an interrupt handler, or halfway
through a data update. The port therefore never switches immediately from an
interrupt: it notes that a switch is needed and performs it at one safe
point, on the way out of the outermost trap.

### 8.1 The preemption point

Preemption on this port is **tick-driven**, and the switch itself always
happens at a controlled point:

1. The machine timer traps.
2. `riscv_port_tick()` advances the comparator and calls
   `os_systick_handler()`.
3. `os_systick_handler()` advances the clocks, checks timers and timeouts
   (which may make a higher-priority thread ready), and calls
   `port::scheduler::reschedule()`.
4. Because execution is inside a trap, `reschedule()` does **not** switch.
   If `scheduler::preemptive()` is true it sets
   `riscv_port_pending[hart] = true`.
5. On the way out of the **outermost** trap, `trap_exit()` asks
   `riscv_port_switch_due()`: is a switch pending and is the scheduler
   unlocked? If yes, it calls `switch_stacks()` and returns the incoming
   frame; `trap.S` restores it and `mret`s into the new thread.

This is Cortex-M tail-chaining without a second exception: the tick handler
returns into the dispatcher, and the dispatcher returns into another thread.

```cpp
void* trap_exit(ctx_t* frame) {
  if (riscv_trap_nesting[this_hart()] == 1 && riscv_port_switch_due())
    return scheduler::switch_stacks((stack::element_t*)frame);
  return frame;
}
```

A **nested** trap never switches (`nesting != 1`), so a switch can never
leave an outer handler half-done.

### 8.2 Voluntary preemption and blocking

Every blocking kernel call ends in `port::scheduler::reschedule()`:
`thread::suspend`, `this_thread::yield`, `semaphore::wait`, `mutex::lock`,
`condition_variable::wait`, `sleep_for`, … . From a thread with `MIE` set
and the scheduler unlocked, that is the `ecall` path: the switch is
immediate and precise.

If the call is made with `MIE` clear (inside `interrupts::critical_section`)
or with the scheduler locked, the request is remembered and performed when
the section ends (section 9).

### 8.3 Turning preemption off

`scheduler::preemptive(false)` makes the scheduler non-preemptive without
changing the tick: clocks and timers still advance, but `reschedule()` from a
trap no longer sets the pending flag, so threads only switch when they block
or yield explicitly. The default is `OS_BOOL_RTOS_SCHEDULER_PREEMPTIVE`
(true).

### 8.4 Preemption on SMP

The model is one scheduler, many harts, with per-hart state:

| State | Meaning |
|---|---|
| `current_thread_[OS_NCPU]` | the thread running on each hart |
| `lock_state[OS_NCPU]` | that hart's scheduler lock |
| `riscv_port_pending[OS_NCPU]` | a switch is due on that hart |
| `riscv_port_yield_deferred[OS_NCPU]` | a switch was asked for with `MIE` clear |
| `riscv_trap_nesting[OS_NCPU]` | trap depth, per hart |
| `riscv_irq_stack_top[OS_NCPU]` | that hart's interrupt stack |
| `os_idle_thread_core[OS_NCPU]` | that hart's idle thread |

The scheduler lock on SMP is stronger than on a single hart: locking takes
the **global kernel spinlock** and keeps this hart's interrupts masked. The
order is important:

```cpp
const reg_t s = csr::mstatus_clear_mie();   // mask first
const unsigned h = this_hart();              // then read the hart id
const state_t tmp = lock_state[h];
if (state == locked) {
    riscv_smp_klock_acquire();
    lock_mie[h] = s;
    lock_state[h] = locked;                  // interrupts stay masked
}
```

Masking before reading `mhartid` guarantees the thread cannot migrate
between reading the hart id and writing that hart's lock state.

Unlocking publishes `unlocked` **before** releasing the spinlock, restores
the saved `MIE`, and then yields if a switch is pending. The kernel's
`kernel_critical_section` falls back to this same scheduler lock on this
port (the port does not define `OS_HAS_PORT_KERNEL_LOCK`), so kernel data is
protected by "interrupts masked on this hart + global spinlock".

**Cross-hart wake-ups.** If a thread is resumed on a hart that is not in its
affinity mask, the kernel calls `port_smp_ipi(c)` for an eligible hart. That
hart takes an MSIP trap and reschedules. Without the IPI it would wait up to
one tick (1 ms by default) before noticing.

**The publish/claim protocol.** A thread must never run on two harts at once.
In `switch_stacks()`:

```cpp
old_thread->context_.port_.stack_ptr = sp;   // publish: frame is complete
internal_switch_threads();                    // pick under the spinlock
new_thread = current_thread_[h];
if (new_thread != old_thread) {
    out_sp = new_thread->stack_ptr;
    new_thread->stack_ptr = nullptr;          // claim: live on this hart
}
```

The kernel's ready-list scan skips any thread whose `stack_ptr` is `nullptr`
(it is live in another hart's registers). The outgoing thread's stack
pointer is published at once, so another hart may pick it immediately; the
incoming thread is claimed by clearing its pointer. This is the same
protocol as the RP2350 Cortex-M port.

**Affinity.** The ready-list scan also applies `cpu_affinity()` and pins each
core's idle thread to its own core. Pinning a thread *after* creating it is
racy: it is already ready with the default "any core" affinity and another
core may pick it up first. The pattern used by the SMP tests is to pin first
thing and yield until the hart matches:

```cpp
this_thread::thread().cpu_affinity(1u << core_id);
while (port_cpu_id() != core_id) this_thread::yield();
```

### 8.5 Preemption summary by board

| Board | Tick preempts? | Nested interrupts? | Switch point |
|---|---|---|---|
| Single-hart CLINT boards | yes | no (unless an ISR re-enables `MIE`) | ecall, or outermost trap exit |
| Pico 2 (Hazard3) | yes | yes, by Xh3irq priority | outermost trap exit, per core |
| VisionFive 2 Lite (4×U74) | yes, per hart | PLIC nesting in handlers | outermost trap exit, per hart |
| CH32V307 (PFIC) | yes | yes, hardware, 4 levels | only interrupt 14 (lowest priority) |

---

## 9. Critical sections and the other protections

**In plain English.** A critical section is a short "do not disturb" sign:
while the kernel is halfway through changing a list or a counter, no
interrupt or other thread may look at or change the same data. The simplest
way to enforce that is to turn interrupts off for a few instructions, then
put them back exactly as they were. On more than one core, turning
interrupts off on one core is not enough, so a small lock makes the other
cores wait their turn.

### 9.1 The basic critical section: `mstatus.MIE`

`interrupts::critical_section` is the kernel's RAII guard. On a standard
RISC-V hart it is one CSR instruction:

```cpp
inline rtos::interrupts::state_t critical_section::enter(void) {
  const riscv::reg_t s = riscv::csr::mstatus_clear_mie(); // csrrci
#if defined(OS_USE_SMP_SCHEDULER)
  riscv_smp_klock_acquire();
#endif
  return s;                    // 0 or MSTATUS_MIE (8)
}

inline void critical_section::exit(state_t state) {
#if defined(OS_USE_SMP_SCHEDULER)
  riscv_smp_klock_release();
#endif
  if (state & riscv::csr::MSTATUS_MIE) {
    const bool deferred = riscv_port_yield_deferred[this_hart()];
    riscv::csr::mstatus_set_mie();          // csrrsi
    if (deferred) riscv_port_deferred_yield();
  }
}
```

Why one instruction matters: `csrrci` both reads the old `mstatus` and
clears `MIE` atomically, with no read-modify-write window. The equivalent
ARM sequence (`mrs` then `cpsid`) has a small window that only matters if an
interrupt changes the state between the two; RISC-V removes it.

The `"memory"` clobber on the inline assembly is essential: without it the
compiler may move loads and stores across the mask and outside the section.

**Nesting and restore.** `state` is the *old* `MIE` bit, so a nested section
whose outer section had interrupts off leaves them off when it exits. Only
the outermost section restores interrupts.

**Deferred switch.** A switch requested inside the section is not lost:

```cpp
if (!s) {                               // MIE was clear
  riscv_port_yield_deferred[h] = true;  // reschedule()
  return;
}
```

`critical_section::exit()` reads that flag while still masked, sets `MIE`,
and only then executes the `ecall`. This is exactly what clearing PRIMASK
does to a pending PendSV on Cortex-M. Reading the flag while masked also
ensures the hart cannot change under the read on SMP.

**`uncritical_section`** is the inverse: it sets `MIE` (returning the old
bit) and restores it on exit. The kernel uses it when it must let a switch
happen inside a kernel operation (a yield, a priority change).

### 9.2 The PFIC variant: threshold instead of `MIE`

On the WCH QingKe the hardware nests and leaves `MIE` set, so masking `MIE`
would not give the Cortex-M `PRIMASK` behaviour. The port uses the PFIC
threshold (`PFIC_ITHRESDR`), the `BASEPRI` analogue:

```cpp
critical_section::enter():
    t = pfic::threshold();
    if (t == 0 || t > KERNEL_THRESHOLD) pfic::set_threshold(KERNEL_THRESHOLD);
    return t;

critical_section::exit(state):
    pfic::set_threshold(state);
    if (state == 0 && !in_trap() && MIE)  // the switch is a pending IRQ 14
        while (pfic::is_pending(IRQ_SWI)) { }
```

The semantics of the PFIC threshold are "an interrupt whose priority value
is **greater than or equal to** the threshold stays pending". Smaller
priority value = more urgent. `KERNEL_THRESHOLD = 0x40` therefore masks the
`0x40`, `0x80` and `0xC0` groups and leaves the `0x00` zero-latency group
running. If the current threshold is already more restrictive (below
`0x40`), it is left alone; if it is less restrictive (`0x80`), it is raised
to `0x40`. The comment "never lower it" means never lower the *protection*.

The `0x00` group is allowed to run through a kernel critical section, so it
**must not call the kernel**. This is the same rule as a zero-latency
interrupt on Cortex-M.

On exit, if the threshold returns to 0, the thread is outside a trap, and
`MIE` is set, the code spins until PFIC interrupt 14 (the switch) is no
longer pending. A thread must not run past the end of its critical section
before it has been switched out.

### 9.3 The scheduler lock

The scheduler lock is a separate concept from the interrupt mask: it stops
**thread switches**, not interrupts.

- Single hart: `lock_state` is a `bool`; `locked(state)` changes it inside an
  interrupts critical section.
- SMP: `lock_state[hart]` is per hart; locking takes the kernel spinlock and
  keeps `MIE` masked until unlock.

The kernel uses `scheduler::critical_section` around ready-list and
object-state changes. A thread may take the scheduler lock without disabling
interrupts globally on a single-hart port, but this port's implementation
does disable them, which is simpler and harmless.

`locked()` is also safe to call from an ISR: single hart reads a `bool`; SMP
briefly masks `MIE` around the read of `lock_state[hart]`.

### 9.4 The SMP kernel spinlock

`os_port_smp_klock_t` is `{word, owner, depth}`. It is **recursive**: the
owner may take it again, incrementing depth, and only the last release
frees it.

```cpp
void riscv_smp_klock_acquire(void) {
  const unsigned h = this_hart();
  if (smp_klock.owner == h) { smp_klock.depth++; return; }
  while (__atomic_exchange_n(&smp_klock.word, 1u, __ATOMIC_ACQUIRE) != 0)
    while (__atomic_load_n(&smp_klock.word, __ATOMIC_RELAXED) != 0) { }
  smp_klock.owner = h;
  smp_klock.depth = 1;
}

void riscv_smp_klock_release(void) {
  if (smp_klock.owner != this_hart() || smp_klock.depth == 0) return;
  if (--smp_klock.depth == 0) {
    smp_klock.owner = SMP_NO_OWNER;
    __atomic_store_n(&smp_klock.word, 0u, __ATOMIC_RELEASE);
  }
}
```

Design points:

- The exchange is a single `amoswap.w.aq` (the A extension), not a
  load-exclusive loop. The inner spin is a relaxed plain load, so a waiting
  hart does not keep the cache line busy with failed swaps.
- The lock is always taken with the caller's `MIE` already clear
  (`critical_section::enter` clears it first), so a hart cannot be
  interrupted while holding the kernel lock. This is why the lock has no
  interrupt-disable of its own.
- `owner`/`depth` are read and written only by the owner; the atomic word is
  the only cross-hart object.
- The lock word is placed in `.data.amo` (`RISCV_AMO_DATA`), because on the
  RP2350 an AMO to the QSPI PSRAM window faults (`mcause` 7, measured). The
  linker script keeps `.data.amo`/`.bss.amo` in SRAM.

### 9.5 Which mechanism protects what

| Mechanism | Protects against | Scope | Where |
|---|---|---|---|
| `interrupts::critical_section` | ISRs and thread switches | this hart (plus the kernel spinlock on SMP) | `os-inlines.h` |
| PFIC threshold | PFIC interrupts at/above `0x40`, and the switch | this hart | `os-inlines.h`, `pfic.hpp` |
| `scheduler::critical_section` | thread switches / ready-list changes | this hart (SMP: plus spinlock) | `os-decls.h`, `os-core.cpp` |
| kernel spinlock (`smp_klock`) | other harts touching kernel data | all harts | `os-core.cpp` |
| `mutex` | application data | threads (priority inheritance/ceiling in the kernel) | `os-mutex.cpp` |
| `semaphore`, `condvar`, `event_flags`, `mqueue` | application objects | threads/ISRs as documented | kernel |
| per-hart `current_thread_`, `pending`, `nesting` | cross-hart corruption of scheduler state | one hart each | `os-core.cpp`, `trap.S` |

There is **no memory protection**: PMP is not programmed and the MMU is not
enabled for the kernel. `mmu.cpp` builds Sv39 tables only for the `mmu-test`,
which proves them through `MPRV` (M-mode accesses translated as S-mode). An
RV32 hart has no MMU code at all.

### 9.6 Memory ordering: fences

RISC-V orders only what you tell it to. The port uses:

| Fence | Where | Why |
|---|---|---|
| `fence o, i` | after `msip_set()` / `msip_clear()` | a later device read must not overtake the posted device write |
| `fence r, r` | after seeing the secondary-release magic | the entry and stack written before the magic are visible |
| `fence.i` | `_start` on every hart; before jumping to released code; PFIC threshold changes | instruction fetch must see newly written code / new interrupt state |
| acquire/release on AMOs | the kernel spinlock and the soft-IRQ bitmaps | publish/consume ordering |
| `"memory"` clobber | every CSR mask/unmask | the compiler must not move memory accesses across the section |

`fence.i` is not a data barrier; it is the instruction-fetch fence. On a
board where a debugger has just written code, every hart that will execute
it needs its own `fence.i` (each hart has its own I-cache).

---

## 10. Atomics

**In plain English.** An atomic operation is all-or-nothing: no other core
can see it half-finished. A normal "read, add, write" can be interrupted
between the steps and lose an update; an atomic add cannot. RISC-V provides
single-instruction atomics and a reserve/write-if-unchanged pair. This
section also explains *ordering*: even when each operation is atomic, the
CPU may reorder unrelated loads and stores unless a fence tells it not to.

### 10.1 What the ISA offers

The A extension provides two families:

- **AMOs** (single instruction, atomic read-modify-write): `amoswap`,
  `amoadd`, `amoand`, `amoor`, `amoxor`, `amomin`, `amomax` (and unsigned
  variants), in `.w` (32-bit) and `.d` (64-bit, RV64 only) forms, each with
  optional `.aq`/`.rl` ordering bits.
- **LR/SC**: `lr.w`/`sc.w` (and `.d` on RV64), with `.aq`/`.rl`.

Recent toolchains split these into `Zaamo` and `Zalrsc`; a build's `-march`
must include `A` (or both). All boards here do: `rv64imafdc…`,
`rv32ima…`, `rv32imafc…`.

### 10.2 How the port uses them

| Purpose | Code | Emitted shape |
|---|---|---|
| kernel spinlock acquire | `__atomic_exchange_n(&word, 1, __ATOMIC_ACQUIRE)` | `amoswap.w.aq` |
| kernel spinlock release | `__atomic_store_n(&word, 0, __ATOMIC_RELEASE)` | release store (fence + `sw`, or `amoswap.w.rl`) |
| spin wait | `__atomic_load_n(&word, __ATOMIC_RELAXED)` | plain load |
| software IRQ enable/disable | `__atomic_fetch_and/or(..., __ATOMIC_SEQ_CST)` | `amoand.w` / `amoor.w` |
| software IRQ pending test | `__atomic_load_n(..., __ATOMIC_ACQUIRE)` | acquire load |
| secondary release magic | `__atomic_store_n(&slot[0], MAGIC, __ATOMIC_RELEASE)` | release store |

The spinning hart deliberately uses a relaxed load in the inner loop: it is
only a hint that the lock may be free, and the acquire exchange is what
actually takes it.

### 10.3 Width: the lock is 32-bit on both RV32 and RV64

The lock word is `uint32_t`, and `amoswap.w` is a 32-bit operation on both
XLENs. No `.d` AMO is needed, so an RV32 hart and an RV64 hart run exactly
the same lock algorithm. AMOs operate on naturally aligned memory; the port
keeps the lock word aligned and in normal cacheable SRAM.

On RV32, 64-bit values (time, timestamps) are plain data, not atomic
objects. The port does not use 64-bit atomics; it uses `rdtime`'s
high/low/high retry loop and the `mtimecmp` split write instead.

### 10.4 Where atomics do not work

An AMO needs memory that supports it. On the WeAct RP2350B an `amoswap.w`
to the QSPI PSRAM window (`0x11000000`) faults with `mcause` 7 (store/AMO
access fault), measured. The port therefore places every object changed with
atomics in dedicated sections:

```cpp
#define RISCV_AMO_DATA __attribute__((section(".data.amo")))
#define RISCV_AMO_BSS  __attribute__((section(".bss.amo")))
```

An ordinary linker script folds these into `.data`/`.bss` with `*(.data
.data.*)`; the PSRAM linker script (`linker-psram.ld`) places them in SRAM.
Objects using them: `smp_klock`, `riscv_soft_irq_enabled`,
`riscv_soft_irq_pending`.

On the RP2350's Hazard3 cores, AMOs are atomic across both cores (the global
monitor). The Cortex-M side of the same chip could not rely on
`LDREX`/`STREX` being cross-core exclusive and used SIO hardware spinlocks
instead; the RISC-V side does not need that workaround.

---

## 11. RV32 versus RV64

**In plain English.** RV32 and RV64 are the same design with different
register widths: 32-bit versus 64-bit. A register holds one pointer or one
machine word, so the saved context, the width of a CSR read, and the way a
64-bit time value is assembled all change. The scheduling logic, the locks
and the critical sections do not: they are written to work at either width.

Everything width-dependent is selected at compile time. The table is the
practical checklist.

| Aspect | RV64 (C906, U74, QEMU virt) | RV32 (Hazard3, QingKe V4F) |
|---|---|---|
| `riscv::reg_t` | `uint64_t` | `uint32_t` |
| CSR width | 64 bits | 32 bits |
| `mstatus.MIE` mask | bit 3, same | bit 3, same |
| `mcause` interrupt bit | bit 63 | bit 31 (`reg_t(1) << (XLEN-1)`) |
| Frame, no FPU | — | 144 bytes |
| Frame, F/D FPU | 528 bytes (D) | 272 bytes (F) |
| Load/store macro | `ld`/`sd` | `lw`/`sw` |
| FP load/store | `fld`/`fsd` | `flw`/`fsw` |
| Stack alignment | 16 bytes (psABI) | 16 bytes (psABI) |
| `rdtime` | one `rdtime` | `rdtimeh`/`rdtime`/`rdtimeh` retry loop |
| `rdcycle` | one `rdcycle` | `rdcycleh`/`rdcycle`/`rdcycleh` retry loop |
| 64-bit tick arithmetic | native | libgcc helpers (`__udivdi3`, `__udivmoddi4`) |
| 64-bit MMIO | one access, or split if the board says so | always two 32-bit accesses |
| MMU | Sv39 (`mmu.cpp`) | none; `mmu-test` reports SKIP |
| MMU test | `MPRV` + Sv39 tables | no code |
| Semihosting `SYS_EXIT` | parameter block `{reason, status}` | reason in `a1`, 32-bit form |
| Stack fill magic | `0xEFBEADDEEFBEADDE` | `0xEFBEADDE` |
| `OS_INTEGER_RTOS_STACK_FILL_MAGIC` | 64-bit | 32-bit |
| Code model | `medany` | `medany` |
| ABI | `lp64d` | `ilp32f` (CH32V307) / `ilp32` (Pico 2) |
| Atomics used | `amoswap.w` (32-bit) | `amoswap.w` (32-bit) |
| FP context | `f0`–`f31` + `fcsr` saved always | same, only when `__riscv_flen` |
| `mstatus.FS` | set `Initial` in `_start` and in new frames | same |

### 11.1 RV64

- The C906 and U74 are RV64GC. The port uses `lp64d`; the FP register file
  is saved on every trap because a preemptive switch can land in the middle
  of any floating-point sequence. There is no lazy-FP bookkeeping: the frame
  is simply bigger.
- Sv39 is the only translation scheme wired (`mmu.cpp` is `#if __riscv_xlen
  == 64`). M-mode accesses are not translated by `satp`; the test uses
  `MPRV`.
- `mtimecmp` is written as one 64-bit store on the U74, and as two 32-bit
  halves on the C906.
- `rdtime` is one CSR read.

### 11.2 RV32

- Hazard3 has no F/D and no FPU; `__riscv_flen` is undefined, so `trap.S`
  has no FP block and the frame is 144 bytes. Floating point is software.
- Hazard3 does not implement the `time`/`timeh` CSRs; the clock is the SIO
  platform timer over MMIO. `clint::now()` selects it with
  `riscv_board::TIME_CSR == false`.
- The QingKe V4F has a single-precision FPU (`__riscv_flen == 32`); the port
  saves `f0`–`f31` and `fcsr`, giving a 272-byte frame.
- 64-bit values are built from two 32-bit reads with a carry-retry loop
  (`rdtime`, `mtime_read`). The split is not atomic; the retry makes the
  composition consistent.
- `mtimecmp` writes are two 32-bit stores with the high half all ones first.
  On an RV32 hart this is mandatory anyway (there is no 64-bit store), and
  it is also the safe order for the C906.
- The tick's `(now - next_tick) / tick_period` is a 64-bit division; on RV32
  this is a libgcc call. It happens only in the tick path, not in the hot
  context-switch path.
- `OS_INTEGER_RTOS_STACK_FILL_MAGIC` is 32-bit; the stack allocation element
  type is still `uint64_t` so stacks stay at least 8-byte aligned.

### 11.3 What is the same on both

- The trap entry, frame offsets, nesting counter and interrupt stack logic
  (`PORT_REGBYTES` is `__riscv_xlen / 8`; `REG_S`/`REG_L` select `sd`/`ld`
  or `sw`/`lw`).
- `csrrci mstatus, 8` / `csrrsi mstatus, 8` critical sections.
- The 32-bit kernel spinlock (`amoswap.w`).
- The scheduler, ready list, preemption points and SMP protocol.
- The board-facing contracts (`riscv_board::*`, `clint::*`, `pfic::*`).
- The psABI 16-byte stack alignment, and the 4-byte `ecall` step-over.

---

## 12. End-to-end sequences

### 12.1 A tick preempts a running thread

```
thread A running (MIE=1)
  machine timer fires
  trap entry: frame on A's stack, nesting=1, sp -> IRQ stack
  mcause=7 -> riscv_port_tick()
      due=1; next_tick += period; write mtimecmp
      os_systick_handler():
          sysclock++, hrclock++
          check timestamps -> thread B (higher priority) becomes ready
          reschedule(): in trap, preemptive -> pending[hart]=true
      guard: deadline not passed
  trap_exit: nesting==1 && pending && scheduler unlocked
      switch_stacks(frame):
          A->stack_ptr = frame (A is suspended or re-linked)
          internal_switch_threads() -> B
          return B->stack_ptr
  trap restore from B's frame; mret
thread B running
```

### 12.2 A thread blocks

```
thread A calls semaphore::wait() -> no token
  internal_link_node(): A removed from ready, state=suspended
  reschedule(): MIE=1, not in trap -> riscv_port_yield()
      ecall with a7="YSOU"
  trap entry: nesting=1
  trap.cpp: mcause=11, marker -> mepc+=4, a7=0
      switch_stacks(frame): A->stack_ptr=frame; pick B
  mret into B
```

When another thread posts the semaphore, `internal_unlink_node` links A back
into the ready list and calls `reschedule()`. If that happens on another
hart, an IPI is sent to an eligible hart.

### 12.3 An ISR wakes a thread

```
device IRQ -> trap, MIE cleared by hardware
  riscv_board_external_interrupt()
      claim, raise threshold, mask MTIE/MSIE, set MIE
      handler(): semaphore.post() -> thread B ready
          reschedule(): in trap -> pending[hart]=true (no switch here)
      clear MIE, restore threshold, complete
  trap_exit: nesting==1 && pending -> switch_stacks()
```

### 12.4 A switch is requested inside a critical section

```
thread A:
  interrupts::critical_section ics;   // MIE 1 -> 0
  ... post a semaphore, wake B ...
  reschedule(): MIE=0 -> yield_deferred[hart]=true
  ... still inside the section, no switch ...
  } // ~critical_section: release klock, deferred=true, set MIE, ecall
      switch to B
```

### 12.5 A secondary hart starts

```
hart 1 enters _start -> riscv_secondary_park
  spins on slot {magic, entry, sp}
CPU 0: riscv_smp_release_hart(1, port_smp_secondary_start, stack)
  slot[2]=sp; slot[1]=entry; release-store slot[0]=magic
hart 1: sees magic, fence r,r, loads sp and entry, fence.i, jr
  port_smp_secondary_start():
      clear MIE; fake_thread for hart 1; current_thread_[1]=fake
      clear MSIP; enable MSIE; start this hart's tick
      riscv_port_yield() -> ecall -> first switch into idle1
```

---

## 13. Particularities that cost real debugging time

These are the places where the specification allows behaviour that bit this
port. They are part of the design, not folklore.

| Symptom / constraint | Cause | Fix in the port |
|---|---|---|
| A suspending thread ran past `reschedule()` and lost its wake-up | MSIP is a posted store; the C906 takes it cycles later | use `ecall` (precise) for thread switches; MSIP only for IRQ lines/IPI |
| Idle hart never took a pending timer interrupt | C906 in `wfi` did not take an enabled `MTIP` (measured) | idle spins; `wait_for_interrupt()` is an empty compiler barrier |
| Tick trap re-entered for ever after a slow callback | comparator already passed before `mret` | `riscv_port_tick_guard()` pushes the comparator one period from now, grid unchanged |
| Time lost while halted or in a long section | SysTick drops missed ticks | count owed periods; `N-1` bare increments + one `os_systick_handler()` |
| Spurious tick on a split `mtimecmp` write | the two halves briefly form a lower value | write high half `0xFFFFFFFF` first |
| `mtime` load faults on the C906 | hardware does not implement it (32-bit included) | use `rdtime`; `MTIME_READABLE=false` |
| PFIC SysTick storm and the switch never runs | latched `CNTIF`/pending survives a moved compare | clear `STK_SR` and pending after the write; re-pend if already due |
| Nested PFIC interrupt built a frame over itself | `sp` restored before nesting decremented | move `sp` to the frame first, then decrement |
| AMO faults in PSRAM on RP2350B | PSRAM does not support AMOs (`mcause` 7) | `.data.amo`/`.bss.amo` kept in SRAM |
| Thread ran on the wrong core | pinned after creation, default affinity let another core pick it | pin first, yield until `port_cpu_id()` matches |
| Stale secondary release in DDR | `.bss` zeroed after secondaries park; DDR survives loads | loader clears `riscv_secondary_boot[]` before starting harts |
| U74 traps on misaligned accesses | U74 does not support them in hardware | portable code must not rely on them; the VF2 `mmu-test` skips that step |
| Hart id is not a dense CPU index | JH-7110S harts are 1..4 (hart 0 is the S7) | `RISCV_HART_BASE=1`; CPU index = `mhartid - base` |
| Semihosting stops servicing long runs on Pico 2 | debug-probe firmware limits | copy only verdict lines to semihosting; the rest to UART |

---

## 14. How to use it (practical notes)

### 14.1 Board contract

A new board must provide:

- `board.cmake`: `UOS_BOARD_FLAGS` (`-march`/`-mabi`/`-mcmodel`),
  `UOS_BOARD_NCPU`, `UOS_BOARD_CAPS`, linker scripts, `PORT_GREETING`, and
  `RISCV_HART_BASE` if the harts do not start at 0;
- `include/riscv-board.hpp`: CLINT/SIO/PFIC addresses, per-hart strides,
  `TIMEBASE_HZ`, and the three timer facts (`TIME_CSR`, `MTIME_READABLE`,
  `MTIMECMP_SPLIT32`), plus `PLIC_BASE` or `RISCV_PFIC`;
- a console writer and the board init hooks (`riscv_board_initialize_early`,
  `riscv_board_initialize`), the optional memory hook, and the external IRQ
  dispatcher (`riscv_board_external_interrupt` or
  `riscv_board_pfic_interrupt`);
- on SMP, a way to start the secondaries (`multicore::launch_coreN` or the
  `_start` park slot).

### 14.2 Application-side checklist

- Create threads, then call `os::rtos::scheduler::start()`.
- A blocking call must not be made from an ISR; use the ISR-safe post
  operations, which end in `reschedule()` and are switched on trap exit.
- Keep critical sections short. On SMP every `interrupts::critical_section`
  also takes the global kernel spinlock.
- On the PFIC board, the priority `0x00` group must not call the kernel.
- On SMP, pin a thread before it can be scheduled (create it with the
  affinity or pin first thing and yield).
- Do not rely on `wfi`; the port's idle spins.

### 14.3 Building and rendering this document

```bash
cd micro-os-plus-iii-riscv
scripts/make-pdf.sh docs/riscv-rtos.md      # -> docs/riscv-rtos.pdf
```

The script uses `pandoc` (GitHub-flavoured Markdown to HTML with a table of
contents) and `weasyprint` (HTML to PDF).

---

## 15. Boards used in tests: standard RISC-V versus vendor-specific

This section takes every board in `test/boards/` (plus the QEMU `virt`
stand-in that some of them build for) and separates three things:

1. what is **ratified RISC-V** (the ISA and the privileged architecture);
2. what is a **de-facto platform convention** (CLINT, PLIC — widely used and
   specified, but not part of the ISA);
3. what is **specific to a vendor or a SoC** (registers, interrupt
   controllers, boot ROMs, memory maps, board wiring, and silicon quirks).

The distinction matters when porting: code that uses only layer 1 moves
between cores unchanged; layer 2 usually moves between SoCs with address
changes; layer 3 must be rewritten or hidden behind a board fact.

### 15.1 What "standard RISC-V" means here

**Layer 1 — ratified by RISC-V International.**

- The instruction set: `RV32I`/`RV64I` plus the extensions named in the
  board's `-march` (`M`, `A`, `F`, `D`, `C`, `Zicsr`, `Zifencei`, and the
  bit-manipulation `Zb*` extensions).
- The machine-mode privileged architecture: CSRs `mstatus`, `mie`, `mip`,
  `mcause`, `mepc`, `mtval`, `mtvec`, `mhartid`, `misa`, `satp`; the trap
  entry rules; `mret`; `ecall`; `ebreak`; the M-mode interrupt causes 3
  (software), 7 (timer), 11 (external).
- The A extension's AMOs and LR/SC; the `fence` family.
- The psABI (register roles, 16-byte stack alignment, `lp64d`, `ilp32`,
  `ilp32f`).

Everything in the port's `src/trap.S`, `src/trap.cpp`, `src/rtos/os-core.cpp`
and `include/riscv-csr.hpp` that is not board-conditional is layer 1.

**Layer 2 — platform convention, not ISA.**

- A **CLINT** at a board-chosen address: `msip` per hart (4-byte stride),
  `mtimecmp` per hart (8-byte stride), shared `mtime`.
- A **PLIC** at a board-chosen address: source priorities, per-context
  enable bits and threshold, claim/complete.
- The optional `time` CSR (`rdtime`) reading the same counter as `mtime`.

These are not in the RISC-V ISA. They come from SiFive's platform and are
copied by most SoC vendors and by QEMU. A board may implement none of them
(CH32V307) or only part (RP2350 has no CLINT, but an SIO timer).

**Layer 3 — vendor- or board-specific.**

- A different interrupt controller (WCH PFIC, Hazard3 Xh3irq).
- A different timer block (RP2350 SIO, WCH SysTick).
- Vendor CSRs (`mxstatus`, `mhcr`, `INTSYSCR`), vendor cause numbering, or
  vendor priority/threshold rules.
- Boot and reset mechanisms (RP2350 boot ROM and OTP, Allwinner FEL/xfel,
  JH-7110 OpenSBI/U-Boot, WCH flash alias), hart numbering, memory maps,
  UART pins, PSRAM wiring.
- Behaviours the ISA allows but that differ in practice: `mtime` not
  readable, `mtimecmp` needing two 32-bit writes, `wfi` not waking, AMOs
  faulting in PSRAM, misaligned accesses trapping, `mtval` hardwired to 0.

### 15.2 The boards in the test tree

**Standard versus vendor-specific, at a glance:**

| Board | Standard RISC-V | Vendor-specific |
|---|---|---|
| **Milk-V Duo** (CV1800B, C906) | RV64GC, CSRs, traps, atomics, `time` CSR, CLINT/PLIC layout | CV1800B addresses; split 32-bit `mtimecmp`; `mtime` unreadable; C906 `mxstatus`/`mhcr` and extended PTE attributes; BL2/OpenSBI boot; `wfi` does not wake |
| **MangoPi MQ-Pro** (Allwinner D1, C906) | Same C906 core and standard CLINT/PLIC layout | D1 addresses; 32-bit-only CLINT bus; no readable `mtime`; C906 cache CSRs; FEL/xfel boot and RTC/watchdog self-reset |
| **Pico 2** (RP2350, 2× Hazard3) | RV32IMA + `Zb*`/`Zc*`, CSRs, traps, atomics, `mhartid` 0/1 | SIO timer + `RISCV_SOFTIRQ` instead of CLINT; Xh3irq CSRs; boot ROM/OTP `ARCHSEL`; FIFO core-1 launch; no `time` CSR; `mtval` hardwired 0; POWMAN clocks |
| **WeAct RP2350B** | Identical to Pico 2 | 16 MB flash + 8 MB QSPI PSRAM; PSRAM init; **AMOs fault in PSRAM**, so `.data.amo` stays in SRAM; UART GPIO12/13 |
| **VisionFive 2 Lite** (JH-7110S, 4× U74) | RV64GC + `Zba`/`Zbb`, Sv39, standard CLINT/PLIC | Hart ids 1–4 (S7 is hart 0); PLIC context `2h−1`; SoC memory map; no `time` CSR; misaligned accesses trap; U-Boot/OpenSBI boot |
| **CH32V307** (QingKe V4F) | RV32IMAFC, standard trap CSRs, `mret`/`ecall`, A-extension atomics | **No CLINT/timer/software interrupt**; PFIC instead of PLIC/NVIC; vendor cause numbering in `mcause`; QingKe SysTick; `INTSYSCR`; pipeline CSR; WCH-LinkE |
| **QEMU `virt`** | Standard/de-facto CLINT, PLIC, `time` CSR, 10 MHz | Only the emulator's `virt` memory map; no silicon quirks |

The same boards, with the details needed to find their tests:

| Board | SoC and core | ISA / ABI | Harts used | Test directory |
|---|---|---|---|---|
| Milk-V Duo (64 MB) | Sophgo CV1800B, T-Head C906 | RV64GC, `lp64d` | 1 | `test/milkv-duo` |
| MangoPi MQ-Pro | Allwinner D1, T-Head C906 | RV64GC, `lp64d` | 1 | `test/mangopi-mq-pro` |
| Raspberry Pi Pico 2 | RP2350, 2× Hazard3 | RV32IMA + `Zb*`/`Zc*`, `ilp32` | 2 (SMP) | `test/pico2` |
| WeAct RP2350B | RP2350B, 2× Hazard3 | same as Pico 2 | 2 (SMP) | `test/pico2-rp2350b-psram` |
| VisionFive 2 Lite | StarFive JH-7110S, 4× U74 | RV64GC + `Zba`/`Zbb`, `lp64d` | 1 or 4 (SMP) | `test/visionfive2-lite` |
| WCH CH32V307V-EVT-R1 | WCH CH32V307, QingKe V4F | RV32IMAFC, `ilp32f` | 1 | `test/ch32v307-evt` |
| QEMU `virt` (RV64/RV32) | emulated SiFive-style platform | RV64GC or RV32 | 1–4 | all boards with QEMU images |

QEMU is not silicon and has no vendor quirks: its job is to test the port's
*generic* code (trap entry, tick, scheduler, SMP protocol) without a board.
Passing on QEMU does **not** prove a board driver; passing on hardware does.

### 15.3 Board-by-board

#### 15.3.1 Milk-V Duo (CV1800B, T-Head C906)

**Standard:** RV64GC (I, M, A, F, D, C), `Zicsr`, `Zifencei`; standard
machine CSRs and trap entry; standard A-extension atomics; `time` CSR
(`rdtime`) present; standard CLINT *layout* at 0x74000000 and standard PLIC
at 0x70000000.

**Vendor-specific:**

- **Sophgo CV1800B memory map** — CLINT, PLIC, UART4, DDR at 0x80000000.
- **`clint,has-no-64bit-mmio`** — a 64-bit `mtimecmp` store is split by the
  bus, so the port writes two 32-bit halves in the safe order. The CLINT base
  and this property are SoC facts.
- **`mtime` is not readable** — any load (even 32-bit) is a load access
  fault, measured. The clock comes from the `time` CSR.
- **C906 extended page attributes** — `mxstatus.MAEE` (CSR 0x7c0, bit 21)
  makes the C906 interpret PTE bits 63..59 as cacheability/shareability.
  BL2 sets it; the MMU map uses those bits. This is T-Head-specific.
- **Boot chain** — boot ROM → minimal fip/BL2 (clocks, DDR, UART4) →
  OpenSBI/payload; OpenOCD halts the hart and loads the test. Not a
  standard RISC-V boot protocol; there is no standard one.
- **`wfi` behavior** — the C906 was measured not taking a pending, enabled
  timer interrupt in `wfi`; the port spins instead.

**Port handling:** `test/boards/milkv-duo/include/riscv-board.hpp` declares
`CLINT_BASE`, `PLIC_BASE`, `MTIMECMP_SPLIT32=true`,
`MTIME_READABLE=false`, `TIME_CSR=true`, `TIMEBASE_HZ=25 MHz`, and the C906
PTE attributes.

#### 15.3.2 MangoPi MQ-Pro (Allwinner D1, T-Head C906)

**Standard:** same C906 core as the Duo, so the same RV64GC, CSRs, trap
entry, atomics, `time` CSR, and standard CLINT/PLIC register layouts.

**Vendor-specific:**

- **Allwinner D1 memory map** — CLINT at 0x14000000, PLIC at 0x10000000,
  DDR at 0x40000000, UART0 on PB8/PB9. Nothing is at the Duo's addresses.
- **32-bit-only CLINT bus** — `reg-io-width = <4>`, so `mtimecmp` is written
  as two halves (same code path as the Duo, different reason).
- **No `mtime` register** — the C906 reads time through `rdtime`; the
  device-tree CLINT has no readable `mtime`.
- **C906 `mxstatus`/`mhcr`** — the board sets MAEE and enables the I- and
  D-caches through vendor CSRs 0x7c0/0x7c1.
- **FEL/xfel boot and self-reset** — xfel brings up DDR and loads the image
  at 0x40000000; the test reports its verdict through the battery-backed RTC
  registers and resets through the D1 watchdog back to FEL. There is no
  JTAG/semihosting on the hardware setup.
- **PLIC state left by the boot ROM** — the board does not trust it and
  leaves external interrupts disabled (`mie.MEIE` cleared); the tests use
  the timer and software interrupts only.

**Port handling:** `test/boards/mangopi-mq-pro/include/riscv-board.hpp` plus
`src/board.cpp` (MAEE, caches, RTC/watchdog).

#### 15.3.3 Raspberry Pi Pico 2 (RP2350, 2× Hazard3)

**Standard:** RV32IMA with `Zba`, `Zbb`, `Zbs`, `Zbkb`, `Zca`, `Zcb`,
`Zcmp`; `Zicsr`, `Zifencei`; standard machine CSRs and trap entry; standard
A-extension atomics; standard `mhartid` values 0 and 1; no FPU.

**Vendor-specific:**

- **SIO instead of a CLINT** — the platform timer is `MTIME`/`MTIMEH` and
  per-core `MTIMECMP`/`MTIMECMPH` in the SIO block at 0xD00001B0/0xD00001B8
  (both cores use the same compare address). There is no `msip` word per
  hart; `RISCV_SOFTIRQ` at 0xD00001A0 sets core *h* with bit *h* and clears
  it with bit `8+h`.
- **No `time` CSR** — Hazard3 does not implement `time`/`timeh`; the port
  reads the SIO timer over MMIO.
- **Xh3irq** — the external interrupt controller is a vendor CSR block
  (`meiea` 0xbe0, `meipa` 0xbe1, `meifa` 0xbe2, `meipra` 0xbe3, `meinext`
  0xbe4), not a PLIC. Priorities run in the opposite direction from ARM.
- **Boot ROM and OTP** — the ROM scans the first 4 KiB of flash for an
  `IMAGE_DEF` block, switches both cores from ARM to Hazard3 according to
  `OTP.ARCHSEL`, and starts core 0 at `_start`. Core 1 is launched through
  the SIO FIFO handshake (`{0,0,1,mtvec,sp,entry}`), and no PSM reset is
  performed (measured: it breaks the handshake).
- **Clock/POWMAN and watchdog-scratch tables** — the clock and voltage
  sequence, and the `clocks::SYS_TABLE` reboot mechanism, are RP2350
  specifics.
- **`mtval` hardwired to 0** — a Hazard3 implementation choice; fault code
  must decode the instruction if it needs an address.
- **PSRAM and AMOs** — on the RP2350B, AMOs to the QSPI PSRAM window fault
  (`mcause` 7, measured); see the RP2350B entry.

**Port handling:** `test/boards/pico2/include/riscv-board.hpp` sets the SIO
addresses, `MTIMECMP_SPLIT32=true`, `TIME_CSR=false`, `TIMEBASE_HZ=1 MHz`,
and `RISCV_BOARD_SOFTIRQ_SIO`; `src/irq.cpp` implements Xh3irq;
`src/multicore.cpp` and `src/secondary.S` implement the boot-ROM launch.

#### 15.3.4 WeAct RP2350B (RP2350B, 2× Hazard3)

**Standard:** identical to the Pico 2 — same SoC, same Hazard3 cores, same
ISA, CSRs, atomics and trap entry. This board includes the Pico 2 board
files and changes only board facts.

**Vendor/board-specific:**

- **16 MB flash and 8 MB QSPI PSRAM** — the PSRAM is on QMI chip-select 1
  (GPIO0); it must be initialised before `.data`/`.bss` that live in it, from
  code running in SRAM.
- **AMOs fail in PSRAM** — an `amoswap.w` to 0x11000000 faults. Atomic
  objects therefore live in `.data.amo`/`.bss.amo`, which the PSRAM linker
  script keeps in SRAM.
- **Different wiring** — UART0 on GPIO12/13 instead of GPIO0/1, LED on
  GPIO25.
- **Its own probe and runner** — the board's `hw.sh` and flash/PSRAM layout.

**Port handling:** `test/boards/pico2-rp2350b-psram/board.cmake` includes
the Pico 2 file, then sets `PICO2_UART_TX_PIN=12`, `PICO2_UART_RX_PIN=13`,
the 16 MB linker scripts and the PSRAM data layout; `psram.cpp` and
`riscv-amo.hpp` handle the rest.

#### 15.3.5 StarFive VisionFive 2 Lite (JH-7110S, 4× SiFive U74)

**Standard:** RV64GC + `Zba`/`Zbb`, `Zicsr`, `Zifencei`; Sv39; standard
machine CSRs and trap entry; standard A-extension atomics; a standard SiFive
CLINT at 0x02000000 with 64-bit `mtimecmp`/`mtime`; a standard PLIC at
0x0C000000.

**Vendor-specific:**

- **Hart numbering** — hart 0 is an S7 monitor core (rv64imac) and the four
  application U74s are harts 1–4. The port's CPU 0 is `mhartid 1`, so
  `RISCV_HART_BASE=1`.
- **PLIC context numbering** — hart *h*'s M-mode context is `2h − 1` in
  JH-7110 device-tree order (hart 0 M, then M and S for each U74). Getting
  this wrong silently enables or masks another core's interrupts.
- **SoC memory map and wiring** — CLINT/PLIC/UART/GPIO/DDR addresses, UART0,
  GMAC, USB, eMMC.
- **No `time` CSR** — the U74 documentation lists none, so the clock is the
  CLINT's `mtime` over MMIO (`TIME_CSR=false`).
- **Misaligned accesses trap** — the U74 does not handle them in hardware;
  the VF2 `mmu-test` skips that step. This is allowed by the ISA
  (implementation-defined), not a vendor register.
- **Boot chain** — BootROM → U-Boot SPL → OpenSBI → U-Boot prompt; OpenOCD
  halts the harts and loads the test into DDR. The S7 and unused U74s stay
  halted or parked.

**Port handling:** `test/boards/visionfive2-lite/include/riscv-board.hpp`
(hart base, PLIC context formula, memory map) and `src/board.cpp` (mask the
PLIC on every U74 M-mode context, park unused harts).

#### 15.3.6 WCH CH32V307V-EVT-R1 (QingKe V4F)

**Standard:** RV32IMAFC (`I`, `M`, `A`, `F`, `C`), `Zicsr`, `Zifencei`;
standard machine CSRs (`mstatus`, `mcause`, `mepc`, `mtvec`, …), `mret`,
`ecall`, `ebreak`; standard A-extension atomics; standard direct-mode
`mtvec` (MODE0).

**Vendor-specific:**

- **No CLINT and no machine timer/software interrupt** — `mie`/`mip` read
  0, and `mcycle`/`cycle`/`time` read 0 (measured). The ISA does not require
  a platform to wire those sources.
- **PFIC instead of CLINT/PLIC** — enable/pend/priority registers at
  0xE000E000, its own IRQ numbers (12 = SysTick, 14 = software interrupt,
  16+ = peripherals), priority groups and a threshold (`BASEPRI` analogue).
- **Vendor cause numbering** — on an interrupt, `mcause` holds the PFIC
  interrupt number, not the standard 3/7/11 codes.
- **QingKe SysTick** — a 64-bit up-counter and compare at 0xE000F000, with
  a latched count flag (`CNTIF`) that needs explicit clearing; the port
  drives it through the same `clint::mtime`/`mtimecmp` code.
- **`INTSYSCR` (CSR 0x804)** — enables hardware nesting and sets the
  preemption levels; HPE (hardware register stacking) is off.
- **Pipeline CSR 0xBC0 and PFIC `fence.i` rule** — WCH start-up values and
  the requirement to synchronise after PFIC/threshold changes.
- **Flash-at-0 boot, 144 MHz HCLK, WCH-LinkE OpenOCD** — board facts.

**Port handling:** `RISCV_PFIC` selects `include/pfic.hpp`,
`src/soft-irq.cpp` compiles out, and `src/trap.cpp` has a PFIC branch. The
threshold implements critical sections; interrupt 14 is the only switch
point.

#### 15.3.7 QEMU `virt` (RV64 and RV32)

**Standard/de-facto:** CLINT at 0x02000000 with 64-bit MMIO, PLIC at
0x0C000000, the `time` CSR, 10 MHz timebase, hart ids 0..N−1, standard
RISC-V CSRs and traps. No vendor quirks.

**QEMU-specific:** the `virt` machine's memory map, 16550 UART at
0x10000000, and the fact that it models a generic SiFive-style platform
rather than any of the real SoCs. The RV32 configuration is deliberately
built to match the Hazard3 feature set (`f=false`, `d=false`, `zba/zbb/
zbs/zbkb`, `zcb`, `zcmp`), but it is still QEMU's machine, not an RP2350.

**Port handling:** `qemu/virt/include/riscv-board.hpp` and
`qemu/virt/src/*`; the board's `tests.cmake` substitutes this target for the
`qemu` image.

### 15.4 Cross-board classification

| Feature | Classification | Boards / notes |
|---|---|---|
| RV32/RV64 base, M, A, F, D, C | **Ratified ISA** | differ by board; `-march`/`-mabi` in `board.cmake` |
| Machine CSRs, trap entry, `mret`, `ecall`, `ebreak` | **Ratified privileged spec** | all boards |
| `mstatus.MIE`, `mie`/`mip`, causes 3/7/11 | **Ratified privileged spec** | generic path on all except PFIC cause encoding |
| A-extension AMOs / LR-SC | **Ratified ISA** | all boards; PSRAM on RP2350B is the exception |
| `time` CSR (`rdtime`) | **Optional standard extension** | Duo/MQ-Pro/QEMU yes; Hazard3/U74/WCH no or zero |
| CLINT layout (`msip`, `mtimecmp`, `mtime`) | **De-facto platform** | Duo, MQ-Pro, VF2, QEMU; absent on Pico 2 and CH32 |
| PLIC | **De-facto platform** | Duo, MQ-Pro, VF2, QEMU; absent on Pico 2 and CH32 |
| SIO timer / `RISCV_SOFTIRQ` | **Vendor (RP2350)** | Pico 2 / RP2350B |
| Xh3irq CSRs | **Vendor (Hazard3)** | Pico 2 / RP2350B |
| PFIC + QingKe SysTick | **Vendor (WCH)** | CH32V307 |
| `mtimecmp` split-32 write | **Vendor/board fact** | Duo, MQ-Pro, Pico 2 (RV32), CH32 |
| `mtime` unreadable | **C906 behaviour** | Duo, MQ-Pro |
| `mxstatus`/`mhcr`, extended PTE attrs | **Vendor (T-Head)** | Duo, MQ-Pro |
| Hart base / numbering | **SoC fact** | VF2 `base=1`; others 0; Pico 2 0/1 |
| PLIC context formula | **SoC fact** | VF2 `2h−1`; others context 0 for M-mode CPU 0 |
| Boot ROM / OTP / FEL / OpenSBI / U-Boot | **Vendor or board** | different on every board; no RISC-V standard |
| Secondary-hart start | **Vendor or board** | park-slot (QEMU/VF2 via loader), ROM FIFO (Pico 2), none (single-hart) |
| WFI behavior | **Implementation-defined** | C906 does not wake (measured); port never uses `wfi` |
| Misaligned accesses | **Implementation-defined** | C906 handles; U74 traps; portable code avoids them |
| `mtval` value | **Implementation-defined** | Hazard3 hardwires 0; others may report the address |
| PSRAM and AMOs | **Board fact** | RP2350B PSRAM faults on AMOs; keep `.data.amo` in SRAM |
| UART pins, LED, clock tree, PSRAM wiring | **Board fact** | every board differs |

### 15.5 What the portable part relies on

The generic port code — `trap.S`, `trap.cpp`, `os-core.cpp`, the scheduler,
the critical sections and the 32-bit atomics — uses only layer 1 and the
board contract. It does not contain a single board address. The board header
supplies:

- `CLINT_*` (or SIO/PFIC equivalents) and `TIMEBASE_HZ`;
- `TIME_CSR`, `MTIME_READABLE`, `MTIMECMP_SPLIT32`;
- `PLIC_BASE` or `RISCV_PFIC` / `RISCV_BOARD_SOFTIRQ_SIO`;
- `BOOT_HART` / `RISCV_HART_BASE` and any PLIC context formula;
- the console, the external interrupt dispatcher, and the start-up hooks.

Everything else in layer 3 stays in the board directory. That is the
practical test for whether a feature belongs in the port or in a board: if
it mentions an address, a pin, a vendor CSR or a boot protocol, it is a
board fact.

### 15.6 Checklist for a new board

1. Is the core's `-march` exactly what the silicon implements? Check
   `misa` and the manual; do not assume `C` or `F`.
2. Does it have a `time` CSR? Make `rdtime`/`mtime` work and set
   `TIME_CSR`/`MTIME_READABLE`.
3. Is `mtimecmp` 64-bit writable? If not, set `MTIMECMP_SPLIT32`.
4. Is there a CLINT? If not, which timer and software-interrupt block
   replaces it (SIO, PFIC, other)?
5. Is there a PLIC? If not, which external controller, and how are its
   priorities/threshold/claim implemented?
6. What are the real hart ids, and which ones does the build drive?
7. How are secondary harts started, and what state do they arrive in
   (`gp`, `mtvec`, `sp`, `MIE`)?
8. What does the boot chain leave enabled (timers, PLIC, interrupts)?
9. Are AMOs safe in every memory the linker uses? If not, use
   `.data.amo`/`.bss.amo`.
10. Does the core take `wfi`, misaligned accesses and `mtval` the way the
    portable code expects? Measure; do not assume.

## 16. Final summary

- **Interrupts**: one direct `mtvec` entry, a full software frame, a
  per-hart nesting counter and a per-hart interrupt stack. `mcause` dispatch
  covers MSIP, MTIP, MEIP, the port's `ecall`, semihosting `ebreak`, and
  faults. Nesting is off by default, on where the board controller supports
  it (PLIC, Xh3irq, PFIC).
- **Tick**: a per-hart CLINT/SIO/PFIC comparator against a free-running
  counter; the handler is rewritten every tick, catches up missed periods,
  and guards against a slow handler. Only hart 0 advances the RTOS clocks;
  the others reschedule.
- **Atomics**: the A extension's AMOs (`amoswap.w.aq`, `amoor.w`) and
  acquire/release ordering, plus `fence`/`fence.i` for devices and
  instruction fetch. Atomics live in `.data.amo`/`.bss.amo`.
- **Protections**: `mstatus.MIE` (atomic `csrrci`), a per-hart scheduler
  lock, and on SMP a recursive global kernel spinlock. The PFIC uses its
  threshold as `BASEPRI`. Deferred switches at critical-section exit
  reproduce PendSV's pending behaviour.
- **Scheduler**: priority-ordered ready list, FIFO within equal priority,
  per-hart `current_thread_`, per-core idle threads and affinity, and a
  publish/claim protocol so a thread never runs on two harts.
- **Preemption**: tick-driven, switch only on the way out of the outermost
  trap (or at an explicit `ecall`), never inside a nested handler or a
  critical section.
- **RV32/RV64**: same mechanisms, different widths — register type, frame
  size and FP block, `mcause` top bit, 64-bit time composition, MMU
  availability, and semihosting details. The 32-bit atomics and the
  scheduler are identical.

---

## 17. Glossary

Every term used in this document, in plain English. Section numbers point to
the place where the term is used in context.

### A

- **ABI (Application Binary Interface)** — the rules for how compiled code
  talks to other compiled code: which registers carry arguments, how the
  stack is laid out, who must preserve which register. RISC-V's version is
  called the **psABI**. See §11.
- **ACLINT** — "Advanced CLINT": a newer family of the same timer/IPI
  hardware (machine timer, software interrupts, per-hart compares). The port
  uses the classic CLINT layout.
- **acquire / release** — two halves of a handshake. An *acquire* load or
  atomic says "nothing after me may move before me"; a *release* store says
  "nothing before me may move after me". Together they let one core publish
  data and another consume it safely. See §10.
- **affinity (CPU affinity)** — a bitmask saying which cores a thread is
  allowed to run on. Used in SMP so a thread does not hop to an unsuitable
  core. See §8.4.
- **AMO (Atomic Memory Operation)** — a single RISC-V instruction that
  reads, modifies and writes a memory location indivisibly, e.g. `amoswap`
  (swap) or `amoadd` (add). See §10.1.
- **aq / rl (acquire / release bits)** — suffix bits on RISC-V atomics:
  `.aq` gives acquire ordering, `.rl` release ordering, `.aqrl` both. They
  save a separate fence. See §10.
- **atomic** — "all or nothing": an operation no other core or interrupt can
  observe half-finished. See §10.

### B

- **BASEPRI** — the Cortex-M register that masks interrupts *below* a chosen
  priority while letting more urgent ones through. The WCH PFIC threshold
  plays that role here. See §9.2.
- **blocking call** — a kernel call that cannot finish immediately and puts
  the calling thread to sleep until it can (e.g. waiting for a semaphore).
  The scheduler switches away and runs something else. See §8.2.
- **boot ROM** — the small vendor program a chip runs first. On the RP2350 it
  also starts core 1 and switches the cores between ARM and RISC-V.
- **busy-wait (spin)** — repeatedly checking a condition instead of sleeping.
  The kernel spinlock spins; the idle loop also spins (the port never uses
  `wfi`). See §9.4.

### C

- **C906 (T-Head)** — the RV64GC core in the Milk-V Duo (CV1800B) and the
  MangoPi MQ-Pro (Allwinner D1). It has vendor CSRs for cache attributes and
  a CLINT whose `mtime` is not readable. See §15.3.1–15.3.2.
- **CV1800B** — the Sophgo SoC in the Milk-V Duo, built around one T-Head
  C906. See §15.3.1.
- **cache** — a small, fast copy of recently used memory kept inside the
  CPU. Caches are why memory ordering and `fence.i` matter.
- **cache line** — the block of memory a cache moves at once. A spinlock's
  inner loop uses a plain load to avoid hammering the line with failed
  atomic swaps.
- **claim / complete (PLIC)** — the two-step way to take an external
  interrupt: read the claim register to learn which device fired (and mark
  it in service), then write the same number back when finished. See §5.5.
- **CLINT (Core-Local Interruptor)** — the standard RISC-V block that holds
  the shared `mtime` counter, one `mtimecmp` per hart, and one `msip`
  software-interrupt word per hart. See §6.1.
- **context** — everything a thread needs in order to continue: its
  registers, stack pointer and floating-point state. In this port a saved
  context is just a saved stack pointer, because the registers are already
  on that stack.
- **context switch** — saving one thread's context and restoring another's,
  so the CPU continues in the second thread. See §7.
- **core / CPU / hart** — one independent instruction-executing unit. RISC-V
  calls it a **hart** ("hardware thread"). This document uses the three
  words interchangeably, except that "hart" also implies a RISC-V
  `mhartid`.
- **critical section** — a short region that must not be interrupted by code
  touching the same data. Implemented by masking interrupts and/or taking a
  lock. See §9.
- **CSR (Control and Status Register)** — a special register accessed with
  `csrr`/`csrw`/`csrs`/`csrc`, holding machine state such as interrupt
  enables, trap cause, and the hart id. See §4.

### D

- **D1 (Allwinner)** — the SoC in the MangoPi MQ-Pro, built around one
  T-Head C906. See §15.3.2.
- **deferred switch** — a switch that was requested while it could not
  happen (interrupts off, scheduler locked) and is performed later, at the
  moment it becomes safe. See §9.1.
- **direct mode (mtvec)** — one trap address for every cause. The alternative
  is *vectored mode*, where the CPU adds `4 × cause` to a base to pick an
  entry. The port uses direct mode.

### E

- **ebreak** — the RISC-V breakpoint instruction. Used by semihosting to
  call the debugger, and by debuggers to stop a hart.
- **ecall** — the RISC-V "environment call" instruction. Here it is the
  synchronous way a thread asks the kernel to switch threads.
- **exception** — an unusual event caused by the instruction stream itself
  (illegal instruction, bad address, `ecall`, `ebreak`), as opposed to an
  external interrupt.
- **EXC_RETURN** — the special value Cortex-M loads into `lr` to return from
  an exception. RISC-V uses `mret` instead; the term appears only in
  comparisons.

### F

- **fence** — a RISC-V ordering instruction. It does not make anything
  atomic; it says which earlier memory accesses must be visible before which
  later ones. `fence rw, rw` orders ordinary loads/stores; `fence o, i`
  orders device output before device input. See §9.6.
- **fence.i** — the instruction-fetch fence. After writing code to memory,
  each hart that will execute it needs `fence.i` so its instruction cache
  sees the new bytes. Not a data barrier.
- **FIFO (first in, first out)** — the tie-break among equal-priority
  threads: the one that has waited longest runs next. See §7.3.
- **frame (trap frame / stack frame)** — the block of saved registers and
  machine state that `trap.S` writes on the stack. Its layout is fixed in
  `port_ctx.hpp`; its size is 144, 272 or 528 bytes depending on XLEN and
  FPU. See §5.1.

### H

- **handler / handler mode** — the code that runs in response to an
  interrupt or exception, and the state of running inside one. RISC-V has no
  `IPSR` register, so the port uses a per-hart nesting counter. See §5.4.
- **hart** — see *core*. A RISC-V hardware thread, identified by `mhartid`.
- **Hazard3** — the RISC-V cores inside the RP2350 (Raspberry Pi Pico 2).
  RV32IMAC, no FPU, no `time` CSR, and a vendor interrupt controller called
  Xh3irq.

### I

- **idle thread** — the thread that runs when nothing else is ready. On SMP
  there is one per core (`idle0`, `idle1`, …), pinned to its core.
- **identity map** — a virtual-to-physical mapping where address *N* maps to
  the same address *N*. Used by `mmu-test` for Sv39.
- **interrupt** — an asynchronous signal from hardware asking the CPU to
  stop and handle an event (timer, UART, another core).
- **interrupt stack** — a separate stack used by the trap dispatcher and
  handlers, so deep interrupt code cannot overflow the current thread's
  stack. See §5.8.
- **IPI (inter-processor interrupt)** — an interrupt one core sends to
  another, here by writing the target hart's `msip` word. Used to make a core
  reschedule promptly. See §5.7.
- **IPSR** — the Cortex-M register that says which exception is active. The
  RISC-V port replaces it with `riscv_trap_nesting[]`.
- **ISA (Instruction Set Architecture)** — the definition of the
  instructions and registers a CPU understands. "RV32" and "RV64" are ISAs;
  letters such as I, M, A, F, D, C name optional extensions.
- **ISR (Interrupt Service Routine)** — a handler for one interrupt source.

### J

- **JH-7110S** — the StarFive SoC in the VisionFive 2 Lite: one S7 monitor
  core (hart 0) and four SiFive U74 application cores (harts 1–4). See
  §15.3.5.

### L

- **LR/SC (load-reserved / store-conditional)** — the RISC-V
  reserve-then-write-if-unchanged pair, `lr.w` / `sc.w` (`.d` on RV64). An
  alternative to AMOs for building locks and counters.
- **lp64d** — the RV64 psABI with 64-bit `long`/pointers and hardware double
  precision. The C906 and U74 builds use it.

### M

- **machine mode (M-mode)** — the most privileged RISC-V execution mode.
  This port runs everything there, so there is no firmware or hypervisor
  below it. See §4.
- **MangoPi MQ-Pro** — an Allwinner D1 board with one T-Head C906. See
  §15.3.2.
- **mcause** — the CSR that says why the trap happened: top bit 63 (RV64) or
  31 (RV32) means "interrupt", the low bits are the cause number.
- **mepc** — the CSR holding the program counter of the instruction that
  trapped. For `ecall`, software adds 4 to continue after it.
- **mhartid** — the CSR holding this hart's hardware id. Not guaranteed to
  start at 0 or to be dense; the port subtracts `RISCV_HART_BASE`.
- **mie / mip** — the machine interrupt-enable register (`mie`) and the
  machine interrupt-pending register (`mip`). `mie` has one bit per source;
  `mip` shows which are currently pending.
- **MIE** — the master interrupt-enable bit in `mstatus` (bit 3). This is the
  RISC-V equivalent of Cortex-M's PRIMASK, inverted: 1 means enabled.
- **misa** — the CSR that reports which ISA extensions the hart implements.
- **MMIO (memory-mapped I/O)** — device registers accessed by ordinary loads
  and stores at fixed addresses. `mtime`, `mtimecmp`, PLIC and UART are all
  MMIO here.
- **MMU (Memory Management Unit)** — hardware that translates virtual
  addresses to physical ones using page tables. M-mode accesses are not
  translated by `satp`; the port only uses the MMU in `mmu-test`. See §11.
- **MPIE** — the `mstatus` bit where the hardware saves the old `MIE` on trap
  entry; `mret` copies it back.
- **MPP** — the `mstatus` field recording the privilege mode to return to.
  New thread frames set it to M-mode.
- **MPRV** — a `mstatus` bit that makes M-mode loads/stores use the
  translation and protection of the mode in MPP. `mmu-test` uses it to prove
  Sv39 tables from M-mode.
- **mret** — "machine return from trap": restores `MIE` from `MPIE` and jumps
  to `mepc`.
- **MSIE / MTIE / MEIE** — the `mie` enable bits for machine software,
  timer and external interrupts.
- **MSIP / MTIP / MEIP** — the corresponding pending bits in `mip`, and the
  names of the three interrupt causes (3, 7, 11).
- **mstatus** — the main machine status CSR: interrupt enable, previous
  enable, previous privilege, floating-point state, and more.
- **mtval** — the CSR that may hold a faulting address or instruction bits.
  Some cores hardwire it to 0 (Hazard3).
- **mtvec** — the CSR holding the trap entry address (and mode).
- **mtime** — the shared free-running timer counter, typically 64-bit, often
  at 10 MHz or a board-specific rate.
- **mtimecmp** — the per-hart compare register: when `mtime` reaches it, that
  hart gets a timer interrupt. Software must rewrite it every tick.
- **medany** — a code model that addresses globals with 32-bit
  PC-relative offsets, usable anywhere in the address space (unlike
  `medlow`, which assumes the low 2 GiB). Used because images sit at
  0x40200000, 0x80050000, etc.
- **Milk-V Duo** — a Sophgo CV1800B board with one T-Head C906. See
  §15.3.1.
- **mutex** — a "mutual exclusion" lock owned by a thread. The kernel adds
  priority inheritance / priority ceiling to avoid priority inversion.

### N

- **nesting (interrupt nesting)** — allowing a more urgent interrupt to
  preempt a handler that is already running. Standard RISC-V masks
  interrupts on entry; boards that support nesting re-enable `MIE` in the
  dispatcher. The port counts the depth per hart. See §5.4.
- **NVIC** — ARM Cortex-M's interrupt controller. RISC-V has no standard
  equivalent; the port emulates a few `NVIC_*` calls with software IRQ lines
  so CMSIS-style code still works. See §5.6.

### O

- **OpenSBI / SBI** — a standard firmware interface that runs in M-mode and
  offers services to an S-mode OS. This port does **not** use it: the RTOS
  itself is the M-mode code.

### P

- **page table** — the in-memory tree the MMU walks to translate addresses.
  Sv39 uses three levels of 512 entries.
- **PendSV** — the Cortex-M exception used for context switches: lowest
  priority, software-triggered, runs when nothing else is active. RISC-V has
  no PendSV; the port uses `ecall` and trap-exit switching instead.
- **PFIC (Programmable Fast Interrupt Controller)** — WCH's interrupt
  controller on the QingKe cores. It provides priorities, hardware nesting,
  a threshold (BASEPRI-like), and a SysTick. See §5.5.
- **Pico 2** — the Raspberry Pi RP2350 board with two Hazard3 cores. See
  §15.3.3.
- **PLIC (Platform-Level Interrupt Controller)** — the standard RISC-V
  external interrupt controller: per-source priorities, per-context
  enable/threshold, claim/complete.
- **PMP (Physical Memory Protection)** — RISC-V's optional per-hart memory
  permission registers. The port does not program them, so there is no
  memory protection.
- **posted write** — a store that the CPU considers finished before the
  device has actually seen it. A later read from the same device (or a
  fence) can be used to wait for it. MSIP writes are posted on the C906.
- **preemption** — the scheduler taking the CPU away from a running thread
  because a more urgent one is ready. See §8.
- **priority** — a number saying how urgent a thread or interrupt is. For
  threads, larger numbers are more urgent in µOS++; for the PFIC, smaller
  numbers are more urgent (as on Cortex-M).
- **priority inheritance** — temporarily raising a lock owner's priority to
  that of the highest waiter, so a medium-priority thread cannot delay it
  indefinitely. Implemented by the kernel's mutex.
- **priority inversion** — the problem priority inheritance solves: a
  high-priority thread waits for a low-priority owner that a medium-priority
  thread keeps preempting.
- **PRIMASK** — the Cortex-M register that disables all interrupts except
  NMI and HardFault. `mstatus.MIE` is the RISC-V counterpart.
- **psABI** — the RISC-V procedure-call standard: register roles, stack
  alignment, argument passing, etc.
- **PSRAM** — external pseudo-static RAM, often behind a serial (QSPI)
  interface. On the RP2350B, AMOs to PSRAM fault, so atomic objects stay in
  SRAM. See §10.4.
- **PTE (page-table entry)** — one entry in a page table: physical page
  number plus valid/read/write/execute/user bits.
- **publish / claim** — the SMP protocol that prevents two harts running the
  same thread: the outgoing stack pointer is *published* when the thread is
  switched out, and the incoming thread is *claimed* by clearing its pointer.
  See §8.4.

### Q

- **QEMU `virt`** — QEMU's generic RISC-V machine, used as the emulated
  stand-in for boards whose silicon QEMU does not model. It has a standard
  CLINT/PLIC layout and no vendor quirks. See §15.3.7.

### R

- **rdtime** — the pseudo-instruction that reads the `time` CSR (the same
  counter as `mtime`). On RV32 it is assembled from `rdtimeh`/`rdtime` with
  a retry loop.
- **ready list** — the list of threads that could run now, ordered by
  priority. See §7.3.
- **recursive lock** — a lock its owner may take again; a depth counter says
  how many times. The SMP kernel lock is recursive.
- **release slot** — the `{magic, entry, sp}` word in memory that a parked
  secondary hart spins on until CPU 0 releases it. See §7.5.
- **relaxed (memory order)** — the weakest ordering: the operation is atomic
  but no ordering with other accesses is implied. Used for the spinlock's
  inner test load.
- **round-robin** — giving equal-priority threads turns in order. In this
  kernel it falls out of linking equal-priority threads at the tail of the
  ready list.
- **RP2350 / RP2350B** — Raspberry Pi's dual-core microcontroller with two
  Hazard3 RISC-V cores (or two Cortex-M33 cores, selected at boot). The
  RP2350B is the larger package used on the WeAct board. See §15.3.3–15.3.4.
- **RTOS (Real-Time Operating System)** — an operating system built to meet
  timing deadlines, not to be fair to interactive users. See §2.1.
- **RV32 / RV64** — the 32-bit and 64-bit RISC-V ISAs. The register width is
  called XLEN. See §11.

### S

- **satp** — the CSR that holds the root page-table address and the
  translation mode (e.g. Sv39). M-mode accesses ignore it.
- **scheduler** — the kernel part that chooses which ready thread runs next,
  and performs context switches. See §7.
- **scheduler lock** — a lock that stops thread switches (but not
  interrupts) while kernel data is being changed. See §9.3.
- **secondary hart** — any hart other than the one that boots first. It
  waits to be released, then runs the same scheduler on its own idle thread.
- **semaphore** — a counter used to signal between threads/ISRs. Waiting
  blocks when the count is zero; posting wakes a waiter.
- **semihosting** — using the debugger as an I/O device: the program executes
  a special breakpoint sequence, the debugger performs the write or exit.
  Used for test verdicts. See §5.3.
- **seq_cst (sequentially consistent)** — the strongest C/C++ memory order:
  all such operations appear in one global order. Used for the software IRQ
  bitmaps.
- **SGI (Software Generated Interrupt)** — ARM GIC's inter-processor
  interrupt. The RISC-V equivalent is an MSIP write.
- **SIO (Single-cycle I/O)** — the RP2350's per-chip block for inter-core
  FIFOs, doorbells, spinlocks and the platform timer. Its
  `RISCV_SOFTIRQ` register is the Hazard3 MSIP.
- **SMP (Symmetric Multiprocessing)** — several identical cores running one
  kernel over shared memory. See §2.8 and §8.4.
- **spinlock** — a lock a core repeatedly tries to acquire, spinning until
  it succeeds. Used for kernel data shared between harts.
- **SRAM** — on-chip static RAM, fast and AMO-capable on the boards here.
- **stack** — the memory region where a thread's local variables, return
  addresses and trap frame live. It grows downward; the stack pointer
  (`sp`) points at the current top.
- **stack pointer (sp)** — register `x2`, the address of the current stack
  top. A saved context is essentially a saved `sp`.
- **Sv39** — the RV64 virtual-memory scheme with 39-bit virtual addresses
  and three page-table levels. RV32 would use Sv32; this port has no RV32
  MMU code.
- **SysTick** — the Cortex-M system timer. The RISC-V equivalent is the
  machine timer (CLINT `mtime`/`mtimecmp`). See §6.

### T

- **tail-chaining** — Cortex-M's ability to go straight from one handler to
  the next without restoring and re-saving state. The RISC-V port gets a
  similar effect by switching threads on trap exit.
- **thread (task)** — an independent sequence of instructions with its own
  stack and saved context. The scheduler runs one per core at a time.
- **threshold (interrupt)** — a priority level below which interrupts are
  held pending. Used by the PLIC and, as BASEPRI's analogue, by the PFIC.
- **tick** — the periodic timer interrupt that drives the RTOS clock. See
  §6.
- **time CSR** — the optional read-only counter defined with `rdtime`. Some
  harts implement it (C906), some do not (Hazard3, U74), and some read zero
  (QingKe). It is not the same as an MMIO `mtime` register.
- **timebase** — the frequency of the free-running timer, in Hz. One tick
  period is `timebase / tick_frequency` counter steps.
- **timeout** — a deadline attached to a sleeping or waiting thread; the
  tick checks it and wakes the thread when it expires.
- **timer callback** — a function the kernel calls when a software timer
  expires. Runs in interrupt context, so it must be short.
- **trap** — the generic RISC-V word for an interrupt or exception: the CPU
  stops the current flow and enters the trap handler.
- **trap frame** — see *frame*.
- **trap vector** — the address the CPU jumps to on a trap, held in `mtvec`.

### U

- **U74** — SiFive's RV64GC application core used in the JH-7110S
  (VisionFive 2 Lite). Four of them run µOS++ as CPUs 0–3 (hart ids 1–4).
- **uncritical section** — the kernel's inverse of a critical section: it
  temporarily *enables* interrupts (or unlocks) so a switch can happen, then
  restores the previous state.

### V

- **vectored mode** — an `mtvec` mode where the CPU computes a different
  entry per interrupt cause. The port uses direct mode.
- **VisionFive 2 Lite** — the StarFive JH-7110S board with four U74
  application cores. See §15.3.5.
- **volatile** — a C/C++ qualifier telling the compiler that a variable can
  change outside the program's control (a device register, another core), so
  it must not cache it in a register or optimise accesses away. It is not a
  substitute for atomics or fences.

### W

- **WFI (wait for interrupt)** — the RISC-V instruction that idles a hart
  until an interrupt arrives. This port does **not** use it: the C906 was
  measured not taking a pending timer interrupt while in `wfi`, so idle
  spins instead.
- **WCH QingKe** — the Chinese RISC-V core family in the CH32V307. It has no
  CLINT; its PFIC supplies SysTick, software interrupts and priorities.
- **WeAct RP2350B** — a Raspberry Pi RP2350B board with 16 MB flash and
  8 MB QSPI PSRAM. It shares the Pico 2's cores and port code but needs its
  own memory layout and keeps atomic objects out of PSRAM. See §15.3.4.

### X

- **XLEN** — the width of a general-purpose register and of an address: 32
  on RV32, 64 on RV64. Selected at compile time by `__riscv_xlen`.
- **Xh3irq** — the Hazard3 vendor interrupt controller: per-core enable,
  pending, force and priority CSRs, plus `meinext` to find the highest
  priority pending IRQ.

### Y

- **yield** — voluntarily giving up the CPU so another thread can run. In
  this port it is an `ecall` with the port's marker in `a7`.

### Z

- **Zaamo / Zalrsc** — the 2023 split of the A extension into "AMOs only"
  and "LR/SC only". A build's `-march` must include what the code uses; all
  boards here include `A`.
- **zero-latency interrupt** — on the WCH PFIC, an interrupt in the priority
  `0x00` group that is never masked, even inside a kernel critical section.
  Such an interrupt must not call the kernel. See §9.2.
- **Zicsr / Zifencei** — the extensions that guarantee the CSR instructions
  (`csrr`, `csrw`, …) and `fence.i`. Modern toolchains require them to be
  named explicitly in `-march`.

### Abbreviations used in the tables

| Short | Expansion |
|---|---|
| ABI | Application Binary Interface |
| ACLINT | Advanced Core-Local Interruptor |
| AMO | Atomic Memory Operation |
| CLINT | Core-Local Interruptor |
| CSR | Control and Status Register |
| FIFO | First In, First Out |
| IPI | Inter-Processor Interrupt |
| ISA | Instruction Set Architecture |
| ISR | Interrupt Service Routine |
| LR/SC | Load-Reserved / Store-Conditional |
| MMIO | Memory-Mapped I/O |
| MMU | Memory Management Unit |
| NVIC | Nested Vectored Interrupt Controller (ARM) |
| PFIC | Programmable Fast Interrupt Controller (WCH) |
| PLIC | Platform-Level Interrupt Controller |
| PMP | Physical Memory Protection |
| psABI | Processor-Specific Application Binary Interface |
| PTE | Page-Table Entry |
| RTOS | Real-Time Operating System |
| SIO | Single-cycle I/O (RP2350) |
| SMP | Symmetric Multiprocessing |
| SRAM | Static Random-Access Memory |
| WFI | Wait For Interrupt |
| XLEN | Register width (32 or 64) |
