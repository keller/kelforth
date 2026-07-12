# Stage 4 — Forth in Forth

The payoff stage. Until now, `if` was JavaScript. In this stage, **`if` is
one line of Forth**:

```forth
: if   ['] 0branch , here 0 , ; immediate
```

Open `core.fs`. That file _is_ this stage: the language, defining itself,
loaded before you get a prompt. The JavaScript shrank into a **kernel** —
only the things Forth genuinely cannot say about itself.

Proof that nothing was lost: `examples/fizzbuzz.fs` and `examples/sieve.fs`
are byte-for-byte the stage 2 and 3 files, and produce identical output.

## Change 1: one memory (threaded code)

In stage 3, compiled code lived in JS arrays of instruction objects, data
lived in `mem`, and never the twain met. Now **code compiles into the same
cell memory as data**, and `here` allocates both:

- A word's identity is its **execution token (xt)** — an index into the
  word table.
- A compiled definition is a run of cells: each cell an xt, or an inline
  operand following `lit` / `branch` / `0branch`.

```
: square dup * ;      compiles at, say, mem[812]:
mem[812] = xt of dup
mem[813] = xt of *
mem[814] = xt of exit      ( compiled by ; )
```

This layout is called **threaded code**, and the ten-line loop that walks
it (`executeXt`) is the **inner interpreter**: fetch a cell, execute it;
calling a colon word pushes the return address on the **return stack**
(a real one now — that's what `>r r> r@` touch) and jumps; `exit` pops it.
This is exactly the classic memory model of Forth, most famously walked
through in jonesforth.

## Change 2: the kernel/library split

Why did unifying memory matter? Because compilation became something Forth
can _do to itself_ with ordinary words:

- `here` — where compilation is happening
- `,` — append a cell to it
- `!` — patch a cell (fill in a branch target)
- `[']` — get a word's xt as a compile-time literal
- `immediate` — mark the last word as run-at-compile-time

Those five, which the kernel had to provide anyway, are a complete
compiler-construction kit. So control flow moved out of the kernel:

```forth
: if      ['] 0branch , here 0 , ; immediate
: then    here swap ! ; immediate
: begin   here ; immediate
: until   ['] 0branch , , ; immediate
```

Same hole-and-patch trick as stage 2 — but where stage 2's `if` was
JavaScript pushing onto a private `cfStack`, this `if` is Forth using the
**data stack** for its compile-time bookkeeping (that's the `( -- hole )`
in its stack comment: it runs at compile time, and its "output" is the
hole address for `then` to consume). do/loop, `variable`, `+!`, `min`,
`abs`, `spaces`… all Forth now. Read `core.fs` top to bottom — order
matters, since each word can only use what's defined above it.

What stayed primitive, and why:

| primitive                                         | why it can't be Forth (here)                                      |
| ------------------------------------------------- | ----------------------------------------------------------------- |
| the outer/inner interpreters                      | the chicken/egg: something must run first                         |
| stacks, memory, `@ ! , here allot`                | the substrate itself                                              |
| `+ - * / mod = < > and or xor invert`             | arithmetic bottoms out in the host CPU                            |
| `lit branch 0branch exit (do) (loop)`             | the runtime targets compilation aims at                           |
| `: ; immediate [ ] ' ['] literal postpone create` | the compiler-construction kit                                     |
| `emit . cr`                                       | I/O crosses to the outside world                                  |
| `."`                                              | needs raw input access + inline strings (stage 5 tackles strings) |

A more fanatical Forth pushes even `:` and number parsing into Forth; ours
draws the line where the teaching value flattens out.

## The new words in the kit

- `' name` ("tick") — push the xt of a word: **a word as a value**. With
  `execute`, that's higher-order programming (see `examples/extend.fs`).
- `['] name` — compile-time tick: compiles the xt as a literal.
- `postpone name` — compile _compilation_: arrange for `name` to be
  compiled into whatever word is being defined when this word runs. This is
  the tool for building your own control structures.
- `[` and `]` — momentarily drop out of / back into compile state.
- `literal` — compile a push-of-whatever's-on-the-stack.
- `words` — list the dictionary. Try it: everything after `spaces` came
  from core.fs.

`examples/extend.fs` uses these to build `unless` (an inverted `if`) and
`times` (a simpler counted loop) — _user-defined control flow_, the thing
almost no other language permits, in four lines.

## Play with it

- `words` — find where the kernel ends and core.fs begins.
- Define your own `if` variant: `: when postpone if ; immediate` and use it.
- `' dup .` — an xt is just a number. `' dup execute` — and it runs.
- Comment out a definition in core.fs (say `min`) and watch what breaks.
  Then put it back.
- In the REPL: `here .  : nothing ;  here .` — definitions visibly consume
  memory now.

## What's missing (on purpose)

Strings are still second-class (`."` is a kernel special case), there's no
`does>` — the word that lets _defining words_ be defined in Forth — and no
`recurse`. Stage 5 adds those and then stops building the language in order
to finally just _write programs in it_.
