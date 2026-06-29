;==============================================================================
; vibit.asm — VIBIT: VIBIX Init and Service Manager (PID 1)
;
; Version 0.2.0
;
; Architecture:
;   _start → getpid() → PID 1: spawn services, reaper loop with respawn
;                      → non-PID-1: dispatch via r12 to service function
;
; Service dispatch via r12 convention:
;   Parent sets r12 = SERVICE_ID before sys_fork.
;   r12 is preserved through fork (kernel copies register state).
;   Child reads r12 → dispatches to function from service table.
;
; Shutdown IPC:
;   Shell writes to shutdown_flag in shared address space
;   (no per-process page tables in VIBIX — all processes share same map).
;   PID 1 checks flag on each iteration of reaper loop.
;
; Build:
;   nasm -f bin -o vibit.bin vibit.asm -I ./
;
; For VIBIX integration, copy vibit.bin as userspace/vibix_blob.bin.
;==============================================================================

; ── Assembler directives ──────────────────────────────────────────────────────
default rel
ORG 0x2000000
bits 64

;==============================================================================
; Syscall numbers (VIBIX kernel ABI)
;==============================================================================
SYS_EXIT       equ 0
SYS_WRITE      equ 1
SYS_READ       equ 2
SYS_GETPID     equ 3
SYS_NANOSLEEP  equ 5
SYS_REBOOT     equ 7
SYS_FORK       equ 8
SYS_EXEC       equ 9
SYS_WAITPID    equ 10

;==============================================================================
; Reboot magic constants (Linux-compatible, VIBIX syscall 7)
;==============================================================================
REBOOT_MAGIC    equ 0xfee1dead
REBOOT_MAGIC2   equ 0x28121969
REBOOT_POWEROFF equ 0x4321fedc
REBOOT_RESTART  equ 0xcdef0123

;==============================================================================
; Shutdown flag values — written by child processes, polled by PID 1
;==============================================================================
SHUTDOWN_NONE     equ 0
SHUTDOWN_REBOOT   equ 1
SHUTDOWN_POWEROFF equ 2

;==============================================================================
; Service descriptor structure (3 qwords per entry)
;==============================================================================
SVC_FUNC  equ 0         ; entry function pointer
SVC_NAME  equ 8         ; name string pointer
SVC_FLAGS equ 16        ; flags (bit 0 = respawn on exit)
SVC_SIZE  equ 24

;==============================================================================
; Service IDs
;==============================================================================
SVC_INIT  equ 0         ; PID 1 boot task (not spawned as child)
SVC_SHELL equ 1         ; Interactive shell (respawnable)

;==============================================================================
; Code section
;==============================================================================
section .text
global _start

;==============================================================================
; _start — entry point (initial boot and exec restart)
;
; Initial boot (PID 1):  init banner, run init tasks, spawn services, reaper
; Child process:         dispatch via r12 to service function
;==============================================================================
_start:
    mov rax, SYS_GETPID
    syscall

    cmp rax, 1
    je .init

    ; ── Child process dispatch ──
    ; r12 = service_id (set by parent before fork, preserved through fork)
    ; After exec(): kernel resets RIP to 0x2000000, but user registers
    ; (including r12) are preserved from the exec'ing process.  If r12
    ; is out of range OR equals SVC_INIT (0, reserved for PID 1), we
    ; fall through to the default shell service.
    cmp r12, svc_count
    jae .set_shell_fallback
    test r12, r12                   ; SVC_INIT (0) is PID 1 only
    jnz .do_dispatch
.set_shell_fallback:
    mov r12, SVC_SHELL              ; fallback to shell
.do_dispatch:
    mov rsp, 0x2003000              ; fresh stack for service
    imul rbx, r12, SVC_SIZE         ; rbx = service_id * 24
    mov rax, [svc_table + rbx + SVC_FUNC]
    jmp rax                         ; jump to service (never returns)

