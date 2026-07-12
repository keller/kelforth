// kelforth stage0-stack-machine — standalone native AArch64 source
//
// This file is the complete stage-0 interpreter and the place to start if
// AArch64 assembly is new to you. Every instruction form and idiom is
// explained the first time it appears; ../AARCH64.md is the companion
// reference for the instruction set, registers, and assembler syntax.
// Read this file top to bottom: host I/O, the data stack, the input
// cursor, the word table, the outer interpreter, the primitives, startup
// registration, and finally the constants and storage they all use.
//
// Later stages are complete copies that add their next layer; no shared
// interpreter source is included. Stage 0 is also deliberately simpler
// than a straight subset of stage 1: dictionary entries carry only the
// three fields this stage reads, and a runtime error (stack underflow,
// division by zero) simply prints its message and exits the process.
// Stage 1 grows the entries and introduces recoverable errors.
//
// libc is used only at the OS boundary: open/read/write/close/exit. The
// stack, tokenizer, number parser, word lookup, and interpreter below are
// AArch64 assembly.

    // Machine code goes in the executable's __TEXT,__text section.
    // .p2align 2 aligns to 2^2 = 4 bytes — every AArch64 instruction is
    // exactly 4 bytes and must be 4-byte aligned.
    .section __TEXT,__text,regular,pure_instructions
    .p2align 2

    // LOAD reg, sym — set reg to the address of a global symbol.
    //
    // AArch64 instructions are 4 bytes, too small to hold a 64-bit
    // address, so an address is built in two steps: adrp computes the
    // 4KB page the symbol lives in (relative to the program counter, so
    // it works wherever the OS loads us), and add fills in the offset
    // within that page. @PAGE/@PAGEOFF are the Mach-O relocations that
    // ask the linker for those two halves. Inside a macro, \reg and
    // \sym substitute the arguments.
    .macro LOAD reg, sym
        adrp \reg, \sym@PAGE
        add  \reg, \reg, \sym@PAGEOFF
    .endm
    // ENTER/LEAVE — the standard function prologue and epilogue.
    //
    // `bl` (branch-with-link, i.e. "call") stores its return address in
    // x30, the link register. A function that itself calls another
    // function would lose that address, so it must save x30 first —
    // along with x29, the frame pointer, which debuggers follow to
    // build backtraces.
    //
    // `stp a, b, [sp, #-16]!` stores the pair a,b and *pre-decrements*
    // sp by 16 (the ! writes the new address back to sp): a push.
    // `ldp a, b, [sp], #16` loads the pair and *post-increments* sp: a
    // pop. sp must stay 16-byte aligned, which is why registers travel
    // in pairs. Leaf routines that call nothing (like dpush below) skip
    // all this and just `ret`.
    .macro ENTER
        stp x29, x30, [sp, #-16]!
        mov x29, sp
    .endm
    .macro LEAVE
        ldp x29, x30, [sp], #16
        ret
    .endm
    // REG name, length, fn — register one primitive in the dictionary.
    // Marshals the three arguments into x0-x2 (the AArch64 argument
    // registers) and calls define_prim.
    .macro REG name, length, fn
        LOAD x0, \name
        mov x1, #\length
        LOAD x2, \fn
        bl define_prim
    .endm
// ---------------------------------------------------------------- host I/O
// The only door to the outside world. C's write(fd, buf, count) expects
// fd in w0, buffer address in x1, count in x2 — the C calling convention
// passes arguments in x0..x7. Our own convention (address in x0, length
// in x1) differs, so these wrappers shuffle registers, then jump to
// _write with `b` rather than `bl`: a tail call. _write's `ret` returns
// straight to our caller, so no frame is needed here. (On macOS, C
// symbols get a leading underscore: C write is assembly _write.)
write_buf: // ( x0=address, x1=length -- ) write to stdout
    mov x2, x1                      // count       (3rd C argument)
    mov x1, x0                      // buffer      (2nd C argument)
    mov w0, #1                      // fd 1 = stdout
    b _write                        // tail call: _write returns for us
write_err: // ( x0=address, x1=length -- ) write to stderr
    mov x2, x1
    mov x1, x0
    mov w0, #2                      // fd 2 = stderr
    b _write
// write_number — print x0 as signed decimal; w1 nonzero appends a space.
//
// There is no printf here, so this converts by hand: divide by 10
// repeatedly, storing digits from the *end* of a small buffer backward
// (the remainders come out least-significant first). This routine calls
// write_buf at the end, so it keeps its working values in x19-x22 —
// callee-saved registers that survive calls — after pushing the caller's
// copies. w-registers are the low 32 bits of the x-registers; they are
// used here for single bytes and flags.
write_number: // x0=signed value, w1=trailing-space?
    ENTER
    stp x19, x20, [sp, #-16]!       // push two callee-saved registers
    stp x21, x22, [sp, #-16]!       // (pairs keep sp 16-byte aligned)
    mov x19, x0                     // x19 = the value
    mov w20, w1                     // w20 = trailing-space flag
    cmp x19, #0                     // compare sets the NZCV flags...
    cset w8, lt                     // ...cset reads them: w8 = 1 if the
                                    // value is negative (lt), else 0
    LOAD x21, number_buffer
    add x21, x21, #64               // x21 = one past the buffer's end
    mov x22, x21                    // x22 = write cursor, moving down
    cbz w20, 1f                     // "compare and branch if zero":
                                    // skip the space unless requested.
                                    // 1f = nearest label `1:` forward
    sub x22, x22, #1
    mov w3, #' '                    // character literals are immediates
    strb w3, [x22]                  // strb stores one byte
1:
    cmp x19, #0
    b.ge 2f                         // branch if signed >= 0
    neg x19, x19 // unsigned magnitude also handles INT64_MIN
2:
    mov x4, #10
3:  // digit loop: peel off the lowest digit until the value is 0.
    // AArch64 has no remainder instruction; the idiom is a divide
    // followed by msub (multiply-subtract): x6 = x19 - x5*10.
    udiv x5, x19, x4                // x5 = value / 10
    msub x6, x5, x4, x19            // x6 = value mod 10
    add w6, w6, #'0'                // digit -> ASCII
    sub x22, x22, #1
    strb w6, [x22]
    mov x19, x5
    cbnz x19, 3b                    // loop while quotient nonzero
                                    // (3b = nearest `3:` backward)
    cbz w8, 4f                      // negative? then prepend '-'
    sub x22, x22, #1
    mov w6, #'-'
    strb w6, [x22]
4:
    mov x0, x22                     // buffer starts at the cursor...
    sub x1, x21, x22                // ...and runs to the buffer's end
    bl write_buf
    ldp x21, x22, [sp], #16         // pop in reverse order of the pushes
    ldp x19, x20, [sp], #16
    LEAVE
write_byte: // w0=byte — emit a single character
    LOAD x1, output_byte
    strb w0, [x1]                   // park the byte in memory so it has
    mov x0, x1                      // an address write_buf can point at
    mov x1, #1
    b write_buf                     // tail call
// ----------------------------------------------------------------- stacks
// Forth's data stack is NOT the CPU stack. It is an ordinary array of
// 64-bit cells (data_stack) plus a depth counter (dsp), both in the
// __DATA section. The CPU stack (sp) keeps holding return addresses and
// saved registers, exactly as the calling convention prescribes; the
// Forth stack is language state, managed only by these two routines.
dpush: // x0=value
    LOAD x1, dsp                    // x1 = address of the depth counter
    ldr x2, [x1]                    // x2 = current depth
    LOAD x3, data_stack
    str x0, [x3, x2, lsl #3]        // data_stack[depth] = value.
                                    // [x3, x2, lsl #3] addresses
                                    // x3 + (x2 << 3): the index scaled
                                    // by 8 bytes — a 64-bit "cell"
    add x2, x2, #1
    str x2, [x1]                    // depth += 1
    ret                             // leaf routine: no frame to unwind
dpop: // -> x0=value
    LOAD x1, dsp
    ldr x2, [x1]
    cbz x2, Lerror_underflow        // popping an empty stack is an error
    sub x2, x2, #1
    str x2, [x1]                    // depth -= 1
    LOAD x3, data_stack
    ldr x0, [x3, x2, lsl #3]        // fetch the cell that was on top
    ret
// Fatal errors. In stage 0 a stack fault or division by zero simply
// prints its message to stderr and exits with status 1 — a fault can
// strike deep inside a primitive, and aborting sidesteps the question of
// how to climb back out. Stage 1 replaces this with a recoverable
// "throw" that unwinds to the interpreter loop instead of exiting.
// Labels starting with L are assembler-local: they never appear in the
// executable's symbol table.
Lerror_underflow:
    LOAD x0, msg_underflow
    mov x1, #23                     // message length (no NUL terminators
                                    // anywhere; strings are addr+len)
    b Lfatal_error
Lerror_divzero:
    LOAD x0, msg_divzero
    mov x1, #24
    b Lfatal_error
Lfatal_error: // x0=message, x1=length; never returns
    bl write_err                    // clobbering x30 is fine: we exit
    mov w0, #1
    b _exit                         // exit(1)
// ------------------------------------------------------------ input source
// The input is a byte buffer described by three globals: source_ptr,
// source_len, and source_pos (the cursor). Words that consume input —
// here just `\`, later `:` and friends — advance the cursor themselves,
// which is how Forth gets away without a separate lexer.
set_source: // x0=ptr, x1=len — install a new input buffer, cursor at 0
    LOAD x2, source_ptr
    str x0, [x2]
    LOAD x2, source_len
    str x1, [x2]
    LOAD x2, source_pos
    str xzr, [x2]                   // xzr always reads as zero: this is
                                    // the idiom for "store a 0"
    ret
// next_token — scan for the next whitespace-delimited token.
// Returns x0=pointer, x1=length; x0=0 signals end of input. Never
// copies: the "token" is a slice of the source buffer itself.
next_token:
    LOAD x2, source_ptr
    ldr x2, [x2]                    // x2 = buffer base
    LOAD x3, source_len
    ldr x3, [x3]                    // x3 = buffer length
    LOAD x4, source_pos
    ldr x5, [x4]                    // x5 = cursor (x4 keeps the address
                                    // so the cursor can be stored back)
1:  // skip leading whitespace: any byte <= ASCII space (32) counts,
    // which covers space, tab, newline, and carriage return.
    cmp x5, x3
    b.hs 4f                         // b.hs = unsigned >=: cursor at end.
                                    // positions/lengths compare unsigned
    ldrb w6, [x2, x5]               // w6 = byte at cursor
    cmp w6, #32
    b.hi 2f                         // unsigned > 32: found a token byte
    add x5, x5, #1
    b 1b
2:  mov x7, x5                      // x7 = token start
3:  // scan to the token's end: the next byte <= 32, or end of input.
    cmp x5, x3
    b.hs 5f
    ldrb w6, [x2, x5]
    cmp w6, #32
    b.ls 5f                         // unsigned <=: hit whitespace
    add x5, x5, #1
    b 3b
4:  // end of input before any token: report EOF.
    str x5, [x4]                    // store the cursor back
    mov x0, #0
    mov x1, #0
    ret
5:  // token found: return its slice.
    str x5, [x4]
    add x0, x2, x7                  // pointer = base + start
    sub x1, x5, x7                  // length  = end - start
    ret
skip_to_char: // w0=delimiter; advance the cursor past it (or to EOF).
// This powers `\` comments: "skip to newline" is all a line comment is.
    LOAD x1, source_ptr
    ldr x1, [x1]
    LOAD x2, source_len
    ldr x2, [x2]
    LOAD x3, source_pos
    ldr x4, [x3]
1:  cmp x4, x2
    b.hs 3f
    ldrb w5, [x1, x4]
    add x4, x4, #1                  // consume the byte either way
    cmp w5, w0
    b.ne 1b
3:  str x4, [x3]
    ret
// --------------------------------------------------------------- dictionary
// The word table. Each entry is 32 bytes: name pointer at offset 0, name
// length at 8, code address at 16, and one spare cell so the stride is a
// power of two — entry #n lives at dictionary + n*32, a single shifted
// add. An entry's index is its execution token ("xt"). Stage 1 widens
// entries with flags, a kind, and a value; stage 0 needs none of that.
entry_addr: // x0=xt -> x0=entry address
    LOAD x1, dictionary
    add x0, x1, x0, lsl #5          // x0 = dictionary + xt*32; the third
                                    // operand can be shifted for free
    ret
define_prim: // x0=name, x1=len, x2=code address — append one entry
    LOAD x4, dict_count
    ldr x5, [x4]                    // x5 = current entry count = new xt
    LOAD x6, dictionary
    add x6, x6, x5, lsl #5          // x6 = address of the new entry
    stp x0, x1, [x6]                // store name and length as a pair
    str x2, [x6, #16]               // store the code address
    add x5, x5, #1
    str x5, [x4]                    // dict_count += 1
    ret
lower_byte: // w0=byte -> w0 lowercased (ASCII only)
    cmp w0, #'A'
    b.lo 1f                         // below 'A': not a letter
    cmp w0, #'Z'
    b.hi 1f                         // above 'Z': already lowercase or
                                    // not a letter
    add w0, w0, #32                 // 'A'..'Z' -> 'a'..'z'
1:  ret
// find_word — case-insensitive lookup. x0=token, x1=len -> x0=xt or -1.
//
// Searches *backward* from the newest entry so that (in later stages) a
// redefined word shadows the old one while the old entry survives. This
// routine calls lower_byte in its inner loop, so everything it needs
// across those calls lives in callee-saved registers x19-x24, pushed
// here and popped on the way out. It saves x29/x30 by hand instead of
// using ENTER — same effect, and all four pops mirror the pushes.
find_word:
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x29, x30, [sp, #-16]!
    mov x19, x0                     // x19 = token pointer
    mov x20, x1                     // x20 = token length
    LOAD x21, dict_count
    ldr x21, [x21]                  // x21 = loop index, counting down
    LOAD x22, dictionary
1:  // candidate loop: try entry x21-1, x21-2, ... down to 0.
    cbz x21, 5f                     // no entries left: not found
    sub x21, x21, #1
    add x23, x22, x21, lsl #5       // x23 = address of entry #x21
    ldr x3, [x23, #8]               // its name length...
    cmp x3, x20
    b.ne 1b                         // ...must match before comparing text
    ldr x24, [x23]                  // x24 = its name pointer
    mov x4, #0                      // x4 = character index
2:  // character loop: compare the two names, case-insensitively.
    cmp x4, x20
    b.hs 4f                         // compared every byte: a match
    ldrb w0, [x19, x4]
    bl lower_byte
    mov w5, w0
    ldrb w0, [x24, x4]
    bl lower_byte
    cmp w5, w0
    b.ne 1b                         // mismatch: next candidate
    add x4, x4, #1
    b 2b
4:  mov x0, x21                     // found: return the index (the xt)
    b 6f
5:  mov x0, #-1                     // not found
6:  ldp x29, x30, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ret
// ---------------------------------------------------------- outer interpreter
execute_outer: // x0=xt — run one word
    ENTER
    bl entry_addr
    ldr x2, [x0, #16]               // fetch the entry's code address
    blr x2                          // and call it: blr is `bl` with the
                                    // target in a register — this one
                                    // indirect call is what makes `+` a
                                    // table entry instead of syntax
    LEAVE
// parse_number — try to read a token as a signed decimal integer.
// x0=ptr, x1=len -> x0=value, w1=1 on success / 0 on failure.
// A leaf routine: no calls, so scratch registers x2-x6 need no saving.
parse_number:
    cbz x1, 5f                      // empty token: not a number
    mov x2, #0                      // x2 = character index
    mov x3, #0 // negative flag
    ldrb w4, [x0]
    cmp w4, #'-'
    b.ne 1f
    mov x3, #1                      // leading '-': note it, skip it
    add x2, x2, #1
    cmp x2, x1
    b.eq 5f                         // "-" alone is not a number
1:  mov x5, #0                      // x5 = accumulator
2:  cmp x2, x1
    b.hs 3f                         // consumed every character: done
    ldrb w4, [x0, x2]
    sub w4, w4, #'0'                // digit value, if it is a digit
    cmp w4, #9
    b.hi 5f                         // not '0'..'9' (as unsigned, any
                                    // non-digit lands above 9): fail
    mov x6, #10
    madd x5, x5, x6, x4             // multiply-add: x5 = x5*10 + digit
    add x2, x2, #1
    b 2b
3:  cbz x3, 4f
    neg x5, x5                      // apply the recorded sign
4:  mov x0, x5
    mov w1, #1
    ret
5:  mov x0, #0
    mov w1, #0
    ret
// interpret — the outer interpreter and the whole Forth grammar:
//   token is a word  -> execute it
//   token is a number -> push it
//   otherwise         -> report "undefined word", return 1
// Returns 0 in x0 at end of input. There is no AST and no parser beyond
// next_token; later stages extend this same loop rather than replacing
// it. The token's pointer/length are parked in x19/x20 because they must
// survive the find_word call.
interpret: // current source -> x0 status
    ENTER
    stp x19, x20, [sp, #-16]!
1:  bl next_token
    cbz x0, 8f                      // x0=0: end of input
    mov x19, x0                     // save the token slice: find_word
    mov x20, x1                     // returns *its* result in x0/x1
    bl find_word
    cmn x0, #1                      // cmn adds: x0 + 1 sets the flags,
                                    // so eq here means x0 == -1 (there
                                    // is no cmp-with-negative-immediate)
    b.eq 4f                         // not a word: try it as a number
    bl execute_outer                // x0 is the xt
    b 1b
4:  mov x0, x19
    mov x1, x20
    bl parse_number
    cbz w1, 7f                      // not a number either
    bl dpush                        // x0 is the parsed value
    b 1b
7:  // undefined word: "error: undefined word: <token>\n" to stderr.
    LOAD x0, msg_undefined
    mov x1, #23
    bl write_err
    mov x0, x19
    mov x1, x20
    bl write_err
    LOAD x0, msg_newline
    mov x1, #1
    bl write_err
    mov x0, #1                      // status 1: something went wrong
    b 9f
8:  mov x0, #0                      // status 0: clean end of input
9:  ldp x19, x20, [sp], #16
    LEAVE
// ----------------------------------------------------- runtime primitives
// Every primitive follows the Forth calling convention, not the C one:
// arguments come from the Forth data stack and results go back there.
// The registers only ferry values between dpop and dpush. Note the
// pattern in the binary operators: the *second* operand comes off the
// stack first (it was pushed last), so `-` computes a-b for "a b -".
// x9 is a caller-saved scratch register, safe here because dpop/dpush
// are leaf routines that never touch it.
// arithmetic
prim_add: // ( a b -- a+b )
    ENTER
    bl dpop                         // x0 = b
    mov x9, x0
    bl dpop                         // x0 = a
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
prim_div: // ( a b -- a/b ) signed division, truncating toward zero
    ENTER
    bl dpop
    mov x9, x0
    bl dpop
    cbz x9, Lerror_divzero // after both pops (JS pop order); sdiv would silently yield 0
    sdiv x0, x0, x9
    bl dpush
    LEAVE
prim_mod: // ( a b -- a mod b ) via the same udiv/msub idiom as printing
    ENTER
    bl dpop
    mov x9, x0
    bl dpop
    cbz x9, Lerror_divzero
    sdiv x10, x0, x9                // x10 = a / b
    msub x0, x10, x9, x0            // x0  = a - (a/b)*b = remainder
    bl dpush
    LEAVE
prim_negate: // ( a -- -a )
    ENTER
    bl dpop
    neg x0, x0
    bl dpush
    LEAVE
// output
prim_dot: // ( n -- ) print the top of stack and a space
    ENTER
    bl dpop
    mov w1, #1                      // with a trailing space
    bl write_number
    LEAVE
prim_dots: // ( -- ) display the stack as "<depth> v1 v2 ..." nondestructively
    ENTER
    stp x19, x20, [sp, #-16]!       // this routine loops across calls,
                                    // so its state needs saved registers
    LOAD x0, msg_lt
    mov x1, #1
    bl write_buf
    LOAD x19, dsp
    ldr x19, [x19]                  // x19 = depth
    mov x0, x19
    mov w1, #0
    bl write_number
    LOAD x0, msg_stack_sep
    mov x1, #2
    bl write_buf
    mov x20, #0                     // x20 = index from the stack bottom
    cbnz x19, 1f
    bl prim_space // JS edition prints two spaces for <0>
    b 2f
1:  cmp x20, x19
    b.hs 2f
    LOAD x1, data_stack
    ldr x0, [x1, x20, lsl #3]       // read cells in place: no popping
    mov w1, #1
    bl write_number
    add x20, x20, #1
    b 1b
2:  ldp x19, x20, [sp], #16
    LEAVE
prim_cr: // ( -- ) newline; the whole body is one tail call
    LOAD x0, msg_newline
    mov x1, #1
    b write_buf
prim_space: // ( -- )
    mov w0, #' '
    b write_byte
prim_bye: // ( -- ) exit the process with status 0
    mov w0, #0
    b _exit
// comments
prim_backslash: // `\` skips the rest of the line — a comment is just a
    mov w0, #10                     // word whose action is "advance the
    b skip_to_char                  // input cursor to the newline (10)"
// ------------------------------------------------------- dictionary setup
// Startup: register every primitive by name. Even `+` is an ordinary
// dictionary entry, not parser syntax — that uniformity is what will let
// user definitions stand beside primitives from stage 1 on.
init_dictionary:
    ENTER
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
    REG name_backslash, 1, prim_backslash
    LEAVE
// --------------------------------------------------------------------- main
// C startup calls main(argc, argv) with argc in x0 and argv in x1.
// With a filename argument: read the file, interpret it once, exit with
// interpret's status. With no argument: a read-eval-print loop.
// .globl exports _main so the linker can find the entry point.
    .globl _main
_main:
    ENTER
    stp x19, x20, [sp, #-16]!
    mov x19, x0 // argc
    mov x20, x1 // argv
    bl init_dictionary
    cmp x19, #2
    b.lt 90f                        // no filename: go to the REPL
    // ---- file mode ----
    ldr x0, [x20, #8]               // argv[1]: argv is an array of
                                    // 8-byte pointers, so +8 skips
                                    // argv[0], the program name
    mov w1, #0                      // O_RDONLY
    bl _open
    cmp w0, #0
    b.lt 97f                        // open failed (returned -1)
    mov w19, w0                     // x19 now holds the fd (argc is done)
    mov w0, w19
    LOAD x1, file_buffer
    mov x2, #1
    lsl x2, x2, #20                 // 1 << 20 = 1MB: immediates are
                                    // small, big constants are shifted
    bl _read
    mov x20, x0                     // x20 = bytes read (or -1)
    mov w0, w19
    bl _close
    cmp x20, #0
    b.lt 97f                        // read failed
    LOAD x0, file_buffer
    mov x1, x20
    bl set_source
    bl interpret
    b 98f                           // exit with interpret's status
90: // ---- REPL mode ----
    LOAD x0, banner0
    mov x1, #62
    bl write_buf
91: // one iteration: prompt, read a line, interpret it.
    LOAD x0, prompt
    mov x1, #2
    bl write_buf
    mov w0, #0                      // fd 0 = stdin
    LOAD x1, repl_buffer
    mov x2, #65536
    bl _read
    cmp x0, #0
    b.le 96f                        // 0 = EOF (ctrl-D), <0 = error: quit
    mov x20, x0
    LOAD x0, repl_buffer
    mov x1, x20
    bl set_source
    bl interpret
    cbnz x0, 94f                    // an error was already printed
    LOAD x0, msg_ok
    mov x1, #4
    bl write_buf
    b 91b
94: // after an undefined word, clear the stack and carry on.
    LOAD x0, dsp
    str xzr, [x0]
    b 91b
96: mov x0, #0                      // clean EOF: exit 0
    b 98f
97: mov x0, #1                      // file trouble: exit 1
98: ldp x19, x20, [sp], #16
    LEAVE                           // returning from main exits with x0
// ---------------------------------------------------------------- constants
// Read-only data. .ascii emits the bytes with no NUL terminator — every
// string in this program travels as an (address, length) pair.
    .section __TEXT,__const
msg_undefined: .ascii "error: undefined word: "
msg_underflow: .ascii "error: stack underflow\n"
msg_divzero: .ascii "error: division by zero\n"
msg_newline: .ascii "\n"
msg_lt: .ascii "<"
msg_stack_sep: .ascii "> "
msg_ok: .ascii " ok\n"
prompt: .ascii "> "
banner0: .ascii "kelforth asm stage 0 - the stack machine. Type `bye` to quit.\n"
// Primitive names. Explicit lengths make these zero-termination independent.
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
// ---------------------------------------------------------- writable storage
// All interpreter state, zero-initialized unless stated. .quad reserves
// one 64-bit value, .space N reserves N bytes. This is the entire
// machine: five scalars and four buffers.
    .section __DATA,__data
    .p2align 4
dsp: .quad 0                        // data-stack depth, in cells
dict_count: .quad 0                 // number of dictionary entries
source_ptr: .quad 0                 // current input: base address...
source_len: .quad 0                 // ...length...
source_pos: .quad 0                 // ...and cursor
output_byte: .byte 0                // one-byte staging area for emit
    .p2align 4
number_buffer: .space 64            // digits are built here, backward
data_stack: .space 65536            // 8192 cells of 8 bytes
dictionary: .space 32768 // 1024 entries of 32 bytes
repl_buffer: .space 65536
file_buffer: .space 1048576         // 1MB: the file-mode source
    .subsections_via_symbols
