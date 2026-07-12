# AArch64 assembly, as used in kelforth

This is the instruction-set companion to the commented `kelforth.s` sources.
The inline comments in each stage explain *what a line accomplishes in
context*; this file explains *how the machine and the assembler work* so
those comments have something to stand on. Everything here is limited to
what the kelforth sources actually use — it is a reading guide, not an
architecture manual.

The target is Apple Silicon (ARM64/AArch64) under macOS, assembled by
clang's integrated assembler into Mach-O object files. A few details below
(leading underscores, `@PAGE` relocations, the reserved `x18`) are
Apple-specific and called out as such.

## 1. The mental model

AArch64 is a RISC load/store architecture:

- Arithmetic and logic happen **only between registers**. Memory is touched
  only by explicit load (`ldr`) and store (`str`) instructions.
- Every instruction is exactly 4 bytes. There is no variable-length
  encoding and no memory-to-memory move.
- There are a lot of registers (31 general-purpose), so most small routines
  never spill values to memory at all.

A typical kelforth routine is therefore a rhythm of: load a global into a
register, compute, store it back, branch.

## 2. Registers

There are 31 general-purpose 64-bit registers, `x0`–`x30`, plus:

| name | meaning |
| --- | --- |
| `sp` | the machine stack pointer (must stay 16-byte aligned when used to access memory) |
| `xzr` / `wzr` | the zero register: reads as 0, writes are discarded |
| `pc` | the program counter — not directly readable/writable; changed by branches |

Each `xN` has a 32-bit view named `wN` — the low half of the same register.
`mov w0, #1` writes 1 and **zeroes the upper 32 bits**; `ldrb w6, [x2]`
loads one byte zero-extended into 32 bits. kelforth uses `w` registers for
bytes, characters, and file descriptors, and `x` registers for Forth cells
(64-bit values), pointers, and indices.

### Roles under the calling convention (AAPCS64, as Apple applies it)

| registers | role |
| --- | --- |
| `x0`–`x7` | arguments and return values; scratch (caller-saved) |
| `x8` | indirect-result pointer; effectively scratch here |
| `x9`–`x15` | scratch (caller-saved temporaries) |
| `x16`, `x17` | scratch, but the linker may clobber them in branch veneers — avoid holding values across calls |
| `x18` | **reserved by the platform on Apple — never touch** |
| `x19`–`x28` | callee-saved: a function that uses them must save and restore them |
| `x29` (`fp`) | frame pointer |
| `x30` (`lr`) | link register: `bl` writes the return address here |

"Caller-saved" means any `bl` (function call) may destroy the register, so
a value that must survive a call goes in `x19`–`x28` (after saving the old
contents) — which is exactly the `stp x19, x20, [sp, #-16]!` /
`ldp x19, x20, [sp], #16` pairs you see bracketing many kelforth routines.
Leaf code that makes no calls (like `dpush`) freely uses `x0`–`x15` and
saves nothing.

## 3. Calls, returns, and the link register

- `bl label` — branch-with-link: sets `x30` to the address of the next
  instruction, then jumps. This is a function call.
- `ret` — jumps to the address in `x30`. This is a function return.
- `blr xN` — like `bl` but the target address is in a register (an
  indirect call). kelforth uses this to invoke a primitive whose code
  address was fetched from the dictionary.
- `b label` — plain jump, `x30` untouched.

Because `bl` *overwrites* `x30`, a function that itself calls functions
must save `x30` first, or it can never return. That is what the `ENTER` /
`LEAVE` macros do (see §6). A function that calls nothing (a *leaf*
function) can skip all of that and just `ret` — most of the small helpers
in kelforth are leaves.

One idiom worth recognizing: **a tail call is written as `b`, not `bl`**.
When the last thing a function does is call another function and return
its result, jumping with `b` lets the callee's `ret` return directly to
the original caller — no frame needed. `write_buf` ends in `b _write` for
exactly this reason, and `prim_cr` is *entirely* a tail call.

## 4. Loads, stores, and addressing modes

`ldr`/`str` move a 64-bit value; `ldrb`/`strb` move one byte (the register
is written zero-extended / read from its low 8 bits). `ldp`/`stp` move a
*pair* of 64-bit registers to/from adjacent memory in one instruction.