.init:
    ; ── Init (PID 1) ──
    mov qword [rel shutdown_flag], SHUTDOWN_NONE

    lea rsi, [str_banner]
    call print

    ; Run the init boot task (one-shot, returns)
    call service_init

    ; Spawn all services as child processes
    call spawn_all

    ; Enter reaper loop (blocks on waitpid, never returns)
    lea rsi, [str_reaper]
    call print
    jmp reaper_loop

;==============================================================================
; Service table — defines all runnable services
;==============================================================================
svc_table:
    dq service_init,  str_svc_init,  0    ; SVC_INIT (PID 1 internal)
    dq service_shell, str_svc_shell, 1    ; SVC_SHELL (respawnable)
svc_count equ ($ - svc_table) / SVC_SIZE

;==============================================================================
; service_init — one-shot boot task (runs as part of PID 1 init sequence)
;
; Returns to caller.  In production this would mount filesystems,
; set up devices, etc.  Currently a placeholder.
;==============================================================================
service_init:
    lea rsi, [str_svc_init_msg]
    call print
    ret

;==============================================================================
; service_shell — launch vish interactive shell via exec
;
; Called in child process context (after fork).  Replaces the child with
; vish via the exec() syscall.  If exec fails, exits with code 1.
;==============================================================================
service_shell:
    lea rsi, [str_svc_shell_msg]
    call print
    lea rsi, [str_newline]
    call print
    ; exec("/bin/vish", ["vish", NULL], envp)
    lea rdi, [rel str_path_vish]
    lea rsi, [rel vish_argv]
    mov rdx, [rel saved_envp]
    mov rax, SYS_EXEC
    syscall
    ; Exec failed — exit with code 1
    xor edi, edi
    inc rdi                              ; exit(1)
    xor eax, eax                         ; SYS_EXIT
    syscall

;==============================================================================
; spawn_all — fork a child for every spawnable service in svc_table
;
; Skips SVC_INIT (PID 1 runs it directly).  For each other service:
;   set r12 = service_id
;   fork
;   parent: continue to next service
;   child:  reset stack, dispatch to service function
;==============================================================================
spawn_all:
    push rbx
    push r12

    xor r12d, r12d
