# Stage 3 — Memory

Words can compute (stage 0–1) and decide (stage 2), but they can't
_remember_. This stage adds Forth's data space: a single flat run of memory,
plus the small set of words for carving it up and poking at it.

```
variable count
7 count !
count @ .
7
```

## The memory model

One array of **cells**. An address is an index into it. That's the entire
model:

```js
const mem = new Array(65536).fill(0);
let here = 0;
```

`here` is the **allocation pointer** — it marks the first free cell and only
moves forward. There is no malloc, no free, no garbage collector. You take
memory by moving `here`, and it's yours forever. (Real Forths use actual
machine addresses and 8-byte cells; ours uses array indices and 1-slot
cells, so `cells` multiplies by 1 instead of 8. Same model, friendlier
numbers.)

## The core words

| word            | stack effect        | meaning                                                |
| --------------- | ------------------- | ------------------------------------------------------ |
| `here`          | `( -- addr )`       | current allocation point                               |
| `allot`         | `( n -- )`          | reserve n cells (move `here` forward)                  |
| `,`             | `( n -- )`          | store n at `here`, advance — "compile into data space" |
| `@`             | `( addr -- value )` | **fetch** the cell at addr                             |
| `!`             | `( value addr -- )` | **store** into the cell at addr                        |
| `+!`            | `( n addr -- )`     | add n to the cell at addr                              |
| `?`             | `( addr -- )`       | print the cell (`@ .`)                                 |
| `cells` `cell+` |                     | address arithmetic (a formality in our 1-slot world)   |

Pronunciation matters here: `@` is "fetch", `!` is "store", `,` is "comma".
`count @ .` reads aloud as "count fetch dot".

## Variables aren't magic

The reveal of this stage: `variable`, `constant`, and `create` are not
language features. They are **defining words** — words that read a name and
create a new dictionary entry — and they're built from the same primitives
you have:

- `variable count` — reserves one cell, defines `count` to push its
  **address**. That's why you need `@` and `!`: `count` is a location, not
  a value. No hidden read/write semantics — you say which one you mean.
- `100 constant limit` — defines `limit` to push the **value** 100.
- `create nums` — defines `nums` to push the current `here`, and allocates
  _nothing_. You follow it with `,` or `allot` to lay down whatever data
  you want:

```
create nums 10 , 20 , 30 , 40 , 50 ,     \ a five-element array
```

There is no array type. `nums 2 + @` is element 2. An "array" is a naming
convention over raw memory — see `examples/array-sum.fs`, which builds
`nth`, `sum`, and an in-place `bump-all` from nothing.

In the JavaScript, each of these is ~4 lines: read a name, capture an
address or value in a closure, add a word that pushes it. In stage 5,
`create ... does>` will let you build defining words _in Forth itself_.

## A real program: the sieve

`examples/sieve.fs` is the Sieve of Eratosthenes — the traditional Forth
benchmark program. It's the first example that needs everything at once:
constants for the limit, `create`/`allot` for the flags array, `do`/`loop`
to scan, `if` to decide, `!`/`@` to mark and test. Read it bottom-up
(Forth programs are written bottom-up): `composite!` and `prime?` first,
then `strike-multiples`, then `sieve` is two lines.

## Play with it

- `variable x  x .` — see the raw address. Then `variable y  y .` —
  addresses are just successive integers.
- `here .  10 allot  here .` — watch the allocation pointer move.
- Store out of bounds: `5 999999 !` — the address check catches it.
- Build a 3-cell "struct": `create point 1 , 2 , 3 ,` then write words
  `x@ y@ z@` to fetch each field.
- Change the sieve's `limit` to 1000.

## What's missing (on purpose)

Look at the JavaScript: compiled code lives in arrays of instruction
objects, data lives in `mem`, and the dictionary is a `Map`. Three separate
worlds — and all of them JavaScript's business, not Forth's. A real Forth keeps
_everything_ — code, data, dictionary — in that one memory, which is what
lets Forth define most of itself in Forth. That unification is stage 4, the
payoff stage.
