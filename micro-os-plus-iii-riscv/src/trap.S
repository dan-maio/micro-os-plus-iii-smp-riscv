/*
 * trap.S -- the RISC-V port's single trap entry (machine mode, direct mtvec).
 *
 * Every interrupt and exception comes here. The frame (port_ctx.hpp) is
 * built on the stack that was interrupted -- the running thread's -- and
 * the C dispatcher runs on the interrupt stack. The dispatcher returns the
 * frame to resume: the same one, or the incoming thread's (a thread's yield
 * ecall, or a trap that made another thread due). Restoring from a
 * different frame IS the context switch.
 *
 * Interrupts stay masked for the whole trap (mstatus.MIE is cleared by the
 * hardware on entry and comes back from MPIE on mret), so interrupts never
 * nest; only an exception inside a handler can (nesting 2), and such a trap
 * never switches. riscv_trap_nesting is what in_handler_mode() reads.
 *
 * On a QingKe PFIC board (RISCV_PFIC) the hardware nests interrupts and
 * leaves MIE set: a more urgent interrupt can preempt this code anywhere,
 * on the same stack (it saves below sp). The nesting count is then the
 * interrupt depth, and only the software interrupt switches threads.
 *
 * Copyright (c) 2026 Dan. MIT license.
 */

#include <port_ctx.hpp>

	.section .text.trap, "ax"
	.balign 64
	.globl	riscv_trap_entry
	.type	riscv_trap_entry, @function
riscv_trap_entry:
	addi	sp, sp, -PORT_CTX_SIZE

	REG_S	x1,  PORT_CTX_X(1)(sp)
	REG_S	x3,  PORT_CTX_X(3)(sp)
	REG_S	x4,  PORT_CTX_X(4)(sp)
	REG_S	x5,  PORT_CTX_X(5)(sp)
	REG_S	x6,  PORT_CTX_X(6)(sp)
	REG_S	x7,  PORT_CTX_X(7)(sp)
	REG_S	x8,  PORT_CTX_X(8)(sp)
	REG_S	x9,  PORT_CTX_X(9)(sp)
	REG_S	x10, PORT_CTX_X(10)(sp)
	REG_S	x11, PORT_CTX_X(11)(sp)
	REG_S	x12, PORT_CTX_X(12)(sp)
	REG_S	x13, PORT_CTX_X(13)(sp)
	REG_S	x14, PORT_CTX_X(14)(sp)
	REG_S	x15, PORT_CTX_X(15)(sp)
	REG_S	x16, PORT_CTX_X(16)(sp)
	REG_S	x17, PORT_CTX_X(17)(sp)
	REG_S	x18, PORT_CTX_X(18)(sp)
	REG_S	x19, PORT_CTX_X(19)(sp)
	REG_S	x20, PORT_CTX_X(20)(sp)
	REG_S	x21, PORT_CTX_X(21)(sp)
	REG_S	x22, PORT_CTX_X(22)(sp)
	REG_S	x23, PORT_CTX_X(23)(sp)
	REG_S	x24, PORT_CTX_X(24)(sp)
	REG_S	x25, PORT_CTX_X(25)(sp)
	REG_S	x26, PORT_CTX_X(26)(sp)
	REG_S	x27, PORT_CTX_X(27)(sp)
	REG_S	x28, PORT_CTX_X(28)(sp)
	REG_S	x29, PORT_CTX_X(29)(sp)
	REG_S	x30, PORT_CTX_X(30)(sp)
	REG_S	x31, PORT_CTX_X(31)(sp)

	csrr	t0, mepc
	REG_S	t0, PORT_CTX_MEPC(sp)
	csrr	t0, mstatus
	REG_S	t0, PORT_CTX_MSTATUS(sp)

	/* With an FPU it is always on (mstatus.FS != Off for every thread), so
	 * the FP file is saved unconditionally: a preemptive switch can land in
	 * the middle of any floating-point sequence. Without one (Hazard3)
	 * there is nothing to save. */
