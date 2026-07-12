# Stage 5 — The AArch64 Playground

The kernel-building progression ends here. This stage adds `create ... does>`,
address/length strings, `recurse`, `pick`, and `+loop`. The examples then use
the language for algorithms, text processing, and a tiny adventure rather
than introducing another interpreter architecture.

## Build and run the examples

```sh
make
./kelforth examples/fibonacci.fs
./kelforth examples/strings.fs
./kelforth examples/bottles.fs
./kelforth examples/adventure.fs
```

Or start the REPL:

```sh
./kelforth
```

The original playground's graded exercises remain useful with this native
interpreter: see [`../../stage5-playground/EXERCISES.md`](../../stage5-playground/EXERCISES.md).

## `create ... does>`: words that define words

`create` makes a dictionary entry whose default behavior is to push a data
address. `does>` attaches a threaded-code address to the most recently created
entry, replacing “just push the address” with “push the address, then run this
behavior.”

That lets `core.fs` define `constant` without an assembly primitive:

```forth
: constant ( n "name" -- ) create , does> @ ;
```

Read `100 constant limit` in two phases:

1. While `constant` runs, `create` makes `limit` and comma stores 100 at its
   data address.
2. `(does>)` records the address of the following `@` code as `limit`'s future
   behavior and returns early from `constant`.

Later, executing `limit` pushes its data address and jumps to that saved `@`,
which replaces the address with 100.

## The created-word dispatch path

Dictionary kind 2 already represents a created word. Stage 5 extends its
invocation path:

```asm
    ldr x0, [entry, #32]            // data address
    bl  dpush
    ldr x3, [entry, #40]            // optional does-address
    cmn x3, #1
    b.eq done                       // plain create: leave the address
    // save current ip on return stack
    // set ip = does-address
```

The runtime helper compiled by `does>` patches offset 40 of the latest entry:

```asm
prim_does_runtime:                  // (does>)
    LOAD x0, latest_xt
    ldr  x0, [x0]
    bl   entry_addr
    LOAD x1, ip
    ldr  x2, [x1]
    str  x2, [x0, #40]             // latest.does = code after (does>)
    bl   rpop
    LOAD x1, ip
    str  x0, [x1]                  // leave the defining word now
```

The immediate compiler word itself only appends that helper's xt:

```asm
prim_does:
    LOAD x0, xt_does_runtime
    ldr  x0, [x0]
    b    compile_cell
```

This split is characteristic Forth design: `does>` has tiny compile-time
behavior that arranges for a tiny runtime behavior, and the rest is expressed
in Forth.

Try another defining word:

```forth
: array ( n "name" -- ) create allot does> + ;
10 array scores
99 3 scores !
3 scores @ . cr
99
```

Executing `scores` pushes its data base, then the attached `+` consumes an
index and that base to produce an element address.

## Strings are two cells, not a type

The stack convention is:

```text
( addr len )
```

Characters occupy one logical Forth cell each. `type` pops a length and base
address, fetches each cell, and writes its low byte:

```asm
prim_type:                          // ( addr len -- )
    bl   dpop
    mov  x20, x0                    // remaining length
    bl   dpop
    mov  x19, x0                    // current cell address
1:  cbz  x20, 2f
    mov  x0, x19
    bl   memory_load
    bl   write_byte
    add  x19, x19, #1
    sub  x20, x20, #1
    b    1b
2:
```

In compile state, `s" text"` emits:

```text
xt((s")) | length | character cells ...
```

At runtime `(s")` pushes the address of the inline characters and their
length, then advances `ip` past them:

```asm
prim_s_quote_runtime:
    // read length at ip
    // push ip + 1 as the character address
    // push length
    // ip += 1 + length
```

Because a string is just two integers, operations need no string object or
allocator. From `examples/strings.fs`:

```forth
: tail ( addr len -- addr+1 len-1 ) swap 1+ swap 1- ;
s" wizard" tail type cr
izard
```

`char Z` reads the next token and pushes its first byte. `[char]` is immediate
and compiles that byte through `lit`, exactly like other compile-time literal
words.

## Explicit recursion

The current dictionary entry remains hidden between `:` and `;`. That allows a
new definition to refer to an older word of the same name, but it also means a
recursive definition cannot find itself normally.

`recurse` solves this by compiling `pending_xt` directly:

```asm
prim_recurse:                       // immediate
    LOAD x0, pending_xt
    ldr  x0, [x0]
    b    compile_cell
```

The Fibonacci example uses it twice:

```forth
: fib ( n -- fib[n] )
  dup 2 < if exit then
  1- dup recurse
  swap 1- recurse
  + ;
```

This is also a demonstration of the return stack and threaded `exit`: every
recursive call saves an `ip`, and every return restores one.

## `+loop` and `pick`

`pick` makes stack access data-driven:

```forth
0 pick   \ same effect as dup
1 pick   \ same effect as over
```

Its primitive is almost a composition of existing helpers:

```asm
prim_pick:
    bl dpop                        // x0 = depth
    bl dpeek
    b  dpush
```

`(+loop)` pops a signed step, adds it to the current loop index, and tests the
limit in the correct direction. Positive steps finish at or above the limit;
negative steps finish below it. The Forth-level immediate `+loop` in `core.fs`
compiles that runtime helper, a `0branch` back to the body, and `(unloop)`.

## Study programs

| file | what to watch |
| --- | --- |
| `fibonacci.fs` | recursive return paths versus an iterative stack pair |
| `strings.fs` | `( addr len )`, `type`, `char`, and substring arithmetic |
| `bottles.fs` | early `exit`, grammar choices, and repeated text |
| `adventure.fs` | a program becoming a domain-specific language of commands |

The adventure is the Forth punchline. After defining `look`, `take`, `north`,
and `south`, playing the game is just entering words. Programs grow by growing
the vocabulary in which the final program is stated.

## Build something next

- Work through the original `EXERCISES.md` using `./kelforth` instead of
  `node kelforth.js`.
- Define `value`/`to` or a structure-building vocabulary with `does>`.
- Add `see`, a decompiler that walks threaded cells and prints xt names.
- Add bounds checks to `dpush`, `dpop`, `memory_load`, and `memory_store`, then
  route failures through a common Forth abort path.
- Replace the fixed data stack with registers for the top one or two cells and
  measure the change; this is a classic native Forth optimization.
- Add Apple Silicon CI that builds every standalone stage and runs
  `make check`.

## Where to go from here

- **Starting Forth**, by Leo Brodie, teaches the language through interactive
  examples.
- **Thinking Forth** explores factoring and vocabulary design.
- **jonesforth** is a heavily commented x86 assembly Forth. Compare its inner
  interpreter, dictionary headers, and `NEXT` with this AArch64 kernel.
- **gforth** shows how these ideas scale into a production implementation.

You now have the full chain: source bytes become tokens; tokens become xts and
inline operands; an AArch64 inner interpreter walks those cells; and Forth
words use the same memory operations to extend their own compiler.
