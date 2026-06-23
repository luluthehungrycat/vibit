;==============================================================================
; vibit.asm — VIBIX Init (PID 1 resident process)
;
; A minimal resident init system for the VIBIX kernel.
; Version 0.1.0
;
; VIBIT replaces the combined userspace blob (vibix_blob.bin) as the first
; user-mode process.  It boots the system (forks an init task), then enters
; a permanent reaper loop that collects zombie children.
;
; Architecture (inspired by sinit / Rich Felker):
;   _start → fork init_child → reaper_loop (resident)
;
; Unlike sinit, VIBIX has no signals, so VIBIT uses synchronous waitpid.
; The reaper loop is the "main event loop" — it blocks in waitpid(-1) and
; wakes only when children exit.
;
; Syscall ABI (VIBIX):
;   rax = syscall number
;   rdi = arg1, rsi = arg2, rdx = arg3, r8  = arg4, r9  = arg5
;   Return in rax.  All regs clobbered except rcx, r11.
;
; Build: nasm -f bin -o vibit.bin vibit.asm
;==============================================================================

default rel

ORG 0x2000000
bits 64

;==============================================================================
; Syscall numbers
;==============================================================================
SYS_EXIT     equ 0
SYS_WRITE    equ 1
SYS_READ     equ 2
SYS_GETPID   equ 3
SYS_BRK      equ 4
SYS_NANOSLEEP equ 5
SYS_UNAME    equ 6
SYS_REBOOT   equ 7
SYS_FORK     equ 8
SYS_EXEC     equ 9
SYS_WAITPID  equ 10

;==============================================================================
; Reboot magic (Linux-compatible, from VIBIX syscall 7)
;==============================================================================
REBOOT_MAGIC   equ 0xfee1dead
REBOOT_MAGIC2  equ 0x28121969
REBOOT_POWEROFF equ 0x4321fedc
REBOOT_RESTART equ 0xcdef0123

;==============================================================================
; String constants
;==============================================================================
section .data

str_banner:     db "VIBIT: pid 1 alive (v0.1.0)", 0x0A, 0
str_booting:    db "VIBIT: spawning init task (fork)...", 0x0A, 0
str_fail:       db "VIBIT: fork failed", 0x0A, 0
str_reaper:     db "VIBIT: reaper loop (waitpid -1)", 0x0A, 0
str_reaped:     db "VIBIT: reaped child ", 0
str_none:       db "VIBIT: no children to reap", 0x0A, 0
str_poweroff:   db "VIBIT: poweroff", 0x0A, 0
str_reboot:     db "VIBIT: reboot", 0x0A, 0
str_newline:    db 0x0A, 0

;==============================================================================
; Code
;==============================================================================
section .text

;------------------------------------------------------------------------------
; _start — kernel entry point
;
; The kernel builds a synthetic iretq frame with RDI = command_id:
;   1 -> boot sequence (fork init process, enter reaper)
;   other -> enter reaper directly (e.g., restart after exec())
;
; Entry registers (set by kernel):
;   RSP = 0x2003000  (top of user stack page)
;   RDI = command_id
;------------------------------------------------------------------------------
global _start
_start:
    mov r12, rdi                    ; r12 = command_id (preserved)

    lea rsi, [str_banner]
    call print

    cmp r12, 1
    je .boot

    ; command_id != 1 -> skip boot, enter reaper
    jmp reaper_loop

.boot:
    lea rsi, [str_booting]
    call print

    ; Fork the init task
    mov rax, SYS_FORK
    syscall

    cmp rax, 0
    je .child                       ; RAX = 0 -> child process
    jl .fork_failed                 ; RAX < 0 -> error

    ; ── Parent: fall through to reaper loop ──
    ; The init task runs as a child; VIBIT reaps it in the resident loop.
    jmp reaper_loop