#if defined(__riscv_flen)
	frcsr	t0
	REG_S	t0, PORT_CTX_FCSR(sp)
	FREG_S	f0,  PORT_CTX_F(0)(sp)
	FREG_S	f1,  PORT_CTX_F(1)(sp)
	FREG_S	f2,  PORT_CTX_F(2)(sp)
	FREG_S	f3,  PORT_CTX_F(3)(sp)
	FREG_S	f4,  PORT_CTX_F(4)(sp)
	FREG_S	f5,  PORT_CTX_F(5)(sp)
	FREG_S	f6,  PORT_CTX_F(6)(sp)
	FREG_S	f7,  PORT_CTX_F(7)(sp)
	FREG_S	f8,  PORT_CTX_F(8)(sp)
	FREG_S	f9,  PORT_CTX_F(9)(sp)
	FREG_S	f10, PORT_CTX_F(10)(sp)
	FREG_S	f11, PORT_CTX_F(11)(sp)
	FREG_S	f12, PORT_CTX_F(12)(sp)
	FREG_S	f13, PORT_CTX_F(13)(sp)
	FREG_S	f14, PORT_CTX_F(14)(sp)
	FREG_S	f15, PORT_CTX_F(15)(sp)
	FREG_S	f16, PORT_CTX_F(16)(sp)
	FREG_S	f17, PORT_CTX_F(17)(sp)
	FREG_S	f18, PORT_CTX_F(18)(sp)
	FREG_S	f19, PORT_CTX_F(19)(sp)
	FREG_S	f20, PORT_CTX_F(20)(sp)
	FREG_S	f21, PORT_CTX_F(21)(sp)
	FREG_S	f22, PORT_CTX_F(22)(sp)
	FREG_S	f23, PORT_CTX_F(23)(sp)
	FREG_S	f24, PORT_CTX_F(24)(sp)
	FREG_S	f25, PORT_CTX_F(25)(sp)
	FREG_S	f26, PORT_CTX_F(26)(sp)
	FREG_S	f27, PORT_CTX_F(27)(sp)
	FREG_S	f28, PORT_CTX_F(28)(sp)
	FREG_S	f29, PORT_CTX_F(29)(sp)
	FREG_S	f30, PORT_CTX_F(30)(sp)
	FREG_S	f31, PORT_CTX_F(31)(sp)
#endif

	/* gp may have been changed by nothing (we never write it), but reload it
	 * so the dispatcher's gp-relative accesses cannot depend on that. */
	.option push
	.option norelax
	la	gp, __global_pointer$
	.option pop

	/* a0 = the frame. Count this hart's nesting and, on the outermost
	 * trap, move to this hart's interrupt stack (riscv_irq_stack_top[],
	 * os-core.cpp). Every caller-saved register is in the frame, so t0..t4
	 * are free here. */
	mv	a0, sp
#if defined(OS_NCPU) && (OS_NCPU > 1)
	csrr	t4, mhartid
	addi	t4, t4, -RISCV_HART_BASE	/* the CPU index (port_ctx.hpp) */
#else
	li	t4, 0
#endif
	slli	t3, t4, 2
	la	t0, riscv_trap_nesting
	add	t0, t0, t3
	lw	t1, 0(t0)
	addi	t2, t1, 1
	sw	t2, 0(t0)
	bnez	t1, 1f
	slli	t3, t4, (PORT_REGBYTES / 4 + 1)	/* hart * REGBYTES */
	la	t0, riscv_irq_stack_top
	add	t0, t0, t3
	REG_L	sp, 0(t0)
1:
	call	riscv_trap_dispatch

	/* a0 = the frame to resume (another thread's after a switch). The
	 * trap returns on the hart it was taken on.
	 *
	 * sp moves to the frame BEFORE the nesting count drops: where
	 * interrupts nest in hardware (the QingKe PFIC, mstatus.MIE stays set
	 * in a trap), an interrupt taken between the two would otherwise see
	 * nesting 0 while sp is still on the interrupt stack, build its frame
	 * near the top and then reset sp to that top for its dispatcher --
	 * over its own frame. With sp on the frame first, it builds below the
	 * frame on the thread's stack, as any first-level trap does. */
	mv	sp, a0
#if defined(OS_NCPU) && (OS_NCPU > 1)
	csrr	t4, mhartid
	addi	t4, t4, -RISCV_HART_BASE
#else
	li	t4, 0
#endif
	slli	t3, t4, 2
	la	t0, riscv_trap_nesting
	add	t0, t0, t3
	lw	t1, 0(t0)
	addi	t1, t1, -1
	sw	t1, 0(t0)

	.globl	riscv_trap_restore
riscv_trap_restore:
	REG_L	t0, PORT_CTX_MSTATUS(sp)
	csrw	mstatus, t0
	REG_L	t0, PORT_CTX_MEPC(sp)
	csrw	mepc, t0

