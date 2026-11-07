# fp-switch

This test checks that the FPU registers survive a preemptive context
switch, and on SMP a move to another core:

- Arm (`__ARM_FP`): s0-s31 and the FPSCR flags (N, Z, C, V);
- RISC-V with an FPU (`__riscv_flen`): f0-f31 (FLEN bits each, `fld`/`fsd`
  with the D extension) and the fcsr.fflags (NV, DZ, OF, UF, NX). The hold
  is calibrated at start-up to about 3 ticks, whatever the core's speed;
  with `OS_USE_SMP_SCHEDULER` at least one round must resume on another
  core, or the test fails (the cross-core save/restore was not exercised).

Without an FPU it prints "no FPU, nothing to test" and passes.
