// kelforth stage3-memory — standalone native AArch64 source
// This file intentionally contains only the routines and storage
// reachable by this stage. Later stages are complete copies that add
// their next layer; no shared interpreter source is included.
//
// New in stage 3, relative to stage 2:
//   - user-visible memory: @ ! +! ? here allot , cells cell+ — all
//     traffic through forth_memory, addressed in *cells* (a Forth
//     address is an index into the cell array, not a machine address)
//   - address checking: the three routines every access funnels through
//     (memory_load, memory_store, compile_cell) validate 0 <= addr <
//     65536 and throw "invalid memory address: N" otherwise — which
//     needs a stderr number printer (write_number_err)
//   - defining words: create (kind 2: pushes its data address, like a
//     variable), variable (create + one zeroed cell), constant (kind 3:
//     pushes a value captured at definition time)
//   - invoke_xt/execute_outer learn to run kinds 2 and 3
//
// AArch64 idioms are explained line by line in stage 0 (and the carried-
// over machinery in stages 1-2); ../AARCH64.md is the instruction-set
// reference. Comments here focus on what this stage adds.
//
// libc is used only for open/read/write/close/exit. Cell memory, defining
// words, the compiler, and the threaded interpreter are assembly.
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
write_buf: // ( x0=address, x1=length -- ) write to stdout
    mov x2, x1
    mov x1, x0
    mov w0, #1                      // fd 1 = stdout
    b _write
write_err: // ( x0=address, x1=length -- ) write to stderr
    mov x2, x1
    mov x1, x0
    mov w0, #2                      // fd 2 = stderr
    b _write
// The decimal printer now takes the file descriptor as a third
// parameter, because the bad-address error message must print the
// offending value to *stderr*. The two entry points below just pick
// the fd and fall into the shared conversion.
write_number: // x0=signed value, w1=trailing-space?
    mov w2, #1
    b write_number_fd
write_number_err: // same conversion, to stderr — for error messages with values
    mov w2, #2                      // falls straight through
write_number_fd: // x0=value, w1=trailing-space?, w2=fd
    ENTER
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    mov x19, x0                     // the value
    mov w20, w1                     // trailing-space flag
    mov w23, w2                     // the fd (survives the calls below)
    cmp x19, #0
    cset w8, lt                     // w8 = 1 if negative
    LOAD x21, number_buffer
    add x21, x21, #64               // one past the buffer's end
    mov x22, x21                    // write cursor, moving down
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
3:  // digit loop: x6 = value mod 10, value /= 10 (udiv/msub idiom)
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
4:  // call write(fd, cursor, end - cursor) directly with the chosen fd
    sub x2, x21, x22
    mov x1, x22
    mov w0, w23
    bl _write
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    LEAVE
write_byte: // w0=byte — emit a single character
    LOAD x1, output_byte
    strb w0, [x1]
    mov x0, x1
    mov x1, #1
    b write_buf