The addressing modes used in kelforth:

| syntax | meaning |
| --- | --- |
| `[x1]` | address is `x1` |
| `[x6, #16]` | address is `x6 + 16` (offset does **not** change `x6`) |
| `[x3, x2, lsl #3]` | address is `x3 + (x2 << 3)` — array indexing with an 8× scale |
| `[sp, #-16]!` | **pre-index**: first `sp -= 16`, then use `sp` as the address |
| `[sp], #16` | **post-index**: use `sp` as the address, then `sp += 16` |

The scaled form `[base, index, lsl #3]` is the machine meaning of "array
of 64-bit cells": shift the index left 3 (multiply by 8) and add it to the
base. All the Forth stacks and `forth_memory` are addressed this way.

Pre-index with a negative offset is a *push*; post-index with a positive
offset is a *pop*. So:

```asm
stp x19, x20, [sp, #-16]!   // push x19 and x20 (sp moves down 16)
ldp x19, x20, [sp], #16     // pop them back (sp moves up 16)
```

`sp` must remain 16-byte aligned whenever it is used to access memory,
which is why everything is pushed in pairs of 8-byte registers, and why a
single value is still pushed with a 16-byte slot (`str x0, [sp, #-16]!`).

## 5. Getting the address of a global: `adrp` + `@PAGE`

There is no "load a 64-bit address constant" instruction — instructions
are only 4 bytes. Position-independent code on Mach-O materializes an
address in two steps:

```asm
adrp x1, dsp@PAGE           // x1 = 4KB page containing dsp (PC-relative)
add  x1, x1, dsp@PAGEOFF    // x1 += offset of dsp within that page
```

`adrp` computes the address of the 4KB *page* a symbol lives in, relative
to the program counter (reach: ±4GB), and `@PAGEOFF` supplies the
remaining low 12 bits. The pair works no matter where the OS loads the
executable (ASLR). It appears so often that kelforth wraps it in a macro:

```asm
.macro LOAD reg, sym
    adrp \reg, \sym@PAGE
    add  \reg, \reg, \sym@PAGEOFF
.endm
```

So every `LOAD x1, dsp` in the sources reads as "x1 = address of the
global `dsp`". Note it loads the **address**; a following `ldr x2, [x1]`
fetches the **value**.

## 6. Function prologue and epilogue: `ENTER` / `LEAVE`

```asm
.macro ENTER
    stp x29, x30, [sp, #-16]!   // push frame pointer and return address
    mov x29, sp                 // start this function's frame
.endm
.macro LEAVE
    ldp x29, x30, [sp], #16     // restore them
    ret
.endm
```

This is the standard AArch64 frame: save the caller's `x29`/`x30` as a
pair, point `x29` at the new frame (debuggers walk the chain of saved
`x29` values to produce backtraces). Any routine that contains a `bl`
needs this, because `bl` clobbers `x30`.

Routines that also need `x19`+ push those pairs *after* `ENTER` and pop
them in reverse order *before* `LEAVE` — stack operations must nest.

## 7. Moving values and constants

- `mov x9, x0` — register copy.
- `mov x4, #10` — small immediate constant. Character literals work too:
  `mov w3, #' '` is the space character (32).
- `neg x0, x0` — two's-complement negate.
- `mvn x0, x0` — bitwise NOT ("move-not").
- `mov x0, #-1` — all-ones, encodable as an immediate. `-1` is Forth's
  canonical `true`, and kelforth also uses it as an "empty/none" sentinel
  (for the threaded-code `ip`, unset `xt_*` cells, and `find_word`'s
  "not found").
- `str xzr, [x0]` — store zero without needing a register that holds 0:
  the zero register *is* that register.

Larger constants are built with shifts: `mov x2, #1` then
`lsl x2, x2, #20` produces 1MB (1 << 20).

## 8. Arithmetic

