// kelforth stage1-words — standalone native AArch64 source
// This file intentionally contains only the routines and storage
// reachable by this stage. Later stages are complete copies that add
// their next layer; no shared interpreter source is included.
//
// New in stage 1, relative to stage 0:
//   - user-defined words: `: square dup * ;` — the colon compiler
//   - a real dictionary entry (48 bytes: flags, kind, value, does)
//     replacing stage 0's minimal (name, length, code) triple
//   - a threaded-code VM: colon bodies are cells of execution tokens in
//     forth_memory, walked by run_inner with the return stack for nesting
//   - a second stack (the return stack) and dpeek
//   - recoverable runtime errors: instead of stage 0's print-and-exit,
//     a fault unwinds back to `interpret` (see Lforth_throw)
//   - stack-shuffling words (dup, swap, over, rot, ...) and emit
//
// Basic AArch64 idioms (LOAD/ENTER/LEAVE, stp/ldp, scaled addressing,
// cbz/b.cond, madd/msub, tail calls) are explained line by line in
// stage 0's kelforth.s and in ../AARCH64.md; the comments here focus on
// what this stage adds.
//
// libc is used only for open/read/write/close/exit. The stacks, dictionary,
// late-bound colon definitions, tokenizer, and interpreter are assembly.
    .section __TEXT,__text,regular,pure_instructions
    .p2align 2

    // Load the address of a Mach-O symbol on Apple ARM64 (adrp+add pair;
    // see stage 0 for the full story).
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
    // New here: the trailing `immediate` flag (default 0). Immediate
    // words execute even in compile state — that is how `;` manages to
    // run at the end of a definition instead of being compiled into it.
    .macro REG name, length, fn, immediate=0
        LOAD x0, \name
        mov x1, #\length
        LOAD x2, \fn
        mov x3, #\immediate
        bl define_prim
    .endm
// ---------------------------------------------------------------- host I/O
// (Unchanged from stage 0.) Shuffle (addr,len) into C's write(fd,buf,n)
// argument registers and tail-call libc.
write_buf: // ( x0=address, x1=length -- ) write to stdout
    mov x2, x1
    mov x1, x0
    mov w0, #1                      // fd 1 = stdout
    b _write                        // tail call: _write returns for us
write_err: // ( x0=address, x1=length -- ) write to stderr
    mov x2, x1
    mov x1, x0
    mov w0, #2                      // fd 2 = stderr
    b _write
// write_number — print x0 as signed decimal; w1 nonzero appends a space.
// Digits are peeled off with udiv/msub (there is no remainder
// instruction) and stored backward from the end of number_buffer.
write_number: // x0=signed value, w1=trailing-space?
    ENTER
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    mov x19, x0                     // x19 = the value
    mov w20, w1                     // w20 = trailing-space flag
    cmp x19, #0
    cset w8, lt                     // w8 = 1 if negative
    LOAD x21, number_buffer
    add x21, x21, #64               // x21 = one past the buffer's end
    mov x22, x21                    // x22 = write cursor, moving down
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
3:  // digit loop: x6 = value mod 10, value /= 10
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
write_byte: // w0=byte — emit a single character
    LOAD x1, output_byte
    strb w0, [x1]                   // park it so it has an address
    mov x0, x1
    mov x1, #1
    b write_buf
