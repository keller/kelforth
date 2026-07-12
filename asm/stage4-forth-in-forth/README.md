# Stage 4 — Forth in Forth on AArch64

This is the payoff stage. In stages 2 and 3, `if` was an AArch64 primitive.
Here it is one line of Forth:

```forth
: if ( -- hole ) ['] 0branch , here 0 , ; immediate
```

Open `core.fs`. The native executable embeds that file and interprets it
before reading your program. Control structures, stack conveniences,
arithmetic conveniences, variables, and output helpers are now ordinary Forth
definitions built on a smaller assembly kernel.

Proof that the language survived the move: the stage-4 `fizzbuzz.fs` and
`sieve.fs` programs are the same programs used in stages 2 and 3.

## Build and try it

```sh
make
./kelforth examples/fizzbuzz.fs
./kelforth examples/sieve.fs
./kelforth examples/extend.fs
./kelforth
```

At the prompt, `words` shows both the kernel vocabulary and everything loaded
from `core.fs`.

## The native threading model

A compiled word is a run of 64-bit cells. Most cells are execution tokens;
some are inline operands consumed by the preceding runtime word:

```text
xt(lit)     | 42
xt(0branch) | destination
xt(branch)  | destination
xt(exit)
```

An xt is a dictionary index. `entry_addr` converts it to an address with a
multiply-add:

```asm
entry_addr:                         // x0 = xt
    LOAD x1, dictionary
    mov  x2, #48
    madd x0, x0, x2, x1
    ret
```

When `invoke_xt` sees a colon entry, it saves the current instruction pointer
on the Forth return stack and jumps to the word's body:

```asm
    cmp  x1, #1                     // kind 1 = colon word
    b.ne not_colon
    LOAD x2, ip
    ldr  x0, [x2]
    bl   rpush                       // save caller continuation
    ldr  x3, [entry, #32]
    LOAD x2, ip
    str  x3, [x2]                   // jump to callee body
```

`exit` performs the inverse operation:

```asm
prim_exit:
    bl   rpop
    LOAD x1, ip
    str  x0, [x1]
```

This is indirect threaded code: the inner interpreter fetches an xt, the
dictionary entry identifies what it means, and colon calls redirect `ip`.
The return stack words `>r`, `r>`, and `r@` deliberately expose the same stack
used for threaded return addresses, which is powerful and requires care.

The native implementation introduced threaded cells before stage 4 so stage
2 could demonstrate real branches directly. The stage-4 conceptual change is
the **kernel/library split**: compilation is no longer exclusively something
assembly primitives do.

## The compiler-construction kit

Five capabilities let Forth extend its own compiler:

- `here` reports where the next cell will be written;
- `,` appends a cell;
- `!` patches an existing cell;
- `['] name` compiles the named word's xt as a literal;
- `immediate` marks a word to execute during compilation.

`[']` is an input-reading primitive because it must consume the following word
name. Its assembly implementation emits `lit` and the found xt:

```asm
prim_bracket_tick:                  // ['] name
    bl   next_token
    bl   find_word
    mov  x19, x0                    // xt(name)
    LOAD x0, xt_lit
    ldr  x0, [x0]
    bl   compile_cell
    mov  x0, x19
    bl   compile_cell
```

When a compile-time word containing `['] 0branch` runs, those two cells push
the xt of `0branch` onto the data stack. Comma can then append that xt to the
definition currently under construction.

## Building `if` and `then` in Forth

Read the first definitions in `core.fs`:

```forth
: if      ( -- hole )       ['] 0branch , here 0 , ; immediate
: then    ( hole -- )       here swap ! ; immediate
: else    ( hole -- hole' ) ['] branch , here 0 ,
                            swap here swap ! ; immediate
```

At compile time, `if`:

1. compiles the xt of `0branch`;
2. puts the address of the following target cell on the data stack;
3. compiles zero as a temporary target.

`then` later stores the current `here` into that hole. This is the exact
back-patching algorithm from stage 2, but the private assembly control-flow
stack is gone. Compile-time bookkeeping uses the ordinary Forth data stack.

Loops follow immediately:

```forth
: begin  ( -- dest )      here ; immediate
: until  ( dest -- )      ['] 0branch , , ; immediate
: while  ( dest -- hole dest ) ['] 0branch , here 0 , swap ; immediate
: repeat ( hole dest -- ) ['] branch , , here swap ! ; immediate
```

Once you understand the cell layout, none of these are syntax. They are words
that run now and write calls and operands for later.

## `postpone`: compile compilation

`postpone name` lets an immediate definition arrange for `name` to affect a
future definition. The kernel distinguishes two cases:

```asm
    // If name is immediate, compile its xt directly.
    // Otherwise compile: lit xt(name) comma
```

For an ordinary word, `lit xt(name) comma` means: when this new immediate word
runs later, push the desired xt and append it to the definition being built.
That is compilation behavior represented as threaded code.

`examples/extend.fs` uses this to define control flow in user space:

```forth
: unless postpone 0= postpone if ; immediate
```

It also defines `times`, proving users can build words of the same rank as the
system's `if` and `do`.

## Bootstrapping `core.fs`

The assembler places the source bytes inside the executable:

```asm
core_source:
    .incbin "core.fs"
core_source_end:
```

Startup points the ordinary source cursor at that byte range and calls the
ordinary outer interpreter:

```asm
    LOAD x0, core_source
    LOAD x1, core_source_end
    sub  x1, x1, x0
    bl   set_source
    bl   interpret
```

There is no separate bootstrap parser. The language is born by using the same
path that later reads your program. If `core.fs` contains an undefined word,
startup fails just as a user file would.

## What stays in the assembly kernel

| kernel responsibility | why it bottoms out here |
| --- | --- |
| outer and inner interpreters | something must execute the first Forth word |
| data/return stacks and memory | the machine substrate itself |
| arithmetic and comparisons | map directly to CPU instructions |
| `lit branch 0branch exit` | runtime targets emitted by the compiler |
| `: ; [ ] ' ['] literal postpone` | input-aware bootstrap compiler tools |
| `@ ! , here allot` | access to the underlying cell memory |
| `emit . cr` | cross the host I/O boundary |
| `."` | consumes raw source and embeds inline characters |

Everything else is a candidate for `core.fs`. The boundary is pedagogical,
not sacred; a more self-hosting Forth can move number parsing, dictionary
headers, and even colon compilation into Forth.

## Play with it

- Run `words` and identify which names were registered by assembly and which
  were appended while loading `core.fs`.
- Use `' dup .` to see an xt as a number, then run `' dup execute`.
- Inspect `here`, define an empty word, and inspect `here` again. Explain every
  consumed cell.
- Define `when` as `: when postpone if ; immediate`.
- Modify the local `core.fs` implementation of `if`, rebuild, and observe that
  it is embedded into the new executable.
- Single-step through startup until the first colon definition in `core.fs`
  becomes visible in the dictionary.

## What is missing on purpose

`create` can make address-returning words, but Forth cannot yet attach custom
runtime behavior to them. Strings are still mostly a print-only compiler
special case, and recursion lacks an explicit compiler word. Stage 5 adds
`does>`, address/length strings, and `recurse`, then uses the completed language
for programs rather than more kernel construction.
