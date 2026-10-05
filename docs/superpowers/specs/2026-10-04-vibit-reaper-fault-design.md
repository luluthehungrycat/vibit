# VIBIT Reaper Fault Design

## Goal

Allow VIBIT to print a reaped child PID and continue its wait/respawn loop after a VIBIX child exits.

## Evidence and root cause

The VIBIT QEMU probe reaches `print_decimal` after `waitpid` returns a child PID. In `vibit.asm`, `print_decimal` computes the first digit pointer in `r13`, sets `rdi` to file descriptor 1, and then calls `strlen`, whose input contract is a pointer in `rdi`. The call therefore reads address 1 and raises a page fault at `0x200049F`. The kernel and VIBIT boot markers succeed before this path.

## Design

Correct the `print_decimal` call setup so `strlen` receives the digit buffer address. Keep the later write syscall's fd and buffer setup intact. The change is local to VIBIT's decimal-print routine and does not change the syscall ABI or reaper state machine.

## Behavior and validation

A VIBIT child exit must print the reaped PID, return to the reaper loop, respawn the shell, and accept another command. Run the NASM build and the existing bounded VIBIT/vish QEMU integration test. Preserve tracked build artifacts by directing assembly output to the onboarding artifact directory when necessary. A successful initial VIBIT banner alone does not satisfy the integration check.

## Constraints

- Do not change VIBIX kernel behavior to mask this userspace pointer bug.
- Keep changes within VIBIT source and its tests unless new evidence proves otherwise.
- Record the change and test result in the VIBIX changelog as required by its agent instructions.