#if defined(__riscv_flen)
	REG_L	t0, PORT_CTX_FCSR(sp)
	fscsr	t0
	FREG_L	f0,  PORT_CTX_F(0)(sp)
	FREG_L	f1,  PORT_CTX_F(1)(sp)
	FREG_L	f2,  PORT_CTX_F(2)(sp)
	FREG_L	f3,  PORT_CTX_F(3)(sp)
	FREG_L	f4,  PORT_CTX_F(4)(sp)
	FREG_L	f5,  PORT_CTX_F(5)(sp)
	FREG_L	f6,  PORT_CTX_F(6)(sp)
	FREG_L	f7,  PORT_CTX_F(7)(sp)
	FREG_L	f8,  PORT_CTX_F(8)(sp)
	FREG_L	f9,  PORT_CTX_F(9)(sp)
	FREG_L	f10, PORT_CTX_F(10)(sp)
	FREG_L	f11, PORT_CTX_F(11)(sp)
	FREG_L	f12, PORT_CTX_F(12)(sp)
	FREG_L	f13, PORT_CTX_F(13)(sp)
	FREG_L	f14, PORT_CTX_F(14)(sp)
	FREG_L	f15, PORT_CTX_F(15)(sp)
	FREG_L	f16, PORT_CTX_F(16)(sp)
	FREG_L	f17, PORT_CTX_F(17)(sp)
	FREG_L	f18, PORT_CTX_F(18)(sp)
	FREG_L	f19, PORT_CTX_F(19)(sp)
	FREG_L	f20, PORT_CTX_F(20)(sp)
	FREG_L	f21, PORT_CTX_F(21)(sp)
	FREG_L	f22, PORT_CTX_F(22)(sp)
	FREG_L	f23, PORT_CTX_F(23)(sp)
	FREG_L	f24, PORT_CTX_F(24)(sp)
	FREG_L	f25, PORT_CTX_F(25)(sp)
	FREG_L	f26, PORT_CTX_F(26)(sp)
	FREG_L	f27, PORT_CTX_F(27)(sp)
	FREG_L	f28, PORT_CTX_F(28)(sp)
	FREG_L	f29, PORT_CTX_F(29)(sp)
	FREG_L	f30, PORT_CTX_F(30)(sp)
	FREG_L	f31, PORT_CTX_F(31)(sp)
#endif

	REG_L	x1,  PORT_CTX_X(1)(sp)
	REG_L	x3,  PORT_CTX_X(3)(sp)
	REG_L	x4,  PORT_CTX_X(4)(sp)
	REG_L	x5,  PORT_CTX_X(5)(sp)
	REG_L	x6,  PORT_CTX_X(6)(sp)
	REG_L	x7,  PORT_CTX_X(7)(sp)
	REG_L	x8,  PORT_CTX_X(8)(sp)
	REG_L	x9,  PORT_CTX_X(9)(sp)
	REG_L	x10, PORT_CTX_X(10)(sp)
	REG_L	x11, PORT_CTX_X(11)(sp)
	REG_L	x12, PORT_CTX_X(12)(sp)
	REG_L	x13, PORT_CTX_X(13)(sp)
	REG_L	x14, PORT_CTX_X(14)(sp)
	REG_L	x15, PORT_CTX_X(15)(sp)
	REG_L	x16, PORT_CTX_X(16)(sp)
	REG_L	x17, PORT_CTX_X(17)(sp)
	REG_L	x18, PORT_CTX_X(18)(sp)
	REG_L	x19, PORT_CTX_X(19)(sp)
	REG_L	x20, PORT_CTX_X(20)(sp)
	REG_L	x21, PORT_CTX_X(21)(sp)
	REG_L	x22, PORT_CTX_X(22)(sp)
	REG_L	x23, PORT_CTX_X(23)(sp)
	REG_L	x24, PORT_CTX_X(24)(sp)
	REG_L	x25, PORT_CTX_X(25)(sp)
	REG_L	x26, PORT_CTX_X(26)(sp)
	REG_L	x27, PORT_CTX_X(27)(sp)
	REG_L	x28, PORT_CTX_X(28)(sp)
	REG_L	x29, PORT_CTX_X(29)(sp)
	REG_L	x30, PORT_CTX_X(30)(sp)
	REG_L	x31, PORT_CTX_X(31)(sp)

	addi	sp, sp, PORT_CTX_SIZE
	mret
	.size	riscv_trap_entry, . - riscv_trap_entry

	.section .bss
	.balign 4
	.globl	riscv_trap_nesting
riscv_trap_nesting:
#if defined(OS_NCPU)
	.space	4 * OS_NCPU
#else
	.space	4
#endif