| instruction | effect |
| --- | --- |
| `add xd, xn, xm` / `sub` | `xd = xn ± xm` (register or `#imm` for the last operand) |
| `mul xd, xn, xm` | `xd = xn * xm` (low 64 bits) |
| `sdiv` / `udiv xd, xn, xm` | signed / unsigned divide, **truncating toward zero**; divide-by-zero yields 0 with no trap — kelforth must check for zero itself |
| `madd xd, xn, xm, xa` | multiply-add: `xd = xa + xn*xm` — one-instruction "base + index*size" and "acc*10 + digit" |
| `msub xd, xn, xm, xa` | multiply-subtract: `xd = xa - xn*xm` — with `xn = a/b` this yields `a mod b`, since AArch64 has **no remainder instruction** |

Two idioms built from these appear throughout:

```asm
mov  x2, #48
madd x0, x0, x2, x1         // x0 = x1 + x0*48: address of dictionary entry #x0

udiv x5, x19, x4            // x5 = n / 10
msub x6, x5, x4, x19        // x6 = n - (n/10)*10 = n mod 10
```

## 9. Flags, comparisons, and conditional instructions

AArch64 has four condition flags, NZCV (Negative, Zero, Carry, oVerflow),
set only by instructions that ask to set them. kelforth uses:

- `cmp xn, op2` — computes `xn - op2`, sets flags, discards the result.
- `cmn xn, op2` — computes `xn + op2` ("compare negative"). The point:
  `cmp x0, #-1` is not encodable (immediates are unsigned), so
  **`cmn x0, #1` is how you compare against -1** — it appears wherever
  kelforth tests for its -1 sentinel.

Conditional branches then test the flags: `b.cond label`. The condition
names come in signed and unsigned flavors, and using the right family is
essential:

| signed | unsigned | true when (after `cmp a, b`) |
| --- | --- | --- |
| `eq` | `eq` | a = b |
| `ne` | `ne` | a ≠ b |
| `lt` | `lo` | a < b |
| `le` | `ls` | a ≤ b |
| `gt` | `hi` | a > b |
| `ge` | `hs` | a ≥ b |

(The unsigned mnemonics: LOwer, Lower-or-Same, HIgher, Higher-or-Same.)
kelforth compares Forth cells as signed (`b.ge`, `csetm x0, lt`) and
buffer positions/lengths as unsigned (`b.hs` for "index ≥ length").

Flags also feed non-branch conditionals:

- `cset w8, lt` — set w8 to **1** if the condition holds, else 0.
- `csetm x0, ge` — set x0 to **-1** (all ones) if the condition holds,
  else 0. This maps flags directly onto Forth's truth values, which is why
  every comparison primitive ends with a `csetm`.

Finally there are compare-and-branch instructions that don't touch flags
at all:

- `cbz x2, label` / `cbnz x2, label` — branch if register is zero /
  nonzero.
- `tbz x1, #0, label` / `tbnz x3, #63, label` — test one **bit** and
  branch if it is zero / nonzero. Bit 63 is the sign bit, so
  `tbnz x2, #63, …` means "branch if negative" without a `cmp`; bits 0
  and 1 are the dictionary's `immediate` and `hidden` flags.

One more encoding trick: `cmp x2, #16, lsl #12` compares against
`16 << 12 = 65536`. Immediates in `cmp`/`add`/`sub` are 12 bits wide,
optionally shifted left by 12 — 65536 is only encodable in the shifted
form. That constant is the size of `forth_memory` in cells.

## 10. Labels

Named labels (`dpush:`, `interpret:`) are ordinary. Two special forms:

- **`L`-prefixed names** (`Lthrow_underflow`) — on Mach-O, symbols
  starting with `L` are assembler-local: they never reach the object
  file's symbol table. Used for internal branch targets.
- **Numeric labels** (`1:`, `2:`) — reusable local labels. A branch to
  `1f` means "the next `1:` *forward*"; `1b` means "the nearest `1:`
  *backward*". They keep short loops readable without inventing dozens of
  names, and the same digit can be reused in every routine. When reading:
  find the referenced digit in the current routine, in the stated
  direction.

## 11. The assembler: sections and data directives

An executable's contents are organized into segments/sections; the
assembler is told where each piece goes:

