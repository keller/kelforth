# Stage 2 — Control Flow & the Compiler

This is the deepest stage of the six. To get `if` and loops, Forth doesn't
add syntax — it adds a **second state of mind**. Understanding this stage is
understanding Forth.

```
: bigger? ( n -- ) 10 > if ." big" else ." small" then cr ;
42 bigger?
big
```

## The problem

In stage 1 a colon word was a saved list of tokens, re-interpreted each time.
How would `if` work in that world? When the interpreter hits `if`, the
condition is on the stack, fine — but how does it *skip ahead* to `else`?
Scan forward through tokens looking for it? What about nested `if`s? It gets
ugly fast. Token lists are the wrong shape for control flow.

## The two big ideas

### 1. Compile, don't record

A definition is now compiled to an array of **instructions**:

```
: countdown  begin dup . 1 - dup 0= until drop ;
```
compiles to:
```
0: call begin?  — no! begin compiles NOTHING, it just remembers "position 0"
0: call dup
1: call .
2: call 1-           (as lit 1, call -)
4: call dup
5: call 0=
6: 0branch -> 0      ("pop a flag; if zero, jump to 0")
7: call drop
```

Control flow became two dumb instructions: `branch` (jump) and `0branch`
(pop a flag, jump if it was zero). Every structure — `if`, `else`, `until`,
`while`, `loop` — compiles down to just these. The inner interpreter (`run`
in the code) is a ten-line loop with an instruction pointer.

Compiling also fixes stage 1's late-binding wart: `{ op: "call", word }`
stores a *reference* to the word looked up at compile time. Redefining a
word no longer changes old definitions.

### 2. STATE and immediate words

The interpreter is now always in one of two states:

- **interpreting** — execute each word as it arrives
- **compiling** — append each word to the definition being built

`:` flips the switch on. But wait — if *everything* gets appended while
compiling, how does `;` ever run to end the definition? Because `;` is
marked **IMMEDIATE**: an immediate word executes even during compilation.

That one flag is the whole mechanism, and it's what makes Forth's compiler
extensible from inside the language. `if`, `then`, `begin`, `until` — all
just immediate words. They run *while your definition is being compiled*
and emit branch instructions into it.

## How `if`/`then` actually works (the hole trick)

```js
prim("if", () => {
  cfStack.push(pendingCode.length);                // remember where the hole is
  pendingCode.push({ op: "0branch", target: -1 }); // compile branch-to-nowhere
}, true);                                          // <- immediate!

prim("then", () => {
  const hole = cfStack.pop();
  pendingCode[hole].target = pendingCode.length;   // fill the hole: jump HERE
}, true);
```

`if` can't know where to jump — the else-part hasn't been compiled yet. So
it compiles a branch with a hole, and pushes the hole's location onto a
little **control-flow stack**. `then` pops it and patches the hole. `else`
does one of each (new hole, patch old one).

Nesting works *for free*: inner `if`s push and pop the cfStack in LIFO
order, which matches how structures nest. Nobody parses anything. This
back-patching trick is why a complete Forth compiler is ~50 lines and a C
compiler is not.

Loops are the same trick in reverse — `begin` remembers a position, `until`
compiles a `0branch` *backwards* to it. No hole needed: jumping backwards,
the target is already known.

## Counted loops: `do`/`loop`

```
10 0 do i . loop      \ prints 0 1 2 ... 9
```

`do` takes `( limit start -- )` — note limit first. The loop bookkeeping
lives on a separate **loop stack**; `i` peeks at the current index, `j` at
the next-outer loop's. `do` and `loop` are immediate words that compile
calls to runtime primitives `(do)`, `(loop)`, `(unloop)` plus a backward
`0branch`. Read them in the source — there is no magic left once you see
the pieces.

## Also new

- **Flags**: comparisons (`= <> < > <= >= 0= 0< 0>`) push `-1` for true, `0`
  for false. All-bits-set means bitwise `and`/`or`/`xor`/`invert` double as
  logical operators — that's *why* true is -1.
- **`."`** — immediate: at compile time it slurps text up to the closing `"`
  and compiles a print instruction. `." Hello"` needs the space after `."`
  because `."` is a word like any other.
- **Multi-line definitions in the REPL** — state persists between lines.
  The prompt says ` compiled` instead of ` ok` while you're mid-definition.

## Play with it

- Type a definition across several lines in the REPL and watch ` compiled`.
- `: test if ." yes" then ;` then `-1 test` and `0 test`.
- Nest loops: `: grid 4 0 do 4 0 do j . i . space loop cr loop ;`
- Try `then` outside a definition — the compile-only guard catches it.
- Try `: broken if ;` — the unbalanced-control-structure check fires.

## What's missing (on purpose)

Words can compute and decide, but they can't *remember* — there is no place
to keep a value except the stack. Stage 3 adds memory: `variable`, `@`, `!`,
and friends.
