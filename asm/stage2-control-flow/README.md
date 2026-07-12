# Stage 2 — Control Flow and the Compiler in AArch64

This is the conceptual center of the project. Stage 1 saved names and looked
them up whenever a word ran. Stage 2 compiles execution tokens and branch
operands into cells. To make control structures extensible, the outer
interpreter gains two states and dictionary entries gain an `immediate` flag.

```forth
: bigger? ( n -- ) 10 > if ." big" else ." small" then cr ;
42 bigger?
big
```

## Build and try it

```sh
make
./kelforth examples/countdown.fs
./kelforth examples/fizzbuzz.fs
./kelforth
```

Definitions can span REPL input lines. The REPL prints `compiled` while
`state` remains nonzero and `ok` after `;` returns it to zero.

## Why saved tokens are the wrong shape

Suppose a stage-1 body contains:

```forth
dup 10 > if ." big" else ." small" then
```

At runtime, `if` would need to scan forward, recognize nesting, find a matching
`else`, and then repeat that work on every call. Instead, stage 2 turns control
flow into addresses before the definition ever runs.

All structures reduce to four runtime ideas:

- call an execution token;
- push an inline literal;
- jump unconditionally;
- pop a flag and jump if it is zero.

## Compiling cells

`here` is a logical cell index. `compile_cell` stores one 64-bit value and
advances it:

```asm
compile_cell:                       // x0 = cell value
    LOAD x1, here
    ldr  x2, [x1]
    LOAD x3, forth_memory
    str  x0, [x3, x2, lsl #3]
    add  x2, x2, #1
    str  x2, [x1]
    ret
```

For a simple definition:

```forth
: square dup * ;
```

the body is conceptually:

```text
xt(dup) | xt(*) | xt(exit)
```

Unlike stage 1, `xt(dup)` is chosen at compile time. Redefining `dup` later
does not change `square`. This is **early binding**.

## The inner interpreter

The outer interpreter consumes source text. The **inner interpreter** consumes
threaded code:

```asm
run_inner:
1:  LOAD x1, ip
    ldr  x0, [x1]                  // current cell address
    cmn  x0, #1                    // -1 is the outer-return sentinel
    b.eq 2f
    add  x2, x0, #1
    str  x2, [x1]                  // advance ip before execution
    bl   memory_load               // fetch xt from Forth memory
    bl   invoke_xt
    b    1b
2:  ret
```

Advancing `ip` before invocation matters. If the xt names a colon word,
`invoke_xt` saves that already-advanced return address and replaces `ip` with
the callee's body address. `exit` restores the saved address.

The native edition uses this threaded engine as its low-level representation
from stage 1 onward; the stage-2 change is that normal body words now compile
fixed xts instead of the late-bound `(token)` records used only by stage 1.

## STATE and immediate words

The outer interpreter asks two questions after finding a word:

```asm
    ldr  x2, [entry, #16]          // flags
    LOAD x3, state
    ldr  x3, [x3]
    cbz  x3, execute_now           // interpreting
    tbnz x2, #0, execute_now       // immediate while compiling
    bl   compile_cell              // ordinary word while compiling
```

The states are:

- `state = 0`: execute a found word immediately;
- `state = 1`: compile an ordinary word's xt;
- `state = 1`, immediate bit set: execute now, during compilation.

`:` enters compile state. `;` must be immediate so it can run, append `exit`,
publish the definition, and leave compile state. `if`, `else`, `then`, and all
loop-building words are immediate for the same reason: their job is to build
code, not to run later as part of the code they build.

## How `if` and `then` patch a hole

`if` cannot know its forward destination because the rest of the definition
has not been compiled. It emits `0branch`, remembers the next cell, and emits a
zero placeholder:

```asm
prim_if:                            // immediate
    LOAD x0, xt_0branch
    ldr  x0, [x0]
    bl   compile_cell
    LOAD x0, here                  // address of target cell
    ldr  x0, [x0]
    bl   cf_push
    mov  x0, #0                    // unresolved destination
    bl   compile_cell
```

`then` pops that address and stores the current `here` into it:

```asm
prim_then:                          // immediate
    bl   cf_pop
    mov  x19, x0                   // hole address
    LOAD x1, here
    ldr  x1, [x1]                  // destination: after the true part
    mov  x0, x19
    bl   memory_store
```

Nesting falls out of the control-flow stack's LIFO order. An inner `if` pushes
and patches its hole before the outer `then` sees the outer hole.

`else` combines both operations: it creates an unconditional branch around
the false part and patches the old conditional hole to the start of that false
part.

## Backward branches and loops

`begin` needs no instruction at all. It pushes the current `here`, which is an
already-known backward destination. `until` compiles `0branch` followed by
that destination:

```asm
prim_begin:
    LOAD x0, here
    ldr  x0, [x0]
    b    cf_push

prim_until:
    LOAD x0, xt_0branch
    ldr  x0, [x0]
    bl   compile_cell
    bl   cf_pop
    b    compile_cell
```

`begin ... while ... repeat` uses both kinds: `begin` supplies a known
backward target, while `while` creates a forward exit hole for `repeat` to
patch.

Counted loops compile runtime words:

```text
xt((do))
    loop body...
xt((loop)) | xt(0branch) | body-address | xt((unloop))
```

`(do)` moves `( limit start )` from the data stack to a separate loop stack.
`(loop)` increments the current index and leaves a completion flag. `i` and
`j` read the innermost and next-outer indices.

## Flags are machine-friendly

Comparisons produce `-1` for true and `0` for false. AArch64 can construct
that convention directly:

```asm
    cmp   x0, x9
    csetm x0, lt                   // all bits set if a < b, else zero
    bl    dpush
```

All-bits-set true is why bitwise `and`, `or`, `xor`, and `invert` also work as
logical operators without conversions.

## Compiling inline text

`."` is immediate because it reads raw source through the closing quote. In
compile state it emits:

```text
xt((.")) | character-count | one character per cell ...
```

At runtime `(.")` reads the count at `ip`, writes each following character,
then leaves `ip` after the inline data. This is the same instruction-plus-
operand pattern used by `lit` and branches.

## Play with it

- Enter a definition over several REPL lines and watch the state indication.
- Compare the stage-1 and stage-2 redefinition experiment from the previous
  README; verify late binding became early binding.
- Define `: choose if 111 else 222 then ;` and sketch its cells before running
  it.
- Nest two `if`s and inspect the order in which `cf_push` and `cf_pop` run.
- Define a grid with nested `do ... loop` and use `j` and `i` as coordinates.
- Add a new immediate control word such as `unless` in assembly by compiling
  `0=` followed by the behavior of `if`.

## What is missing on purpose

The language can calculate and choose, but persistent values still need a
home. Stage 3 exposes the cell memory already used by the threaded engine and
adds the Forth words for allocation, fetch, store, variables, constants, and
arrays.