.loop:
    cmp r12, svc_count
    jae .done

    ; Skip SVC_INIT (it's for PID 1, not a child process)
    test r12, r12
    jz .next

    ; Announce spawn
    lea rsi, [str_spawn]
    call print
    imul rcx, r12, SVC_SIZE         ; rcx = service_id * 24
    mov rsi, [svc_table + rcx + SVC_NAME]
    call print

    ; Save current service_id to global for the child.
    ; VIBIX fork zeros all user registers in the child frame, so r12
    ; won't survive the syscall.  The child reads spawn_id to dispatch.
    mov [rel spawn_id], r12

    mov rax, SYS_FORK
    syscall

    test rax, rax
    jz .child                           ; child: rax = 0
    jl .error                           ; error: rax < 0

    ; Parent: announce success
    lea rsi, [str_done]
    call print
    jmp .next

.child:
    mov rsp, 0x2003000
    mov r12, [rel spawn_id]             ; restore service_id (fork zeros r12)
    imul rbx, r12, SVC_SIZE            ; rbx = service_id * 24
    mov rax, [svc_table + rbx + SVC_FUNC]
    jmp rax                             ; never returns

.error:
    lea rsi, [str_fail]
    call print

.next:
    inc r12
    jmp .loop

.done:
    pop r12
    pop rbx
    ret

;==============================================================================
; reaper_loop — infinite waitpid(-1) loop with respawn and shutdown
;
; On each child exit:
;   1. Reap the zombie
;   2. Check shutdown flag (child may have set it)
;   3. If flag set → poweroff or reboot
;   4. If shell exited → respawn a new instance
;
; waitpid detail: RAX=0 when blocked parent resumes (kernel limitation).
; We just retry the waitpid.
;==============================================================================
reaper_loop:
.loop:
    ; Check shutdown flag (non-blocking poll before waitpid)
    mov r8, [rel shutdown_flag]
    test r8, r8
    jnz .shutdown

    ; waitpid(-1, NULL, 0) — blocks until a child exits
    mov rax, SYS_WAITPID
    xor edi, edi
    dec rdi                         ; pid = -1 (any child)
    xor esi, esi                    ; wstatus = NULL
    xor edx, edx                    ; flags = 0 (blocking)
    syscall

    cmp rax, -1
    je .no_children

    test rax, rax
    jz .loop                        ; RAX=0: was blocked, retry

    ; ── Reaped child PID in rax ──
    push rax
    lea rsi, [str_reaped]
    call print
    pop rax
    call print_decimal
    lea rsi, [str_newline]
    call print

    ; Check shutdown flag (child may have set it before exiting)
    mov r8, [rel shutdown_flag]
    test r8, r8
    jnz .shutdown

    ; Respawn shell
    lea rsi, [str_respawn]
    call print

    mov r12, SVC_SHELL
    mov rax, SYS_FORK
    syscall

    test rax, rax
    jz .child_respawn
    jl .respawn_error

    lea rsi, [str_done]
    call print
    jmp .loop

.child_respawn:
    ; Dispatch through the service table — same path as spawn_all's children.
    ; r12 = SVC_SHELL was set before fork above, but we load from the table
    ; directly for clarity and to keep the dispatch logic in one place.
    mov rsp, 0x2003000
    lea rbx, [svc_table]
    mov rax, [rbx + SVC_SHELL * SVC_SIZE + SVC_FUNC]
    jmp rax

.respawn_error:
    lea rsi, [str_respawn_fail]
    call print
    jmp .loop

.no_children:
    lea rsi, [str_none]
    call print
    ; nanosleep(1, 0) — wait a bit before retrying
    mov rax, SYS_NANOSLEEP
    mov rdi, 1
    xor esi, esi
    syscall
    jmp .loop

.shutdown:
    lea rsi, [str_shutdown_msg]
    call print
    mov r8, [rel shutdown_flag]
    cmp r8, SHUTDOWN_REBOOT
    je .do_reboot
    call poweroff
    jmp .loop
.do_reboot:
    call reboot
    jmp .loop

;==============================================================================
; poweroff — syscall 7 with REBOOT_POWEROFF
;==============================================================================
poweroff:
    lea rsi, [str_poweroff]
    call print
    mov rax, SYS_REBOOT
    mov rdi, REBOOT_MAGIC
    mov rsi, REBOOT_MAGIC2
    mov rdx, REBOOT_POWEROFF
    syscall
    ret

;==============================================================================
; reboot — syscall 7 with REBOOT_RESTART
;==============================================================================
reboot:
    lea rsi, [str_reboot]
    call print
    mov rax, SYS_REBOOT
    mov rdi, REBOOT_MAGIC
    mov rsi, REBOOT_MAGIC2
    mov rdx, REBOOT_RESTART
    syscall
    ret

;==============================================================================
; print — write null-terminated string to stdout
;
; IN:  rsi = pointer to null-terminated string
; OUT: (none)
; CLOBBERS: rax, rcx, rdx, r11
;==============================================================================
print:
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rsi                        ; save string pointer for syscall
    mov rdi, rsi                    ; strlen expects rdi
    call strlen
    mov rdx, rax                    ; length
    pop rsi                         ; restore string pointer
    mov rax, SYS_WRITE
    mov rdi, 1                      ; stdout
    syscall
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

;==============================================================================
; print_decimal — print unsigned 64-bit decimal to stdout
;
; IN:  rax = value to print
; OUT: (none)
; CLOBBERS: rax, rcx, rdx, r11
;==============================================================================
print_decimal:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 24
    lea r13, [rsp + 22]
    mov byte [r13 + 1], 0
    mov r14, rax
    mov r15, 10
.convert:
    xor edx, edx
    mov rax, r14
    div r15
    add dl, '0'
    mov [r13], dl
    dec r13
    mov r14, rax
    test rax, rax
    jnz .convert
    inc r13
    mov rsi, r13
    mov rdi, 1
    call strlen
    mov rdx, rax
    mov rax, SYS_WRITE
    mov rdi, 1
    syscall
    add rsp, 24
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

;==============================================================================
; String constants
;==============================================================================
str_banner:        db "VIBIT v0.2.0: PID 1 init", 0x0A, 0
str_spawn:         db "VIBIT: spawning ", 0
str_done:          db " ...done", 0x0A, 0
str_fail:          db " ...failed", 0x0A, 0
str_reaper:        db "VIBIT: reaper loop", 0x0A, 0
str_reaped:        db "VIBIT: reaped child ", 0
str_respawn:       db "VIBIT: respawning shell...", 0
str_respawn_fail:  db "VIBIT: respawn failed", 0x0A, 0
str_none:          db "VIBIT: no children (idle)", 0x0A, 0
str_poweroff:      db "VIBIT: poweroff", 0x0A, 0
str_reboot:        db "VIBIT: reboot", 0x0A, 0
str_svc_init:      db "init", 0
str_svc_shell:     db "shell", 0
str_svc_init_msg:  db "VIBIT: init task complete", 0x0A, 0
str_svc_shell_msg: db "VIBIT: starting shell", 0x0A, 0
str_shutdown_msg:  db "VIBIT: shutdown requested", 0x0A, 0

; ── Spawn IPC (fork service_id passthrough) ──────────────────────────────────
; VIBIX fork zeros all user registers in the child's register frame.
; We save the service_id here before SYS_FORK so the child can read it.
spawn_id: dq 0

; ── Environment pointer saved from _start (r15 = envp) ──────────────────────
saved_envp: dq 0

; ── Shutdown IPC flag (protocol address for vish) ──────────────────────────
;
; Protocol:
;   Any process writes one of the SHUTDOWN_* values below to this flag.
;   PID 1 polls it on each iteration of the reaper loop (before and after
;   waitpid).  When non-zero, PID 1 prints the shutdown message and calls
;   sys_reboot with the appropriate magic.
;
;   Address: Fixed offset in the flat binary at 0x2000000.  Because VIBIX
;   has no per-process page tables, all processes share the same address
;   space — a write from any child is instantly visible to PID 1.
;
;   Values:  SHUTDOWN_NONE=0    (no action)
;            SHUTDOWN_REBOOT=1  (calls reboot → sys_reboot RESTART)
;            SHUTDOWN_POWEROFF=2 (calls poweroff → sys_reboot POWEROFF)
;
;   vish (vibix_shell.inc) writes to this via RIP-relative addressing:
;       mov dword [rel shutdown_flag], SHUTDOWN_POWEROFF
;       mov dword [rel shutdown_flag], SHUTDOWN_REBOOT
;
;   PID 1 reads it in reaper_loop:
;       mov r8, [rel shutdown_flag]
;       test r8, r8
;       jnz .shutdown
;=======================================================================;
shutdown_flag: dq SHUTDOWN_NONE

;==============================================================================
; Include shared VIBIX service implementations
;
; These must come in this order: core and tiny provide utility functions
; and constants referenced by echo, cat, printenv, clear.
;==============================================================================
%include "vibix_core.inc"
%include "vibix_tiny.inc"
%include "vibix_echo.inc"
%include "vibix_cat.inc"
%include "vibix_printenv.inc"
%include "vibix_clear.inc"

; argv for vish exec
vish_argv:
    dq str_vish_name
    dq 0                                 ; null-terminated

str_path_vish:  db "/bin/vish", 0
str_vish_name:  db "vish", 0