// ----------------------------------------------------------------- stacks
// (Unchanged: arrays of 64-bit cells plus depth counters.)
dpush: // x0=value
    LOAD x1, dsp
    ldr x2, [x1]
    LOAD x3, data_stack
    str x0, [x3, x2, lsl #3]
    add x2, x2, #1
    str x2, [x1]
    ret
dpop: // -> x0=value
    LOAD x1, dsp
    ldr x2, [x1]
    cbz x2, Lthrow_underflow
    sub x2, x2, #1
    str x2, [x1]
    LOAD x3, data_stack
    ldr x0, [x3, x2, lsl #3]
    ret
dpeek: // x0=depth -> x0=value, x0 slots below the top
    LOAD x1, dsp
    ldr x2, [x1]
    sub x2, x2, x0
    sub x2, x2, #1
    tbnz x2, #63, Lthrow_underflow  // negative index: underflow
    LOAD x3, data_stack
    ldr x0, [x3, x2, lsl #3]
    ret
rpush: // x0=value
    LOAD x1, rsp_count
    ldr x2, [x1]
    LOAD x3, return_stack
    str x0, [x3, x2, lsl #3]
    add x2, x2, #1
    str x2, [x1]
    ret
rpop: // -> x0=value
    LOAD x1, rsp_count
    ldr x2, [x1]
    cbz x2, Lthrow_runderflow
    sub x2, x2, #1
    str x2, [x1]
    LOAD x3, return_stack
    ldr x0, [x3, x2, lsl #3]
    ret
// Control-flow stack: compile-time only, holds branch holes and loop
// tops for if/then, begin/until, do/loop (see stage 2).
cf_push: // x0=value
    LOAD x1, cf_count
    ldr x2, [x1]
    LOAD x3, control_stack
    str x0, [x3, x2, lsl #3]
    add x2, x2, #1
    str x2, [x1]
    ret
cf_pop: // -> x0=value
    LOAD x1, cf_count
    ldr x2, [x1]
    sub x2, x2, #1
    str x2, [x1]
    LOAD x3, control_stack
    ldr x0, [x3, x2, lsl #3]
    ret
// A stack fault can strike deep inside nested primitives, so recovery is
// a throw: print the message, abandon every machine-stack frame below
// interpret (whose sp was saved at entry) by resetting sp — a bare-metal
// longjmp — and return 1 from interpret, the same path an undefined
// word takes.
Lthrow_underflow:
    LOAD x0, msg_underflow
    mov x1, #23
    b Lforth_throw
Lthrow_runderflow:
    LOAD x0, msg_runderflow
    mov x1, #30
    b Lforth_throw
Lthrow_divzero:
    LOAD x0, msg_divzero
    mov x1, #24
    b Lforth_throw
// New in this stage: the bad-address throw includes the offending
// value, so it prints three pieces (message, number, newline) before
// unwinding rather than taking the one-message Lforth_throw path.
Lthrow_badaddr: // x0 = the out-of-range cell address
    mov x19, x0 // safe to clobber: the unwind restores interpret's x19
    LOAD x0, msg_badaddr
    mov x1, #31
    bl write_err
    mov x0, x19
    mov w1, #0
    bl write_number_err             // the address itself, to stderr
    LOAD x0, msg_newline
    mov x1, #1
    bl write_err
    b Lforth_unwind
Lforth_throw: // x0=message, x1=length; never returns to the faulting code
    bl write_err                    // then falls into the unwind
Lforth_unwind:
    LOAD x0, state
    str xzr, [x0]                   // abandon any half-built definition
    LOAD x1, err_sp
    ldr x2, [x1]
    mov sp, x2                      // discard every frame in between
    mov x0, #1
    b Linterpret_epilogue
// ------------------------------------------------------------ input source
// (Unchanged; see stage 0, and stage 2 for parse_quoted.)
set_source: // x0=ptr, x1=len — install a new input buffer, cursor at 0
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
1:  // skip whitespace (any byte <= ASCII space)
    cmp x5, x3
    b.hs 4f
    ldrb w6, [x2, x5]
    cmp w6, #32
    b.hi 2f
    add x5, x5, #1
    b 1b
2:  mov x7, x5                      // token start
3:  // scan to the token's end
    cmp x5, x3
    b.hs 5f
    ldrb w6, [x2, x5]
    cmp w6, #32
    b.ls 5f
    add x5, x5, #1
    b 3b
4:  str x5, [x4]                    // EOF
    mov x0, #0
    mov x1, #0
    ret
5:  str x5, [x4]                    // return the slice
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
1:  cmp x4, x2
    b.hs 3f
    ldrb w5, [x1, x4]
    add x4, x4, #1
    cmp w5, w0
    b.ne 1b
3:  str x4, [x3]
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
    add x5, x5, #1                  // skip the single delimiter space
1:  mov x7, x5                      // string start
2:  cmp x5, x3
    b.hs 3f
    ldrb w6, [x2, x5]
    cmp w6, #'"'
    b.eq 4f
    add x5, x5, #1
    b 2b
3:  str x5, [x4]                    // unterminated: return what we have
    add x0, x2, x7
    sub x1, x5, x7
    ret
4:  add x6, x5, #1                  // step past the closing quote
    str x6, [x4]
    add x0, x2, x7
    sub x1, x5, x7
    ret
// --------------------------------------------------------------- dictionary
// Entry (48 bytes): name*, length, flags, kind, value, does-address.
// flags: bit 0 immediate, bit 1 hidden. kind: 0 prim, 1 colon,
// 2 created, 3 constant.
//
// Kinds 2 and 3 come alive in this stage: a created word's value is its
// data address in forth_memory (executing it pushes that address), a
// constant's value is pushed directly. The does-address stays -1 until
// stage 5.
entry_addr: // x0=xt -> x0=entry address
    LOAD x1, dictionary
    mov x2, #48
    madd x0, x0, x2, x1             // x0 = dictionary + xt*48
    ret
define_prim: // x0=name,x1=len,x2=fn,x3=immediate -> x0=xt
    LOAD x4, dict_count
    ldr x5, [x4]                    // x5 = new entry's index (its xt)
    LOAD x6, dictionary
    mov x7, #48
    madd x6, x5, x7, x6
    stp x0, x1, [x6]                // name, length
    stp x3, xzr, [x6, #16]          // flags, kind 0 (primitive)
    str x2, [x6, #32]               // value = machine-code address
    mov x7, #-1
    str x7, [x6, #40]               // does = -1 (none)
    add x7, x5, #1
    str x7, [x4]
    LOAD x4, latest_xt
    str x5, [x4]
    mov x0, x5
    ret
// copy_name — copy a token into the stable name pool (bump-allocated).
copy_name: // x0=source,x1=len -> x0=copied address
    LOAD x2, name_pool_here
    ldr x3, [x2]
    LOAD x4, name_pool
    add x4, x4, x3                  // next free byte
    mov x5, #0
1:  cmp x5, x1
    b.hs 2f
    ldrb w6, [x0, x5]
    strb w6, [x4, x5]
    add x5, x5, #1
    b 1b
2:  add x3, x3, x1
    str x3, [x2]
    mov x0, x4
    ret
// define_user — dictionary entry for a user definition; the caller
// chooses kind/value/does/flags (parked in callee-saved registers
// across the copy_name call).
define_user: // x0=name,x1=len,x2=kind,x3=value,x4=does,x5=flags -> x0=xt
    ENTER
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    mov x19, x1                     // length
    mov x20, x2                     // kind
    mov x21, x3                     // value
    mov x22, x4                     // does
    mov x23, x5                     // flags
    bl copy_name
    mov x24, x0                     // the stable copy
    LOAD x6, dict_count
    ldr x7, [x6]
    LOAD x8, dictionary
    mov x9, #48
    madd x8, x7, x9, x8
    stp x24, x19, [x8]              // name, length
    stp x23, x20, [x8, #16]         // flags, kind
    stp x21, x22, [x8, #32]         // value, does
    add x9, x7, #1
    str x9, [x6]
    LOAD x6, latest_xt
    str x7, [x6]
    mov x0, x7                      // return the xt
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    LEAVE
lower_byte: // w0=byte -> w0 lowercased (ASCII only)
    cmp w0, #'A'
    b.lo 1f
    cmp w0, #'Z'
    b.hi 1f
    add w0, w0, #32
1:  ret
// find_word — case-insensitive lookup, newest entry first, skipping
// hidden entries. x0=token, x1=len -> x0=xt or -1.
find_word:
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x29, x30, [sp, #-16]!
    mov x19, x0                     // token pointer
    mov x20, x1                     // token length
    LOAD x21, dict_count
    ldr x21, [x21]                  // loop index, counting down
    LOAD x22, dictionary
1:  cbz x21, 5f                     // no entries left: not found
    sub x21, x21, #1
    mov x2, #48
    madd x23, x21, x2, x22          // address of entry #x21
    ldr x3, [x23, #16]
    tbnz x3, #1, 1b // hidden
    ldr x3, [x23, #8]               // length must match first
    cmp x3, x20
    b.ne 1b
    ldr x24, [x23]
    mov x4, #0
2:  cmp x4, x20                     // then compare the bytes
    b.hs 4f
    ldrb w0, [x19, x4]
    bl lower_byte
    mov w5, w0
    ldrb w0, [x24, x4]
    bl lower_byte
    cmp w5, w0
    b.ne 1b                         // mismatch: next candidate
    add x4, x4, #1
    b 2b
4:  mov x0, x21                     // found: the index is the xt
    b 6f
5:  mov x0, #-1
6:  ldp x29, x30, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ret
// ---------------------------------------------------- compiler and inner VM
// New in this stage: every path into forth_memory is bounds-checked.
// A Forth address must satisfy 0 <= addr < 65536 (the memory size in
// cells). The negative test is a sign-bit check (tbnz bit 63); the
// upper test uses `cmp x, #16, lsl #12` — cmp immediates are 12 bits,
// optionally shifted left 12, and 16 << 12 = 65536. Programs cannot
// reach outside the array no matter what address arithmetic they do.
compile_cell: // x0=value — append one cell at `here`, bounds-checked
    LOAD x1, here
    ldr x2, [x1]
    tbnz x2, #63, Lcompile_oob      // here < 0 (after a wild allot)
    cmp x2, #16, lsl #12
    b.hs Lcompile_oob               // here >= 65536
    LOAD x3, forth_memory
    str x0, [x3, x2, lsl #3]        // forth_memory[here] = value
    add x2, x2, #1
    str x2, [x1]
    ret
Lcompile_oob: // report `here` itself as the bad address
    mov x0, x2
    b Lthrow_badaddr
memory_load: // x0=cell address -> x0=value
    tbnz x0, #63, Lthrow_badaddr    // negative address
    cmp x0, #16, lsl #12 // 65536 cells
    b.hs Lthrow_badaddr
    LOAD x1, forth_memory
    ldr x0, [x1, x0, lsl #3]
    ret
memory_store: // x0=address, x1=value
    tbnz x0, #63, Lthrow_badaddr
    cmp x0, #16, lsl #12 // 65536 cells
    b.hs Lthrow_badaddr
    LOAD x2, forth_memory
    str x1, [x2, x0, lsl #3]
    ret
// invoke_xt — execute one xt while the VM is running. Now handles all
// four kinds: primitives are called, colon bodies entered via the
// return stack, created words push their data address (and, from
// stage 5, may run a does> body), constants push their value.
invoke_xt: // x0=xt
    ENTER
    stp x19, x20, [sp, #-16]!
    mov x19, x0
    bl entry_addr
    mov x20, x0                     // entry address
    ldr x1, [x20, #24]              // kind
    cbnz x1, 1f
    ldr x2, [x20, #32]              // kind 0: call the machine code
    blr x2
    b 5f
1:  cmp x1, #1
    b.ne 2f
    LOAD x2, ip                     // kind 1: save ip, jump to the body
    ldr x0, [x2]
    bl rpush
    ldr x3, [x20, #32]
    LOAD x2, ip
    str x3, [x2]
    b 5f
2:  cmp x1, #2
    b.ne 4f
    ldr x0, [x20, #32]              // kind 2 (created): push the data
    bl dpush                        // address...
    ldr x3, [x20, #40]              // ...and if a does> body exists
    cmn x3, #1                      // (does != -1; stage 5 sets it),
    b.eq 5f                         // enter it like a colon body
    mov x19, x3
    LOAD x2, ip
    ldr x0, [x2]
    bl rpush
    LOAD x2, ip
    str x19, [x2]
    b 5f
4:  ldr x0, [x20, #32] // constant
    bl dpush
5:  ldp x19, x20, [sp], #16
    LEAVE
// run_inner — the VM's fetch-execute loop (see stage 1).
run_inner:
    ENTER
1:  LOAD x1, ip
    ldr x0, [x1]
    cmn x0, #1                      // ip == -1: the VM is done
    b.eq 2f
    add x2, x0, #1
    str x2, [x1]                    // ip += 1 (before executing)
    bl memory_load
    bl invoke_xt
    b 1b
2:  LEAVE
// execute_outer — run one word from outside the VM. Kinds 2 and 3
// mirror invoke_xt; a created word with a does> body (or a colon word)
// starts the VM with the -1 sentinel on the return stack.
execute_outer: // x0=xt
    ENTER
    stp x19, x20, [sp, #-16]!
    mov x19, x0
    bl entry_addr
    mov x20, x0
    ldr x1, [x20, #24]              // kind
    cbnz x1, 1f
    ldr x2, [x20, #32]              // primitive: plain indirect call
    blr x2
    b 5f
1:
    cmp x1, #3
    b.ne 2f
    ldr x0, [x20, #32]              // constant: push the value
    bl dpush
    b 5f
2:  cmp x1, #2
    b.ne 3f
    ldr x0, [x20, #32]              // created: push the data address
    bl dpush
    ldr x3, [x20, #40]
    cmn x3, #1                      // no does> body: done
    b.eq 5f
    b 4f                            // else run it (x3 = body address)
3:
    ldr x3, [x20, #32]              // colon word: x3 = body address
4:  mov x19, x3
    mov x0, #-1
    bl rpush                        // sentinel: "stop after this body"
    LOAD x2, ip
    str x19, [x2]
    bl run_inner
5:  ldp x19, x20, [sp], #16
    LEAVE
// parse_number — signed decimal. x0=ptr,x1=len -> x0=value, w1=success.
parse_number:
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
1:  mov x5, #0
2:  cmp x2, x1
    b.hs 3f
    ldrb w4, [x0, x2]
    sub w4, w4, #'0'
    cmp w4, #9
    b.hi 5f
    mov x6, #10
    madd x5, x5, x6, x4             // accumulator = acc*10 + digit
    add x2, x2, #1
    b 2b
3:  cbz x3, 4f
    neg x5, x5
4:  mov x0, x5
    mov w1, #1
    ret
5:  mov x0, #0
    mov w1, #0
    ret
// interpret — the outer interpreter with compile state and early
// binding (see stage 2 for the tour; unchanged here).
interpret: // current source -> x0 status
    ENTER
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    LOAD x1, err_sp // recovery point for Lforth_throw
    mov x2, sp
    str x2, [x1]
1:  bl next_token
    cbz x0, 8f
    mov x19, x0
    mov x20, x1
    mov x21, x0
    mov x22, x1
    bl find_word
    cmn x0, #1                      // -1: not a defined word
    b.eq 4f
    mov x19, x0 // xt
    bl entry_addr
    ldr x2, [x0, #16]               // flags
    LOAD x3, state
    ldr x3, [x3]
    cbz x3, 3f                      // interpreting: execute
    tbnz x2, #0, 3f                 // immediate: execute even compiling
    mov x0, x19
    bl compile_cell                 // compile the resolved xt
    b 1b
3:  mov x0, x19
    bl execute_outer
    b 1b
4:  mov x0, x19
    mov x1, x20
    bl parse_number
    cbz w1, 7f
    mov x19, x0
    LOAD x2, state
    ldr x2, [x2]
    cbz x2, 6f
    LOAD x3, xt_lit                 // compiling a number: emit `lit n`
    ldr x0, [x3]
    bl compile_cell
    mov x0, x19
    bl compile_cell
    b 1b
6:  mov x0, x19                     // interpreting a number: push it
    bl dpush
    b 1b
7:  // undefined word: report to stderr and return 1.
    LOAD x0, msg_undefined
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
8:  mov x0, #0
9:
Linterpret_epilogue:                // Lforth_unwind re-enters here
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    LEAVE
// ----------------------------------------------------- runtime primitives
// prim_lit — push the next body cell as a literal (see stage 1).
prim_lit:
    ENTER
    LOAD x1, ip
    ldr x0, [x1]
    add x2, x0, #1
    str x2, [x1]                    // ip past the operand
    bl memory_load
    bl dpush
    LEAVE
// prim_branch / prim_0branch / prim_exit — threaded-code control
// transfers (see stages 1-2).
prim_branch:
    LOAD x1, ip
    ldr x0, [x1]
    b memory_load_to_ip
memory_load_to_ip: // x0=cell address; ip = forth_memory[x0]
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
    cbnz x3, 1f                     // nonzero flag: fall through
    bl memory_load_to_ip
    LEAVE
1:  add x0, x0, #1                  // skip the destination cell
    str x0, [x1]
    LEAVE
prim_exit:
    ENTER
    bl rpop
    LOAD x1, ip
    str x0, [x1]
    LEAVE
// arithmetic (see stage 0)
prim_add: // ( a b -- a+b )
    ENTER
    bl dpop
    mov x9, x0
    bl dpop
    add x0, x0, x9
    bl dpush
    LEAVE
prim_sub: // ( a b -- a-b )
    ENTER
    bl dpop
    mov x9, x0
    bl dpop
    sub x0, x0, x9
    bl dpush
    LEAVE
prim_mul: // ( a b -- a*b )
    ENTER
    bl dpop
    mov x9, x0
    bl dpop
    mul x0, x0, x9
    bl dpush
    LEAVE
prim_div: // ( a b -- a/b )
    ENTER
    bl dpop
    mov x9, x0
    bl dpop
    cbz x9, Lthrow_divzero // after both pops (JS pop order); sdiv would silently yield 0
    sdiv x0, x0, x9
    bl dpush
    LEAVE
prim_mod: // ( a b -- a mod b )
    ENTER
    bl dpop
    mov x9, x0
    bl dpop
    cbz x9, Lthrow_divzero
    sdiv x10, x0, x9
    msub x0, x10, x9, x0            // remainder = a - (a/b)*b
    bl dpush
    LEAVE
prim_negate: // ( a -- -a )
    ENTER
    bl dpop
    neg x0, x0
    bl dpush
    LEAVE
// stack manipulation (see stage 1)
prim_dup: // ( a -- a a )
    ENTER
    mov x0, #0
    bl dpeek
    bl dpush
    LEAVE
prim_drop: // ( a -- )
    ENTER
    bl dpop
    LEAVE
prim_swap: // ( a b -- b a )
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
prim_over: // ( a b -- a b a )
    ENTER
    mov x0, #1
    bl dpeek
    bl dpush
    LEAVE
prim_rot: // ( a b c -- b c a )
    ENTER
    bl dpop
    mov x9, x0                      // c
    bl dpop
    mov x10, x0                     // b
    bl dpop
    mov x11, x0                     // a
    mov x0, x10
    bl dpush
    mov x0, x9
    bl dpush
    mov x0, x11
    bl dpush
    LEAVE
prim_nip: // ( a b -- b )
    ENTER
    bl dpop
    mov x9, x0
    bl dpop
    mov x0, x9
    bl dpush
    LEAVE
prim_tuck: // ( a b -- b a b )
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
prim_depth: // ( -- n )
    ENTER
    LOAD x0, dsp
    ldr x0, [x0]
    bl dpush
    LEAVE
// comparisons and bit logic — cmp + csetm maps CPU flags onto Forth's
// -1/0 truth values (see stage 2)
prim_eq: // ( a b -- flag )
    ENTER
    bl dpop
    mov x9, x0                      // b
    bl dpop                         // x0 = a
    cmp x0, x9
    csetm x0, eq
    bl dpush
    LEAVE
prim_ne: // ( a b -- flag )
    ENTER
    bl dpop
    mov x9, x0
    bl dpop
    cmp x0, x9
    csetm x0, ne
    bl dpush
    LEAVE
prim_lt: // ( a b -- flag ) signed a < b
    ENTER
    bl dpop
    mov x9, x0
    bl dpop
    cmp x0, x9
    csetm x0, lt
    bl dpush
    LEAVE
prim_gt: // ( a b -- flag )
    ENTER
    bl dpop
    mov x9, x0
    bl dpop
    cmp x0, x9
    csetm x0, gt
    bl dpush
    LEAVE
prim_le: // ( a b -- flag )
    ENTER
    bl dpop
    mov x9, x0
    bl dpop
    cmp x0, x9
    csetm x0, le
    bl dpush
    LEAVE
prim_ge: // ( a b -- flag )
    ENTER
    bl dpop
    mov x9, x0
    bl dpop
    cmp x0, x9
    csetm x0, ge
    bl dpush
    LEAVE
prim_zero_eq: // ( a -- flag )
    ENTER
    bl dpop
    cmp x0, #0
    csetm x0, eq
    bl dpush
    LEAVE
prim_zero_lt: // ( a -- flag )
    ENTER
    bl dpop
    cmp x0, #0
    csetm x0, lt
    bl dpush
    LEAVE
prim_zero_gt: // ( a -- flag )
    ENTER
    bl dpop
    cmp x0, #0
    csetm x0, gt
    bl dpush
    LEAVE
prim_and: // ( a b -- a&b )
    ENTER
    bl dpop
    mov x9, x0
    bl dpop
    and x0, x0, x9
    bl dpush
    LEAVE
prim_or: // ( a b -- a|b )
    ENTER
    bl dpop
    mov x9, x0
    bl dpop
    orr x0, x0, x9
    bl dpush
    LEAVE
prim_xor: // ( a b -- a^b )
    ENTER
    bl dpop
    mov x9, x0
    bl dpop
    eor x0, x0, x9
    bl dpush
    LEAVE
prim_invert: // ( a -- ~a )
    ENTER
    bl dpop
    mvn x0, x0
    bl dpush
    LEAVE
prim_true: // ( -- -1 )
    ENTER
    mov x0, #-1
    bl dpush
    LEAVE
prim_false: // ( -- 0 )
    ENTER
    mov x0, #0
    bl dpush
    LEAVE
// output
prim_dot: // ( n -- ) print and a space
    ENTER
    bl dpop
    mov w1, #1
    bl write_number
    LEAVE
prim_dots: // ( -- ) display the stack nondestructively
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
1:  cmp x20, x19
    b.hs 2f
    LOAD x1, data_stack
    ldr x0, [x1, x20, lsl #3]
    mov w1, #1
    bl write_number
    add x20, x20, #1
    b 1b
2:  LEAVE
prim_emit: // ( char -- )
    ENTER
    bl dpop
    bl write_byte
    LEAVE
prim_cr: // ( -- )
    LOAD x0, msg_newline
    mov x1, #1
    b write_buf
prim_space: // ( -- )
    mov w0, #' '
    b write_byte
prim_bye: // ( -- )
    mov w0, #0
    b _exit
// comments
prim_backslash: // `\` skips to end of line
    mov w0, #10
    b skip_to_char
prim_paren: // `(` skips to the closing paren
    mov w0, #')'
    b skip_to_char
// -------------------------------------------------------- colon compiler
// (Unchanged; see stage 1.)
prim_colon:
    ENTER
    bl next_token
    cbz x0, 1f
    mov x2, #1 // colon
    LOAD x3, here
    ldr x3, [x3]                    // value = body start (= here)
    mov x4, #-1                     // does = none
    mov x5, #2 // hidden until ;
    bl define_user
    LOAD x1, pending_xt
    str x0, [x1]
    LOAD x1, state
    mov x2, #1
    str x2, [x1]                    // enter compile state
1:  LEAVE
prim_semicolon:
    ENTER
    LOAD x0, xt_exit
    ldr x0, [x0]
    bl compile_cell                 // every body ends in exit
    LOAD x1, pending_xt
    ldr x0, [x1]
    bl entry_addr
    ldr x1, [x0, #16]
    bic x1, x1, #2                  // clear the hidden flag (bit 1)
    str x1, [x0, #16]
    LOAD x0, state
    str xzr, [x0]                   // back to interpreting
    LEAVE
// ------------------------------------------------------ native control flow
// Used by stages 2 and 3. Stages 4 and 5 define these words in core.fs.
// All immediate; forward jumps are compiled as a branch with a 0
// "hole" whose address waits on the control-flow stack until the
// closing word patches it. (See stage 2 for the full walkthrough.)
prim_if: // compile: 0branch [hole]; push hole address
    ENTER
    LOAD x0, xt_0branch
    ldr x0, [x0]
    bl compile_cell
    LOAD x0, here
    ldr x0, [x0]
    bl cf_push                      // remember where the hole is
    mov x0, #0
    bl compile_cell                 // the hole itself
    LEAVE
prim_then: // patch the pending hole to jump *here*
    ENTER
    bl cf_pop
    mov x19, x0                     // hole address
    LOAD x1, here
    ldr x1, [x1]                    // destination = current here
    mov x0, x19
    bl memory_store                 // fill the hole
    LEAVE
prim_else: // close the true branch, patch if's hole to land here
    ENTER
    bl cf_pop
    mov x19, x0                     // if's hole
    LOAD x0, xt_branch
    ldr x0, [x0]
    bl compile_cell                 // branch [new hole] over the false
    LOAD x0, here                   // branch
    ldr x0, [x0]
    bl cf_push
    mov x0, #0
    bl compile_cell
    LOAD x1, here
    ldr x1, [x1]
    mov x0, x19
    bl memory_store                 // false branch starts here
    LEAVE
prim_begin: // record the loop-start address
    ENTER
    LOAD x0, here
    ldr x0, [x0]
    bl cf_push
    LEAVE
prim_until: // compile: 0branch [begin]
    ENTER
    LOAD x0, xt_0branch
    ldr x0, [x0]
    bl compile_cell
    bl cf_pop
    bl compile_cell                 // destination: the saved begin
    LEAVE
prim_again: // compile: branch [begin]
    ENTER
    LOAD x0, xt_branch
    ldr x0, [x0]
    bl compile_cell
    bl cf_pop
    bl compile_cell
    LEAVE
prim_while: // guarded exit: same emit as `if`
    ENTER
    LOAD x0, xt_0branch
    ldr x0, [x0]
    bl compile_cell
    LOAD x0, here
    ldr x0, [x0]
    bl cf_push
    mov x0, #0
    bl compile_cell
    LEAVE
prim_repeat: // jump back to begin; while's exit lands after the loop
    ENTER
    bl cf_pop
    mov x19, x0 // hole
    bl cf_pop
    mov x20, x0 // begin destination
    LOAD x0, xt_branch
    ldr x0, [x0]
    bl compile_cell
    mov x0, x20
    bl compile_cell                 // jump back to begin
    LOAD x1, here
    ldr x1, [x1]
    mov x0, x19
    bl memory_store                 // while's exit lands here
    LEAVE
// counted loops — loop frames are (limit, index) pairs, 16 bytes each,
// hence the lsl #4 scaling (see stage 2)
prim_paren_do: // (do) runtime: ( limit index -- ) push a loop frame
    ENTER
    bl dpop
    mov x9, x0 // index
    bl dpop // limit
    LOAD x1, loop_count
    ldr x2, [x1]
    LOAD x3, loop_stack
    add x3, x3, x2, lsl #4          // frame address = base + count*16
    stp x0, x9, [x3]                // store limit and index together
    add x2, x2, #1
    str x2, [x1]
    LEAVE
prim_paren_loop: // (loop) runtime: index += 1; push "done?" flag
    ENTER
    LOAD x1, loop_count
    ldr x2, [x1]
    sub x2, x2, #1                  // topmost frame
    LOAD x3, loop_stack
    add x3, x3, x2, lsl #4
    ldp x4, x5, [x3]                // x4 = limit, x5 = index
    add x5, x5, #1
    str x5, [x3, #8]                // store the bumped index back
    cmp x5, x4
    csetm x0, ge                    // -1 (leave) when index >= limit
    bl dpush
    LEAVE
prim_paren_unloop: // (unloop) runtime: drop the loop frame
    LOAD x1, loop_count
    ldr x2, [x1]
    sub x2, x2, #1
    str x2, [x1]
    ret
prim_i: // ( -- index ) current loop index
    ENTER
    LOAD x1, loop_count
    ldr x2, [x1]
    sub x2, x2, #1
    LOAD x3, loop_stack
    add x3, x3, x2, lsl #4
    ldr x0, [x3, #8]                // the index half of the frame
    bl dpush
    LEAVE
prim_j: // ( -- index ) enclosing loop's index: one frame down
    ENTER
    LOAD x1, loop_count
    ldr x2, [x1]
    sub x2, x2, #2
    LOAD x3, loop_stack
    add x3, x3, x2, lsl #4
    ldr x0, [x3, #8]
    bl dpush
    LEAVE
prim_do: // compile (do); record the loop top
    ENTER
    LOAD x0, xt_paren_do
    ldr x0, [x0]
    bl compile_cell
    LOAD x0, here
    ldr x0, [x0]
    bl cf_push
    LEAVE
prim_loop: // compile: (loop) 0branch [top] (unloop)
    ENTER
    bl cf_pop
    mov x19, x0                     // loop-top address
    LOAD x0, xt_paren_loop
    ldr x0, [x0]
    bl compile_cell
    LOAD x0, xt_0branch
    ldr x0, [x0]
    bl compile_cell
    mov x0, x19
    bl compile_cell                 // back to the loop top
    LOAD x0, xt_paren_unloop
    ldr x0, [x0]
    bl compile_cell                 // fell out: discard the frame
    LEAVE
// -------------------------------------------------------------- memory
// The user-visible memory words — the point of this stage. Forth
// addresses are cell indices, so most of these are one dpop/dpush away
// from the checked memory_load/memory_store funnels.
prim_here: // ( -- addr ) the next free cell
    ENTER
    LOAD x0, here
    ldr x0, [x0]
    bl dpush
    LEAVE
prim_allot: // ( n -- ) reserve n cells (moving `here`)
    ENTER
    bl dpop
    LOAD x1, here
    ldr x2, [x1]
    add x2, x2, x0
    str x2, [x1]                    // no check here: the *access* is
    LEAVE                           // checked, wherever it lands
prim_comma: // ( x -- ) `,` appends one cell at here
    ENTER
    bl dpop
    bl compile_cell
    LEAVE
prim_fetch: // ( addr -- x ) `@`
    ENTER
    bl dpop
    bl memory_load
    bl dpush
    LEAVE
prim_store: // ( x addr -- ) `!`
    ENTER
    bl dpop
    mov x19, x0 // address — checked before the value is popped (JS order)
    tbnz x0, #63, Lthrow_badaddr
    cmp x0, #16, lsl #12 // 65536 cells
    b.hs Lthrow_badaddr
    bl dpop                         // now the value
    mov x1, x0
    mov x0, x19
    bl memory_store
    LEAVE
prim_plus_store: // ( n addr -- ) `+!` add n into the cell at addr
    ENTER
    bl dpop
    mov x19, x0                     // address, checked first as in `!`
    tbnz x0, #63, Lthrow_badaddr
    cmp x0, #16, lsl #12 // 65536 cells
    b.hs Lthrow_badaddr
    bl dpop
    mov x20, x0                     // n
    mov x0, x19
    bl memory_load
    add x1, x0, x20
    mov x0, x19
    bl memory_store
    LEAVE
prim_cells: // ( n -- n ) cells *are* the address unit here, so this is
    ret                             // the identity — a bare ret
prim_cell_plus: // ( addr -- addr+1 ) next cell = next index
    ENTER
    bl dpop
    add x0, x0, #1
    bl dpush
    LEAVE
prim_question: // ( addr -- ) `?` fetch and print
    ENTER
    bl dpop
    bl memory_load
    mov w1, #1
    bl write_number
    LEAVE
// The defining words. `create name` makes a kind-2 entry whose value is
// the current `here`: executing `name` pushes that address. What lives
// there is up to the program — `variable` allots one zeroed cell,
// arrays come from create + allot.
prim_create:
    ENTER
    bl next_token
    cbz x0, 1f                      // no name: silently ignore
    mov x2, #2                      // kind 2: created
    LOAD x3, here
    ldr x3, [x3]                    // value = its data address
    mov x4, #-1                     // does = none
    mov x5, #0                      // visible immediately
    bl define_user
1:  LEAVE
prim_variable: // create + one zero cell of storage
    ENTER
    bl next_token
    cbz x0, 1f
    mov x2, #2
    LOAD x3, here
    ldr x3, [x3]
    mov x4, #-1
    mov x5, #0
    bl define_user
    mov x0, #0
    bl compile_cell                 // the variable's cell, initially 0
1:  LEAVE
prim_constant: // ( n -- ) name the popped value: a kind-3 entry
    ENTER
    bl next_token
    cbz x0, 1f
    mov x19, x0                     // park the name around the dpop
    mov x20, x1
    bl dpop
    mov x3, x0                      // value = n, captured now
    mov x0, x19
    mov x1, x20
    mov x2, #3                      // kind 3: constant
    mov x4, #-1
    mov x5, #0
    bl define_user
1:  LEAVE
// ------------------------------------------------------- strings and text
// `." ..."` — the string lives inline in the threaded code as a length
// cell plus one cell per character (see stage 2).
prim_dot_quote_runtime: // print the inline string at ip
    ENTER
    LOAD x19, ip
    ldr x0, [x19]
    bl memory_load
    mov x20, x0                     // length (first operand cell)
    ldr x21, [x19]
    add x21, x21, #1
    str x21, [x19]                  // ip past the length cell
1:  cbz x20, 2f
    mov x0, x21
    bl memory_load                  // one character per cell
    bl write_byte
    add x21, x21, #1
    sub x20, x20, #1
    b 1b
2:  str x21, [x19]                  // ip past the characters
    LEAVE
compile_chars: // x0=ptr,x1=len — append one cell per character
    ENTER
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    mov x19, x0
    mov x20, x1
    mov x21, #0
1:  cmp x21, x20
    b.hs 2f
    ldrb w0, [x19, x21]
    bl compile_cell
    add x21, x21, #1
    b 1b
2:  ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    LEAVE
prim_dot_quote: // `."` — compile the runtime + inline string, or print
    ENTER                           // right away if interpreting
    bl parse_quoted
    mov x19, x0
    mov x20, x1
    LOAD x2, state
    ldr x2, [x2]
    cbz x2, 1f
    LOAD x0, xt_dotq_runtime
    ldr x0, [x0]
    bl compile_cell                 // (.") runtime
    mov x0, x20
    bl compile_cell                 // length
    mov x0, x19
    mov x1, x20
    bl compile_chars                // the characters
    b 2f
1:  mov x0, x19
    mov x1, x20
    bl write_buf
2:  LEAVE
// ------------------------------------------------------- dictionary setup
init_dictionary:
    ENTER
    // Threaded-code runtime is present from stage 1 onward. Primitives
    // that the compiler itself emits have their xts captured in globals.
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
    // Immediate words (trailing 1) execute during compilation.
    REG name_dot_quote, 2, prim_dot_quote, 1
    REG name_if, 2, prim_if, 1
    REG name_else, 4, prim_else, 1
    REG name_then, 4, prim_then, 1
    REG name_begin, 5, prim_begin, 1
    REG name_until, 5, prim_until, 1
    REG name_again, 5, prim_again, 1
    REG name_while, 5, prim_while, 1
    REG name_repeat, 6, prim_repeat, 1
    REG name_do, 2, prim_do, 1
    REG name_loop, 4, prim_loop, 1
    // The stage-3 memory vocabulary. `,`'s xt is captured for later
    // stages' postpone (and symmetry); nothing reads it in stage 3.
    REG name_here, 4, prim_here
    REG name_allot, 5, prim_allot
    REG name_comma, 1, prim_comma
    LOAD x1, xt_comma
    str x0, [x1]
    REG name_fetch, 1, prim_fetch
    REG name_store, 1, prim_store
    REG name_plus_store, 2, prim_plus_store
    REG name_cells, 5, prim_cells
    REG name_cell_plus, 5, prim_cell_plus
    REG name_question, 1, prim_question
    REG name_variable, 8, prim_variable
    REG name_constant, 8, prim_constant
    REG name_create, 6, prim_create
    LEAVE
// --------------------------------------------------------------------- main
// Same shell as stage 2: file mode or a REPL. (See stage 0 for the
// line-by-line walkthrough of this startup pattern.)
    .globl _main
_main:
    ENTER
    stp x19, x20, [sp, #-16]!
    mov x19, x0 // argc
    mov x20, x1 // argv
    LOAD x0, ip
    mov x1, #-1
    str x1, [x0]                    // VM not running
    bl init_dictionary
    cmp x19, #2
    b.lt 90f
    // ---- file mode ----
    ldr x0, [x20, #8]               // argv[1]
    mov w1, #0                      // O_RDONLY
    bl _open
    cmp w0, #0
    b.lt 97f
    mov w19, w0                     // the fd
    mov w0, w19
    LOAD x1, file_buffer
    mov x2, #1
    lsl x2, x2, #20                 // 1MB
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
90: // ---- REPL mode ----
    LOAD x0, banner3
    mov x1, #51
    bl write_buf
91: LOAD x0, prompt
    mov x1, #2
    bl write_buf
    mov w0, #0                      // stdin
    LOAD x1, repl_buffer
    mov x2, #65536
    bl _read
    cmp x0, #0
    b.le 96f                        // EOF or error: quit
    mov x20, x0
    LOAD x0, repl_buffer
    mov x1, x20
    bl set_source
    bl interpret
    cbnz x0, 94f
    LOAD x0, state
    ldr x0, [x0]
    cbnz x0, 93f                    // mid-definition: say so
    LOAD x0, msg_ok
    mov x1, #4
    bl write_buf
    b 91b
93: LOAD x0, msg_compiled
    mov x1, #10
    bl write_buf
    b 91b
94: // after an error, reset all interpreter state and carry on.
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
96: mov x0, #0
    b 98f
97: mov x0, #1
98: ldp x19, x20, [sp], #16
    LEAVE
// ---------------------------------------------------------------- constants
    .section __TEXT,__const
msg_undefined: .ascii "error: undefined word: "
msg_underflow: .ascii "error: stack underflow\n"
msg_divzero: .ascii "error: division by zero\n"
msg_badaddr: .ascii "error: invalid memory address: "
msg_runderflow: .ascii "error: return stack underflow\n"
msg_newline: .ascii "\n"
msg_lt: .ascii "<"
msg_stack_sep: .ascii "> "
msg_ok: .ascii " ok\n"
msg_compiled: .ascii " compiled\n"
prompt: .ascii "> "
banner3: .ascii "kelforth asm stage 3 - memory. Type `bye` to quit.\n"
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
name_i: .ascii "i"
name_j: .ascii "j"
name_if: .ascii "if"
name_else: .ascii "else"
name_then: .ascii "then"
name_begin: .ascii "begin"
name_until: .ascii "until"
name_again: .ascii "again"
name_while: .ascii "while"
name_repeat: .ascii "repeat"
name_do: .ascii "do"
name_loop: .ascii "loop"
// (.") and ." spelled as raw bytes: 40 46 34 41 = ( . " )
name_dotq_runtime: .byte 40, 46, 34, 41
name_dot_quote: .byte 46, 34
name_here: .ascii "here"
name_allot: .ascii "allot"
name_comma: .ascii ","
name_fetch: .ascii "@"
name_store: .ascii "!"
name_plus_store: .ascii "+!"
name_cells: .ascii "cells"
name_cell_plus: .ascii "cell+"
name_question: .ascii "?"
name_variable: .ascii "variable"
name_constant: .ascii "constant"
name_create: .ascii "create"
// ---------------------------------------------------------- writable storage
    .section __DATA,__data
    .p2align 4
dsp: .quad 0                        // data-stack depth
err_sp: .quad 0                     // machine sp saved by interpret
rsp_count: .quad 0                  // return-stack depth
cf_count: .quad 0                   // control-flow-stack depth
loop_count: .quad 0                 // loop-stack depth (in frames)
dict_count: .quad 0                 // number of dictionary entries
name_pool_here: .quad 0             // name-pool allocation cursor
source_ptr: .quad 0                 // current input: base address...
source_len: .quad 0                 // ...length...
source_pos: .quad 0                 // ...and cursor
state: .quad 0                      // 0 = interpret, 1 = compile
here: .quad 0                       // next free cell in forth_memory
ip: .quad -1                        // VM instruction pointer (-1 = idle)
latest_xt: .quad -1                 // newest definition
pending_xt: .quad -1                // definition being compiled by :
// xts of the primitives the compiler itself emits, captured at startup:
xt_lit: .quad -1
xt_exit: .quad -1
xt_branch: .quad -1
xt_0branch: .quad -1
xt_paren_do: .quad -1
xt_paren_loop: .quad -1
xt_paren_unloop: .quad -1
xt_comma: .quad -1
xt_dotq_runtime: .quad -1
output_byte: .byte 0                // one-byte staging area for emit
    .p2align 4
number_buffer: .space 64
data_stack: .space 65536            // 8192 cells
return_stack: .space 65536
control_stack: .space 8192          // compile-time branch holes
loop_stack: .space 16384            // (limit, index) frames, 16 bytes each
dictionary: .space 49152 // 1024 entries
name_pool: .space 65536             // stable copies of names
forth_memory: .space 524288 // 65536 64-bit cells
repl_buffer: .space 65536
file_buffer: .space 1048576
    .subsections_via_symbols
