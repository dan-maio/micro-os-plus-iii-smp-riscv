# micro-os-plus-iii-riscv

The **RISC-V port of µOS++ III**: RV64 or RV32, with or without an FPU,
machine mode, one hart or SMP (`OS_NCPU` harts). The fourth
architecture project beside `micro-os-plus-iii-cortexm`, `-aarch32` and
`-aarch64`, built and tested the same way.

First board: **Milk-V Duo (64 MB)** -- Sophgo CV1800B, T-Head C906 @ 850 MHz,
64 MiB DDR2 (RV64GC). Second board: **Raspberry Pi Pico 2** (RP2350) on its
two Hazard3 cores (RV32IMAC, no FPU), µOS++ SMP on both -- see *RV32 and the
Pico 2*, *SMP* and *Pico 2 hardware* below. Third board: **WeAct RP2350B**
(16 MB flash, 8 MB QSPI PSRAM) -- the Pico 2's sources with the data in the
PSRAM, the clock table and the 250 MHz overclock; see *WeAct RP2350B*.
Fourth board: **StarFive VisionFive 2 Lite** (JH-7110S, four SiFive U74
RV64GC harts + one S7 monitor hart), µOS++ SMP on the four U74 in M-mode
(mhartid 1..4 = CPUs 0..3), every test loaded into and run from DDR -- see
*StarFive VisionFive 2 Lite*. Fifth board: **WCH CH32V307V-EVT-R1**
(CH32V307, one QingKe V4F core, RV32IMAFC, single-precision FPU): no CLINT,
so the port runs its **PFIC path** there -- the PFIC software interrupt as
PendSV, SysTick as the tick, the PFIC threshold as BASEPRI, nested
interrupts; see *WCH CH32V307V-EVT-R1*.

## Layout

```text
micro-os-plu-iii-smp-riscv-pr-github/       the workspace
├── micro-os-plus-iii/                      the kernel (sibling clone)
└── micro-os-plus-iii-riscv/                this port
    ├── CMakeLists.txt                      micro-os-plus::riscv, ::riscv-bare,
    │                                       ::riscv-qemu-virt, ::riscv-qemu-virt32
    ├── cmake/toolchains/riscv-none-elf.cmake
    ├── include/                            the port contract + ISA headers
    │   ├── cmsis-plus/rtos/port/           os-c-decls.h, os-decls.h, os-inlines.h
    │   ├── port_ctx.hpp                    the trap frame (528 bytes)
    │   ├── riscv-csr.hpp, clint.hpp, mmu.hpp, semihosting.hpp
    │   ├── pfic.hpp                        the QingKe PFIC (RISCV_PFIC boards)
    │   └── cmsis_device.h, riscv-eabi-compat.h
    ├── src/
    │   ├── startup.S, startup.cpp          reset entry, start-up hooks, init arrays
    │   ├── trap.S, trap.cpp                the single trap entry and dispatcher
    │   ├── rtos/os-core.cpp                the scheduler's port half
    │   ├── soft-irq.cpp                    software IRQ lines (the "NVIC")
    │   ├── mmu.cpp                         Sv39 identity map
    │   ├── trace.cpp, syscalls.c, syscalls-time.cpp, semihosting-exit.cpp
    ├── qemu/virt/                          the QEMU `virt` stand-in board
    ├── scripts/make-pdf.sh                 Markdown -> PDF (pandoc + weasyprint)
    └── test/
        ├── CMakeLists.txt                  the shared test builder (as cortexm/aarch*)
        ├── qemu.sh, hw.sh, hw-all.sh       dispatchers -> boards/<board>/
        ├── boards/milkv-duo/               board.cmake, linker.ld, openocd.cfg,
        │                                   qemu.sh, hw.sh, hw-all.sh,
        │                                   hw-reset.sh + reset.cfg,
        │                                   wait-power-cycle.sh, include/, src/, usb/
        ├── boards/pico2/                   the RP2350 sources (both RP2350 boards)
        ├── boards/pico2-rp2350b-psram/     board.cmake (includes pico2's),
        │                                   linker.ld (16 MB), linker-psram.ld,
        │                                   hw.sh, qemu.sh
        ├── boards/visionfive2-lite/        board.cmake, linker.ld (DDR),
        │                                   jh7110_daplink.cfg, hw.sh,
        │                                   include/ (multicore.hpp), src/
        ├── boards/ch32v307-evt/            board.cmake, linker.ld (flash), hw.sh,
        │                                   openocd-wch/ (build script, patches),
        │                                   include/ (ch32v307.hpp), src/
        ├── milkv-duo/, pico2/,             one directory per test application
        ├── pico2-rp2350b-psram/
        ├── visionfive2-lite/
        └── ch32v307-evt/
```

## The port

RISC-V has no PendSV, and the port does not imitate one. The context switch
is built on what the RISC-V privileged spec guarantees:

| situation | Cortex-M (upstream) | this port |
|---|---|---|
| a thread blocks / yields | set PendSV pending | **`ecall`** (a7 = `RISCV_PORT_YIELD_ECALL`): a precise, synchronous exception, taken AT the instruction; `trap.cpp` calls `switch_stacks()` and `mret`s on the incoming thread's frame |
| an interrupt makes a thread due (tick, post from an ISR) | ISR sets PendSV, tail-chained | `is_reschedule_pending` only; the switch is made **on the way out of the outermost trap** |
| switch asked for inside a critical section | PendSV waits for PRIMASK | deferred; `critical_section::exit()` yields when it sets `mstatus.MIE` again |
| scheduler locked | nothing until unlock | same; unlocking yields if a switch is pending |
| SysTick | SysTick | machine timer (CLINT `mtimecmp` against `rdtime`) |
| missed ticks | dropped (one pending SysTick) | **caught up**: each tick trap counts the whole periods `rdtime` has passed; N owed ticks = N-1 bare `sysclock`/`hrclock` increments + one `os_systick_handler()`, so timeouts and timers are checked once against the advanced clock (no burst of a periodic timer). The comparator is never set closer than one period from now (`riscv_port_tick_guard`). The kernel's simulated RTC still loses halted time |
| PRIMASK | PRIMASK | `mstatus.MIE` (`csrrci`/`csrrsi`, atomic) |
| exception frame + r4-r11 | | full frame by `trap.S`: x1..x31, mepc, mstatus, fcsr, f0..f31 (528 bytes) |
| IPSR != 0 | | `riscv_trap_nesting != 0` |
| NVIC (validator's IRQ 0) | | software IRQ lines multiplexed on CLINT MSIP (`soft-irq.cpp`) |

**Why not MSIP as "PendSV"** (the first version did that): a CLINT MSIP
write is a posted store. QEMU takes the interrupt on the next instruction;
the C906 takes it some cycles later. The kernel marks a thread suspended,
calls `reschedule()` and, once that returns, removes the thread's wake-up
node. On the Duo the thread ran past `reschedule()` before the switch, removed
its own wake-up, and was then switched out for ever. Measured with GDB on the
board: every thread `suspended`, `clock_node_ = 0`, in no list; `smp_test0`
stopped after its first `sleep_for`. With `ecall` there is no such window.
For the same reason `NVIC_SetPendingIRQ()` from a thread (interrupts
enabled) waits until the line's handler has run, as it has on Cortex-M.

The port's `ecall` marker in `a7` is consumed by the trap handler (`a7`
comes back 0), so an application's own `ecall` (`exc-test`) is never taken
for a yield. Idle never executes `wfi` (`wait_for_interrupt()` is empty).

The tick is re-armed on a fixed grid of `rdtime` deadlines, before the
handler. **After** the handler, `riscv_port_tick_guard()` checks the
deadline again: if the handler itself ran past it (a slow timer callback),
the next tick is set one full period from now, so threads always get at least
one period between ticks. Measured on the Duo without it: `rtos-apis`'
1-tick periodic timer, whose callback `printf`s, kept the hart inside the
tick trap for ever (the next tick was pending before `mret`), and `main`
never ran again.