| directive | meaning |
| --- | --- |
| `.section __TEXT,__text,regular,pure_instructions` | executable machine code |
| `.section __TEXT,__const` | read-only data (strings, embedded files) |
| `.section __DATA,__data` | read-write data (all the interpreter's state) |
| `.p2align 2` / `.p2align 4` | align to 2² = 4 / 2⁴ = 16 bytes |
| `.quad 0` | emit one 64-bit value |
| `.byte`, `.short`, `.long` | emit 1-, 2-, 4-byte values |
| `.ascii "…"` | emit string bytes, **no** trailing NUL |
| `.asciz "…"` | emit string bytes plus a trailing NUL (for C functions like `system`) |
| `.space 65536` | reserve N zero bytes |
| `.incbin "core.fs"` | paste a file's raw bytes into the section (stages 4–5 embed their Forth core this way) |
| `.globl _main` | export the symbol so the linker can see it |
| `.macro` / `.endm` | textual macros; `\param` substitutes an argument |
| `.subsections_via_symbols` | standard Mach-O marker letting the linker dead-strip per-symbol |

kelforth's strings carry no NUL terminators — every string is passed as
(address, length) pairs, which is also exactly Forth's convention.

## 12. Talking to the OS: the libc boundary

On Apple platforms, C symbols get a leading underscore: C `write` is
assembly `_write`. kelforth calls only a handful of libc wrappers —
`_open`, `_read`, `_write`, `_close`, `_exit`, and in stage 5 `_poll`,
`_usleep`, `_isatty`, `_system` — using the normal C calling convention:
first argument in `x0`/`w0`, second in `x1`, third in `x2`, result in
`x0`. For example:

```asm
write_buf:            // our convention: x0 = address, x1 = length
    mov x2, x1        // C write(fd, buf, count): count is arg 3
    mov x1, x0        //                          buf   is arg 2
    mov w0, #1        //                          fd 1 = stdout
    b _write          // tail call; write's return value is ours
```

(Direct `svc` system calls are private/unstable ABI on macOS; going
through libc is the supported route.)

## 13. Reading and exploring the binaries

Useful commands while studying the code:

```sh
make                                   # build every stage
objdump -d stage0-stack-machine/kelforth | less   # disassemble
nm stage0-stack-machine/kelforth        # symbol table (note the L-labels are gone)

lldb stage0-stack-machine/kelforth
(lldb) b dpush                          # break on every push
(lldb) run
> 2 3 +
(lldb) register read x0 x1 x2           # watch the value being pushed
(lldb) x/4gx &data_stack                # dump the first stack cells
(lldb) memory read -f d -c 4 -s 8 &data_stack   # same, as signed decimals
(lldb) finish                           # run to the end of dpush
```

A rewarding exercise: disassemble a routine and match each instruction
back to its source line — the assembler emits them 1:1, no optimizer in
between.

## 14. Idioms cheat-sheet (codebase-specific)

| you see | it means |
| --- | --- |
| `LOAD x1, sym` | x1 = address of global `sym` (adrp+add pair) |
| `ENTER` … `LEAVE` | function prologue/epilogue (save/restore fp + lr) |
| `REG name, len, fn[, imm]` | register one primitive in the dictionary at startup |
| `stp x19, x20, [sp, #-16]!` | push two callee-saved registers |
| `ldr x0, [x3, x2, lsl #3]` | x0 = 64-bit array element `x3[x2]` |
| `cmn x0, #1` + `b.eq` | "if x0 == -1" (the none/empty sentinel) |
| `csetm x0, cond` | x0 = Forth flag: -1 if cond else 0 |
| `tbnz x2, #63, …` | "if x2 is negative" (sign-bit test) |
| `tbnz x3, #1, …` | "if dictionary entry is hidden" (flags bit 1) |
| `cmp x2, #16, lsl #12` | compare with 65536 (memory size in cells) |
| `madd x0, x0, x2, x1` (x2=48) | x0 = address of 48-byte dictionary entry #x0 |
| `udiv` + `msub` | quotient + remainder (no hardware `mod`) |
| `b somewhere` at end of routine | tail call — callee returns for us |
| `1f` / `1b` in a branch | nearest numeric label `1:` forward / backward |