.child:
    ; ── Init task (child process) ──
    ; In production, this would exec an init script.
    ; exec(#9) resets RIP to 0x2000000 and re-enters _start.
    ; For this scaffold, simulate work then exit.
    ;
    ; mov rax, SYS_EXEC
    ; xor edi, edi                   ; path (ignored by kernel)
    ; xor esi, esi                   ; argv
    ; xor edx, edx                   ; envp
    ; syscall                        ; never returns (resets to _start)

    mov rcx, 5
.child_loop:
    ; nanosleep(0, 200000000) = 200ms
    mov rax, SYS_NANOSLEEP
    xor edi, edi
    mov esi, 200000000
    syscall
    dec rcx
    jnz .child_loop

    ; exit(42) — non-zero to demonstrate reaping in serial output
    mov rax, SYS_EXIT
    mov rdi, 42
    syscall
    ; unreachable

.fork_failed:
    lea rsi, [str_fail]
    call print
    jmp reaper_loop

;------------------------------------------------------------------------------
; reaper_loop — resident zombie collector
;
; Infinite loop: waitpid(-1) blocks until a child exits, then reaps.
; This is VIBIT's "main event loop" — it is the process that lives
; forever as PID 1.
;
; Waitpid return value semantics:
;   PID > 0: child reaped successfully
;   0:       parent was blocked and rescheduled (RAX clobbered by kernel's
;            exit_or_block path) — retry immediately
;   -1:      no children at all (all reaped, none alive)
;------------------------------------------------------------------------------
reaper_loop:
    lea rsi, [str_reaper]
    call print

.loop:
    ; waitpid(-1, NULL, 0) — block until any child exits
    mov rax, SYS_WAITPID
    xor edi, edi
    dec rdi                         ; rdi = -1 (any child)
    xor esi, esi                    ; wstatus = NULL
    xor edx, edx                    ; flags = 0
    syscall

    cmp rax, -1
    je .no_children

    test rax, rax
    jz .loop                        ; RAX = 0 -> was blocked, retry

    ; RAX = child PID — announce reaping
    push rax
    lea rsi, [str_reaped]
    call print
    pop rax
    call print_decimal
    lea rsi, [str_newline]
    call print
    jmp .loop

.no_children:
    ; No children alive — wait, then poll
    lea rsi, [str_none]
    call print

    ; nanosleep(1, 0) = 1 second
    mov rax, SYS_NANOSLEEP
    mov rdi, 1
    xor esi, esi
    syscall
    jmp .loop

;------------------------------------------------------------------------------
; poweroff — halt the machine (callable by VIBIT or user code)
;
; Invokes VIBIX reboot syscall with POWER_OFF command.
;------------------------------------------------------------------------------
poweroff:
    lea rsi, [str_poweroff]
    call print

    mov rax, SYS_REBOOT
    mov rdi, REBOOT_MAGIC
    mov rsi, REBOOT_MAGIC2
    mov rdx, REBOOT_POWEROFF
    syscall
    ret

;------------------------------------------------------------------------------
; reboot — restart the machine (callable by VIBIT or user code)
;
; Invokes VIBIX reboot syscall with RESTART command.
;------------------------------------------------------------------------------
reboot:
    lea rsi, [str_reboot]
    call print

    mov rax, SYS_REBOOT
    mov rdi, REBOOT_MAGIC
    mov rsi, REBOOT_MAGIC2
    mov rdx, REBOOT_RESTART
    syscall
    ret

;------------------------------------------------------------------------------
; print — write null-terminated string to stdout (fd=1)
;
; Args:
;   RSI = pointer to null-terminated string
; Returns:
;   RAX = bytes written
; Clobbers: rax, rcx, rdx, rdi, rsi, r8, r9, r10, r11
;------------------------------------------------------------------------------
print:
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov rdi, 1                      ; fd = stdout
    call strlen
    mov rdx, rax                    ; length
    mov rax, SYS_WRITE
    mov rdi, 1                      ; fd
    ; rsi still holds string pointer
    syscall

    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

;------------------------------------------------------------------------------
; strlen — length of null-terminated string
;
; Args:
;   RSI = string pointer
; Returns:
;   RAX = length (excluding null terminator)
; Clobbers: rax
;------------------------------------------------------------------------------
strlen:
    xor eax, eax
.l:
    cmp byte [rsi + rax], 0
    je .d
    inc rax
    jmp .l
.d:
    ret

;------------------------------------------------------------------------------
; print_decimal — print signed 64-bit integer to stdout (fd=1)
;
; Args:
;   RAX = integer value
; Clobbers: rax, rcx, rdx, rsi, rdi, r8, r9, r10, r11, r12, r13, r14, r15
; Uses small stack buffer for digit conversion (builds string backwards).
;------------------------------------------------------------------------------
print_decimal:
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov r12, rax                    ; save value
    sub rsp, 24                     ; scratch buffer
    lea r13, [rsp + 22]             ; point near end of buffer
    mov byte [r13 + 1], 0           ; null terminator at rsp+23

    test r12, r12
    jns .positive

    ; Negative value
    mov r14, 1                      ; sign flag
    neg r12                         ; work with absolute value
    jmp .convert

.positive:
    xor r14d, r14d                  ; sign flag = 0

.convert:
    mov rax, r12
    mov r15, 10
.loop:
    xor edx, edx
    div r15
    add dl, '0'
    mov [r13], dl
    dec r13
    test rax, rax
    jnz .loop

    ; Attach sign character if negative
    test r14d, r14d
    jz .emit
    mov [r13], byte '-'
    dec r13

.emit:
    inc r13                         ; move to first output character

    ; write(fd=1, r13, strlen(r13))
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
