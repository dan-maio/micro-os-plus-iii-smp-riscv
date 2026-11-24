/*
 * startup.S -- reset entry of a µOS++ RISC-V image (machine mode, hart 0).
 *
 * On the Milk-V Duo this is NOT the reset vector: the boot ROM, the FSBL and
 * the minimal fip.bin have already brought up the clocks, DDR and UART4, and
 * OpenOCD loads the image into DDR and sets the PC here (test/boards/
 * milkv-duo/hw.sh). Under QEMU (-bios none) the virt machine starts here.
 * Either way the state left by whoever ran before is distrusted: interrupts
 * off, our own trap vector, our own stack, .bss cleared.
 *
 * Copyright (c) 2026 Dan. MIT license.
 */

	.section .text.entry, "ax"
#include <port_ctx.hpp>

	.globl	_start
	.type	_start, @function
_start:
	/* Interrupts off, every source off, nothing pending we caused. */
	csrci	mstatus, 8
	csrw	mie, zero

	/* Our trap vector (direct mode). */
	la	t0, riscv_trap_entry
	csrw	mtvec, t0

	.option push
	.option norelax
	la	gp, __global_pointer$
	.option pop
	mv	tp, zero

	/* MPRV off; with an FPU: FPU on (FS = Initial), clean rounding state.
	 * On EVERY hart, before the secondaries park: the trap entry saves the
	 * FP registers, so a secondary with FS = Off would take an illegal
	 * instruction on its first trap (an FPU SMP board: the U74s). */
	li	t0, (1 << 17)
	csrc	mstatus, t0
#if defined(__riscv_flen)
	li	t0, (3 << 13)
	csrc	mstatus, t0
	li	t0, (1 << 13)
	csrs	mstatus, t0
	fscsr	zero
#endif

	/* The image was just written by the debugger: drop stale I-cache lines
	 * (each hart has its own I-cache). */
	fence.i

#if defined(OS_NCPU) && (OS_NCPU > 1)
	/* Every hart but CPU 0 (mhartid RISCV_HART_BASE) waits to be released
	 * (riscv_secondary_park). */
	csrr	t0, mhartid
	li	t1, RISCV_HART_BASE
	bne	t0, t1, riscv_secondary_park
#endif

	/* The boot stack: main() runs on it until the scheduler starts. */
	la	sp, __stack_top

	/* External memory before anything is written to it: a board whose
	 * .data/.bss live outside on-chip RAM (the RP2350B's QSPI PSRAM)
	 * brings that memory up here, on the boot stack, with nothing of .data
	 * or .bss usable yet. The default does nothing. */
	call	riscv_board_initialize_memory

	/* .data from its load address, for an image that runs from flash (the
	 * Pico 2); an image loaded into RAM has them equal and skips this. */
	la	t0, __data_load
	la	t1, __data_start
	la	t2, __data_end
	beq	t0, t1, 2f
1:	bgeu	t1, t2, 2f
	lw	t3, 0(t0)
	sw	t3, 0(t1)
	addi	t0, t0, 4
	addi	t1, t1, 4
	j	1b
2:
	/* Zero .bss (a register at a time; the linker aligns both ends). */
	la	t0, __bss_start
	la	t1, __bss_end
1:	bgeu	t0, t1, 2f
	REG_S	zero, 0(t0)
	addi	t0, t0, PORT_REGBYTES
	j	1b
2:
	call	os_startup_initialize_hardware_early
	call	os_startup_initialize_hardware
	call	os_run_init_array

	li	a0, 0
	li	a1, 0
	call	main
	call	exit

3:	j	3b
	.size	_start, . - _start

/* The default memory hook: nothing outside on-chip RAM to bring up. A board
 * overrides it (test/boards/pico2/src/psram.cpp with PICO2_PSRAM). */
	.weak	riscv_board_initialize_memory
	.type	riscv_board_initialize_memory, @function
riscv_board_initialize_memory:
	ret
	.size	riscv_board_initialize_memory, . - riscv_board_initialize_memory

#if defined(OS_NCPU) && (OS_NCPU > 1)
/* A secondary hart that entered at _start (QEMU virt with -bios none starts
 * every hart there). mtvec and gp are set; interrupts are off. It waits on
 * its slot in riscv_secondary_boot[] -- { magic, entry, sp }, XLEN words --
 * until hart 0 writes the entry and the stack and then the magic
 * (riscv_smp_release_hart(), os-core.cpp), and jumps to the entry on that
 * stack. It reads nothing else: hart 0 is meanwhile zeroing .bss (the slot
 * included) and running the constructors. A hart this build does not drive
 * (CPU index mhartid - RISCV_HART_BASE outside 0..OS_NCPU-1; below the base
 * the subtraction wraps and the unsigned compare parks it too) stays
 * parked. No wfi, as everywhere in this port.
 *
 * The slot must not hold a stale magic when a hart arrives here: QEMU's RAM
 * starts zeroed; on a board whose DDR keeps the previous run, the loader
 * clears riscv_secondary_boot[] before it starts the harts
 * (test/boards/visionfive2-lite/hw.sh). */
	.globl	riscv_secondary_park
	.type	riscv_secondary_park, @function
riscv_secondary_park:
	csrr	t0, mhartid
	addi	t0, t0, -RISCV_HART_BASE
	li	t1, OS_NCPU
	bgeu	t0, t1, 9f
	li	t1, (3 * PORT_REGBYTES)
	mul	t0, t0, t1
	la	t1, riscv_secondary_boot
	add	t0, t0, t1
	li	t2, RISCV_SECONDARY_MAGIC
1:	REG_L	t1, 0(t0)
	bne	t1, t2, 1b
	fence	r, r
	REG_L	sp, (2 * PORT_REGBYTES)(t0)
	REG_L	t1, PORT_REGBYTES(t0)
	fence.i
	jr	t1
9:	j	9b
	.size	riscv_secondary_park, . - riscv_secondary_park

	.section .bss
	.balign 16
	.globl	riscv_secondary_boot
	.type	riscv_secondary_boot, @object
riscv_secondary_boot:
	.space	(3 * PORT_REGBYTES * OS_NCPU)
	.size	riscv_secondary_boot, (3 * PORT_REGBYTES * OS_NCPU)
#endif
