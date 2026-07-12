// kelforth stage5-playground — standalone native AArch64 source
// This file intentionally contains only the routines and storage
// reachable by this stage. Later stages are complete copies that add
// their next layer; no shared interpreter source is included.


// libc is used only for open/read/write/close/exit. This final assembly kernel
// adds does>, recursion, strings, keyboard/terminal I/O, pick, and +loop,
// then embeds core.fs.
    .section __TEXT,__text,regular,pure_instructions
    .p2align 2

    // Load the address of a Mach-O symbol on Apple ARM64.
    .macro LOAD reg, sym
        adrp \reg, \sym@PAGE
        add  \reg, \reg, \sym@PAGEOFF
    .endm
    .macro ENTER
        stp x29, x30, [sp, #-16]!
        mov x29, sp
    .endm
    .macro LEAVE
        ldp x29, x30, [sp], #16
        ret
    .endm
    // Register one static primitive. define_prim returns its xt in x0.
    .macro REG name, length, fn, immediate=0
        LOAD x0, \name
        mov x1, #\length
        LOAD x2, \fn
        mov x3, #\immediate
        bl define_prim
    .endm
// ---------------------------------------------------------------- host I/O
write_buf: // ( x0=address, x1=length -- )
    mov x2, x1
    mov x1, x0
    mov w0, #1
    b _write
write_err:
    mov x2, x1
    mov x1, x0
    mov w0, #2
    b _write
write_number: // x0=signed value, w1=trailing-space?
    ENTER
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    mov x19, x0
    mov w20, w1
    cmp x19, #0
    cset w8, lt
    LOAD x21, number_buffer
    add x21, x21, #64
    mov x22, x21
    cbz w20, 1f
    sub x22, x22, #1
    mov w3, #' '
    strb w3, [x22]
1:
    cmp x19, #0
    b.ge 2f
    neg x19, x19 // unsigned magnitude also handles INT64_MIN
2:
    mov x4, #10
3:
    udiv x5, x19, x4
    msub x6, x5, x4, x19
    add w6, w6, #'0'
    sub x22, x22, #1
    strb w6, [x22]
    mov x19, x5
    cbnz x19, 3b
    cbz w8, 4f
    sub x22, x22, #1
    mov w6, #'-'
    strb w6, [x22]
4:
    mov x0, x22
    sub x1, x21, x22
    bl write_buf
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    LEAVE
write_byte: // w0=byte
    LOAD x1, output_byte
    strb w0, [x1]
    mov x0, x1
    mov x1, #1
    b write_buf
// ----------------------------------------------------------------- stacks
dpush:
    LOAD x1, dsp
    ldr x2, [x1]
    LOAD x3, data_stack
    str x0, [x3, x2, lsl #3]
    add x2, x2, #1
    str x2, [x1]
    ret
dpop:
    LOAD x1, dsp
    ldr x2, [x1]
    cbz x2, Lthrow_underflow
    sub x2, x2, #1
    str x2, [x1]
    LOAD x3, data_stack
    ldr x0, [x3, x2, lsl #3]
    ret
dpeek: // x0=depth
    LOAD x1, dsp
    ldr x2, [x1]
    sub x2, x2, x0
    sub x2, x2, #1
    tbnz x2, #63, Lthrow_underflow
    LOAD x3, data_stack
    ldr x0, [x3, x2, lsl #3]
    ret
rpush:
    LOAD x1, rsp_count
    ldr x2, [x1]
    LOAD x3, return_stack
    str x0, [x3, x2, lsl #3]
    add x2, x2, #1
    str x2, [x1]
    ret
rpop:
    LOAD x1, rsp_count
    ldr x2, [x1]
    cbz x2, Lthrow_runderflow
    sub x2, x2, #1
    str x2, [x1]
    LOAD x3, return_stack
    ldr x0, [x3, x2, lsl #3]
    ret
// A stack fault can strike deep inside nested primitives, so recovery is
// a throw: print the message, abandon every machine-stack frame below
// interpret (whose sp was saved at entry), and return 1 from interpret —
// the same path an undefined word takes. The REPL then resets the Forth
// stacks; file mode exits 1.
Lthrow_underflow:
    LOAD x0, msg_underflow
    mov x1, #23
    b Lforth_throw
Lthrow_runderflow:
    LOAD x0, msg_runderflow
    mov x1, #30
    b Lforth_throw
Lforth_throw: // x0=message, x1=length; never returns to the faulting code
    bl write_err
    LOAD x0, state
    str xzr, [x0]
    LOAD x1, err_sp
    ldr x2, [x1]
    mov sp, x2
    mov x0, #1
    b Linterpret_epilogue
// ------------------------------------------------------------ input source
set_source: // x0=ptr, x1=len
    LOAD x2, source_ptr
    str x0, [x2]
    LOAD x2, source_len
    str x1, [x2]
    LOAD x2, source_pos
    str xzr, [x2]
    ret
next_token: // returns x0=ptr,x1=len; x0=0 at EOF
    LOAD x2, source_ptr
    ldr x2, [x2]
    LOAD x3, source_len
    ldr x3, [x3]
    LOAD x4, source_pos
    ldr x5, [x4]
1: cmp x5, x3
    b.hs 4f
    ldrb w6, [x2, x5]
    cmp w6, #32
    b.hi 2f
    add x5, x5, #1
    b 1b
2: mov x7, x5
3: cmp x5, x3
    b.hs 5f
    ldrb w6, [x2, x5]
    cmp w6, #32
    b.ls 5f
    add x5, x5, #1
    b 3b
4: str x5, [x4]
    mov x0, #0
    mov x1, #0
    ret
5: str x5, [x4]
    add x0, x2, x7
    sub x1, x5, x7
    ret
skip_to_char: // w0=delimiter; consumes it
    LOAD x1, source_ptr
    ldr x1, [x1]
    LOAD x2, source_len
    ldr x2, [x2]
    LOAD x3, source_pos
    ldr x4, [x3]
1: cmp x4, x2
    b.hs 3f
    ldrb w5, [x1, x4]
    add x4, x4, #1
    cmp w5, w0
    b.ne 1b
3: str x4, [x3]
    ret
parse_quoted: // returns x0=ptr,x1=len; consumes closing quote
    LOAD x2, source_ptr
    ldr x2, [x2]
    LOAD x3, source_len
    ldr x3, [x3]
    LOAD x4, source_pos
    ldr x5, [x4]
    cmp x5, x3
    b.hs 1f
    ldrb w6, [x2, x5]
    cmp w6, #' '
    b.ne 1f
    add x5, x5, #1
1: mov x7, x5
2: cmp x5, x3
    b.hs 3f
    ldrb w6, [x2, x5]
    cmp w6, #'"'
    b.eq 4f
    add x5, x5, #1
    b 2b
3: str x5, [x4]
    add x0, x2, x7
    sub x1, x5, x7
    ret
4: add x6, x5, #1
    str x6, [x4]
    add x0, x2, x7
    sub x1, x5, x7
    ret
// --------------------------------------------------------------- dictionary
// Entry (48 bytes): name*, length, flags, kind, value, does-address.
// flags: bit 0 immediate, bit 1 hidden. kind: 0 prim, 1 colon,
// 2 created, 3 constant.
entry_addr: // x0=xt -> x0=entry address
    LOAD x1, dictionary
    mov x2, #48
    madd x0, x0, x2, x1
    ret
define_prim: // x0=name,x1=len,x2=fn,x3=immediate
    LOAD x4, dict_count
    ldr x5, [x4]
    LOAD x6, dictionary
    mov x7, #48
    madd x6, x5, x7, x6
    stp x0, x1, [x6]
    stp x3, xzr, [x6, #16]
    str x2, [x6, #32]
    mov x7, #-1
    str x7, [x6, #40]
    add x7, x5, #1
    str x7, [x4]
    LOAD x4, latest_xt
    str x5, [x4]
    mov x0, x5
    ret
copy_name: // x0=source,x1=len -> x0=copied address
    LOAD x2, name_pool_here
    ldr x3, [x2]
    LOAD x4, name_pool
    add x4, x4, x3
    mov x5, #0
1: cmp x5, x1
    b.hs 2f
    ldrb w6, [x0, x5]
    strb w6, [x4, x5]
    add x5, x5, #1
    b 1b
2: add x3, x3, x1
    str x3, [x2]
    mov x0, x4
    ret
define_user: // x0=name,x1=len,x2=kind,x3=value,x4=does,x5=flags
    ENTER
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    mov x19, x1
    mov x20, x2
    mov x21, x3
    mov x22, x4
    mov x23, x5
    bl copy_name
    mov x24, x0
    LOAD x6, dict_count
    ldr x7, [x6]
    LOAD x8, dictionary
    mov x9, #48
    madd x8, x7, x9, x8
    stp x24, x19, [x8]
    stp x23, x20, [x8, #16]
    stp x21, x22, [x8, #32]
    add x9, x7, #1
    str x9, [x6]
    LOAD x6, latest_xt
    str x7, [x6]
    mov x0, x7
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    LEAVE
lower_byte:
    cmp w0, #'A'
    b.lo 1f
    cmp w0, #'Z'
    b.hi 1f
    add w0, w0, #32
1: ret
find_word: // x0=token,x1=len -> x0=xt or -1
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x29, x30, [sp, #-16]!
    mov x19, x0
    mov x20, x1
    LOAD x21, dict_count
    ldr x21, [x21]
    LOAD x22, dictionary
1: cbz x21, 5f
    sub x21, x21, #1
    mov x2, #48
    madd x23, x21, x2, x22
    ldr x3, [x23, #16]
    tbnz x3, #1, 1b // hidden
    ldr x3, [x23, #8]
    cmp x3, x20
    b.ne 1b
    ldr x24, [x23]
    mov x4, #0
2: cmp x4, x20
    b.hs 4f
    ldrb w0, [x19, x4]
    bl lower_byte
    mov w5, w0
    ldrb w0, [x24, x4]
    bl lower_byte
    cmp w5, w0
    b.ne 1b
    add x4, x4, #1
    b 2b
4: mov x0, x21
    b 6f
5: mov x0, #-1
6: ldp x29, x30, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ret
// ---------------------------------------------------- compiler and inner VM
compile_cell: // x0=value
    LOAD x1, here
    ldr x2, [x1]
    LOAD x3, forth_memory
    str x0, [x3, x2, lsl #3]
    add x2, x2, #1
    str x2, [x1]
    ret
memory_load: // x0=cell address -> x0=value
    LOAD x1, forth_memory
    ldr x0, [x1, x0, lsl #3]
    ret
memory_store: // x0=address,x1=value
    LOAD x2, forth_memory
    str x1, [x2, x0, lsl #3]
    ret
invoke_xt: // invoke inside the current threaded VM
    ENTER
    stp x19, x20, [sp, #-16]!
    mov x19, x0
    bl entry_addr
    mov x20, x0
    ldr x1, [x20, #24]
    cbnz x1, 1f
    ldr x2, [x20, #32]
    blr x2
    b 5f
1: cmp x1, #1
    b.ne 2f
    LOAD x2, ip
    ldr x0, [x2]
    bl rpush
    ldr x3, [x20, #32]
    LOAD x2, ip
    str x3, [x2]
    b 5f
2: cmp x1, #2
    b.ne 4f
    ldr x0, [x20, #32]
    bl dpush
    ldr x3, [x20, #40]
    cmn x3, #1
    b.eq 5f
    mov x19, x3
    LOAD x2, ip
    ldr x0, [x2]
    bl rpush
    LOAD x2, ip
    str x19, [x2]
    b 5f
4: ldr x0, [x20, #32] // constant
    bl dpush
5: ldp x19, x20, [sp], #16
    LEAVE
run_inner:
    ENTER
1: LOAD x1, ip
    ldr x0, [x1]
    cmn x0, #1
    b.eq 2f
    add x2, x0, #1
    str x2, [x1]
    bl memory_load
    bl invoke_xt
    b 1b
2: LEAVE
execute_outer: // x0=xt
    ENTER
    stp x19, x20, [sp, #-16]!
    mov x19, x0
    bl entry_addr
    mov x20, x0
    ldr x1, [x20, #24]
    cbnz x1, 1f
    ldr x2, [x20, #32]
    blr x2
    b 5f
1:
    cmp x1, #3
    b.ne 2f
    ldr x0, [x20, #32]
    bl dpush
    b 5f
2: cmp x1, #2
    b.ne 3f
    ldr x0, [x20, #32]
    bl dpush
    ldr x3, [x20, #40]
    cmn x3, #1
    b.eq 5f
    b 4f
3:
    ldr x3, [x20, #32]
4: mov x19, x3
    mov x0, #-1
    bl rpush
    LOAD x2, ip
    str x19, [x2]
    bl run_inner
5: ldp x19, x20, [sp], #16
    LEAVE
parse_number: // x0=ptr,x1=len -> x0=value,w1=success
    cbz x1, 5f
    mov x2, #0
    mov x3, #0 // negative flag
    ldrb w4, [x0]
    cmp w4, #'-'
    b.ne 1f
    mov x3, #1
    add x2, x2, #1
    cmp x2, x1
    b.eq 5f
1: mov x5, #0
2: cmp x2, x1
    b.hs 3f
    ldrb w4, [x0, x2]
    sub w4, w4, #'0'
    cmp w4, #9
    b.hi 5f
    mov x6, #10
    madd x5, x5, x6, x4
    add x2, x2, #1
    b 2b
3: cbz x3, 4f
    neg x5, x5
4: mov x0, x5
    mov w1, #1
    ret
5: mov x0, #0
    mov w1, #0
    ret
interpret: // current source -> x0 status
    ENTER
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    LOAD x1, err_sp // recovery point for Lforth_throw
    mov x2, sp
    str x2, [x1]
1: bl next_token
    cbz x0, 8f
    mov x19, x0
    mov x20, x1
    mov x21, x0
    mov x22, x1
    bl find_word
    cmn x0, #1
    b.eq 4f
    mov x19, x0 // xt
    bl entry_addr
    ldr x2, [x0, #16]
    LOAD x3, state
    ldr x3, [x3]
    cbz x3, 3f
    tbnz x2, #0, 3f
    mov x0, x19
    bl compile_cell
    b 1b
3: mov x0, x19
    bl execute_outer
    b 1b
4: mov x0, x19
    mov x1, x20
    bl parse_number
    cbz w1, 7f
    mov x19, x0
    LOAD x2, state
    ldr x2, [x2]
    cbz x2, 6f
    LOAD x3, xt_lit
    ldr x0, [x3]
    bl compile_cell
    mov x0, x19
    bl compile_cell
    b 1b
6: mov x0, x19
    bl dpush
    b 1b
7: LOAD x0, msg_undefined
    mov x1, #23
    bl write_err
    mov x0, x19
    mov x1, x20
    bl write_err
    LOAD x0, msg_newline
    mov x1, #1
    bl write_err
    LOAD x0, state
    str xzr, [x0]
    mov x0, #1
    b 9f
8: mov x0, #0
9:
Linterpret_epilogue:
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    LEAVE
// ----------------------------------------------------- runtime primitives
prim_lit:
    ENTER
    LOAD x1, ip
    ldr x0, [x1]
    add x2, x0, #1
    str x2, [x1]
    bl memory_load
    bl dpush
    LEAVE
prim_branch:
    LOAD x1, ip
    ldr x0, [x1]
    b memory_load_to_ip
memory_load_to_ip:
    LOAD x2, forth_memory
    ldr x0, [x2, x0, lsl #3]
    LOAD x1, ip
    str x0, [x1]
    ret
prim_0branch:
    ENTER
    bl dpop
    mov x3, x0
    LOAD x1, ip
    ldr x0, [x1]
    cbnz x3, 1f
    bl memory_load_to_ip
    LEAVE
1: add x0, x0, #1
    str x0, [x1]
    LEAVE
prim_exit:
    ENTER
    bl rpop
    LOAD x1, ip
    str x0, [x1]
    LEAVE
// arithmetic
prim_add:
    ENTER
    bl dpop
    mov x9, x0
    bl dpop
    add x0, x0, x9
    bl dpush
    LEAVE
prim_sub:
    ENTER
    bl dpop
    mov x9, x0
    bl dpop
    sub x0, x0, x9
    bl dpush
    LEAVE
prim_mul:
    ENTER
    bl dpop
    mov x9, x0
    bl dpop
    mul x0, x0, x9
    bl dpush
    LEAVE
prim_div:
    ENTER
    bl dpop
    mov x9, x0
    bl dpop
    sdiv x0, x0, x9
    bl dpush
    LEAVE
prim_mod:
    ENTER
    bl dpop
    mov x9, x0
    bl dpop
    sdiv x10, x0, x9
    msub x0, x10, x9, x0
    bl dpush
    LEAVE
prim_negate:
    ENTER
    bl dpop
    neg x0, x0
    bl dpush
    LEAVE
// stack manipulation
prim_dup:
    ENTER
    mov x0, #0
    bl dpeek
    bl dpush
    LEAVE
prim_drop:
    ENTER
    bl dpop
    LEAVE
prim_swap:
    ENTER
    bl dpop
    mov x9, x0
    bl dpop
    mov x10, x0
    mov x0, x9
    bl dpush
    mov x0, x10
    bl dpush
    LEAVE
prim_over:
    ENTER
    mov x0, #1
    bl dpeek
    bl dpush
    LEAVE
prim_rot:
    ENTER
    bl dpop
    mov x9, x0
    bl dpop
    mov x10, x0
    bl dpop
    mov x11, x0
    mov x0, x10
    bl dpush
    mov x0, x9
    bl dpush
    mov x0, x11
    bl dpush
    LEAVE
prim_nip:
    ENTER
    bl dpop
    mov x9, x0
    bl dpop
    mov x0, x9
    bl dpush
    LEAVE
prim_tuck:
    ENTER
    bl dpop
    mov x9, x0
    bl dpop
    mov x10, x0
    mov x0, x9
    bl dpush
    mov x0, x10
    bl dpush
    mov x0, x9
    bl dpush
    LEAVE
prim_depth:
    ENTER
    LOAD x0, dsp
    ldr x0, [x0]
    bl dpush
    LEAVE
prim_pick:
    ENTER
    bl dpop
    bl dpeek
    bl dpush
    LEAVE
// comparisons and bit logic
prim_eq:
    ENTER
    bl dpop
    mov x9, x0
    bl dpop
    cmp x0, x9
    csetm x0, eq
    bl dpush
    LEAVE
prim_ne:
    ENTER
    bl dpop
    mov x9, x0
    bl dpop
    cmp x0, x9
    csetm x0, ne
    bl dpush
    LEAVE
prim_lt:
    ENTER
    bl dpop
    mov x9, x0
    bl dpop
    cmp x0, x9
    csetm x0, lt
    bl dpush
    LEAVE
prim_gt:
    ENTER
    bl dpop
    mov x9, x0
    bl dpop
    cmp x0, x9
    csetm x0, gt
    bl dpush
    LEAVE
prim_le:
    ENTER
    bl dpop
    mov x9, x0
    bl dpop
    cmp x0, x9
    csetm x0, le
    bl dpush
    LEAVE
prim_ge:
    ENTER
    bl dpop
    mov x9, x0
    bl dpop
    cmp x0, x9
    csetm x0, ge
    bl dpush
    LEAVE
prim_zero_eq:
    ENTER
    bl dpop
    cmp x0, #0
    csetm x0, eq
    bl dpush
    LEAVE
prim_zero_lt:
    ENTER
    bl dpop
    cmp x0, #0
    csetm x0, lt
    bl dpush
    LEAVE
prim_zero_gt:
    ENTER
    bl dpop
    cmp x0, #0
    csetm x0, gt
    bl dpush
    LEAVE
prim_and:
    ENTER
    bl dpop
    mov x9, x0
    bl dpop
    and x0, x0, x9
    bl dpush
    LEAVE
prim_or:
    ENTER
    bl dpop
    mov x9, x0
    bl dpop
    orr x0, x0, x9
    bl dpush
    LEAVE
prim_xor:
    ENTER
    bl dpop
    mov x9, x0
    bl dpop
    eor x0, x0, x9
    bl dpush
    LEAVE
prim_invert:
    ENTER
    bl dpop
    mvn x0, x0
    bl dpush
    LEAVE
prim_true:
    ENTER
    mov x0, #-1
    bl dpush
    LEAVE
prim_false:
    ENTER
    mov x0, #0
    bl dpush
    LEAVE
// output
prim_dot:
    ENTER
    bl dpop
    mov w1, #1
    bl write_number
    LEAVE
prim_dots:
    ENTER
    LOAD x0, msg_lt
    mov x1, #1
    bl write_buf
    LOAD x19, dsp
    ldr x19, [x19]
    mov x0, x19
    mov w1, #0
    bl write_number
    LOAD x0, msg_stack_sep
    mov x1, #2
    bl write_buf
    mov x20, #0
    cbnz x19, 1f
    bl prim_space // JS edition prints two spaces for <0>
    b 2f
1: cmp x20, x19
    b.hs 2f
    LOAD x1, data_stack
    ldr x0, [x1, x20, lsl #3]
    mov w1, #1
    bl write_number
    add x20, x20, #1
    b 1b
2: LEAVE
prim_emit:
    ENTER
    bl dpop
    bl write_byte
    LEAVE
prim_cr:
    LOAD x0, msg_newline
    mov x1, #1
    b write_buf
prim_space:
    mov w0, #' '
    b write_byte
prim_bye:
    ENTER
    bl terminal_restore
    mov w0, #0
    bl _exit
prim_words:
    ENTER
    stp x19, x20, [sp, #-16]!
    LOAD x19, dict_count
    ldr x19, [x19]
    mov x20, #0
1: cmp x20, x19
    b.hs 2f
    mov x0, x20
    bl entry_addr
    ldr x1, [x0, #16]
    tbnz x1, #1, 3f
    ldr x1, [x0, #8]
    ldr x0, [x0]
    bl write_buf
    bl prim_space
3: add x20, x20, #1
    b 1b
2: bl prim_cr
    ldp x19, x20, [sp], #16
    LEAVE
// comments
prim_backslash:
    mov w0, #10
    b skip_to_char
prim_paren:
    mov w0, #')'
    b skip_to_char
// return stack words
prim_to_r:
    ENTER
    bl dpop
    bl rpush
    LEAVE
prim_r_from:
    ENTER
    bl rpop
    bl dpush
    LEAVE
prim_r_fetch:
    ENTER
    LOAD x1, rsp_count
    ldr x2, [x1]
    sub x2, x2, #1
    LOAD x1, return_stack
    ldr x0, [x1, x2, lsl #3]
    bl dpush
    LEAVE
// -------------------------------------------------------- colon compiler
prim_colon:
    ENTER
    bl next_token
    cbz x0, 1f
    mov x2, #1 // colon
    LOAD x3, here
    ldr x3, [x3]
    mov x4, #-1
    mov x5, #2 // hidden until ;
    bl define_user
    LOAD x1, pending_xt
    str x0, [x1]
    LOAD x1, state
    mov x2, #1
    str x2, [x1]
1: LEAVE
prim_semicolon:
    ENTER
    LOAD x0, xt_exit
    ldr x0, [x0]
    bl compile_cell
    LOAD x1, pending_xt
    ldr x0, [x1]
    bl entry_addr
    ldr x1, [x0, #16]
    bic x1, x1, #2
    str x1, [x0, #16]
    LOAD x0, state
    str xzr, [x0]
    LEAVE
prim_immediate:
    LOAD x0, latest_xt
    ldr x0, [x0]
    mov x1, #48
    LOAD x2, dictionary
    madd x0, x0, x1, x2
    ldr x1, [x0, #16]
    orr x1, x1, #1
    str x1, [x0, #16]
    ret
prim_left_bracket:
    LOAD x0, state
    str xzr, [x0]
    ret
prim_right_bracket:
    LOAD x0, state
    mov x1, #1
    str x1, [x0]
    ret
prim_literal:
    ENTER
    LOAD x0, xt_lit
    ldr x0, [x0]
    bl compile_cell
    bl dpop
    bl compile_cell
    LEAVE
prim_tick:
    ENTER
    bl next_token
    bl find_word
    bl dpush
    LEAVE
prim_bracket_tick:
    ENTER
    bl next_token
    bl find_word
    mov x19, x0
    LOAD x0, xt_lit
    ldr x0, [x0]
    bl compile_cell
    mov x0, x19
    bl compile_cell
    LEAVE
prim_execute:
    ENTER
    bl dpop
    mov x19, x0
    LOAD x1, ip
    ldr x1, [x1]
    cmn x1, #1
    b.eq 1f
    mov x0, x19
    bl invoke_xt
    b 2f
1: mov x0, x19
    bl execute_outer
2: LEAVE
prim_postpone:
    ENTER
    bl next_token
    bl find_word
    mov x19, x0
    bl entry_addr
    ldr x1, [x0, #16]
    tbz x1, #0, 1f
    mov x0, x19
    bl compile_cell
    b 2f
1: LOAD x0, xt_lit
    ldr x0, [x0]
    bl compile_cell
    mov x0, x19
    bl compile_cell
    LOAD x0, xt_comma
    ldr x0, [x0]
    bl compile_cell
2: LEAVE
prim_recurse:
    LOAD x0, pending_xt
    ldr x0, [x0]
    b compile_cell
// counted loops
prim_paren_do:
    ENTER
    bl dpop
    mov x9, x0 // index
    bl dpop // limit
    LOAD x1, loop_count
    ldr x2, [x1]
    LOAD x3, loop_stack
    add x3, x3, x2, lsl #4
    stp x0, x9, [x3]
    add x2, x2, #1
    str x2, [x1]
    LEAVE
prim_paren_loop:
    ENTER
    LOAD x1, loop_count
    ldr x2, [x1]
    sub x2, x2, #1
    LOAD x3, loop_stack
    add x3, x3, x2, lsl #4
    ldp x4, x5, [x3]
    add x5, x5, #1
    str x5, [x3, #8]
    cmp x5, x4
    csetm x0, ge
    bl dpush
    LEAVE
prim_paren_plus_loop:
    ENTER
    bl dpop
    mov x9, x0
    LOAD x1, loop_count
    ldr x2, [x1]
    sub x2, x2, #1
    LOAD x3, loop_stack
    add x3, x3, x2, lsl #4
    ldp x4, x5, [x3]
    add x5, x5, x9
    str x5, [x3, #8]
    cmp x9, #0
    b.le 1f
    cmp x5, x4
    csetm x0, ge
    b 2f
1: cmp x5, x4
    csetm x0, lt
2: bl dpush
    LEAVE
prim_paren_unloop:
    LOAD x1, loop_count
    ldr x2, [x1]
    sub x2, x2, #1
    str x2, [x1]
    ret
prim_i:
    ENTER
    LOAD x1, loop_count
    ldr x2, [x1]
    sub x2, x2, #1
    LOAD x3, loop_stack
    add x3, x3, x2, lsl #4
    ldr x0, [x3, #8]
    bl dpush
    LEAVE
prim_j:
    ENTER
    LOAD x1, loop_count
    ldr x2, [x1]
    sub x2, x2, #2
    LOAD x3, loop_stack
    add x3, x3, x2, lsl #4
    ldr x0, [x3, #8]
    bl dpush
    LEAVE
// -------------------------------------------------------------- memory
prim_here:
    ENTER
    LOAD x0, here
    ldr x0, [x0]
    bl dpush
    LEAVE
prim_allot:
    ENTER
    bl dpop
    LOAD x1, here
    ldr x2, [x1]
    add x2, x2, x0
    str x2, [x1]
    LEAVE
prim_comma:
    ENTER
    bl dpop
    bl compile_cell
    LEAVE
prim_fetch:
    ENTER
    bl dpop
    bl memory_load
    bl dpush
    LEAVE
prim_store:
    ENTER
    bl dpop
    mov x19, x0 // address
    bl dpop
    mov x1, x0
    mov x0, x19
    bl memory_store
    LEAVE
prim_create:
    ENTER
    bl next_token
    cbz x0, 1f
    mov x2, #2
    LOAD x3, here
    ldr x3, [x3]
    mov x4, #-1
    mov x5, #0
    bl define_user
1: LEAVE
prim_does_runtime:
    ENTER
    LOAD x0, latest_xt
    ldr x0, [x0]
    bl entry_addr
    LOAD x1, ip
    ldr x2, [x1]
    str x2, [x0, #40]
    bl rpop
    LOAD x1, ip
    str x0, [x1]
    LEAVE
prim_does:
    LOAD x0, xt_does_runtime
    ldr x0, [x0]
    b compile_cell
// ------------------------------------------------------- strings and text
prim_dot_quote_runtime:
    ENTER
    LOAD x19, ip
    ldr x0, [x19]
    bl memory_load
    mov x20, x0
    ldr x21, [x19]
    add x21, x21, #1
    str x21, [x19]
1: cbz x20, 2f
    mov x0, x21
    bl memory_load
    bl write_byte
    add x21, x21, #1
    sub x20, x20, #1
    b 1b
2: str x21, [x19]
    LEAVE
compile_chars: // x0=ptr,x1=len
    ENTER
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    mov x19, x0
    mov x20, x1
    mov x21, #0
1: cmp x21, x20
    b.hs 2f
    ldrb w0, [x19, x21]
    bl compile_cell
    add x21, x21, #1
    b 1b
2: ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    LEAVE
prim_dot_quote:
    ENTER
    bl parse_quoted
    mov x19, x0
    mov x20, x1
    LOAD x2, state
    ldr x2, [x2]
    cbz x2, 1f
    LOAD x0, xt_dotq_runtime
    ldr x0, [x0]
    bl compile_cell
    mov x0, x20
    bl compile_cell
    mov x0, x19
    mov x1, x20
    bl compile_chars
    b 2f
1: mov x0, x19
    mov x1, x20
    bl write_buf
2: LEAVE
prim_s_quote_runtime:
    ENTER
    LOAD x19, ip
    ldr x0, [x19]
    bl memory_load
    mov x20, x0
    ldr x21, [x19]
    add x21, x21, #1
    str x21, [x19]
    mov x0, x21
    bl dpush
    mov x0, x20
    bl dpush
    add x21, x21, x20
    str x21, [x19]
    LEAVE
prim_s_quote:
    ENTER
    bl parse_quoted
    mov x19, x0
    mov x20, x1
    LOAD x2, state
    ldr x2, [x2]
    cbz x2, 1f
    LOAD x0, xt_squote_runtime
    ldr x0, [x0]
    bl compile_cell
    mov x0, x20
    bl compile_cell
    mov x0, x19
    mov x1, x20
    bl compile_chars
    b 3f
1: mov x21, #65000
    mov x22, #0
2: cmp x22, x20
    b.hs 4f
    ldrb w1, [x19, x22]
    add x0, x21, x22
    bl memory_store
    add x22, x22, #1
    b 2b
4: mov x0, x21
    bl dpush
    mov x0, x20
    bl dpush
3: LEAVE
prim_type:
    ENTER
    bl dpop
    mov x20, x0
    bl dpop
    mov x19, x0
1: cbz x20, 2f
    mov x0, x19
    bl memory_load
    bl write_byte
    add x19, x19, #1
    sub x20, x20, #1
    b 1b
2: LEAVE
prim_char:
    ENTER
    bl next_token
    cbz x0, 1f
    ldrb w0, [x0]
    bl dpush
1: LEAVE
prim_bracket_char:
    ENTER
    bl next_token
    cbz x0, 1f
    ldrb w19, [x0]
    LOAD x0, xt_lit
    ldr x0, [x0]
    bl compile_cell
    mov x0, x19
    bl compile_cell
1: LEAVE

// ------------------------------------------------------- terminal & keyboard
// macOS terminal mode is delegated to stty. poll(2) makes key? non-blocking;
// key and accept use ordinary synchronous read(2) calls.
terminal_raw:
    ENTER
    LOAD x1, raw_enabled
    ldr x2, [x1]
    cbnz x2, 1f
    mov w0, #0
    bl _isatty
    cbz w0, 1f
    LOAD x0, command_raw
    bl _system
    LOAD x1, raw_enabled
    mov x2, #1
    str x2, [x1]
1:  LEAVE

terminal_restore:
    ENTER
    LOAD x1, raw_enabled
    ldr x2, [x1]
    cbz x2, 1f
    LOAD x0, command_sane
    bl _system
    LOAD x1, raw_enabled
    str xzr, [x1]
1:  LEAVE

prim_key:                          // ( -- char ) blocking, one raw byte
    ENTER
    bl terminal_raw
    LOAD x1, typed_ahead
    ldr x0, [x1]
    cmn x0, #1
    b.eq 1f
    mov x2, #-1
    str x2, [x1]
    bl dpush
    LEAVE
1:  mov w0, #0
    LOAD x1, input_byte
    mov x2, #1
    bl _read
    cmp x0, #1
    b.ne 2f
    LOAD x1, input_byte
    ldrb w0, [x1]
    bl dpush
    LEAVE
2:  mov x0, #-1                  // EOF: a visible sentinel, not a key
    bl dpush
    LEAVE

prim_key_query:                    // ( -- flag ) poll without blocking
    ENTER
    bl terminal_raw
    LOAD x1, typed_ahead
    ldr x0, [x1]
    cmn x0, #1
    b.ne 3f
    LOAD x0, poll_stdin
    strh wzr, [x0, #6]            // clear revents
    mov w1, #1                    // one pollfd
    mov w2, #0                    // zero-millisecond timeout
    bl _poll
    cmp w0, #1
    b.ne 2f
    LOAD x0, poll_stdin
    ldrh w1, [x0, #6]
    tbz w1, #0, 2f                // POLLIN
    mov w0, #0
    LOAD x1, input_byte
    mov x2, #1
    bl _read
    cmp x0, #1
    b.ne 2f
    LOAD x1, input_byte
    ldrb w0, [x1]
    LOAD x1, typed_ahead
    str x0, [x1]
3:  mov x0, #-1
    bl dpush
    LEAVE
2:  mov x0, #0
    bl dpush
    LEAVE

prim_accept:                       // ( addr max -- len )
    ENTER
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    bl dpop
    mov x20, x0                    // maximum length
    bl dpop
    mov x19, x0                    // destination cell address
    mov x21, #0                    // current length
    LOAD x0, raw_enabled
    ldr x22, [x0]                  // restore raw mode afterward if needed
    cbz x22, 1f
    bl terminal_restore
1:  cmp x21, x20
    b.hs 5f
    LOAD x0, typed_ahead
    ldr x23, [x0]
    cmn x23, #1
    b.eq 2f
    mov x1, #-1
    str x1, [x0]
    b 3f
2:  mov w0, #0
    LOAD x1, input_byte
    mov x2, #1
    bl _read
    cmp x0, #1
    b.ne 5f
    LOAD x0, input_byte
    ldrb w23, [x0]
3:  cmp w23, #10                  // newline ends the accepted line
    b.eq 5f
    cmp w23, #13                  // ignore carriage return
    b.eq 1b
    add x0, x19, x21
    mov x1, x23
    bl memory_store
    add x21, x21, #1
    b 1b
5:  cbz x22, 6f
    bl terminal_raw
6:  mov x0, x21
    bl dpush
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    LEAVE

prim_pad:                          // ( -- addr )
    mov x0, #65000
    b dpush

prim_ms:                           // ( milliseconds -- )
    ENTER
    bl dpop
    mov x1, #1000
    mul x0, x0, x1
    bl _usleep
    LEAVE

prim_page:                         // clear screen and home the cursor
    LOAD x0, ansi_page
    mov x1, #7
    b write_buf

prim_at_xy:                        // ( col row -- ) zero-based cursor position
    ENTER
    stp x19, x20, [sp, #-16]!
    bl dpop
    mov x20, x0                    // row
    bl dpop
    mov x19, x0                    // column
    LOAD x0, ansi_csi
    mov x1, #2
    bl write_buf
    add x0, x20, #1
    mov w1, #0
    bl write_number
    mov w0, #';'
    bl write_byte
    add x0, x19, #1
    mov w1, #0
    bl write_number
    mov w0, #'H'
    bl write_byte
    ldp x19, x20, [sp], #16
    LEAVE

// ------------------------------------------------------- dictionary setup
init_dictionary:
    ENTER
    // Threaded-code runtime is present from stage 1 onward.
    REG name_lit, 3, prim_lit
    LOAD x1, xt_lit
    str x0, [x1]
    REG name_branch, 6, prim_branch
    LOAD x1, xt_branch
    str x0, [x1]
    REG name_0branch, 7, prim_0branch
    LOAD x1, xt_0branch
    str x0, [x1]
    REG name_exit, 4, prim_exit
    LOAD x1, xt_exit
    str x0, [x1]
    REG name_add, 1, prim_add
    REG name_sub, 1, prim_sub
    REG name_mul, 1, prim_mul
    REG name_div, 1, prim_div
    REG name_mod, 3, prim_mod
    REG name_negate, 6, prim_negate
    REG name_dot, 1, prim_dot
    REG name_dots, 2, prim_dots
    REG name_cr, 2, prim_cr
    REG name_bye, 3, prim_bye
    REG name_backslash, 1, prim_backslash, 1
    REG name_dup, 3, prim_dup
    REG name_drop, 4, prim_drop
    REG name_swap, 4, prim_swap
    REG name_over, 4, prim_over
    REG name_rot, 3, prim_rot
    REG name_nip, 3, prim_nip
    REG name_tuck, 4, prim_tuck
    REG name_depth, 5, prim_depth
    REG name_emit, 4, prim_emit
    REG name_paren, 1, prim_paren, 1
    REG name_colon, 1, prim_colon
    REG name_semicolon, 1, prim_semicolon, 1
    REG name_eq, 1, prim_eq
    REG name_ne, 2, prim_ne
    REG name_lt, 1, prim_lt
    REG name_gt, 1, prim_gt
    REG name_le, 2, prim_le
    REG name_ge, 2, prim_ge
    REG name_zero_eq, 2, prim_zero_eq
    REG name_zero_lt, 2, prim_zero_lt
    REG name_zero_gt, 2, prim_zero_gt
    REG name_and, 3, prim_and
    REG name_or, 2, prim_or
    REG name_xor, 3, prim_xor
    REG name_invert, 6, prim_invert
    REG name_true, 4, prim_true
    REG name_false, 5, prim_false
    REG name_space, 5, prim_space
    REG name_paren_do, 4, prim_paren_do
    LOAD x1, xt_paren_do
    str x0, [x1]
    REG name_paren_loop, 6, prim_paren_loop
    LOAD x1, xt_paren_loop
    str x0, [x1]
    REG name_paren_unloop, 8, prim_paren_unloop
    LOAD x1, xt_paren_unloop
    str x0, [x1]
    REG name_i, 1, prim_i
    REG name_j, 1, prim_j
    REG name_dotq_runtime, 4, prim_dot_quote_runtime
    LOAD x1, xt_dotq_runtime
    str x0, [x1]
    REG name_dot_quote, 2, prim_dot_quote, 1
    REG name_here, 4, prim_here
    REG name_allot, 5, prim_allot
    REG name_comma, 1, prim_comma
    LOAD x1, xt_comma
    str x0, [x1]
    REG name_fetch, 1, prim_fetch
    REG name_store, 1, prim_store
    REG name_to_r, 2, prim_to_r
    REG name_r_from, 2, prim_r_from
    REG name_r_fetch, 2, prim_r_fetch
    REG name_words, 5, prim_words
    REG name_immediate, 9, prim_immediate
    REG name_left_bracket, 1, prim_left_bracket, 1
    REG name_right_bracket, 1, prim_right_bracket
    REG name_literal, 7, prim_literal, 1
    REG name_tick, 1, prim_tick
    REG name_bracket_tick, 3, prim_bracket_tick, 1
    REG name_execute, 7, prim_execute
    REG name_postpone, 8, prim_postpone, 1
    REG name_create, 6, prim_create
    REG name_paren_plus_loop, 7, prim_paren_plus_loop
    REG name_does_runtime, 7, prim_does_runtime
    LOAD x1, xt_does_runtime
    str x0, [x1]
    REG name_does, 5, prim_does, 1
    REG name_recurse, 7, prim_recurse, 1
    REG name_pick, 4, prim_pick
    REG name_squote_runtime, 4, prim_s_quote_runtime
    LOAD x1, xt_squote_runtime
    str x0, [x1]
    REG name_s_quote, 2, prim_s_quote, 1
    REG name_type, 4, prim_type
    REG name_char, 4, prim_char
    REG name_bracket_char, 6, prim_bracket_char, 1
    REG name_key, 3, prim_key
    REG name_key_query, 4, prim_key_query
    REG name_accept, 6, prim_accept
    REG name_pad, 3, prim_pad
    REG name_ms, 2, prim_ms
    REG name_page, 4, prim_page
    REG name_at_xy, 5, prim_at_xy
    LEAVE
// --------------------------------------------------------------------- main
    .globl _main
_main:
    ENTER
    stp x19, x20, [sp, #-16]!
    mov x19, x0 // argc
    mov x20, x1 // argv
    LOAD x0, ip
    mov x1, #-1
    str x1, [x0]
    bl init_dictionary
    LOAD x0, core_source
    LOAD x1, core_source_end
    sub x1, x1, x0
    bl set_source
    bl interpret
    cbnz x0, 97f
    cmp x19, #2
    b.lt 90f
    ldr x0, [x20, #8]
    mov w1, #0
    bl _open
    cmp w0, #0
    b.lt 97f
    mov w19, w0
    mov w0, w19
    LOAD x1, file_buffer
    mov x2, #1
    lsl x2, x2, #20
    bl _read
    mov x20, x0
    mov w0, w19
    bl _close
    cmp x20, #0
    b.lt 97f
    LOAD x0, file_buffer
    mov x1, x20
    bl set_source
    bl interpret
    b 98f
90:
    LOAD x0, banner5
    mov x1, #83
    bl write_buf
91:
    LOAD x0, prompt
    mov x1, #2
    bl write_buf
    mov w0, #0
    LOAD x1, repl_buffer
    mov x2, #65536
    bl _read
    cmp x0, #0
    b.le 96f
    mov x20, x0
    LOAD x0, repl_buffer
    mov x1, x20
    bl set_source
    bl interpret
    cbnz x0, 94f
    LOAD x0, state
    ldr x0, [x0]
    cbnz x0, 93f
    LOAD x0, msg_ok
    mov x1, #4
    bl write_buf
    b 91b
93:
    LOAD x0, msg_compiled
    mov x1, #10
    bl write_buf
    b 91b
94:
    LOAD x0, dsp
    str xzr, [x0]
    LOAD x0, rsp_count
    str xzr, [x0]
    LOAD x0, loop_count
    str xzr, [x0]
    LOAD x0, cf_count
    str xzr, [x0]
    LOAD x0, ip
    mov x1, #-1
    str x1, [x0]
    b 91b
96:
    mov x0, #0
    b 98f
97:
    mov x0, #1
98:
    str x0, [sp, #-16]!
    bl terminal_restore
    ldr x0, [sp], #16
    ldp x19, x20, [sp], #16
    LEAVE
// ---------------------------------------------------------------- constants
    .section __TEXT,__const
msg_undefined: .ascii "error: undefined word: "
msg_underflow: .ascii "error: stack underflow\n"
msg_runderflow: .ascii "error: return stack underflow\n"
msg_newline: .ascii "\n"
msg_lt: .ascii "<"
msg_stack_sep: .ascii "> "
msg_ok: .ascii " ok\n"
msg_compiled: .ascii " compiled\n"
prompt: .ascii "> "
banner5: .ascii "kelforth asm stage 5 - the playground. Type `bye` to quit, `words` to look around.\n"
command_raw: .asciz "stty raw -echo"
command_sane: .asciz "stty sane"
ansi_page: .byte 27, 91, 50, 74, 27, 91, 72
ansi_csi: .byte 27, 91
// Primitive names. Explicit lengths make these zero-termination independent.
name_lit: .ascii "lit"
name_branch: .ascii "branch"
name_0branch: .ascii "0branch"
name_exit: .ascii "exit"
name_add: .ascii "+"
name_sub: .ascii "-"
name_mul: .ascii "*"
name_div: .ascii "/"
name_mod: .ascii "mod"
name_negate: .ascii "negate"
name_dot: .ascii "."
name_dots: .ascii ".s"
name_cr: .ascii "cr"
name_bye: .ascii "bye"
name_backslash: .ascii "\\"
name_dup: .ascii "dup"
name_drop: .ascii "drop"
name_swap: .ascii "swap"
name_over: .ascii "over"
name_rot: .ascii "rot"
name_nip: .ascii "nip"
name_tuck: .ascii "tuck"
name_depth: .ascii "depth"
name_emit: .ascii "emit"
name_paren: .ascii "("
name_colon: .ascii ":"
name_semicolon: .ascii ";"
name_eq: .ascii "="
name_ne: .ascii "<>"
name_lt: .ascii "<"
name_gt: .ascii ">"
name_le: .ascii "<="
name_ge: .ascii ">="
name_zero_eq: .ascii "0="
name_zero_lt: .ascii "0<"
name_zero_gt: .ascii "0>"
name_and: .ascii "and"
name_or: .ascii "or"
name_xor: .ascii "xor"
name_invert: .ascii "invert"
name_true: .ascii "true"
name_false: .ascii "false"
name_space: .ascii "space"
name_paren_do: .ascii "(do)"
name_paren_loop: .ascii "(loop)"
name_paren_unloop: .ascii "(unloop)"
name_paren_plus_loop: .ascii "(+loop)"
name_i: .ascii "i"
name_j: .ascii "j"
name_dotq_runtime: .byte 40, 46, 34, 41
name_dot_quote: .byte 46, 34
name_here: .ascii "here"
name_allot: .ascii "allot"
name_comma: .ascii ","
name_fetch: .ascii "@"
name_store: .ascii "!"
name_create: .ascii "create"
name_to_r: .ascii ">r"
name_r_from: .ascii "r>"
name_r_fetch: .ascii "r@"
name_words: .ascii "words"
name_immediate: .ascii "immediate"
name_left_bracket: .ascii "["
name_right_bracket: .ascii "]"
name_literal: .ascii "literal"
name_tick: .ascii "'"
name_bracket_tick: .ascii "[']"
name_execute: .ascii "execute"
name_postpone: .ascii "postpone"
name_does_runtime: .ascii "(does>)"
name_does: .ascii "does>"
name_recurse: .ascii "recurse"
name_pick: .ascii "pick"
name_squote_runtime: .byte 40, 115, 34, 41
name_s_quote: .byte 115, 34
name_type: .ascii "type"
name_char: .ascii "char"
name_bracket_char: .ascii "[char]"
name_key: .ascii "key"
name_key_query: .ascii "key?"
name_accept: .ascii "accept"
name_pad: .ascii "pad"
name_ms: .ascii "ms"
name_page: .ascii "page"
name_at_xy: .ascii "at-xy"
core_source:
    .incbin "core.fs"
core_source_end:
// ---------------------------------------------------------- writable storage
    .section __DATA,__data
    .p2align 4
dsp: .quad 0
err_sp: .quad 0
rsp_count: .quad 0
cf_count: .quad 0
loop_count: .quad 0
dict_count: .quad 0
name_pool_here: .quad 0
source_ptr: .quad 0
source_len: .quad 0
source_pos: .quad 0
state: .quad 0
here: .quad 0
ip: .quad -1
latest_xt: .quad -1
pending_xt: .quad -1
xt_lit: .quad -1
xt_exit: .quad -1
xt_branch: .quad -1
xt_0branch: .quad -1
xt_paren_do: .quad -1
xt_paren_loop: .quad -1
xt_paren_unloop: .quad -1
xt_comma: .quad -1
xt_dotq_runtime: .quad -1
xt_does_runtime: .quad -1
xt_squote_runtime: .quad -1
typed_ahead: .quad -1
raw_enabled: .quad 0
poll_stdin: .long 0
             .short 1             // POLLIN
             .short 0             // revents
input_byte: .byte 0
output_byte: .byte 0
    .p2align 4
number_buffer: .space 64
data_stack: .space 65536
return_stack: .space 65536
loop_stack: .space 16384
dictionary: .space 49152 // 1024 entries
name_pool: .space 65536
forth_memory: .space 524288 // 65536 64-bit cells
repl_buffer: .space 65536
file_buffer: .space 1048576
    .subsections_via_symbols
