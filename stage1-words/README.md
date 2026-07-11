# Stage 1 — Words and the Dictionary

Stage 0 could compute, but it couldn't _learn_. This stage adds the single
most important word in Forth — `:` — and with it the idea that makes Forth a
language instead of a calculator: **you extend the language by defining new
words, and new words are indistinguishable from built-in ones.**

```
: square ( n -- n^2 ) dup * ;
5 square . cr
25
```

## How we got here (diff against stage 0)

Three changes, in order of importance:

### 1. The dictionary

The fixed builtin table became `dict`, a map from name to `Word`, where a
word is now _either_ a primitive (a JavaScript function) or a **colon
definition** (a list of tokens the user wrote). The interpreter doesn't care
which — `execute` handles both. Once `square` is defined, it is exactly as
much a "real" word as `+`.

Redefining a word replaces it. Real Forths keep the old entry around (old
definitions that used it keep working) — ours doesn't yet, and that's
related to a wart described below.

### 2. The input became an object (`makeSource`)

Stage 0 pre-split each line into tokens. But `:` needs to read the _next_
token itself (the name being defined), and `(` needs to skip input until
`)`. So input is now a little object made by `makeSource` — the text and a
read position live in a closure, and tokens are pulled on demand. Real
Forths work this way; the position variable is traditionally called `>IN`.

This buys a genuinely Forthy insight: **comments are just words.**

```js
prim("\\", () => input.skipUntil("\n"));
prim("(", () => input.skipUntil(")"));
```

`\` is a word that eats the rest of the line. `(` is a word that eats input
until `)` — which is why Forth comments need the spaces: `( like this )`.
There is no comment syntax in the parser, because there is no parser.

### 3. The colon compiler

```js
prim(":", () => {
  const name = input.nextToken();
  // collect tokens until ";" ...
  dict.set(name, { name, body });
});
```

`:` grabs a name, hoovers up tokens until `;`, and stores them. Executing a
colon word just interprets its saved tokens one at a time. This is called
**string threading**, and it is the simplest implementation that can work.

Two honest limitations of string threading — both fixed by the real
compiler in stage 2:

- **Late binding.** The body is looked up token-by-token at _run_ time, so
  if you redefine `double`, every word that used `double` silently changes
  behavior. Standard Forth binds at _definition_ time.
- **In the REPL, a definition must fit on one line**, because each line is
  its own source. (In files, definitions can span lines — the whole file
  is one source.) Stage 2 introduces compile _state_ that persists across
  lines.

## The stack-shuffling words

Forth has no local variables (yet — arguably ever), so instead of naming
values you _arrange_ them. These six words are the vocabulary for that:

| word   | stack effect         | trick for remembering                         |
| ------ | -------------------- | --------------------------------------------- |
| `dup`  | `( a -- a a )`       | duplicate the top                             |
| `drop` | `( a -- )`           | throw the top away                            |
| `swap` | `( a b -- b a )`     | exchange top two                              |
| `over` | `( a b -- a b a )`   | copy the second over the top                  |
| `rot`  | `( a b c -- b c a )` | rotate the third to the top                   |
| `nip`  | `( a b -- b )`       | drop the second (swap drop)                   |
| `tuck` | `( a b -- b a b )`   | tuck a copy of the top underneath (swap over) |

Plus `depth ( -- n )` and `emit ( char -- )`, which prints a number as an
ASCII character.

Run `examples/stack-juggling.fs` and follow along with `.s`.

## Factoring: the Forth aesthetic

Look at `examples/average.fs`. Forth style is a _lot_ of tiny words — the
folk rule is that a definition longer than one or two lines is a smell.
Because every word reads its arguments from the stack, small words compose
with zero syntax, and each one can be tested interactively the moment it's
defined. This bottom-up, test-as-you-go style is Forth's real legacy.

## Play with it

- Define `f>c` from the examples, then check `-40 f>c .` — the famous fixed point.
- Define a word in terms of another, then redefine the inner one. Observe
  the outer word change behavior (the late-binding wart, live).
- Try `: broken dup` on one line in the REPL — see the `missing ;` error,
  and know that stage 2 makes multi-line definitions work.
- Write `minutes>seconds` and `hours>seconds` where the latter uses the former.

## What's missing (on purpose)

You still can't make a _decision_ — no `if`, no loops. Doing that properly
forces the big conceptual leap of Forth: the difference between
**interpreting** and **compiling**, and words that run _during_ compilation.
That's stage 2, the deepest stage of the six.
