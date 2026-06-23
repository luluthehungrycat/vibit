# vibit

A (mostly) vibecoded minimal init system for the VIBIX kernel project.

VIBIT is the **PID 1 resident init process** for VIBIX. It replaces the
combined userspace blob (`vibix_blob.bin`) as the first user-mode process.

## Architecture

VIBIT is a flat x86-64 binary loaded at `0x2000000` and run as PID 1 by the
VIBIX kernel.  Its structure follows the sinit / Rich Felker minimal init
philosophy: **fork, wait, repeat**.

```
_start → fork init_child → reaper_loop (resident)
                              │
                    waitpid(-1, ...) ∞
```

### Lifecycle

1. **Entry** (`_start`): The kernel builds a synthetic iretq frame with
   `RDI = command_id`.  `command_id=1` triggers the boot sequence; other
   values skip to the reaper loop (used after `exec()` restart).

2. **Boot sequence**: VIBIT forks an init child process.  The child
   performs system initialization (mount filesystems, start services, spawn
   gettys).  In production the child would call `exec()` — VIBIX's `exec`
   syscall resets RIP to `0x2000000`, re-entering `_start` as a fresh
   process.

3. **Reaper loop**: The parent (VIBIT) enters an infinite `waitpid(-1, 0, 0)`
   loop.  This is the resident event loop — it blocks until any child exits,
   reaps the zombie, and loops.  When no children exist, it sleeps and polls.

### Shutdown

VIBIT provides `poweroff` and `reboot` routines that invoke the VIBIX
`reboot(7)` syscall with the Linux-compatible magic constants:

| Constant | Value |
|----------|-------|
| `REBOOT_MAGIC` | `0xfee1dead` |
| `REBOOT_MAGIC2` | `0x28121969` |
| `REBOOT_POWEROFF` | `0x4321fedc` |
| `REBOOT_RESTART` | `0xcdef0123` |

## Syscall Interface (VIBIX ABI)

| # | Name | Description |
|---|------|-------------|
| 0 | `exit` | Terminate current process |
| 1 | `write` | Write to fd (stdout → serial COM1) |
| 2 | `read` | Read from fd (stdin → keyboard + serial) |
| 3 | `getpid` | Return process ID |
| 4 | `brk` | Set program break (heap) |
| 5 | `nanosleep` | Busy-wait sleep |
| 6 | `uname` | System identification |
| 7 | `reboot` | Poweroff or restart machine |
| 8 | `fork` | Duplicate process |
| 9 | `exec` | Reset process context (limited MVP) |
| 10 | `waitpid` | Wait for / reap child process |

### waitpid Caveat

When a child is still running, VIBIX blocks the parent and clobbers RAX
to 0 on resume (the `exit_or_block` path builds a zeroed register frame).
VIBIT's reaper handles this by retrying on `RAX = 0`.

## Build

```sh
nasm -f bin -o vibit.bin vibit.asm
```

Or using the Makefile:

```sh
make        # builds vibit.bin
make clean  # removes build artifacts
make size   # show binary size
```

## Integration with VIBIX

To use VIBIT as the VIBIX init:

1. Build `vibit.bin`
2. Copy it to the VIBIX kernel source as `userspace/vibix_blob.bin`
3. Rebuild the kernel with `make -C kernel_rust`

VIBIT does not embed a shell — interactive use is delegated to a separate
process spawned by the init script.

## License

MIT