// ----------------------------------------------------------------- stacks
// The data stack, as in stage 0: an array of 64-bit cells plus a depth
// counter, entirely separate from the CPU stack.
dpush: // x0=value
    LOAD x1, dsp
    ldr x2, [x1]
    LOAD x3, data_stack
    str x0, [x3, x2, lsl #3]        // data_stack[depth] = value
    add x2, x2, #1
    str x2, [x1]
    ret
dpop: // -> x0=value
    LOAD x1, dsp
    ldr x2, [x1]
    cbz x2, Lthrow_underflow        // empty: throw (recoverable now)
    sub x2, x2, #1
    str x2, [x1]
    LOAD x3, data_stack
    ldr x0, [x3, x2, lsl #3]
    ret
// dpeek — read the cell x0 slots below the top without popping.
// depth-x0-1 is the array index of that cell; if x0 is too large the
// subtraction goes negative, caught by testing the sign bit (bit 63)
// with tbnz — a single-bit test-and-branch, no cmp needed.
dpeek: // x0=depth -> x0=value
    LOAD x1, dsp
    ldr x2, [x1]
    sub x2, x2, x0
    sub x2, x2, #1
    tbnz x2, #63, Lthrow_underflow  // negative index: underflow
    LOAD x3, data_stack
    ldr x0, [x3, x2, lsl #3]
    ret
// The return stack — new in this stage. When a colon word calls another
// word, the VM must remember where to resume in the caller's body; the
// return stack holds those saved instruction pointers (and, in real
// Forths, whatever else programmers dare to put there). Same shape as
// the data stack: an array plus a depth counter.
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
// Recoverable errors — new in this stage (stage 0 just printed and
// exited). A stack fault can strike deep inside nested primitives, so
// recovery is a throw: print the message, abandon every machine-stack
// frame below interpret (whose sp was saved in err_sp at entry) by
// simply resetting sp to that saved value — a bare-metal longjmp — and
// return 1 from interpret, the same path an undefined word takes. This
// is also roughly how ABORT works in real Forths. The REPL then resets
// the Forth stacks; file mode exits 1.
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
Lforth_throw: // x0=message, x1=length; never returns to the faulting code
    bl write_err
    LOAD x0, state
    str xzr, [x0]                   // abandon any half-built definition
    LOAD x1, err_sp
    ldr x2, [x1]
    mov sp, x2                      // discard every frame in between
    mov x0, #1
    b Linterpret_epilogue           // "return" from interpret with 1
// ------------------------------------------------------------ input source
// (Unchanged from stage 0.) The input is a byte buffer plus a cursor;
// words that consume input advance the cursor themselves.
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
// --------------------------------------------------------------- dictionary
// Entry (48 bytes): name*, length, flags, kind, value, does-address.
// flags: bit 0 immediate, bit 1 hidden. kind: 0 prim, 1 colon,
// 2 created, 3 constant.
//
// This is the stage-1 upgrade from stage 0's three-field entry. The new
// fields:
//   flags  - immediate (runs during compilation) and hidden (invisible
//            to find_word; a definition is hidden until `;` finishes it)
//   kind   - what the `value` field means and how to execute the entry
//   value  - a machine-code address for primitives (kind 0), or the
//            first cell of a threaded-code body for colon words (kind 1)
//   does   - unused until stage 5 (-1 = none); reserved now so the
//            entry layout never changes again
// An entry's index is its execution token ("xt"). 48 is not a power of
// two, so addressing uses madd (base + xt*48) instead of a shift.
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
    str x5, [x4]                    // remember the newest definition
    mov x0, x5
    ret
// copy_name — copy x1 bytes at x0 into the name pool; return the copy.
// Needed because tokens are slices of the input buffer, and the REPL
// buffer is overwritten on every line: a dictionary entry (or a saved
// body token) must point at bytes that stay put. The pool is bump-
// allocated and never freed.
copy_name: // x0=source,x1=len -> x0=copied address
    LOAD x2, name_pool_here
    ldr x3, [x2]
    LOAD x4, name_pool
    add x4, x4, x3                  // x4 = next free byte
    mov x5, #0
1:  cmp x5, x1
    b.hs 2f
    ldrb w6, [x0, x5]               // byte-by-byte copy
    strb w6, [x4, x5]
    add x5, x5, #1
    b 1b
2:  add x3, x3, x1
    str x3, [x2]                    // bump the allocation cursor
    mov x0, x4
    ret
// define_user — create a dictionary entry for a user definition.
// Like define_prim, but the name is copied to stable storage first and
// the caller chooses kind/value/does/flags. Six arguments arrive in
// x0-x5; five must survive the copy_name call, so they are parked in
// callee-saved registers x19-x23 (pushed here, popped on the way out).
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
    bl copy_name                    // x0 (name) is consumed here
    mov x24, x0                     // x24 = the stable copy
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
// find_word — case-insensitive lookup. x0=token, x1=len -> x0=xt or -1.
// Searches backward from the newest entry, so a redefinition shadows
// the old word while old compiled references keep working. New since
// stage 0: entries whose hidden flag (bit 1) is set are skipped — that
// is what keeps a half-compiled definition from finding itself.
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
    madd x23, x21, x2, x22          // x23 = address of entry #x21
    ldr x3, [x23, #16]
    tbnz x3, #1, 1b // hidden
    ldr x3, [x23, #8]               // length must match first
    cmp x3, x20
    b.ne 1b
    ldr x24, [x23]                  // then compare the bytes
    mov x4, #0
2:  cmp x4, x20
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
// The heart of stage 1. A colon definition's body is *threaded code*:
// consecutive cells in forth_memory, each holding an execution token
// (plus inline operands for words like lit). Running a body means
// walking those cells with `ip` — the VM's instruction pointer, a cell
// index into forth_memory, not a machine address — and invoking each
// xt. ip = -1 is the sentinel for "not inside the VM / return to
// assembly". Calls nest via the return stack: enter a colon word by
// pushing the current ip and pointing ip at its body; `exit` pops it.
compile_cell: // x0=value — append one cell at `here`, the next free cell
    LOAD x1, here
    ldr x2, [x1]
    LOAD x3, forth_memory
    str x0, [x3, x2, lsl #3]        // forth_memory[here] = value
    add x2, x2, #1
    str x2, [x1]                    // here += 1
    ret
memory_load: // x0=cell address -> x0=value
    LOAD x1, forth_memory
    ldr x0, [x1, x0, lsl #3]
    ret
// invoke_xt — execute one xt while the VM is already running.
// kind 0 (primitive): call its machine code directly.
// kind 1 (colon): push the current ip on the return stack and point ip
//   at the body — the VM equivalent of `bl`. Nothing is "called" here;
//   run_inner's loop simply continues at the new ip.
invoke_xt: // x0=xt
    ENTER
    stp x19, x20, [sp, #-16]!
    mov x19, x0
    bl entry_addr
    mov x20, x0                     // x20 = entry address
    ldr x1, [x20, #24]              // x1 = kind
    cbnz x1, 1f
    ldr x2, [x20, #32]              // kind 0: value is a code address
    blr x2
    b 5f
1:  cmp x1, #1
    b.ne 2f
    LOAD x2, ip                     // kind 1: save ip, jump to the body
    ldr x0, [x2]
    bl rpush
    ldr x3, [x20, #32]              // value is the body's first cell
    LOAD x2, ip
    str x3, [x2]
    b 5f
2:  // other kinds arrive in stage 3
5:  ldp x19, x20, [sp], #16
    LEAVE
// run_inner — the inner interpreter: the VM's fetch-execute loop.
// Fetch the cell at ip, advance ip, invoke it; stop when ip returns to
// the -1 sentinel (planted by execute_outer, popped back by the final
// `exit`). Note ip is advanced *before* invoking, so a primitive that
// reads inline operands (lit) or redirects execution (branch, exit)
// sees ip already pointing at the next cell.
run_inner:
    ENTER
1:  LOAD x1, ip
    ldr x0, [x1]
    cmn x0, #1                      // cmn: flags of x0+1, so eq means
    b.eq 2f                         // ip == -1 — the VM is done
    add x2, x0, #1
    str x2, [x1]                    // ip += 1 (before executing)
    bl memory_load                  // x0 = forth_memory[old ip] = an xt
    bl invoke_xt
    b 1b
2:  LEAVE
// execute_outer — run one word from *outside* the VM (the interpreter
// found it in the source). Primitives are called directly; a colon word
// starts the VM: push the -1 sentinel (so the body's final `exit` stops
// run_inner), point ip at the body, and loop until it finishes.
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
    ldr x3, [x20, #32]              // colon word: x3 = body address
4:  mov x19, x3
    mov x0, #-1
    bl rpush                        // sentinel: "stop after this body"
    LOAD x2, ip
    str x19, [x2]
    bl run_inner
5:  ldp x19, x20, [sp], #16
    LEAVE
// parse_number — try to read a token as a signed decimal integer.
// (Unchanged from stage 0.) x0=ptr,x1=len -> x0=value, w1=success.
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
// interpret — the outer interpreter, extended with compile state.
// `state` is 0 when interpreting, 1 inside a `:` definition. The stage-0
// grammar (word -> execute, number -> push) gains compile-mode variants:
// word -> compile it (unless immediate), number -> compile `lit n`,
// and stage 1 specifically saves *unresolved* tokens for runtime lookup
// (see compile_token below). x19/x20 hold the token across calls;
// x21/x22 hold a second copy that survives the found-word path, where
// x19 is reused for the xt.
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
    cmn x0, #1                      // -1: not (yet) a defined word
    b.eq 4f
    mov x19, x0 // xt
    bl entry_addr
    ldr x2, [x0, #16]               // x2 = flags
    LOAD x3, state
    ldr x3, [x3]
    cbz x3, 3f                      // interpreting: execute
    tbnz x2, #0, 3f                 // immediate: execute even compiling
    mov x0, x21                     // compiling: save the token itself
    mov x1, x22                     // (stage 1 late-binds names; stage 2
    bl compile_token                // will compile the xt instead)
    b 1b
3:  mov x0, x19
    bl execute_outer
    b 1b
4:  mov x0, x19
    mov x1, x20
    LOAD x2, state
    ldr x2, [x2]
    cbz x2, 41f
    bl compile_token // stage 1 accepts unresolved body tokens
    b 1b
41:
    mov x0, x19
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
    str xzr, [x0]                   // abandon any half-built definition
    mov x0, #1
    b 9f
8:  mov x0, #0
9:
Linterpret_epilogue:                // Lforth_throw re-enters here after
    ldp x21, x22, [sp], #16         // resetting sp to err_sp
    ldp x19, x20, [sp], #16
    LEAVE
// compile_token — stage 1's late binding. Instead of resolving a body
// token to an xt at compile time, save the *name* (copied to the stable
// pool) and compile three cells:
//     xt of (token) | token-address | token-length
// At run time, prim_token below re-looks it up. This deliberately
// preserves the original lesson's behavior: redefine a word and old
// callers pick up the *new* definition. Stage 2 switches to compiling
// resolved xts (early binding).
compile_token: // x0=ptr, x1=len — save a late-bound token in threaded code
    ENTER
    stp x19, x20, [sp, #-16]!
    mov x19, x1
    bl copy_name
    mov x20, x0
    LOAD x0, xt_token
    ldr x0, [x0]
    bl compile_cell                 // cell 1: the (token) primitive
    mov x0, x20
    bl compile_cell                 // cell 2: name address
    mov x0, x19
    bl compile_cell                 // cell 3: name length
    ldp x19, x20, [sp], #16
    LEAVE
// prim_token — the runtime half: read the two operand cells after ip
// (advancing ip past them), look the name up *now*, and invoke it; if
// it is not a word, parse it as a number. This is what runs for every
// body token in stage 1.
prim_token:
    ENTER
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    LOAD x19, ip
    ldr x0, [x19]
    bl memory_load                  // x20 = name address (operand 1)
    mov x20, x0
    ldr x0, [x19]
    add x0, x0, #1
    str x0, [x19]                   // ip past operand 1
    bl memory_load                  // x21 = name length (operand 2)
    mov x21, x0
    ldr x0, [x19]
    add x0, x0, #1
    str x0, [x19]                   // ip past operand 2
    mov x0, x20
    mov x1, x21
    bl find_word
    cmn x0, #1
    b.eq 1f
    bl invoke_xt                    // found now: run it in the VM
    b 2f
1:  mov x0, x20
    mov x1, x21
    bl parse_number
    bl dpush
2:  ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    LEAVE
// ----------------------------------------------------- runtime primitives
// prim_lit — push the next cell of the body as a literal. The number's
// cell sits inline in the threaded code right where ip points (run_inner
// already advanced ip past lit itself), so: read it, skip it, push it.
prim_lit:
    ENTER
    LOAD x1, ip
    ldr x0, [x1]
    add x2, x0, #1
    str x2, [x1]                    // ip past the operand
    bl memory_load
    bl dpush
    LEAVE
// prim_branch — unconditional jump inside a body: the operand cell holds
// the destination, so ip = forth_memory[ip]. Compiled by stage 2's
// control-flow words; registered here so the runtime is complete.
prim_branch:
    LOAD x1, ip
    ldr x0, [x1]
    b memory_load_to_ip             // tail call does the load+store
memory_load_to_ip: // x0=cell address; ip = forth_memory[x0]
    LOAD x2, forth_memory
    ldr x0, [x2, x0, lsl #3]
    LOAD x1, ip
    str x0, [x1]
    ret
// prim_0branch — conditional jump: pop a flag; if zero, branch to the
// operand's destination, otherwise step over the operand cell.
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
// prim_exit — return from a colon word: pop the caller's ip (or the -1
// sentinel) off the return stack. `;` compiles this at the end of every
// definition.
prim_exit:
    ENTER
    bl rpop
    LOAD x1, ip
    str x0, [x1]
    LEAVE
// arithmetic — Forth calling convention: pop operands, push the result.
// The second operand comes off first (it was pushed last), so `-`
// computes a-b for "a b -". (See stage 0 for the full walkthrough.)
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
// stack manipulation — new in this stage. With no local variables,
// Forth programs arrange values explicitly with these. Each is a few
// pops and pushes; dup and over instead peek (dpeek n = copy the cell n
// slots below the top) so the original stays put.
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
    mov x9, x0                      // x9 = b
    bl dpop
    mov x10, x0                     // x10 = a
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
    mov x9, x0                      // b
    bl dpop
    mov x10, x0                     // a
    mov x0, x9
    bl dpush
    mov x0, x10
    bl dpush
    mov x0, x9
    bl dpush
    LEAVE
prim_depth: // ( -- n ) the stack depth itself
    ENTER
    LOAD x0, dsp
    ldr x0, [x0]
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
    ldr x0, [x1, x20, lsl #3]       // read in place: no popping
    mov w1, #1
    bl write_number
    add x20, x20, #1
    b 1b
2:  LEAVE
prim_emit: // ( char -- ) print one character
    ENTER
    bl dpop
    bl write_byte
    LEAVE
prim_cr: // ( -- ) newline; a bare tail call
    LOAD x0, msg_newline
    mov x1, #1
    b write_buf
prim_space: // ( -- )
    mov w0, #' '
    b write_byte
prim_bye: // ( -- ) exit the process
    mov w0, #0
    b _exit
// comments — words whose action is "advance the input cursor"
prim_backslash: // `\` skips to end of line
    mov w0, #10
    b skip_to_char
prim_paren: // `(` skips to the closing paren
    mov w0, #')'
    b skip_to_char
// -------------------------------------------------------- colon compiler
// prim_colon — `:` reads the next token as a name, creates a colon entry
// whose body will start at `here`, marks it hidden (so the incomplete
// body cannot be found — or call itself), remembers it in pending_xt,
// and flips state to compiling. From here until `;`, interpret compiles
// instead of executing.
prim_colon:
    ENTER
    bl next_token
    cbz x0, 1f                      // no name: silently ignore
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
// prim_semicolon — `;` finishes the definition: compile `exit`, clear
// the hidden bit (bic = bit-clear: AND with the complement), and return
// to interpret state. `;` itself is registered immediate — that is the
// only reason it *executes* here rather than being compiled into the
// body like every other word.
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
// ------------------------------------------------------- dictionary setup
init_dictionary:
    ENTER
    // Threaded-code runtime is present from stage 1 onward. The first
    // five primitives are compiled *into* bodies by the compiler, so
    // their xts (returned by define_prim in x0) are saved in globals
    // for it to use.
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
    REG name_token, 7, prim_token
    LOAD x1, xt_token
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
    LEAVE
// --------------------------------------------------------------------- main
// Same shell as stage 0 — file mode or a REPL — with three additions:
// ip starts at the -1 sentinel, the REPL reports " compiled" while a
// definition is open, and an error resets the return stack and ip too.
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
    LOAD x0, banner1
    mov x1, #69
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
msg_runderflow: .ascii "error: return stack underflow\n"
msg_newline: .ascii "\n"
msg_lt: .ascii "<"
msg_stack_sep: .ascii "> "
msg_ok: .ascii " ok\n"
msg_compiled: .ascii " compiled\n"
prompt: .ascii "> "
banner1: .ascii "kelforth asm stage 1 - words and the dictionary. Type `bye` to quit.\n"
// Primitive names. Explicit lengths make these zero-termination independent.
name_lit: .ascii "lit"
name_branch: .ascii "branch"
name_0branch: .ascii "0branch"
name_exit: .ascii "exit"
name_token: .ascii "(token)"
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
// ---------------------------------------------------------- writable storage
    .section __DATA,__data
    .p2align 4
dsp: .quad 0                        // data-stack depth
err_sp: .quad 0                     // machine sp saved by interpret,
                                    // restored by Lforth_throw
rsp_count: .quad 0                  // return-stack depth
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
xt_token: .quad -1
output_byte: .byte 0                // one-byte staging area for emit
    .p2align 4
number_buffer: .space 64
data_stack: .space 65536            // 8192 cells
return_stack: .space 65536
dictionary: .space 49152 // 1024 entries
name_pool: .space 65536             // stable copies of names
forth_memory: .space 524288 // 65536 64-bit cells
repl_buffer: .space 65536
file_buffer: .space 1048576
    .subsections_via_symbols