On the board the console is copied to semihosting **from threads only**. A
semihosting call halts the hart for a JTAG round trip (tens of ms), so output
written inside a trap (a timer callback's `printf`) goes to the UART only.
Verdict lines and exits are written from threads.

**MMU attributes (C906).** BL2 sets `mxstatus = 0xc0638000`, which includes
MAEE (bit 21): the C906 then reads PTE bits 63..59 as memory attributes
(SO, C, B, SH, Sec). With them at 0 a RAM page is non-cacheable: accesses
through the MMU bypass the D-cache that untranslated M-mode accesses use
(measured: `mmu-test` failed on the Duo, passed on QEMU). The board supplies
the values the SDK's Linux uses (`arch/riscv/include/asm/pgtable*.h`):
RAM = `C|B|SH`, devices = `SO|SH` (`riscv_board::FLAGS_RAM/_DEV`). The QEMU
board keeps 0: on a standard Sv39 hart those bits are reserved.

Semihosting is the `slli/ebreak/srai` sequence; without a debugger the trap
handler skips it (a0 = -1) instead of faulting. The kernel's "embedded" code
paths are selected with `__ARM_EABI__`, as on AArch64 (see
`include/riscv-eabi-compat.h`).

The Sv39 tables are real: the kernel runs in M-mode, where satp does not
translate its own accesses, so `mmu-test` proves them through MPRV (M-mode
loads/stores translated as S-mode), including a non-identity alias.

## RV32 and the Pico 2

**XLEN- and FPU-generic.** Nothing in the port assumes RV64 or an FPU:

| | RV64GC (C906) | RV32IMAC, no FPU (Hazard3) |
|---|---|---|
| CSR values | `riscv::reg_t` = 64 bit | 32 bit |
| trap frame (`port_ctx.hpp`) | x1..x31, mepc, mstatus, fcsr, f0..f31: **528 bytes** | x1..x31, mepc, mstatus: **144 bytes** |
| `trap.S`, `startup.S` | `REG_S/REG_L` = `sd/ld`; FP block saved | `sw/lw`; no FP block (`__riscv_flen` undefined) |
| `mcause` interrupt bit | bit 63 | bit 31 (`MCAUSE_INTERRUPT` = top bit of XLEN) |
| 64-bit `time`/`cycle` | one CSR read | `rdtimeh`/`rdtime`/`rdtimeh`, repeated on a carry |
| semihosting `SYS_EXIT` | block `{reason, status}` | reason in a1: status 0 -> `ApplicationExit` (exit 0), else `RunTimeErrorUnknown` (exit 1) |
| MMU | Sv39 (`mmu.cpp`) | none; `mmu-test` reports `RESULT: SKIP` |

**RV32 stand-in.** `micro-os-plus::riscv-qemu-virt32` is the `virt` machine
compiled exactly as the pico-sdk compiles for Hazard3
(`-march=rv32ima_zicsr_zifencei_zba_zbb_zbs_zbkb_zca_zcb_zcmp -mabi=ilp32`).
`qemu.sh` picks the emulator from the image's ELF class; an RV32 image runs on
`qemu-system-riscv32 -cpu rv32,f=false,d=false,zfa=false,zba=true,zbb=true,zbs=true,zbkb=true,zcb=true,zcmp=true`
(QEMU's default rv32 model enables Zfa, which needs F). Any board's emulated
tests can be built for it:

```bash
cmake -S . -B test/build-rv32 -G Ninja -D CMAKE_TOOLCHAIN_FILE=cmake/toolchains/riscv-none-elf.cmake \
      -D BOARD=milkv-duo -D UOS_QEMU_STANDIN=micro-os-plus::riscv-qemu-virt32
cmake --build test/build-rv32 && (cd test/build-rv32 && ctest -LE hwd)
```

A `RESULT: SKIP` with exit 0 is a skip, not a failure (`qemu.sh` returns 77,
CTest's `SKIP_RETURN_CODE`).

**Pico 2 bring-up facts (measured 2026-11-05, Raspberry Pi Debug Probe, SWD):**

| | |
|---|---|
| architecture switch | `OTP.ARCHSEL` (`0x40120158`), sampled per core at warm reset; the boot ROM switches both cores to Hazard3 by itself when the flash image's IMAGE_DEF block says RISC-V (datasheet §3.9). Read back after flashing a RISC-V image: `ARCHSEL = ARCHSEL_STATUS = 3` |
| OpenOCD | **the Raspberry Pi build** (`~/.pico-sdk/openocd/0.12.0+dev`, `target/rp2350-riscv.cfg`). xPack OpenOCD 0.12.0-7.1 cannot: its `riscv` target rejects `-dap` (RISC-V debug over the Arm DAP) |
| cores | both examined: XLEN=32, `misa=0x40901105`; core 1 waits in the boot ROM (pc `0x76de`) until launched |
| semihosting | works; `SYS_EXIT` (32-bit form) ends OpenOCD with exit status 0, as on the Duo |
| probe | Debugprobe firmware 2.0.1: OpenOCD warns it is old and uses a slower workaround |
| time | Hazard3 does **not** implement the `time`/`timeh` CSRs (datasheet, RVCSR `MCOUNTEREN.TM`): the clock is the SIO platform timer `MTIME`/`MTIMEH` (`0xd00001b0`), one counter shared by both cores; `MTIMECMP`/`MTIMECMPH` (`0xd00001b8`) are per core at the same address |
| soft IRQ | SIO `RISCV_SOFTIRQ` (`0xd00001a0`): bit h sets core h's MSIP, bit 8+h clears it (not a CLINT word per hart) |

## SMP (OS_NCPU > 1)

The kernel's SMP contract (`OS_USE_SMP_SCHEDULER`, defined by `uos_add_app`
when NCPU > 1) and how the RISC-V port meets it -- the same model as the
RP2350 Cortex-M port, on RISC-V mechanisms:

| | RP2350 Cortex-M port | RISC-V port |
|---|---|---|
| CPU id (`port_cpu_id()`) | `SIO_CPUID` | `mhartid` (`riscv::this_hart()`) |
| kernel lock | recursive spinlock on SIO hardware spinlock 0 | recursive spinlock on an AMO (`amoswap.w.aq` / store-release), owner + depth; the lock word lives where AMOs work (`include/riscv-amo.hpp`, see *WeAct RP2350B*) |
| critical section | PRIMASK + kernel lock | `mstatus.MIE` + kernel lock |
| scheduler lock | per core, holds the kernel lock with IRQs masked | the same, per hart |
| switch | PendSV per core | `ecall` per hart (as single-hart) |
| frame publish | `stack_ptr` published at once, incoming claimed (`nullptr`) | the same: trap.S saves the frame on the thread's stack, the dispatcher runs on the hart's own interrupt stack |
| IPI (`port_smp_ipi()`, `OS_SMP_IPI_SGI`) | SIO FIFO IRQ | the target hart's machine software interrupt (mcause 3) |
| tick | per-core SysTick; core 0 advances the clock | per-hart `mtimecmp`; hart 0 calls `os_systick_handler()`, the others only reschedule |
| secondary start | boot-ROM FIFO handshake | QEMU virt: every hart enters `_start`, harts > 0 wait in `riscv_secondary_park` for their slot `{magic, entry, sp}`; RP2350: the boot ROM FIFO (board) |
| per-core data | `lock_state[]`, core-1 MSP stack | `lock_state[]`, `riscv_trap_nesting[]`, `riscv_port_pending[]`, `riscv_port_yield_deferred[]`, `riscv_irq_stack_top[]` |

"Inside a trap" is read safely on SMP: a trap always runs with MIE clear, so
with MIE set it is thread code, and with MIE clear the thread cannot move to
another hart while it reads its hart's nesting count.

Tests launch the second hart the way the Cortex-M Pico 2 tests do, with the
same names (`include/riscv-smp.hpp`): register `idle1` in
`os_idle_thread_core[1]`, then
`multicore::launch_core1 (port_smp_secondary_start, port_core1_stack_top ())`.

`riscv_sw_log[256]` records the first 256 switches (hart, outgoing and
incoming thread, outgoing state), for a debugger.

A board without a hardware linker script builds only `qemu` images
(`UOS_BOARD_LINKER_HW ""`); `board_test_qemu_ncpu()` lets an SMP board's QEMU
images keep their hart count; `qemu.sh` starts as many harts as the image was
built for (`riscv_secondary_boot`'s size), one for a single-hart image.

## Pico 2 hardware (test/boards/pico2)

| | |
|---|---|
| image | runs from flash (XIP, `linker.ld`); `src/image-def.S` puts the RISC-V IMAGE_DEF block (EXE / RISC-V / RP2350, entry `_start`, sp) first, inside the 4 KiB the boot ROM scans; on an Arm boot the ROM switches both cores to Hazard3. `startup.S` now copies `.data` from `__data_load` (`LOADADDR(.data)`; equal to `__data_start` on RAM images) |
| clocks | `src/clocks.cpp` (the Cortex-M pico2 sequence and API): XOSC 12 MHz -> PLL_SYS -> clk_sys = clk_peri, 150 MHz by default; `PICO2_SYS_CLK_KHZ` = 48000 / 100000 / 120000 / 150000 / 200000 / 250000 (200 and 250 MHz raise the core voltage first, POWMAN VREG 1.20 / 1.25 V); `PICO2_CLOCK_FROM_SCRATCH`: a row of `clocks::SYS_TABLE` (48..200 MHz, + 250 MHz with `PICO2_ENABLE_250MHZ`) from the watchdog scratch, 48 MHz on a cold boot, `clocks::reboot_to_index()` reboots into another row. The QSPI dividers are set before the clock changes and **only raised** (flash SCK <= 50 MHz, PSRAM SCK <= 109 MHz): measured, lowering the flash divider to 1 on the boot clock made the next fetch garbage (mcause 2 inside `clocks::init()`). TICKS from clk_ref: watchdog, TIMER0 and the RISC-V timer at 1 us, whatever clk_sys is. `clocks::adc_clk_init()` (clk_adc from PLL_USB), `src/adc.cpp` |
| time | SIO `MTIME` (`MTIME_CTRL` EN, FULLSPEED off): **1 MHz** (`TIMEBASE_HZ`); `TIME_CSR = false` (Hazard3 has no `time` CSR) |
| comparator / IPI | SIO `MTIMECMP` per core at one address (stride 0); `RISCV_SOFTIRQ` set/clear bits (`RISCV_BOARD_SOFTIRQ_SIO` in `clint.hpp`) |
| console | UART0 PL011, GPIO0 TX / GPIO1 RX (the Debug Probe's UART; `PICO2_UART_TX_PIN` / `_RX_PIN`), 115200, the divider from the running clock (`clocks::current_khz()`); shared by both harts under SIO spinlock 1 with MIE masked; `uart::get_char()` non-blocking |
| LED | GPIO25 (`PICO2_LED_PIN`) |
| libraries | the toolchain has no multilib for the Hazard3 `-march`, and alone picks `rv32ia` -- **no M**: libgcc's software float multiplied through a shift-and-add `__mulsi3`, four calls per float multiply. `board.cmake` links `-march=rv32imc_zicsr_zifencei` (`UOS_BOARD_LINK_FLAGS`, link only; same ilp32 ABI). Measured on the RP2350B, smp-mat-test N=300: parallel 49.99 s -> **14.44 s**, classical 57.96 s -> **23.95 s**, 2-core ratio 1.16x -> **1.66x**. Hazard3 has no FPU: float stays in software |
| core 1 | `src/multicore.cpp`: the boot ROM FIFO handshake `{0, 0, 1, mtvec, sp, entry}` (pico-sdk `multicore_launch_core1_raw`, `h3.unblock` for SEV) into `src/secondary.S` (loads gp and mtvec -- the ROM does not set gp), then the caller's entry. **No PSM reset of core 1**: measured, forcing it off/on under the debugger gives `[rp2350.rv1] Hart unexpectedly reset!` and no handshake; after a chip reset it already waits in the ROM (as the pico-sdk assumes) |
| interrupts | Hazard3 Xh3irq as the NVIC (`src/irq.cpp`, `include/rp2350-irq.h`, generated from the pico-sdk's `intctrl.h`): `NVIC_Enable/DisableIRQ` = `meiea` (per core) + `mie.MEIE`, `NVIC_Set/ClearPendingIRQ` = `meifa` (forced pending; a `meinext` read that returns the IRQ clears it), `NVIC_SetPriority(n, p)` = `meipra` 15 - p; the trap's external interrupt loops on `meinext` and calls `<NAME>_Handler` (the Cortex-M vector names, weak; an unhandled IRQ is disabled). The port's soft-IRQ `NVIC_*` are weak and stay the Duo's |
| nested interrupts | the pico-sdk's dispatcher: save `meicontext` with CLEARTS, then per `meinext` (with UPDATE, which raises the preemption threshold to that IRQ's priority) set `mstatus.MIE`, call the handler, clear MIE; restore `meicontext`. A higher-priority IRQ preempts a running handler. The port reads "inside a trap" with MIE briefly cleared on SMP (`riscv::in_trap()`), and `reschedule()` restores MIE in a handler. `smp-test-nested` proves it: TIMER0 alarm 2 (priority 8) preempts the UART0 handler (12), counted per core |
| console to semihosting | **verdict lines only** (a write containing `RESULT:`); the rest is UART only. Measured: with every line copied, OpenOCD + the Debug Probe (fw 2.0.1) stopped servicing semihosting in long runs (validator: core 0 halted on a valid `SYS_WRITE0` after 43; smp-mat-test lost the debug module after ~114). The trap report also goes to semihosting (mcause, mepc, mtval, ra) |
| `mtval` | Hazard3 hardwires it to 0 (datasheet): code that needs a fault address decodes the instruction (the validator's DWT emulation does) |
| harness | kernel platform `riscv-pico2` (`xpm run ... --config riscv-pico2-cmake-gcc-{debug,release}`); `test/pico2/include/cmsis-plus/os-app-config.h` caps rtos-apis's RTOS arena at 96 KiB on hardware and leaves FatFs out (the free store is 468992 bytes; 512 KiB threw bad_alloc), as the Cortex-M Pico 2 board does |
| `hw.sh` | Raspberry Pi OpenOCD (`~/.pico-sdk/openocd/*`, also looked up on the mounted home), probe pinned by VID:PID **2e8a:000c** (with the Duo's Sipeed probe also plugged in, OpenOCD took that one first) and, when the VisionFive 2's "JTAG probe on Pico" (same VID:PID) is also plugged in, by the Debug Probe's serial number; `init; reset init; program <elf> verify; reset init; arm semihosting enable` (both harts)`; resume`; verdict = RESULT line + OpenOCD's exit status (SYS_EXIT) |

## WeAct RP2350B (test/boards/pico2-rp2350b-psram)

The RP2350B (48 GPIOs) with 16 MB flash and an 8 MB APS6404 QSPI PSRAM. Its
`board.cmake` includes the Pico 2's (so `src/` and `include/` are shared) and
sets its own linker scripts, pins and greeting.

| | |
|---|---|
| probe | its own CMSIS-DAP, **c251:f001**, 1000 kHz -- nothing is shared with the Pico 2's Debug Probe (2e8a:000c) or the Duo's Sipeed (d6e7:3507); `hw.sh` pins it by VID:PID and disables the GDB/telnet/TCL ports, so it runs beside the Pico 2's session |
| flash | `set FLASHSIZE 0x1000000` (the default 4 MB silently truncates); `linker.ld` is the Pico 2's with 16 MB |
| console, LED | UART0 on **GPIO12 TX / GPIO13 RX**, LED GPIO25 (`PICO2_UART_TX_PIN=12`, ...) |
| Arm view | if `rp2350-riscv.cfg` cannot examine the harts, `hw.sh` first programs the image through `target/rp2350.cfg`; the boot ROM then switches both cores to Hazard3. Measured: this also brings the board back after a clock test left the harts unreachable (`Examination failed`), with no power cycle |
| PSRAM | `src/psram.cpp` (`PICO2_PSRAM`, CS = GPIO0 = `PICO2_PSRAM_CS_PIN`): the Cortex-M driver -- QMI direct mode, RSTEN/RST, quad enable, M1 read 0xEB / write 0x38 formats and timing, window 1 writable. `init()`/`read_id()` are in `.psram_ram`, run from SRAM (in direct mode the QMI cannot serve flash XIP), with MIE off. `PICO2_PSRAM_COPY` (as on Cortex-M): start-up only copies `.psram_ram`, the application calls `psram::init()`. Fixed: the Cortex-M original popped the direct-mode RX FIFO with `(void) reg (QMI_DIRECT_RX);`, which in C++ does **not** read a `volatile` (GCC: "conversion to void will not access object"); it is a real load now, as in the pico-sdk |
| start-up hook | `startup.S` calls `riscv_board_initialize_memory()` (weak, empty by default) on the boot stack **before** the `.data` copy and the `.bss` zeroing; with `PICO2_PSRAM` it copies `.psram_ram` to SRAM and runs `psram::init()`; a failed read-back ends the run with `RESULT: FAIL (PSRAM init ...)` over semihosting |
| `linker-psram.ld` | `.data`, `.bss` and the heap (thread stacks too) at 0x11000000 (8 MB); SRAM keeps `.psram_ram`, the AMO targets, the boot and IRQ stacks and `.noinit` |
| **AMOs** | measured: an `amoswap.w` to the PSRAM window faults (**mcause 7**, store/AMO access fault) -- the first kernel lock after start-up. The objects the port changes with AMOs (`smp_klock`, the soft-IRQ words) are placed in `.data.amo` / `.bss.amo` (`include/riscv-amo.hpp`): ordinary linker scripts fold them into `.data`/`.bss`, `linker-psram.ld` keeps them in SRAM inside `.psram_ram` (copied from flash, zeros included). The PSRAM images contain no other AMO/LR/SC (checked with objdump) |
| clocks | as the Pico 2's (`PICO2_SYS_CLK_KHZ`, the table, 250 MHz); at 250 MHz the PSRAM divider becomes 3 (83 MHz) |
| trap report | adds the hart, `mstatus` and 16 words of the interrupted stack (a jump to 0 leaves mepc and ra 0) |
| flash writer | `src/flash_rp2350.cpp` (`include/flash_rp2350.h`): the predecessor's `mu_flash_erase / _program / _xip_flush / _core1_lockout` API (micro-os-plus-iii-pico2, `src/xip-flash`) on the pico-sdk's RP2350 sequence -- ROM functions through the RISC-V lookup entry (16-bit address at `0x7dfa`, `RT_FLAG_FUNC_RISCV`); MIE off; XIP cache cleaned (pending PSRAM writes); QSPI pads, QMI M0 timing and the CS1 (PSRAM) registers saved; `connect_internal_flash`, `flash_exit_xip`, erase/program, `flash_flush_cache`; XIP re-entered through the boot ROM's setup stub copied from boot RAM (as the SDK's `flash_enable_xip_via_boot2`), or `flash_enter_cmd_xip` when the stub is empty; everything restored. It lives in `.data.ramfunc` (SRAM on every linker script) and calls out only through registers (checked in the disassembly) |
| why MIE is off | between `flash_exit_xip` and the re-entry nothing can be fetched from flash, and the trap vector, the dispatcher and every handler are in flash: an interrupt there (the 1 ms tick, during a tens-of-ms erase) would fetch from a flash that is not mapped. The other hart is parked in SRAM (`mu_flash_core1_lockout`) with its MIE off for the same reason. `mtime` keeps counting and the tick catches the missed periods up (*The port*, missed ticks) |
| `linker-psram-exec.ld` | psram-exec: the supervisor in flash with its data in SRAM, `.psram_ram` in SRAM, and two applications linked at 0x11000000 (A) and 0x11400000 (B), loaded from flash |
| `linker-flatfs.ld` | the image in the first 1 MiB, `FLASH_FS` (3 MiB) at 0x10100000, `_fs_base / _fs_size / _flash_fs_begin / _flash_fs_end` -- the predecessor's `pico2-rp2350-flatfs.ld` layout; data in SRAM (a flash write takes the PSRAM away too, so the caller's stack must not be there) |

The nested-clock tests are interactive, as on the Cortex-M board: a cold boot
runs at 48 MHz and shows the potentiometer (GPIO40 = ADC0) and the clock it
selects; `y` on the UART reboots through the watchdog into that clock
(`reboot_to_index()`: this hart's MIE off, the other core held off through
PSM `FRCE_OFF`, the watchdog's debug-pause bits cleared) and the test starts
there. After the reboot OpenOCD has lost both harts (`Hart unexpectedly
reset!`), so the verdict is the `RESULT` line on the UART, not `hw.sh`'s exit.

## Milk-V Duo facts (from the duo-buildroot-sdk)

| | |
|---|---|
| timebase | 25 MHz (`cv180x_base_riscv.dtsi`) |
| CLINT | `0x74000000`, **32-bit MMIO only** (`clint,has-no-64bit-mmio`); `mtimecmp` written as split 32-bit halves. **`mtime` (+0xBFF8) is not readable from M-mode** -- measured: load access fault (mcause 5), also with 32-bit loads; the port uses `rdtime` only (`MTIME_READABLE = false`) |
| PLIC | `0x70000000`; hart 0 M-mode = context 0 (enable +0x2000, threshold +0x200000, claim +0x200004); priorities 1..7. The C906's interrupt IDs: SG2002 TRM table 3.2 (UART4 = **48**, as in the CV1800B dtsi; DW Timer0..7 = **79..86**). `src/irq.cpp` (`duo_irq::`): a nested dispatcher -- claim, threshold = the source's priority, `mie.MTIE`/`MSIE` cleared (Hazard3's CLEARTS by hand: the tick stays below every external IRQ), `mstatus.MIE` set around the handler, complete, threshold back. Not the `NVIC_*` names: on this board those are the port's soft-IRQ lines (the CMSIS validator uses them) |
| DW timers | `0x030A0000`, 8 x 32-bit down counters, `0x14` apart (load, current, control [enable, user mode, int mask], EOI-on-read, status); count clock **measured 25 MHz** against `rdtime` (TRM 12.4.3 reset default); gates and resets on after BL2 (`CLK_EN_0..4 = 0xffffffff`) |
| reset button | header pin **30 RUN** to pin **36 3V3(OUT)**: RUN is inverted on the Duo -- a high level holds the chip in reset (datasheet 2.7); not pin 37 (3V3_EN switches the 3.3 V off) |
| `mxstatus` | `0xc0638000` written by BL2: MAEE on (PTE bits 63..59 are T-Head attributes) |
| console | UART4 `0x041C0000`, header pins 4 (TX) / 5 (RX), 115200 8N1 (set by BL2) |
| LED | GPIOC (`0x03022000`) bit 24 (Linux GPIO 440) |
| JTAG | TDI 1, TDO 2, TMS 16, TCK 17, GND 18; IDCODE `0x10000b6f` (T-Head/C-SKY), 1 MHz. Measured: the first OpenOCD attach after a previous session fails (IR capture / `dtmcontrol` 0), the second works -- `hw.sh` retries |
| USB | DWC2 v4.20a at `0x04340000` (`GSNPSID = 0x4f54420a`, 8 device endpoints, UTMI+ 16-bit HS PHY, 3072-word FIFO), PLIC IRQ **30** (SG2002 TRM table 3.2); TinyUSB's DWC2 driver in slave mode (`test/boards/milkv-duo/usb/`), brought up with BL2's `cv_usb_hw_init()` + `dwc2_reconfig_usbd()` sequence |

## StarFive VisionFive 2 Lite (test/boards/visionfive2-lite)

The Ethernet + USB-CDC test (`smp-test-usb-cdc-net`, seven threads on the four
U74s, a DesignWare GMAC 5.20 driver and lwIP) **passes on hardware**: 1 Gb/s
link, DHCP lease and ICMP echo replies, with the USB CDC as its console.  The
bring-up, the four bugs behind it and the measured register values are in
**[visionfive2-lite-net.md](visionfive2-lite-net.md)**
(**[PDF](visionfive2-lite-net.pdf)**).

JH-7110S: a U74-MC complex -- hart 0 is the S7 monitor core (rv64imac, no
MMU, not used), harts 1..4 are SiFive U74 (`rv64imafdc_zba_zbb`, Sv39).
µOS++ runs in M-mode on **all four U74** in **every** test (`OS_NCPU = 4`,
CPU n = mhartid n + 1, `RISCV_HART_BASE = 1`). smp-test2 and smp-mat-test
start CPUs 1..3 themselves; every other test gets
`test/visionfive2-lite/src/smp-autostart.cpp` (`test/visionfive2-lite/
tests.cmake`): the test's `os_main()` is renamed `vf2_test_os_main()` (a
`-D` on the test's own sources only), and the board's `os_main()` creates
idle1..3, launches CPUs 1..3, checks that each runs its idle thread on its
own hart (`smp: 4 cores, CPU 0 = mhartid 1, ... -- SMP running`; a core
that does not start fails the test) and then calls the test. The test
sources are unchanged. The board is left at the **U-Boot prompt** (SPL has trained
the DDR, U-Boot has set up UART0); OpenOCD loads each test into DDR at
`0x40200000` and starts it there -- nothing is written to flash or SD.
Build: `cmake -S . -B test/build-vf2 -G Ninja -D BOARD=visionfive2-lite -D
CMAKE_TOOLCHAIN_FILE=cmake/toolchains/riscv-none-elf.cmake`; hardware images
only (no QEMU stand-in).

| | |
|---|---|
| sources | Linux `jh7110.dtsi` / `jh7110-common.dtsi`, the SiFive U7 core complex manual (`vic_u7_manual`), the JH7110 TRM (preliminary V2), `JH-7110S Bare-Metal.md` |
| flags | `-march=rv64imafdc_zicsr_zifencei_zba_zbb -mabi=lp64d -mcmodel=medany -mtune=sifive-7-series` (the same `rv64imafdc_zicsr_zaamo_zalrsc/lp64d` multilib as the Duo) |
| memory | `linker.ld`: everything -- code, data, stacks, heap, page tables -- in a 32 MiB DDR window at `0x40200000` (OpenSBI's `FW_JUMP_ADDR`); OpenSBI at `0x40000000` is left alone |
| timebase | 4 MHz (`timebase-frequency`) |
| CLINT | `0x02000000`, standard SiFive (64-bit `mtimecmp`/`mtime`). The U7 manual lists no `time` CSR, so the clock is **`mtime` over MMIO** (`TIME_CSR = false`, `MTIME_READABLE = true`); measured by clock-test: `sleep_for(100)` = 99 999 µs, 1000 ticks = 999 999 µs |
| hart index | the port's CPU index is `mhartid - RISCV_HART_BASE` (`include/port_ctx.hpp`; 0 on every other board, 1 here, a board define) in `riscv::this_hart()`, `trap.S` (nesting count, IRQ stack) and `startup.S` (which hart boots, the secondary park and release slot; harts below the base or beyond the last CPU stay parked). The CLINT is indexed by mhartid (hart 0 = S7): `BOOT_HART = RISCV_HART_BASE` offsets `CLINT_MSIP`/`CLINT_MTIMECMP`, so CPU n uses hart n+1's `msip`/`mtimecmp` |
| SMP | CPUs 1..3 park in `startup.S` (`riscv_secondary_park`) and are released by `multicore::launch_core(n, port_smp_secondary_start, port_secondary_stack_top(n))` (`include/multicore.hpp`), after their idle threads `idle1..idle3` are registered in `os_idle_thread_core[]`. Fixed for an FPU SMP board: `startup.S` now enables the FPU (`mstatus.FS`) on every hart **before** the secondaries park -- the trap entry saves the FP registers, so a secondary with FS = Off would fault on its first trap (QEMU rv32 and the Pico 2 have no FPU). A thread pinned with `cpu_affinity()` after creation can be picked up by another core first and stay there (measured in smp-mat-test: solver_c0 on mhartid 4): the tests' threads pin themselves first and yield until they are on their core |
| PLIC | `0x0C000000`, 136 sources; contexts in `interrupts-extended` order (0 = hart 0 M, then M and S per U74): hart h's M-mode context is **2h - 1** (1, 3, 5, 7); start-up (CPU 0, before any release) disables the sources and sets the threshold to 7 on all four |
| MMU | standard Sv39 PTEs (no T-Head attributes): CLINT, PLIC, UART0..2, sys_syscon/sysgpio, aon_syscon/aongpio, and the first GiB of DDR. mmu-test's alias moved to `0x80000000` (`0x40000000` is mapped DDR here) |
| misaligned | the U74 traps misaligned loads/stores (U7 manual, data memory system): mmu-test's misaligned step is not run |
| console | UART0 `0x10000000` (DW 8250, reg-shift 2), GPIO5 TX / GPIO6 RX, 115200 8N1 as U-Boot left it (the divisor is kept) |
| LED | `gpio-leds` on **AON GPIO 3**, active high; AON IOMUX `0x17020000` (TRM 2.8.8): DOEN byte at +0x0 (index 0 = output enabled), DOUT byte at +0x4 (0 low / 1 high) |
| park loop | `riscv_board_park` (`src/board.cpp`, section `.text.park`, kept by `linker.ld`): a jump to itself, used by `hw.sh` |

### OpenOCD on the VisionFive 2 Lite (jh7110_daplink.cfg, hw.sh)

`jh7110_daplink.cfg` is the user's `~/Desktop/jh7110_daplink.cfg`, adapted;
everything below was measured on the board (2026-11-06).

| | |
|---|---|
| probe | DAPLink **0d28:0204**, firmware 0255, **CMSIS-DAP v1 (HID only)**. The cfg also accepts the Sipeed d6e7:3507 (CMSIS-DAP v2, bulk, ~40 KiB/s on the Duo) first, if it is plugged in |
| speed | HID costs one 1 ms USB frame per debug-module word: **3.3 KiB/s** loads (44 KiB in 13.4 s), ~**0.8 s per semihosting call**. Neither TCK (2, 4, 10 MHz all 13.4 s) nor the access path (system bus: same load, slower verify; abstract memory access: not supported) changes it. A test takes 1..7 min, mostly its console lines |
| scan chain | two TAPs as in the original cfg (E24, then U74-MC), but **both read IDCODE `0x07110cfd`**: the expected `0x20000c2f` of the first is not what the chip reports. OpenOCD complains and uses the chain anyway; debugging works |
| debug module | 5 harts (`found 5 harts`), `misa 0x800000000094112f`, progbuf 16, datacount 2; abstract CSR reads/writes unsupported (OpenOCD falls back to the progbuf) |
| targets | four **independent** targets `jh7110.cpu1..4` (`-coreid 1..4`); no `init`/`halt`/`echo` at the end (hw.sh drives the session) |
| no `target smp` | with the SMP group, OpenOCD's semihosting handler resumed one hart of four (`3 harts should remain halted, and 1 should resume`) and the program's registers were wrong after the first call -- every run. Also: in a group, `resume <addr>` sends **every** hart to `<addr>` (three harts ran the test at once on the UART) |
| `reset halt` | optional (`HW_RESET=1 hw.sh <test>`): measured not to touch DDR or UART0 (LCR stays 0x03), and the chip stays stable after it; the default is a plain halt of the U-Boot-booted board. U-Boot's `starfive_visionfive2_defconfig` enables no watchdog |
| **semihosting state** | a hart left halted on the **previous** session's semihosting `exit` ebreak (`dcsr.cause = 1`) did **not** halt on its semihosting ebreaks in the next session, although `dcsr.ebreakm` read 1: runs strictly alternated PASS / hang (UART showing PASS, OpenOCD seeing nothing). `hw.sh` therefore loads the image, runs hart 1 on `riscv_board_park` for 100 ms and stops it with a halt request (`dcsr.cause = 3`) before `reg pc _start; resume` -- then 4/4 back-to-back PASS |
| console copy | `src/uart.cpp` copies each console write to semihosting with **`SYS_WRITE`** (one bulk read of the buffer), not `SYS_WRITE0` (one probe round trip per byte, which on this probe ended in link errors) |
| session | `init` -> halt harts 2, 3, 4, 1 -> `load_image` -> for each hart the image drives: `reg priv 3`, park, resume, 100 ms, halt, `arm semihosting enable` -> (SMP) clear the release slots, `reg pc <entry>; resume` on harts 2..n (they park) -> `reg pc <entry>; resume` on hart 1. The verdict is the semihosting exit (OpenOCD's exit status) checked against the `RESULT` line |
| interrupts off | before resuming any hart, `hw.sh` writes `mie = 0` and clears `mstatus.MIE` (so do the Eclipse GDB scripts). Measured 2026-11-07: a hart halted in the middle of the previous test keeps its interrupt enables and its CLINT timer is long overdue; resumed on `riscv_board_park` it took the interrupt at once and ran the **new** image's trap handler and tick before `_start` (pc away from the park after 100 ms, every run). In some runs that left the kernel lock `smp_klock` held by CPU 0 (owner 0, depth 1, no fresh acquire after `.bss` was cleared -- `.data` is not re-initialised for a RAM image), and CPUs 1..3 spun in `riscv_smp_klock_acquire` forever: "CPU n NOT RUNNING", smp-test2 workers with 0 beats, an Eclipse thread pool 20/0/0/0. With the fix: clock-test 6/6, every test PASS. `hw.sh` reports a hart that is not on the park after the 100 ms (`HW.SH PARK FAILED`) |
| SMP images | detected from `riscv_secondary_boot` (NCPU = its size / 24). Its slots are **cleared through OpenOCD** before the harts start: the DDR keeps the previous run's, and a stale magic would release a hart before CPU 0 has set it up. Semihosting is enabled on every target: threads on any core print, and each hart halts on its own ebreak |
| diagnostics | every run keeps a timestamped log in `test/build-vf2/.hw-logs/`; on a timeout `hw.sh` asks the live OpenOCD (Tcl port 6666) for hart 1's `pc mcause mepc mtval ra sp mstatus dcsr` and the port's `riscv_semihosting_absent` before stopping it |
| wiring | 40-pin header: TMS 35, TCK 37, TDI 38, TDO 40, GND 39 (pin 36 = GPIO36, not reset, not used); console UART0 TX pin 8, RX pin 10 |

### Second probe: Raspberry Pi "JTAG probe on Pico" (jh7110_picoprobe*.cfg)

Every VisionFive 2 config and script in the repo root has a copy for this
probe, identical except for the probe lines.

`test/boards/visionfive2-lite/hw.sh` (and so every VF2 test under CTest)
takes the probe that is plugged in: `jh7110_daplink.cfg` when the DAPLink
(0d28:0204) is there, else `jh7110_picoprobe.cfg` when a 2e8a:000c with the
USB product name "JTAG probe on Pico" is there, pinned by its serial number
(read from sysfs). `VF2_PROBE=daplink|picoprobe` forces one. The probe is
shown in the run's header line. The Pico 2's `hw.sh` in turn pins its Debug
Probe by serial number, skipping the JTAG probe on Pico, so both can stay
plugged in.

| DAPLink | JTAG probe on Pico |
|---|---|
| `jh7110_daplink.cfg` | `jh7110_picoprobe.cfg` |
| `jh7110_daplink_debug.cfg` | `jh7110_picoprobe_debug.cfg` |
| `jh7110_daplink_semihost.cfg` | `jh7110_picoprobe_semihost.cfg` |
| `jh7110_daplink_srst.cfg` | `jh7110_picoprobe_srst.cfg` |
| `jh7110_wdt_reset.cfg` | `jh7110_wdt_reset_picoprobe.cfg` |
| `jh7110_wdt_disable.cfg` | `jh7110_wdt_disable_picoprobe.cfg` |
| `jh7110_jtag_key.cfg` | `jh7110_jtag_key_picoprobe.cfg` |
| `vf2-reset-to-uboot.sh` | `vf2-reset-to-uboot-picoprobe.sh` |
| `vf2-jtag-stop-uboot.sh` | `vf2-jtag-stop-uboot-picoprobe.sh` |

| | |
|---|---|
| probe | a Raspberry Pi Pico with the "JTAG probe on Pico" firmware: **2e8a:000c**, `CMSIS-DAP v2 Interface` (vendor class, USB bulk) plus a CDC-ACM UART; OpenOCD reports FW 2.0.0, SWD and JTAG supported. The cfg selects `vid_pid 0x2e8a 0x000c` and `backend usb_bulk` |
| same VID:PID | the Pico 2's Raspberry Pi Debug Probe is also 2e8a:000c. With both plugged in, set `PICOPROBE_SERIAL` (this probe: `E4623492931D2230`); the cfg then adds `adapter serial` |
| speed | the cfgs set TCK **10 MHz** (`adapter speed 10000`). Measured 2026-11-07, `hw.sh smp-test2` (82 600-byte image, 4 cores, 32 console lines over semihosting), both PASS: **10 MHz: load 2.2 s (37.4 KiB/s), whole test 16 s**; 2 MHz: load 2.6 s (30.7 KiB/s), 17 s. The DAPLink: 24.6 s (3.3 KiB/s) at any TCK |
| SRST | not checked whether this firmware drives a reset line |
| wiring | the same header pins (TMS 35, TCK 37, TDI 38, TDO 40, GND 39). A session that read both IDCODEs but then only zeros past the chain end (`auto0..18.tap idcode=0x0`, `dtmcontrol is 0`) had **TDI** not reaching the board: TCK, TMS and TDO were working |

## WCH CH32V307V-EVT-R1 (test/boards/ch32v307-evt)

CH32V307VCT6: one WCH **QingKe V4F** core, RV32IMAFC (single-precision
FPU), on WCH's evaluation board, with its on-board **WCH-LinkE**
(`1a86:8010`) for debug and console. The chip has no CLINT, so the port runs
its **PFIC path** here (`RISCV_PFIC`, *Interrupts* below): the kernel
runs, preemptive, with nested interrupts, close to the Cortex-M port.
Images run from flash. Build: `cmake -S . -B test/build-ch32v307 -G Ninja
-D BOARD=ch32v307-evt -D
CMAKE_TOOLCHAIN_FILE=cmake/toolchains/riscv-none-elf.cmake`; hardware
images only (QEMU models neither the chip nor the PFIC). Run:
`test/boards/ch32v307-evt/hw.sh <app>`.

Tests (`test/ch32v307-evt/`): `board-basics` (kernel-free: start-up,
clocks, console, LED, key, semihosting), `smp-test1` (the kernel: three
threads, sleeps, a mutex, a counting semaphore, the LED -- the Pico 2's
single-core bring-up) and `pfic-test` (the PFIC path itself, with two
software-raised peripheral interrupts, IRQ 16 at `0x40` and IRQ 17 at
`0x00`: an interrupt waking a thread; a higher-priority thread woken from an
interrupt or inside a critical section running before the waker goes on;
IRQ 17 nesting inside IRQ 16; the threshold holding IRQ 16 but not IRQ 17;
IRQ 16 preempting a timer callback in the SysTick handler; 2000
interrupt-to-thread hand-offs), and `usb-cdc-stream` (a 1 MiB file round
trip over USB HS on P6, streamed: the board sends each piece back as it
arrives -- 64 KiB of SRAM cannot hold the file -- with a running CRC-32;
the PC side is `test/ch32v307-evt/usb-cdc-stream/usb-stream-host.py`
beside `name.dat`, run by hand once the console shows `[usb] mounted`). Under the kernel's harness (platform
`riscv-ch32v307-evt`, xpm configurations
`riscv-ch32v307-evt-cmake-gcc-debug|release`, CTest cases
`riscv-ch32v307-evt-<app>-hwd`) also the suites blinky, fp-switch,
mutex-stress, instrumentation, rtos-apis and cmsis-os-validator
(`test/ch32v307-evt/<suite>/harness-suite.cpp`, `include/harness-suite.hpp`).

What fits 64 KiB of SRAM: the board sets
`OS_INTEGER_RTOS_DEFAULT_STACK_SIZE_BYTES=2048` (`board.cmake`; with the
port's 8 KiB six fp-switch threads ran the free store out, `bad_alloc`), and
the board's `include/cmsis-plus/os-app-config.h` caps a suite's RTOS arena
at 20 KiB and leaves rtos-apis' FatFs part out (as on the Pico 2).

Console: `riscv_board_console_write()` (trace, stdout) writes the UART and,
on a hardware image under the debugger, semihosting too -- from threads
only, never from a trap -- so a run's output reaches the PC; the suites'
RESULT line goes to both. Peripheral interrupts: `src/irq.cpp`, generated
from WCH's vector table (PFIC 16..103, WCH's handler names, weak), and the
`NVIC_*` Cortex-M code calls: IRQ n = PFIC 16 + n, every one at the
kernel-aware `0x40`; enabling discards a stale request; a pend from a
thread waits until the handler has run (the CMSIS validator's "IRQ 0" is
PFIC 16, WCH's WWDG vector).

| | |
|---|---|
| sources | `CH32FV2x_V3xRM` V2.5 (reference manual), `QingKeV4_Processor_Manual` V1.5, `CH32V307DS0`, the EVT schematic and *Evaluation Board Reference*, WCH's EVT code (`system_ch32v30x.c`, `startup_ch32v30x_D8C.S`), Zephyr's `ch32v307v_evt_r1` board page |
| core (measured) | `misa = 0x40901125` (I M A F C, U, X), `marchid = 0xdc68d881`, `mvendorid = 0`; chip ID `0x30700528` (CH32V307VCT in WCH's ID table) |
| CSRs (measured) | a probe run from SRAM read and wrote each one: `mie`, `mip` read 0 and take writes; `mhartid` 0; **`mcycle`, `cycle`, `time` read 0** -- no CSR time base; vendor `gintenr` 0x800, `intsyscr` 0x804, `corecfgr` 0xBC0 present. `fence.i` is documented |
| flags | `-march=rv32imafc_zicsr_zifencei -mabi=ilp32f -mcmodel=medany` (multilib `rv32imafc_zicsr_zaamo_zalrsc/ilp32f`) |
| memory | as configured: **256 KiB code flash + 64 KiB SRAM** -- `FLASH_OBR = 0x03fffefc`, `SRAM_CODE_MODE` bits [9:8] = `10` ("CODE-256KB + RAM-64KB"), and the WCH OpenOCD reports the same. `ESIG_FLACAP` reads 288 KiB: the whole flash, not the split. `linker.ld`: code at the flash's `0x00000000` alias (where the core starts), `.data` copied from flash, 2 KiB IRQ + 2 KiB boot stack |
| start-up | `startup.S` unchanged (its `csrw mie, zero` is harmless here); under `RISCV_PFIC` `startup.cpp` disables and clears every PFIC interrupt instead of clearing the CLINT MSIP (a store there hit flash address 0 and trapped, `mcause` 3 -- measured); `riscv_board_initialize_early()` writes `corecfgr = 0x1f` (WCH's start-up value), the clocks, and starts SysTick free-running |
| clocks | WCH's own `SystemInit()` + `SetSysClockTo144_HSE()`, register for register: HSE 8 MHz, PLL x18 (the D8C encoding, `PLLMUL = 0000`), **144 MHz** HCLK = PCLK2, PCLK1 72 MHz. Measured against the host's wall clock (semihosting `SYS_TIME`, SysTick ticks between two second edges 9 s apart), three runs: **144.35**, **142.68** and **144.27 MHz** (+0.24, -0.9, +0.19 %) -- within the error of catching the edges through semihosting round trips over the WCH-Link; the readable UART at 115200 is the other check |
| time base | SysTick (`0xE000F000`), 64-bit, counting up at HCLK; `ch32::systick_now()`. For the kernel it is the tick: `riscv-board.hpp` maps `CLINT_MTIME` to its counter (`STK_CNTL/H`) and `CLINT_MTIMECMP` to its compare (`STK_CMPLR/HR`), so the port's mtime/mtimecmp code (catch-up, guard) drives it unchanged |
| console | USART1, **PA9 TX / PA10 RX**, 115200 8N1 (`BRR = 1250`), through the EVT's J2 jumpers to the WCH-LinkE's CDC port (`/dev/ttyACM0`) |
| LED | **LED1 on PD0** by a jumper wire (the EVT's LEDs are not connected to the chip in its layout -- Zephyr's board page), active low |
| key | **S2 on PA1** by a jumper wire: like the LEDs, S2 reaches the chip only through the **J3** header (WCH *Evaluation Board Reference* V1.9: "USER button S2: Connect the I/O port of the main MCU through J3 pin"); PA1 is Zephyr's choice. Active low (S2 to GND), input with the internal pull-up |
| USB | device on the **high-speed port P6** (USBHS): TinyUSB's WCH driver `portable/wch/dcd_ch32_usbhs.c` + `ch32_usbhs_reg.h`, taken from the same TinyUSB commit as the tree the Pico 2 carries (`91fbbd192`, added to `test/boards/pico2/usb/tinyusb`). The driver includes WCH's `<ch32v30x.h>` only for the `USBHSD` register struct, `USBHS_IRQn` and `NVIC_*`: `usb/wch-shim/ch32v30x.h` gives exactly those (WCH's struct, copied with its notice; `USBHS_IRQn` = PFIC 85 = the port's IRQ 69). `usb/ch32-usb.cpp`: the USBHS clock and PHY (TinyUSB's CH32V30x board code is six WCH library calls; as registers: `RCC_CFGR2` bits 31/30 = 1, 29:28 = 01 (4 MHz reference), 27 = 0 (HSE), 26:24 = 001 (HSE / 2), `RCC_AHBPCENR` bit 11) and `USBHS_IRQHandler` -> `tud_int_handler(0)` at `0x40`; a thread runs `tud_task()`. `usb/cdc`: `tusb_config.h` (CH32V307, USBHS, high speed, no OS) and high-speed descriptors (512-byte bulk, device qualifier, other-speed configuration, as TinyUSB's cdc_msc example), VID:PID `cafe:4014` |

### Interrupts: the PFIC path (RISCV_PFIC, include/pfic.hpp)

The QingKe V4F has no `mtime`/`mtimecmp` and no machine timer or software
interrupt: everything goes through the **PFIC** at `0xE000E000` (SysTick =
interrupt 12, software interrupt = 14, peripherals from 16), which has
priorities and **hardware nesting** -- `mstatus.MIE` is **not** cleared on a
trap. Measured first (an SRAM probe, `INTSYSCR = 0x0a`, HPE off, IRQ 14 at
priority 0xC0, IRQ 12 at 0x00, both pended through `PFIC_IPSR`): IRQ 12
preempted IRQ 14 three instructions into its handler (`PFIC_GISR = 0x103`:
nesting level 2), and after it returned the low handler's **`mepc`,
`mcause` and `mstatus` were intact**. So the port uses the Cortex-M model,
board-selected by the define `RISCV_PFIC` (the other boards are unchanged):

| Cortex-M | CH32V307 (PFIC) |
|---|---|
| PendSV, lowest priority | the software interrupt **14**, priority `0xC0`: the **only** place threads switch. It runs when no other interrupt is active, so a switch never leaves another interrupt half-done in the PFIC's active state (an interrupt that switched threads before an outer one's `mret` would keep that one -- and everything at or below its priority -- blocked until its thread came back) |
| SysTick | the QingKe SysTick, interrupt **12**, priority `0x80`, through the port's mtime/mtimecmp code (64-bit compare, catch-up, guard) |
| BASEPRI | `PFIC_ITHRESDR`: an interrupt with priority value >= the threshold stays pending, 0 = none. A critical section raises it to **`0x40`**; the `0x00` group keeps running and must not call the kernel |
| PendSV request + DSB/ISB | `reschedule()` pends 14 and, from a thread that 14 can interrupt now, waits until `PFIC_IPR0` shows it taken -- precise: the thread does not run on past its request. In a handler or a critical section it is taken when the handlers return / the threshold drops (`critical_section::exit()` waits for it too) |
| nesting | `INTSYSCR = 0x0a`: INESTEN, PMTCFG `10` (4 levels, priority bits [7:6]), HPE off |
| IPSR != 0 | `riscv_trap_nesting != 0` (the interrupt depth) |
| PendSV's own BASEPRI | `switch_stacks()` runs inside a kernel critical section (threshold `0x40`) and clears the request and the pending 14 there, as the Cortex-M PendSV handler does. The kernel's `internal_switch_threads()` re-links and unlinks the ready list without protecting itself; without the section SysTick preempted it mid-way and woke a thread into the same list -- mutex-stress's ten workers then stopped for good, the reporter thread running on (measured) |
| a level timer | CLINT's timer interrupt is a level that drops when mtimecmp moves ahead; the QingKe SysTick **latches** `CNTIF` and the PFIC latches the pending bit. So every compare the port writes is followed by clearing both and, if the counter has reached the deadline meanwhile, pending 12 by software. Without it a compare passed during a slow handler (rtos-apis' 1-tick periodic timer printing from the tick) kept 12 pending: SysTick re-entered back to back and the switch never ran (measured on the stuck chip: `IPR0 = 0x5000`, `CNTIF = 1`, the switch's trap entry preempted) |

Priorities: `0x00` zero-latency (never masked), `0x40` kernel-aware,
`0x80` SysTick, `0xC0` the switch. The full frame is saved by the shared
`trap.S`; a nested interrupt saves its own below the current `sp`. One race
in `trap.S` mattered only here and is fixed for every board: on the way out
`sp` now moves to the frame **before** the nesting count drops -- otherwise
an interrupt in between saw nesting 0 while `sp` was still on the interrupt
stack, built its frame near the top and then reset `sp` to that top for its
dispatcher, over its own frame. A peripheral interrupt (16+) goes to the
board's `riscv_board_pfic_interrupt(irq)`; one it does not handle is
disabled and reported as a fault. `soft-irq.cpp` (CLINT MSIP lines)
compiles out; the board's `NVIC_*` on PFIC interrupts are still to come
(the CMSIS validator needs them).

### OpenOCD for the WCH-LinkE (openocd-wch/, hw.sh)

The upstream OpenOCD does not know the WCH-LinkE's protocol; WCH's own
(MounRiver) fork does. The one used here:

| | |
|---|---|
| source | [karlp/openocd-hacks](https://github.com/karlp/openocd-hacks), branch `mrs-wch-riscv-221010`, commit `266d7c8d3` -- the MounRiver fork (0.11.0+dev) with its `interface/wlink.cfg` and `target/wch-riscv.cfg` |
| patch 1 | `openocd-wch/gcc16-werror-fixes.patch` (notes: `gcc16-werror-fixes.md`): the fork builds with `-Werror`, and GCC 16 stops it in the WCH drivers (`wlink.c`, `wchriscv.c`, ...), the RISC-V target and a few upstream files; source-level fixes only, `-Werror` stays on |
| patch 2 | `openocd-wch/wlinke-type-0x12.patch`: this WCH-LinkE (firmware 2.10) answers the identify command with probe type **`0x12`** (measured: reply `82 0d 04 02 0a 12 00`), which 221010 rejects ("unknow WCH-LINK"). The newer fork `mrs-wch-riscv-230824` treats `0x12` as the LinkE; the patch does the same (one `case` line: it only names the probe) |
| build + install | `test/boards/ch32v307-evt/openocd-wch/build-openocd-wch.sh [<src>] [<prefix>]`: clones/checks out the commit, applies both patches (once), `./configure --prefix=<prefix> --enable-wlink`, `make`, `make install`. Default prefix `~/.local/openocd-wch` (an existing `bin/openocd` is kept as `openocd.prev`). Installed here: `~/.local/openocd-wch/bin/openocd`, the unpatched binary kept as `openocd.221010-unpatched` |
| what it finds | `WCH-LinkE-CH32V307 mod:RV version 2.10`; RISC-V debug over the LinkE's two-wire SDI (OpenOCD prints a JTAG tap `0x00000001`: the fork fakes one); chip family 6 (CH32V30x), 256-byte flash pages; `ROM 256 kbytes RAM 64 kbytes`; flash bank `wch_riscv` at `0x00000000` |

**hw.sh** (`test/boards/ch32v307-evt/hw.sh <app> [seconds]`): `flash
write_image erase <elf>` (the WCH driver erases the **whole chip**), the
flash read back with `dump_image` and compared on the PC, segment by
segment, with the ELF's LOAD file bytes (a gap between segments stays erased
and is not compared); on a mismatch it reads the flash once more before
failing (`FLASH READBACK DIFFERS` = exit 6: once, a 186 KB image read back
with one wrong byte, and two new read-backs were identical -- a read error
over the link, not a bad write), then a second session
`reset halt`, `arm semihosting enable`, `resume`. OpenOCD ends itself on the
test's semihosting `SYS_EXIT`, with its code: exit 0 PASS, 1 FAIL, 3
TIMEOUT, 4 OPENOCD DIED, 5 NO EXIT. Env: `BUILD=` (default
`test/build-ch32v307`), `OPENOCD=` (default the installed one),
`OPENOCD_SCRIPTS=`.

By hand -- the scripts are found by the installed binary itself:

```bash
O=~/.local/openocd-wch/bin/openocd
# connect, read where the core is, let it run on (read-only)
$O -f interface/wlink.cfg -f target/wch-riscv.cfg -c init -c halt \
   -c "reg pc" -c "reg mcause" -c "reg mepc" -c "mdw 0xE000E04C" -c resume -c shutdown
# program and start an image
$O -f interface/wlink.cfg -f target/wch-riscv.cfg -c init -c "reset halt" \
   -c "flash write_image erase app.elf" -c "reset run" -c shutdown
# a program in SRAM (linked at 0x20000000 with -Wl,-n), with semihosting
$O -f interface/wlink.cfg -f target/wch-riscv.cfg -c init -c "reset halt" \
   -c "arm semihosting enable" -c "load_image app.elf" -c "reg pc 0x20000000" -c resume
```

What this OpenOCD does wrong (all measured; hw.sh avoids each):

| | |
|---|---|
| RAM loads below SRAM | in WCH mode every memory write **below `0x20000000`** is taken as flash data and copied into a 256-byte buffer **without a bounds check** (`riscv-013.c`, `write_flash_data`; found with AddressSanitizer). An ELF whose first segment starts below SRAM -- the linker's default page-aligned headers, `0x1ffff000` for a `-Ttext=0x20000000` link -- crashed OpenOCD (in libusb, from the corrupted heap). Link SRAM images with `-Wl,-n`; write flash only through `flash write_image` |
| `verify_image` | fails silently: its checksum runs in the work area, and `target/wch-riscv.cfg`'s `0x80000000` is not RAM on this chip. Compare a `dump_image` instead |
| `SYS_CLOCK` | returns OpenOCD's own CPU time (`clock()`), not wall time. `SYS_TIME` is wall time (seconds) -- board-basics measures HCLK against it |
| flash bank | at `0x00000000` (not `0x08000000`), where the image is linked |
| gaps | `flash write_image` writes only the segments' file bytes, so a gap between them (or a segment's memory-only tail: a padding-only section becomes NOBITS) keeps the erased value (`e339e339`); hw.sh compares each segment's file bytes only |
| the factory demo's UART | after a debug session halted WCH's demo, its UART showed garbage until a power cycle: its clock read HSI x15 = 120 MHz while its `BRR` (1111) fits 128 MHz -- about 108 000 baud. The tests set their own clock and baud |

## Build and test

Toolchain: xPack `riscv-none-elf-gcc` 15.2.0-1.1 (found under `~/.local/xPacks`).

```bash
xpm install                      # or have the xPacks installed globally
xpm run build                    # = cmake -S . -B test/build ... && cmake --build
xpm run test                     # emulated set: ctest -LE hwd
xpm run test-hwd                 # every hardware test (test/hw-all.sh)
xpm run hw-reset                 # watchdog reset over JTAG (see below)

test/qemu.sh <app>               # one test on QEMU virt
test/hw.sh <app>                 # one test on the Duo
test/hw-all.sh [app ...]         # all (or the named) hardware tests in a row
```

Under the kernel's harness (`micro-os-plus-iii/tests`, local branch `riscv`):

```bash
xpm run install  --config riscv-milkv-duo-cmake-gcc-debug
xpm run prepare  --config riscv-milkv-duo-cmake-gcc-debug
xpm run build    --config riscv-milkv-duo-cmake-gcc-debug
xpm run test     --config riscv-milkv-duo-cmake-gcc-debug   # 14 qemu cases
xpm run test-<app>-hwd --config riscv-milkv-duo-cmake-gcc-debug
xpm run test-hwd-all  --config riscv-milkv-duo-cmake-gcc-debug   # hw-all.sh
```

### Emulated images

QEMU does not model the CV1800B (nor the RP2350). Each test's `qemu` image links the port
against QEMU's `virt` machine (`micro-os-plus::riscv-qemu-virt`: virt CLINT,
NS16550 console, virtual LED, own linker script) -- the same sources, run on
different silicon, the way the Cortex-M port runs the pico2's tests.

### Hardware (`hwd`)

Wiring: JTAG TDI pin 1, TDO pin 2, TMS pin 16, TCK pin 17, GND pin 18 (SIPEED
RV CMSIS-DAP, `d6e7:3507`); console UART4 TX pin 4, RX pin 5, 115200 8N1.
Power the Duo from its own USB-C.

1. Boot the Duo from an SD card holding the minimal `fip.bin`
   (`milkv-duo (opensbi)/output/fip.bin`): BL2 brings up clocks, DDR, UART4 and
   the JTAG pinmux, OpenSBI parks the hart.
2. `test/hw.sh <app> [secs]`: OpenOCD alone (no GDB) halts the hart, sets
   M-mode (`reg priv 3`), loads the ELF into DDR at `0x80050000`, enables
   semihosting and resumes at `_start`. Nothing is written to the SD card.
   The verdict has two halves: the `RESULT:` line (UART + semihosting) and the
   **semihosting exit**. With no GDB connected, OpenOCD handles `SYS_EXIT` by
   calling `exit(code)` itself and prints nothing (`semihosting_common.c`), so
   **OpenOCD's own exit status is the test's exit code**. With a GDB
   connected it prints `semihosting: *** application exited with N ***`
   instead; `hw.sh` reads either.
   Codes: 0 PASS, 1 FAIL, 2 no such test / stale build, 3 TIMEOUT,
   4 OPENOCD DIED, 5 NO EXIT. `hw.sh` **refuses an ELF older than any port or
   board source** (a fix was once "tested" with a stale image).
   After a clean exit the hart is left debug-halted on the exit `ebreak`; the
   next session attaches to it directly, no power-cycle needed.
3. `test/hw-all.sh [app ...]`: every hardware test in a row, `GAP` (3-5 s,
   default 4) between tests. `RESET` selects what happens after a test that
   did not end cleanly (TIMEOUT, NO EXIT, OPENOCD DIED):
   - `manual` (default): the board is power-cycled **by hand**;
     `wait-power-cycle.sh` asks for it, waits for BL2's USB device
     `3346:1000` to appear (`DETECT=none`: press ENTER instead), then waits
     `POWERUP_WAIT` (5-10 s, default 8). Measured once: the USB appearance
     was not seen after a power-cycle -- use `DETECT=none` if so.
   - `wdt`: the watchdog reset below, before every test.
   - `0`: no reset; a stuck test ends the run.

   Summary in `<build>/.hw-logs/hw-all-<date>.txt`.

#### The reset (no reset line on the header)

`test/boards/milkv-duo/reset.cfg` (`hw-reset.sh`) uses BL2's own
`__system_reset()`: the RTC domain's watchdog-reset path plus the TOP
watchdog (DesignWare WDT at `0x03010000`, ~166 ms):

| write | meaning |
|---|---|
| `0x050260E0 <- 1` | rtc_core watchdog reset enable |
| `0x050260C8 <- 1` | rtc_core power cycle enable |
| `0x050250AC <- 0` | rtcsys_rstn_src_sel |
| `0x05025004 <- 0xAB18` | `RTC_CTRL0` unlock |
| `0x05025008 <- 0x00400040` | rtc_ctrl watchdog reset enable |
| `0x03010004 <- 0x66`, `0x0301001C <- 0x20` | WDT timeout |
| `0x0301000C <- 0x76` | WDT restart |
| `0x03010000 <- 0x11` | WDT enable, reset on timeout |

Measured: it brought the board back 4 times out of 4 from the parked OpenSBI
state, and **not** after a stuck test (JTAG chain read all ones afterwards).
The SDK's RTC warm reset (`cvi-reboot.c`) reset the SoC but the board did not
come back. A hung board is therefore power-cycled by hand (or pin 30 RUN).

## Tests (test/milkv-duo)

| test | from | what |
|---|---|---|
| mos-test1 | nucleof411 | producers/consumers, mutex, recursive mutex, semaphores, LED |
| sc-test-ko | pico2 | every kernel object, single core |
| mutex-ceiling-test | native | refused protect lock leaves nothing behind |
| smp_test0 | all ports | Phase-1 bring-up: 10 heartbeats (one hart is the whole system) |
| clock-test | all ports | sysclock / hrclock against `rdtime`; CLINT offset |
| exc-test | RP2350 (RISC-V form) | illegal insn, ecall, access fault mid-thread; regs survive |
| mmu-test | RISC-V | Sv39 through MPRV, alias both directions, misaligned |
| semihosting-test | RISC-V | WRITEC/WRITE0, value-returning calls, with the tick running |
| smp-test1 | pico2 (Cortex-M) | single-core RTOS bring-up: two workers, mutex, LED (the same source as the Pico 2's) |
| smp-mat-test | pico2 (Cortex-M) | the block solver at one hart, N = 300, B = 50 (the RP2350B's size), the barrier's SIO spinlock as an AMO, TIMER0 as `rdtime`: block 87.7 ms, classical 113.6 ms on the C906's FPU (RP2350B Hazard3, software float, two cores: 14.4 s / 24.0 s) |
| smp-test-nested | RP2350B (Cortex-M), hw only | nested PLIC interrupts: DW Timer0 (priority 3, one-shot 500 us into the UART handler) must preempt UART4's handler (priority 1, its TX-empty interrupt started by a thread, busy 2 ms); DW Timer1 periodic (2). PASS needs `t2_in_uart > 0`; prints the DW timer, `rdtime` and `sysclock` elapsed times |
| clock-catchup | RISC-V | `sysclock` follows `rdtime` within 2 % across ten 100 ms masked periods |
| smp-test-usb-cdc-acm | pico2 (Cortex-M), hw only | USB CDC-ACM (`cafe:4013`) on the CV1800B's DWC2 controller (TinyUSB DWC2, slave mode): echoes each line ("you typed: ..."), Escape ends with PASS (`usb-host.py cdc`) |
| smp-test-usb-hid | pico2 (Cortex-M), hw only | generic in/out USB HID (`cafe:4012`) on DWC2: receives 64-byte OUTPUT reports, prints characters on UART4, Escape ends with PASS (`usb-host.py hid`) |
| blinky, fp-switch, instrumentation, mutex-stress, rtos-apis, cmsis-os-validator | harness suites | built under the kernel's harness only |

Not carried: the two-core SMP tests (`smp-test2..5`, `smp-test-ko`, the
nested-clock tests) -- µOS++ drives one hart on the Duo (the second C906 is a
separate, non-coherent core); `sd_test`.

### Status (2026-11-07)

WCH CH32V307V-EVT-R1, on-board WCH-LinkE, image in flash: **board-basics
PASS** -- boot from flash into `_start`, static constructors, clocks HSE ->
PLL x18 (144.35, 142.68 and 144.27 MHz measured against the host in three
runs), USART1 115200, LED1 on PD0, key S2 on PA1, semihosting console and
exit; the flash read back identical (3 runs, all PASS). The key: 0 presses
in the first two runs -- S2 was not wired (it reaches the chip only through
J3); with the J3 KEY -> PA1 jumper, **7 presses counted** in the 10 s
window, released at rest. Installed OpenOCD (patched) used by hw.sh.

The kernel on the CH32V307 (PFIC path, 2026-11-07): **smp-test1 PASS** from
flash -- three threads switched by the PFIC software interrupt, 1 ms SysTick
ticks through the mtime/mtimecmp code, sleeps, a mutex and a counting
semaphore under threshold critical sections, the semihosting exit.
**pfic-test PASS**, 6/6: wake from IRQ 16; preemption 2a (high ran at 1,
low continued at 2) and 2b (in a section: 11, 12); nesting (IRQ 17 inside
IRQ 16, nesting 2, `GISR = 0x103`); BASEPRI (threshold `0x40`, inside the
section IRQ 16 0 / IRQ 17 1, after it IRQ 16 1); the timer callback in
SysTick (`IACTR0` bit 12) preempted by IRQ 16; 2000/2000 hand-offs in 46
ms (~23 us each). smp-test1 and board-basics rerun after the linker change:
PASS.

The harness on the CH32V307 (2026-11-07, platform `riscv-ch32v307-evt`,
debug): **9/9 PASS** -- board-basics, smp-test1, pfic-test, blinky,
fp-switch (1188 rounds, 0 bad: the single-precision registers and `fcsr`
held across preemption; on one core the higher-priority threads take most
of the rounds, by design), mutex-stress (sum 2777 after 35 s, workers within
+-5 %), instrumentation, rtos-apis (every section but FatFs, 105 s) and
**cmsis-os-validator 60/60** (every interrupt case through the board's
`NVIC_*`). Found on the way: the unprotected `switch_stacks()` and the
latching SysTick (*Interrupts* above). Release (`-cmake-gcc-release`): **9/9
PASS** as well -- fp-switch 967 rounds, 0 bad (calibrated to 147692 spin
loops: the optimised hold is faster), mutex-stress within +-3 %, rtos-apis
the same 33 sections as debug, cmsis-os-validator 60/60.

USB on the CH32V307 (2026-11-07): **usb-cdc-stream PASS** -- enumerated at
**high speed** on P6 (`cafe:4014 TinyUSB CH32V307 CDC-ACM`), 1 MiB streamed
through the board in 565 ms (1812 KiB/s each way), board CRC-32 agreeing,
`name.dat.back` identical; a second run, `usb-stream-host.py` started by
hand and waiting for the device: 396 ms (2585 KiB/s each way), identical
again. The rate is the test loop's, not the link's: at most 512 bytes per
step and a 1 ms sleep whenever TinyUSB has no event.

StarFive VisionFive 2 Lite, JTAG probe on Pico at 10 MHz, full console over
semihosting, every test in DDR, **every test on all four U74**: **11/11
PASS** (8..19 s each; smp-mat-test 47 s). The nine auto-started tests each
printed `CPU 0..3 = mhartid 1..4 -- SMP running`; smp-test2: wrk0..3 8 beats
each on its own hart; smp-mat-test: thread-pool tasks per CPU 6/6/4/4,
solvers c0..c3 on mhartid 1..4, speedup 5.33x.

Harness suites (kernel `tests/`, platform `riscv-visionfive2-lite`, xpm
configurations `riscv-visionfive2-lite-cmake-gcc-debug|release`, CTest
cases `riscv-visionfive2-lite-<app>-hwd` for all 17 applications): blinky,
fp-switch, mutex-stress, instrumentation, rtos-apis and cmsis-os-validator,
each on **all four U74** (`include/harness-suite.hpp`: the
`__wrap_os_main()` calls `vf2_smp_start()` before the suite) -- **6/6 PASS**
(8..86 s). fp-switch now really tests the FPU on RISC-V (it had an Arm path
only and printed "no FPU, nothing to test" here and on the Duo): f0-f31
(64-bit) and fflags held across preemption, the hold calibrated to about 3
ticks, and on SMP at least one round must resume on another core --
3894 rounds, 0 bad, 860 migrated.

eMMC (2026-11-07): `test/boards/visionfive2-lite/src/emmc.cpp` drives the
JH-7110's SDIO0, a Synopsys DesignWare MMC host at `0x16010000`, polled:
1-bit, 399 kHz for identification and 24.75 MHz after (CLKDIV 248 / 4 of a
198 MHz controller clock = PLL2 1188 MHz / 3 / 2, read from the PLL
registers), sector addressing, the controller's FIFO at `0x200` and **32
bits wide** (HCON H_DATA_WIDTH 1; read 64 bits at a time it returned
garbage). Register map and sequences: Linux `dw_mmc.h/.c`. U-Boot leaves
the controller unused (PWREN/CLKENA 0). About 2.9 MB/s both ways.

| | |
|---|---|
| card | Samsung (MID `0xEC`) "A31M8C", EXT_CSD rev 8, 122142720 sectors (58.24 GiB) |
| GPT | 1 u-boot-spl (4096..8191), 2 u-boot (8192..16383), 3 EFI System vfat (16384..221183), 4 Linux root (221184..109928447, to 52.42 GiB) |
| test area | after the highest partition, before the backup GPT minus 1 MiB: LBA 109928448..122138623 = 5962 MiB (`test/visionfive2-lite/include/emmc-area.hpp`). The space from 40 GiB is **not** free: the Linux root reaches 52.42 GiB |
| emmc-probe | read only (its image has no `emmc::write`): card, GPT, partitions, the area -- PASS |
| emmc-fs-test | FatFs 0.13.1 (core copied from the harness xPack, `emmc-fs-test/fatfs/`, without the xPack's `FF_FS_POSIX_INTEGRATION`) on the area, FAT32, 32 KiB clusters; the disk layer refuses any sector outside it; formats only when no filesystem is there; `RUNS.TXT` counts the runs; text, 64 KiB and 1 MiB files written, read back, listed, deleted, re-read after a remount; both GPT copies, partitions 1-2, the first 4 MiB of the vfat partition and the first and last MiB of the Linux root are hashed before and after: unchanged. Runs 1 (formatted), 2 and 3 (harness) PASS, hash `02a3425c229d9a83` every time. The partition table is not written: Linux does not see this filesystem |

USB device (2026-11-07) on the **USB-C connector** (the board's power input):
schematic page 22, J13's data pins go to HSD2 of U27 (FSUSB42 2:1 switch),
whose common side is the JH-7110's USB 2.0 PHY; SEL = **GPIO62**: 0 = the
USB-A hub (Linux: `dr_mode = "host"`), 1 = the USB-C. The controller is the
Cadence USBSS-DRD (`usb@10100000`, OTG DID `0x0004024e` = cdns3 v1, device
controller version `0x0002450d`). TinyUSB has no Cadence driver:
`test/boards/visionfive2-lite/usb/cdns3/dcd_cdns3.c` is one, from Linux's
`cdns3-gadget.c` / `cdns3-ep0.c` (polled, full speed forced, EP0 through a
2-TRB pool with the controller's own STATUS stage behind `EP_CMD_REQ_CMPL`,
data endpoints on small TRB rings closed by a LINK TRB, transfers held until
`USB_CONF_CFGSET`), registered in the local TinyUSB as `OPT_MCU_JH7110`.

| | |
|---|---|
| bring-up | `usb/vf2-usb.cpp`, each step from Linux and measured: stg_syscon+4 PLL/refclk/suspend-bypass + strap DEVICE, STG clocks 1..6 on, resets 7..10 released, PHY RX power + LS keep-alive off + `USB_PDRSTN_SPLIT`, OTG `DEV_BUS_REQ \| OTG_DIS` until `DEV_READY`, GPIO62 = 1. A block left running by the previous image is first disconnected (`DEVDS`, 200 ms) and put back in reset: without it the PC never saw a disconnect between runs and did not re-enumerate |
| DMA | not cache-coherent on the JH-7110 (Linux: the L2 controller's `FLUSH64` for every DMA sync): every TRB and buffer goes through `vf2_dcache_flush()`; TinyUSB buffers are 64-byte aligned (`CFG_TUSB_MEM_ALIGN`) |
| smp-test-usb-cdc-acm | CDC-ACM `Cafe:4013`, line echo, PASS on Escape; host `test/boards/pico2/usb-host.py cdc`. Passed (enumeration, echo both ways); with the shared line-buffered glue a PC-side tty echo in the instant before the port goes raw can feed the board's own text back and replace the line (measured: rx_line = "[cdc] mounted") |
| smp-test-usb-cdc-file | binary CDC, no echo: the PC sends `name.dat` (1 MiB), the board keeps it in DDR (4 MiB buffer), returns it with its CRC-32, the PC saves `name.dat.back`, compares and answers K/X. Host: `smp-test-usb-cdc-file/usb-file-host.py`. Run twice: **PASS**, identical, CRC `1dca192b`; PC to board 434 KiB/s, board to PC 853 KiB/s (full speed, 64-byte transfers) |
| run | `hw.sh smp-test-usb-cdc-file 300 &`, then, once the UART shows `[usb] mounted`, `cd test/visionfive2-lite/smp-test-usb-cdc-file && python3 usb-file-host.py name.dat` |
| smp-test-usb-cdc-file-fs | the same round trip **through the eMMC**: the PC sends `name.dat` with its name (`UOSN`), the board writes it to `/usb/name.dat` on the FAT filesystem in the eMMC area (emmc-area.hpp, the disk layer limited to it), unmounts, clears the DDR buffer, mounts again, reads the file back from the card and sends that; the UART lists the whole filesystem before and after. Host: `smp-test-usb-cdc-file-fs/usb-file-host.py`. **PASS**: identical, CRC `1dca192b` at every step; USB in 537 KiB/s, eMMC write 2.9 MB/s, read 3.0 MB/s, USB out 854 KiB/s; protected-sector hash `02a3425c229d9a83` unchanged |
| vf2-wifi-ram-disk | files **over Wi-Fi into a 512 MiB RAM disk**: smp-wifi's AIC8800 (SDIO1) + WPA2 + lwIP code, unchanged, plus a RAM disk at `0x60000000..0x7fffffff` (FatFs drive 0, FAT32, 4 KiB clusters, created at start; a probe checks the 512 MiB are distinct memory) and a TCP file server on port 5000 with the MangoPi MQ-Pro's protocol (`ls df put get rm format`, plus `verdict`). The board joins with the build's `WIFI_TEST_SSID`/`WIFI_TEST_PASS`, then broadcasts `VF2-RAM-DISK <ip> 5000` on UDP 5001 once a second. After a `put` it re-reads the file through FatFs and returns that CRC-32. The radio thread [cpu 1] owns lwIP and FatFs; blink [2], stats + 600 s watchdog [3]. Host: `vf2-wifi-ram-disk/vf2-wifi-ram-disk-host.py` runs `hw.sh`, finds the board (beacon, or a /24 scan for TCP 5000 when a firewall such as ufw drops the broadcast), sends the files, lists the disk, reads each back as `<file>.bak`, compares SHA-256 and sends the verdict; the board then prints RESULT. UART0 is never read. **PASS** (2026-11-11, Pico probe): beacon 29.7 s after the start (load + radio + join + DHCP), 128 KiB / 857 KiB / 2 MiB stored at 1440 / 1412 / 1555 KiB/s with matching CRC-32 (`6240cbac`, `f440ff5a`, random), read back at 92 / 584 / 3621 KiB/s (the small first `get` is TCP slow start on the board's side), SHA-256 identical; 0 SDIO I/O errors, 0 timeouts; threads on harts 1/2/3/0; whole run 38.5 s |
| run | board at the U-Boot prompt; build in `test/build-vf2-wifi` (configured with `-DWIFI_TEST_SSID=... -DWIFI_TEST_PASS=...`), `ninja -C test/build-vf2-wifi vf2-wifi-ram-disk-hwd`, then `test/visionfive2-lite/vf2-wifi-ram-disk/vf2-wifi-ram-disk-host.py file1 file2 --random 2097152` (it calls hw.sh itself; `--no-load` / `--host IP` if the test is already running) |
| smp-net-ram-disk | the same RAM-disk file transfer **over Ethernet** (GMAC0, no Wi-Fi, no USB console): the GMAC driver and lwIP glue of smp-test-usb-cdc-net, unchanged, plus the RAM disk and file server shared with vf2-wifi-ram-disk (`ram-disk.cpp`, `file-server.cpp` in that directory). Beacon `VF2-NET-RAM-DISK <ip> 5000` on UDP 5001. Threads: eth-rx [cpu 1] (the file server's TCP callbacks and every FatFs call run here, inside `net_lwip::input()`), net [2] (lwIP timers, the beacon, carrier), app [3] (carrier, DHCP, wait for the verdict), stats and a 600 s watchdog [0]. lwIP and FatFs are serialised by net-lwip.cpp's one lwIP mutex: the server does nothing outside lwIP callbacks and timers. Host: `smp-net-ram-disk/smp-net-ram-disk-host.py` (the same runner as vf2-wifi-ram-disk). Diagnostic build options, off by default: `NET_RAMDISK_DHCP_TRACE` (lwIP DHCP_DEBUG + every received DHCP frame decoded) and `NET_RAMDISK_FALLBACK_IP` (a fixed address after a failed DHCP; the verdict stays FAIL). It needed the MAC speed/duplex fix (fe5f6ff): before it, every DHCP DISCOVER left the DMA without reaching the wire. **PASS** (2026-11-11): board on the LAN 10.1 s after the start, 128 KiB / 857 KiB / 2 MiB stored at 11.0 / 14.4 / 13.9 MiB/s with matching CRC-32, read back at 12.1 / 29.7 / 32.0 MiB/s, SHA-256 identical; gmac err 0/0, unf 0, ovf 0; whole run 12 s |
| run | board at the U-Boot prompt, Ethernet cabled to the LAN; `ninja -C test/build-vf2 smp-net-ram-disk-hwd`, then `test/visionfive2-lite/smp-net-ram-disk/smp-net-ram-disk-host.py file1 file2 --random 2097152` |

The same RAM-disk file transfer runs on the **MangoPi MQ-Pro** over its Wi-Fi
(RTL8723DS), as `test/mangopi-mq-pro/wifi-ram-disk` (PASS, 1.2–1.8 MiB/s both
ways; `mangopi-mq-pro.md`, section 9b), with the same RAM disk, file server
and PC runner.

#### vf2-wifi-ram-disk / smp-net-ram-disk: the PC scripts

Both live in `test/visionfive2-lite/vf2-wifi-ram-disk/` and run on the PC,
not on the board. Neither opens the UART (`ttyACM0` stays the user's
console); everything goes over JTAG (hw.sh) and Wi-Fi.

| script | what it is | what it does |
|---|---|---|
| `wifi_fs.py` | the **file-transfer client** (a tool and a Python class, `wifi_fs.Board`) | connects to the board on TCP 5000 and speaks its file protocol: `ls`, `df`, `put`, `get`, `rm`, `format`, `verdict`. After a `put` it checks the CRC-32 the board computed from the *stored* file; after a `get` it checks the received data against the board's CRC-32. A copy of the MangoPi MQ-Pro's `host/wifi_fs.py` (same protocol), with `verdict` added |
| `vf2-wifi-ram-disk-host.py` | the **test runner**: the whole test in one command, using `wifi_fs.py` for every transfer | 1. starts `hw.sh` (JTAG load into DDR);<br>2. finds the board: its UDP broadcast on port 5001 (`VF2-RAM-DISK <ip> 5000`), or, if a host firewall such as ufw drops it, a scan of the local /24 for a host answering the file protocol on TCP 5000;<br>3. uploads every file to the RAM disk;<br>4. lists the RAM disk and checks every name and size;<br>5. downloads every file back as `<file>.bak` next to the original and compares SHA-256;<br>6. sends `verdict PASS\|FAIL <summary>`: the board prints `RESULT` and makes its semihosting exit;<br>7. waits for `hw.sh` and prints its verdict line. Exit status 0 only when the transfers verified **and** hw.sh reported PASS |

In short: `wifi_fs.py` is the tool, `vf2-wifi-ram-disk-host.py` is the test
that uses it.  `smp-net-ram-disk/smp-net-ram-disk-host.py` is a small wrapper
that runs the same runner for the Ethernet test (test name
`smp-net-ram-disk`, beacon tag `VF2-NET-RAM-DISK`, build directory
`test/build-vf2`); `wifi_fs.py` works unchanged over Ethernet.  The MangoPi's
`test/mangopi-mq-pro/wifi-ram-disk/wifi-ram-disk-host.py` is the same kind of
wrapper (board `mangopi-mq-pro`, whose `hw.sh` loads over xfel; beacon tag
`MQPRO-RAM-DISK`; build directory `test/build-mqpro`).

```sh
# the whole test (board at the U-Boot prompt)
test/visionfive2-lite/vf2-wifi-ram-disk/vf2-wifi-ram-disk-host.py \
    test.bin photo.png --random 2097152

#   --no-load     the board test is already running (do not call hw.sh)
#   --host IP     skip the search, use this address
#   --build DIR   build directory (default test/build-vf2-wifi)
#   --keep        leave the files on the RAM disk

# the tool alone, while the test runs on the board
cd test/visionfive2-lite/vf2-wifi-ram-disk
python3 wifi_fs.py -H 192.168.1.128 df
python3 wifi_fs.py -H 192.168.1.128 put photo.png
python3 wifi_fs.py -H 192.168.1.128 ls
python3 wifi_fs.py -H 192.168.1.128 get photo.png copy.png
python3 wifi_fs.py -H 192.168.1.128 rm photo.png
```

The board ends its run only on a `verdict` (or after its 600 s watchdog),
so when `wifi_fs.py` is used by hand the test keeps serving until then.

Before (2026-11-06, DAPLink, 11/11 PASS):
- SMP on the four U74 (`OS_NCPU = 4`):
  - **smp-test2**: one worker per core, every beat read from mhartid on its
    own hart (8/8 each), global 32;
  - **smp-mat-test** (N = 240, B = 30, 8 blocks): solvers c0..c3 on mhartid
    1..4, parallel 15.9 ms against classical 60.3 ms on core 0 (**3.80x**),
    max difference 0. (The thread pool then ran all 20 tasks on CPU 0: its
    workers were pinned only after creation; fixed 2026-11-07.) (N = 200,
    B = 50: 12.6 ms against 34.8 ms, 2.76x.)
- One hart (`OS_NCPU = 1`): smp_test0 (4 back-to-back runs), semihosting-test,
  clock-test, clock-catchup (sysclock 1500 ms vs mtime 1499 ms), mmu-test,
  exc-test (50 illegal + 50 ecall traps, registers intact), mos-test1,
  sc-test-ko, smp-test1.
- A run takes 1..7 min, mostly the console over semihosting (~0.8 s per line
  with this probe); the image load is 13..17 s (only the loadable part).
- The port changes for it (`RISCV_HART_BASE`, the FPU on every hart before
  the park, `port_secondary_stack_top()`) leave the other boards as they
  were: Duo QEMU 11/11, Pico 2 QEMU 4/4 (2-hart SMP included).

RV32 (phase 1 of the Pico 2 port): the Duo's tests built for the RV32 stand-in
(`test/build-rv32`): **7 passed, mmu-test skipped** (no MMU on RV32). RV64
unchanged: port 8/8, harness 14/14.

SMP (phase 2): board `pico2` (emulated only so far), `smp-test2` ported from
the Cortex-M Pico 2 test, on `qemu-system-riscv32 -smp 2`: **PASS 8/8**
(both workers, 40 handoffs, worker 1 on hart 1). Single-hart builds
unchanged (RV64 8/8, RV32 7 + skip, harness 14/14).

Pico 2 hardware (phase 3, Raspberry Pi Debug Probe): **`smp-test2` PASS,
twice in a row** -- worker 0 on core 0 and worker 1 on core 1, 20 rounds
each, 40 handoffs, exit 0. A worker's lines are ~650 ms apart in RTOS time on
the board against 500 ms on QEMU (cause not measured yet).

Phase 4 (porting the Cortex-M Pico 2 tests to the Hazard3 board), on the
Pico 2 (Raspberry Pi Debug Probe), one run after the semihosting change:

| test | cores | Pico 2 | QEMU |
|---|---|---|---|
| sc-test-ko | 1 | **PASS** | PASS |
| smp-test1 | 1 | **PASS** | PASS |
| smp-test2 | 2 | **PASS** | PASS |
| smp-test3 | 2 | **PASS** | hw only |
| smp-test4 | 2 | **PASS** | hw only |
| smp-test5 | 2 | **PASS** -- UART0 IRQ 33 on core 1 through Xh3irq, 48848 bytes, 0 dropped | hw only |
| smp-test-ko | 2 | **PASS** | hw only |
| smp-mat-test | 2 | **PASS** -- 120x120, block == classical, 1.373x on 2 cores | hw only |
| exc-test (the RISC-V one) | 1 | **PASS** | PASS |
| fp-switch (harness) | 1 | **PASS** | PASS |
| mutex-stress (harness) | 1 | **PASS** | PASS |
| rtos-apis (harness) | 1 | **PASS** (96 KiB arena, no FatFs) | PASS |
| cmsis-os-validator (harness) | 1 | **PASS** | PASS |
| smp-test0 (bare, no kernel) | 2 | **PASS** -- 5 KiB image, core 1 launched and blinking | hw only |
| smp-mat-test-ram | 2 | **PASS** from SRAM | hw only |
| mutex-stress-ram (harness) | 1 | **PASS** from SRAM | hw only |
| rtos-apis-ram (harness) | 1 | **PASS** from SRAM | hw only |
| cmsis-os-validator-ram (harness) | 1 | **PASS** from SRAM | hw only |

| smp-test-usb-cdc-acm | 2 | **PASS** -- enumerates as `cafe:4013`, echoes the host's line, Escape ends it | hw only |
| smp-test-usb-hid | 2 | **PASS** -- enumerates as `cafe:4012`, HID OUTPUT reports, Escape ends it | hw only |

**All 20 Cortex-M Pico 2 tests pass on the RISC-V Pico 2.** Since then:
`smp-test-nested` (nested Xh3irq interrupts, ported from the RP2350B's
Cortex-M test) **PASS** on the Pico 2 -- `wrk0=20 wrk1=20 uart=11 t2=32
t3=16 t2_in_uart=11` (alarm 2 preempted all 11 UART handler runs) -- and
smp-mat-test **PASS** with the `rv32imc` libraries (6 s for the whole run,
26 s before).

WeAct RP2350B (2026-11-06, probe c251:f001):

| test | cores | RP2350B | notes |
|---|---|---|---|
| sc-test-ko | 1 | **PASS** | |
| exc-test | 1 | **PASS** | |
| smp-test0 (bare) | 2 | **PASS** | |
| smp-test1 | 1 | **PASS** | |
| smp-test2 | 2 | **PASS** | |
| smp-test3 | 2 | **PASS** | |
| smp-test4 | 2 | **PASS** | |
| smp-test5 | 2 | **PASS** | UART0 on GPIO12/13 |
| smp-test-ko | 2 | **PASS** | |
| smp-test-nested | 2 | **PASS** | `t2_in_uart=11` |
| smp-mat-test | 2 | **PASS** | N=300, B=50, matrices in PSRAM, 150 MHz: parallel 14.44 s, classical 23.95 s, 1.66x |
| smp-mat-test_200 | 2 | **PASS** | the same at a fixed 200 MHz (PSRAM 100 MHz); not a Cortex-M test |
| smp-mat-test_250 | 2 | **PASS** | the same at a fixed 250 MHz, 1.25 V (PSRAM 83 MHz); not a Cortex-M test |
| smp-test-nested-clock_200 | 2 | **PASS** (UART) | N=500; pot -> 200 MHz, `y`, watchdog reboot, solver + nested IRQs |
| smp-test-nested-clock_250 | 2 | **PASS** (UART) | N=800; pot -> **250 MHz** overclock, `y`, reboot, solver + nested IRQs |
| smp-test-nested-clock | 2 | not run yet | N=1000 (4 MB in place) |
| psram-exec (bare) | 1 | **PASS** (UART, interactive) | the Cortex-M pico2-pizero board's (the predecessor's `pizero-psram-exec*`): a supervisor copies two self-contained applications into the PSRAM (staged through SRAM, retried until verified, XIP cache cleaned + invalidated) and switches between them on ESC; `x` ends it. RISC-V: Arm's vector table + `VTOR` become a header `{magic, entry, trap}`, `mtvec` = the application's own trap handler while it runs, the entry called through a register; each application takes an `ecall` into its PSRAM trap handler. The disassembly shows no call or address leaving the PSRAM |
| smp-test-xip | 2 | **PASS** | from the predecessor (not in the Cortex-M repo): erase a FLASH_FS sector (reads 0xFF), program a page (reads back through XIP), then core 1 runs |
| smp-test-xip-core1park | 2 | **PASS** | 4/4 rounds of erase + program while core 1 runs from flash, parked in SRAM for each write; its counter moved every round |
| smp-test-xip-fs | 2 | **PASS** | the predecessor's append-log flat-fs (`fs-archive.cpp`, unchanged) on the writer: format, three files added, listed, CRC-32 and bytes checked through XIP, found by name. The predecessor's XIP-classifier step (it parses the stored files as ARM `.so` modules) moves to the loader stage; the three files are kept as payloads |
| fp-switch (harness) | 1 | not run yet | built (the kernel suite through the port tree); the kernel-harness platform is not added yet |

The first eleven passed twice: once with the `rv32ia` libraries and again with
`rv32imc`, both before the clock driver was extended. **Not rerun since that
change** (the clock table, the raise-only QSPI dividers, the UART divider from
the running clock): those eleven and the Pico 2's tests. The flash
group is from the predecessor project (`micro-os-plus-iii-pico2`); its loader
tests (`smp-test-loader-*`, `smp-test-xip-loader-*`) are not ported yet;
the pico2-pizero board's `psram-mat-test-250` (the arrays alone in the PSRAM,
a workaround for that board's PSRAM) is left out -- smp-mat-test and `_250`
cover it here. After the RX FIFO fix in `psram.cpp`, smp-mat-test passed
again; the other PSRAM-data tests were not rerun. One
`smp-test-nested-clock_200` run trapped on the second boot after the reboot
(mcause 2, mepc 0, ra 0, on the boot stack); the next run passed. Not
root-caused; the extended trap report is for the next occurrence.

**USB** (`test/boards/pico2/usb/`): TinyUSB, its RP2040/RP2350 device driver
and the pico-sdk shim, as the Cortex-M board carries them, with the Arm parts
made RISC-V (barriers -> `fence`, PRIMASK critical sections -> `mstatus.MIE`,
`sev` -> `h3.unblock`); the USB IRQ goes through Xh3irq; `clocks::usb_init()`
(PLL_USB -> 48 MHz). Linked only into the two USB tests. The Pico 2 has no
WS2812 (the Cortex-M CDC test was brought up on an RP2350B-MINI-A), so
`ws2812.hpp`'s stubs stand in. The Pico 2's own micro-USB must be connected to
the PC.

The PC's half: `test/boards/pico2/usb-host.py cdc|hid` waits for the device,
then sends a line and Escape -- on the CDC tty (Escape **followed by Return**:
the test reads lines), or as HID OUTPUT reports (`{length, chars}`, 64 bytes,
pyusb; detaching `usbhid` usually needs `sudo` or a udev rule). `hw.sh` starts
it for the two USB tests; `HOST_HELPER=0` leaves it to you.

**Bare runtime** (`micro-os-plus::riscv-bare`, for `BOARD_TEST_NO_KERNEL`):
the board, `startup.S`, `trap.S` and `src/bare/runtime.cpp` -- start-up hooks
that only bring the board up, the static constructors, `_exit` -> semihosting,
and a trap dispatcher with semihosting, the exception hook, the board's
external interrupts and the fault report (no tick, no switch); the test
support headers without the board contract.

**`-ram` tests**: `<name>-ram` is `<name>` linked by `linker-ram.ld`
(everything in SRAM, no IMAGE_DEF, no `.data` copy). `hw.sh` picks the session
from the image's entry: in SRAM -> `reset init`, OpenOCD's work area moved
into the image's NOLOAD heap (0x20078000), `load_image`, `verify_image`,
`reg pc <entry>` on core 0, semihosting on both, `resume`; core 1 stays in
the boot ROM until launched. Nothing is written to flash (smp-mat-test-ram:
92 KiB loaded in 0.66 s).

Porting changes: `bsp/` headers -> the board's; Arm idle `dsb`/`wfi` -> yield
only; `dmb`/`__DMB` -> `fence rw, rw`; smp-mat-test's configuration-error
`wfi` parks end the run with FAIL, and it prints every tenth element of the
solution (all 120 are still compared) -- printing all of them cost one
semihosting round trip per call and once ended with the debug module lost
after line 114 (`halted due to undefined`, `dmcontrol=0x0`; not explained
yet). `hw.sh`'s stale-image check was narrowed (both boards) to the port,
the board and the test's own sources: another test's edit made every image
look stale. Its limit, measured: a NEW header that shadows an old one (the
board's os-app-config.h) changes no recorded dependency, so ninja does not
rebuild and the check passes on a stale image -- clean the target
(`ninja -t clean <app>-hwd`) after adding such a header.

Found on the way, in the runner: `qemu.sh` ran under `pipefail` and tested the
image with `nm ... | grep -q`. `grep -q` exits at the first match, `nm` then
dies of SIGPIPE, and the test reads false -- intermittently. SMP images were
started with `-smp 1` in 3 runs of 5 and hart 1 never existed. The pipes now
read to the end.

Kernel harness, QEMU virt (`xpm run test --config ...`):

| config | result |
|---|---|
| `riscv-milkv-duo-cmake-gcc-release` | **14/14 passed** |
| `riscv-milkv-duo-cmake-gcc-debug` | 13/14 -- all but `cmsis-os-validator` in that run |

`cmsis-os-validator` passed all 60 cases in 3 of the 5 runs made with the
current port. Its thread-to-ISR cases (`TC_MsgFromThreadToISR`,
`TC_MailFromThreadToISR`) are intermittent: when the ISR's sequence counter
gets out of step with the thread's, every later message fails (a hang until
the timeout), or the validator's debug `printf` inside the ISR aborts on
`malloc`. The same cases fail intermittently on the Arm boards (their saved
logs show `!PASSED` in several runs). Not yet root-caused.

QEMU after the `ecall` switch: port tree 8/8, harness release 14/14.

Hardware, Milk-V Duo, full run (`hw-all.sh`, `RESET=wdt`: BL2 watchdog reset
and 4 s of boot before every test), every test ending in its semihosting exit
with code 0:

| test | port tree | harness |
|---|---|---|
| blinky | -- | **PASS** |
| clock-test | **PASS** | **PASS** |
| cmsis-os-validator | -- | **PASS** |
| exc-test | **PASS** | **PASS** |
| fp-switch | -- | **PASS** |
| instrumentation | -- | **PASS** |
| mmu-test | **PASS** | **PASS** |
| mos-test1 | **PASS** | **PASS** |
| mutex-ceiling-test | **PASS** | **PASS** |
| mutex-stress | -- | **PASS** |
| rtos-apis | -- | **PASS** |
| sc-test-ko | **PASS** | **PASS** |
| semihosting-test | **PASS** | **PASS** |
| smp_test0 | **PASS** | **PASS** |
| total | **8/8** (228 s) | **14/14** (606 s) |

What the first full run found, fixed since: `mmu-test` (C906 MAEE page
attributes), `rtos-apis` (tick-handler overrun; semihosting from a trap),
`semihosting-test` (OpenOCD's SYS_ERRNO starts at -1). See *The port*.

Seen during the run, not a failure: OpenOCD logged `dmstatus=0x0` ("Debug
Module version 0") once in `mutex-stress` and once in `rtos-apis`, the two
tests with the most semihosting traffic; it recovered and both passed.

Before the switch rewrite every blocking test stopped at its first blocking
call (the MSIP window described under *The port*).

Hardware, Milk-V Duo, 2026-11-06, after the RV32/SMP, nested-interrupt, AMO,
start-up-hook changes and the tick catch-up, every test ending in its
semihosting exit 0 (`RESET=0`, back to back): **port tree 12/12** (368 s; the
8 above + clock-catchup, smp-test1, smp-mat-test, smp-test-nested) and
**harness 18/18** (757 s; the 14 + the four, rtos-apis included). Earlier the
same day, before the new tests: port 8/8, harness 14/14.

USB on the Milk-V Duo (`test/boards/milkv-duo/usb/`, 2026-11-06):
**`smp-test-usb-cdc-acm` PASS** (`cafe:4013`, `/dev/ttyACM1`, full banner +
line echo, Escape, exit 0) and **`smp-test-usb-hid` PASS** (`cafe:4012`,
64-byte HID OUTPUT reports, Escape, exit 0) with `test/boards/pico2/usb-host.py`
-- **port tree 14/14** on the Duo. Found and fixed during the DWC2 bring-up:

- **CV1800B DWC2 v4.20a slave mode (`dcd_dwc2.c`)**: `GUSBCFG`
  (`ForceDevMode | (1 << 19) | (5 << TRDT) | PHYIF16`) must be written
  immediately after `dwc2_core_init()` *before* sizing/flushing FIFOs or
  programming device registers (as BL2's `dwc2_reconfig_usbd()` does);
  `dfifo_device_init()` statically programs `GRXFSIZ = 0x400`,
  `DIEPTXF0 = 0x00400400` and `DIEPTXF[0..6]` above `0x440` before flushing,
  and `dfifo_alloc()` is a no-op so `SET_CONFIGURATION` does not rewrite
  `DIEPTXFn` live without a FIFO flush; `DOEPTSIZ0` uses `STUPCNT = 1` and
  `handle_bus_reset()` does not re-flush FIFOs; `dcd_int_handler()` pops one
  packet per `GINTSTS_RXFLVL` interrupt (polling `GRXSTSP` in a tight `do/while`
  underflowed into 32-entry phantom `6/ep0/8` bursts); `dcd_init()` holds
  `DCTL_SDIS` for 300 ms so the upstream hub tears down any prior enumeration.
- **PLIC IRQ 30 starvation (`osal_none.h`)**: `osal_queue_receive()` disabled
  and re-enabled the USB IRQ on every empty-queue poll; preempted by the 1000 Hz
  tick while `usb_device_task` had `plic_en = 0`, PLIC source 30 stayed masked
  throughout UART/semihosting prints. `osal_queue_receive()` now returns `false`
  immediately when `tu_fifo_empty(&qhdl->ff)` is true, and `usb_device_task`
  guards `tud_task()` with `tud_task_event_ready()`.
- **Post-reset SETUP drop (`usbd.c`)**: `usbd_reset()` zeroed
  `_usbd_queued_setup` when `DCD_EVENT_BUS_RESET` was dequeued from `_usbd_q`,
  which wiped the count of post-reset `DCD_EVENT_SETUP_RECEIVED` events already
  queued behind `DCD_EVENT_BUS_RESET` in the FIFO and caused `tud_task()` to
  discard `GET_DESCRIPTOR`.
- **Host helper timing (`milkv-duo/hw.sh`)**: JTAG `halt` stops the C906 core
  without resetting the DWC2 peripheral, so a previous run's `/dev/ttyACM*`
  stays alive during OpenOCD's 2.2 s `load_image`; `hw.sh` starts `usb-host.py`
  only once `[usb] tusb_init done` appears in the log.

Found on the way: the tick dropped missed periods -- smp-test-nested measured
`sysclock` 19 s against 45 s of `rdtime` and DW timer (semihosting halts the
hart for every console line); fixed by the catch-up above, then
`elapsed: DW timer 34066 ms, rdtime 34066 ms, sysclock 34067 ms`. And twice
the same C++ trap: `(void) reg (addr);` on a `volatile` reference performs
**no load** (GCC: "conversion to void will not access object") -- the DW
timer's EOI was never read, its interrupt stayed asserted and the hart lived
in the dispatcher (the PSRAM driver's RX-FIFO pop had the same fault); the
reads go through a helper now, and no build gives the warning.

The Duo's JTAG watchdog reset is not always enough: after a hang, or a
failed reset, the JTAG chain reads all ones until a hand power cycle (pin 30
RUN to 3V3 would do it, see the facts table).

### What the RISC-V port found in the shared code

The first 64-bit, first non-Arm run of several suites; fixed on the kernel's
local `riscv` branch:

- `src/diag/trace.cpp`: the alias mangling assumed Arm's `va_list`.
- `tests/sources/instrumentation`: a message queue of `sizeof (int)` slots,
  below the kernel's `sizeof (void*)` minimum on 64-bit.
- `tests/sources/mutex-stress`: a 4000-byte main stack, too small for RV64
  (8-byte registers, 528-byte trap frames).
- `tests/sources/rtos-apis`: its C-API block test opened `/dev/mb2`, a device
  that does not exist (`mb-p2`); every Arm platform defines
  `OS_USE_SEMIHOSTING_SYSCALLS`, so the block had never been compiled.
