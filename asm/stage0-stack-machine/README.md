# Stage 0 — The Stack Machine in AArch64

This is the smallest native program that is recognizably Forth: a data
stack, a small vocabulary of primitive words, and a loop that reads one
whitespace-delimited token at a time. There are no user definitions, branches,
or user-visible memory yet. It is an RPN calculator with the architecture that
the later stages will grow into a language.

The executable is written in ARM64/AArch64 assembly. It calls libc only at the
operating-system boundary (`read`, `write`, `open`, `close`, and `exit`); the
tokenizer, stacks, number parser, word lookup, and interpreter are assembly.

## Build and try it

```sh
make
./kelforth
```

At the prompt:

```forth
2 3 + . cr
5
```

Or run a source file:

```sh
./kelforth examples/arithmetic.fs
```

`kelforth.s` is the complete stage-0 interpreter. Read it top to bottom: host
I/O wrappers, data-stack operations, source cursor, word table, outer
interpreter, primitives, startup registration, and storage. Later stages copy
this whole file and add their next layer, so a side-by-side diff shows exactly
what each concept costs in assembly.

## The one language idea: the data stack

Forth does not parse expressions or apply precedence. A number pushes itself;
a word consumes and produces stack values. For:

```forth
2 3 +
```

the machine performs:

1. Push 2: stack is `2`.
2. Push 3: stack is `2 3`.
3. Execute `+`: pop 3 and 2, then push 5.

This postfix order makes `(2 + 3) * (10 - 6)` simply:

```forth
2 3 + 10 6 - *
```

Execution order is already explicit, so no expression grammar is needed.

## Building the stack in assembly

`dsp` holds a depth, not the CPU stack pointer. `data_stack` is a reserved
array of 64-bit cells. A push stores at `data_stack[dsp]` and increments the
depth:

```asm
dpush:                              // x0 = value
    LOAD x1, dsp
    ldr  x2, [x1]
    LOAD x3, data_stack
    str  x0, [x3, x2, lsl #3]      // each cell is 8 bytes
    add  x2, x2, #1
    str  x2, [x1]
    ret
```

A pop reverses those operations:

```asm
dpop:                               // returns value in x0
    LOAD x1, dsp
    ldr  x2, [x1]
    sub  x2, x2, #1
    str  x2, [x1]
    LOAD x3, data_stack
    ldr  x0, [x3, x2, lsl #3]
    ret
```

The `lsl #3` is the machine-level meaning of “cell”: multiplying an index by
eight to address a 64-bit value. Later, Forth programs use logical cell
indices, while this shift remains an implementation detail.

Do not confuse Forth's data stack with AArch64's `sp`. The hardware stack is
used for function return addresses and saved registers according to the
AArch64 procedure-call standard; the Forth stack is language state managed by
`dpush` and `dpop`.

## A word is a named machine action

Arithmetic primitives follow the Forth calling convention rather than the C
calling convention: their arguments live on the Forth stack and their result
goes back there.

```asm
prim_add:                            // ( a b -- a+b )
    ENTER
    bl   dpop                        // x0 = b
    mov  x9, x0
    bl   dpop                        // x0 = a
    add  x0, x0, x9
    bl   dpush
    LEAVE
```

`ENTER` and `LEAVE` save and restore AArch64's frame pointer and link register.
Every primitive therefore looks like a tiny stack-to-stack function. `-`,
`*`, `/`, `mod`, `negate`, and `.` use the same pattern.

Primitive names and code addresses are registered together during startup:

```asm
REG name_add,    1, prim_add
REG name_sub,    1, prim_sub
REG name_mul,    1, prim_mul
REG name_div,    1, prim_div
REG name_mod,    3, prim_mod
REG name_negate, 6, prim_negate
```

The `REG` macro passes a name pointer, name length, function address, and
immediate flag to `define_prim`. Even at stage 0, `+` is not hard-coded into
the parser: it is an ordinary dictionary entry.

## The outer interpreter

`next_token` walks `source_ptr`, `source_len`, and `source_pos`. It skips bytes
whose value is at most ASCII space, then returns a pointer and length in
`x0`/`x1`. It never allocates and never copies the source.

The main interpreter loop has only three semantic cases:

```asm
interpret:
1:  bl   next_token
    cbz  x0, done
    bl   find_word
    // found: execute its code address
    // not found but decimal: push the parsed number
    // otherwise: report "undefined word"
    b    1b
done:
```

That is Forth's **outer interpreter**. There is no AST and no syntax tree.
Later stages add compile state to this same loop instead of replacing it.

Case-insensitive lookup is a reverse walk through fixed-size dictionary
entries. Reverse order matters: when later stages redefine a word, the newest
definition wins while older entries still exist.

## Output and the host boundary

`emit` eventually reaches one small wrapper:

```asm
write_buf:                           // x0 = address, x1 = length
    mov x2, x1
    mov x1, x0
    mov w0, #1                       // stdout
    b   _write                       // macOS libc symbol
```

On Mach-O, external C symbols have a leading underscore, hence `_write`.
Everything above this wrapper speaks in Forth values and memory. Keeping the
host boundary narrow is a useful systems-programming habit: the language does
not depend on a formatting library or runtime object model.

## Words in this stage

| word | stack effect | meaning |
| --- | --- | --- |
| `+ - * / mod` | `( a b -- c )` | signed integer arithmetic |
| `negate` | `( a -- -a )` | change sign |
| `.` | `( n -- )` | print a signed number and a space |
| `.s` | `( -- )` | display the data stack without consuming it |
| `cr` | `( -- )` | print a newline |
| `bye` | `( -- )` | exit the process |
| `\` | `( -- )` | skip source bytes through newline |

Stack effects put the top of stack on the right. They are not enforced, but
they are the standard interface notation for Forth words.

## Play with it

- Run `1 2 3 .s`, then `. . .` to observe last-in, first-out order.
- Translate `((8 + 2) * 3) - 4` to postfix.
- Read `prim_swap` even though stage 0 does not register it yet. Predict the
  sequence of loads, stores, and pushes stage 1 will need.
- Set a breakpoint on `prim_add` and inspect `dsp` and `data_stack` before and
  after `2 3 +`.
- Find the `.space 65536` reservation for `data_stack`. Work out how many
  64-bit values it can hold.

## What is missing on purpose

The machine can calculate `212 32 - 5 * 9 /`, but it cannot give that phrase a
name. Stage 1 adds the dictionary machinery for user-defined words and the
colon compiler, turning the calculator into an extensible language.
