# Stage 5 — The Playground

The building is done. This stage rounds off the language — `create ... does>`,
strings, `recurse` — and then stops adding machinery so you can finally just
**write Forth**. The examples are small study programs; `EXERCISES.md` is a
graded path from REPL warm-ups down into kernel surgery.

## New since stage 4

### `create ... does>` — defining words, defined in Forth

The deepest word in Forth. `create` makes a word that pushes a data address;
`does>` attaches _behavior_ to the most recently created word. Together they
let you define **words that define words** — in Forth. The proof is in
core.fs, where `constant` (a kernel primitive in stage 4) became one line:

```forth
: constant ( n "name" -- )  create , does> @ ;
```

Read it as a recipe with two halves. When you run `100 constant limit`:
the first half runs — `create` makes the word `limit`, `,` stores 100 in
its data field. `does> @` is the second half: it becomes the _body_ of
`limit` itself. So later, `limit` pushes its data address and runs `@` —
and 100 appears. One line, and you've manufactured a new kind of word.

Try `: array ( n "name" -- ) create allot does> + ;` — exercise 10.

In the kernel this took ~15 lines: a created word grew optional `dataAddr`
and `doesAddr` fields, and the `(does>)` primitive patches the latest word
and returns early. Read `invoke` in `kelforth.js` — the four kinds of word,
one small function.

### Strings: `( addr len )`

A string is not a type. It's two numbers — an address and a count — with
characters in memory. `s" hello"` gives you the pair; `type` prints one;
everything else is arithmetic (see `examples/strings.fs`, where `tail` is
just `swap 1+ swap 1-`). `char A` pushes 65; `[char]` is its compile-time
twin. `."` remains the print-only shortcut.

### Odds and ends

- `recurse` — call the word being defined. (Its own name is hidden until
  `;`, so recursion must be explicit — see `examples/fibonacci.fs`.)
- `exit` — return from a word early.
- `+loop` — counted loop with a custom step: `10 0 do i . 2 +loop`.
- `pick` — `n pick` copies the nth-from-top; `0 pick` is `dup`.

## The examples

| file           | what it teaches                                                                                                                                                               |
| -------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `fibonacci.fs` | `recurse`, `exit`, and why the iterative version wins                                                                                                                         |
| `bottles.fs`   | string output with grammar; a `begin/until` song loop                                                                                                                         |
| `strings.fs`   | the `( addr len )` convention, `char`, string words from arithmetic                                                                                                           |
| `adventure.fs` | the punchline: a Forth program is a **language**. `look`, `take`, `north` are words — playing the game is typing Forth. Paste the definitions into the REPL and play it live. |

Run them with `node kelforth.js examples/<file>.fs`.

## Where to go from here

- **`EXERCISES.md`** — in this directory. Start at 1; number 14 (`see`,
  the decompiler) is the most rewarding thing you can add.
- **Starting Forth** (Leo Brodie) — the classic, joyful tutorial. Free
  online, and everything in it works here or is an exercise away.
- **Thinking Forth** (Brodie again) — the philosophy of factoring; a great
  software-design book even for non-Forth work.
- **jonesforth** — a real x86 Forth in one massively-commented assembly
  file. You have now built its exact architecture; reading it is déjà vu.
- **gforth** — a serious, standard Forth. Your kelforth code mostly runs
  there (`cells` will finally multiply by 8, addresses get real).

You built a language. It's ~400 lines of JavaScript and one file of Forth
that teaches itself. Not bad.
