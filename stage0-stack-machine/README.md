# Stage 0 — The Stack Machine

This is the smallest program that is recognizably Forth: about 100 lines of
JavaScript that give you a **data stack**, a dozen built-in **words**, and a
loop that reads text and executes it. No user-defined words yet, no control
flow, no memory. Just the beating heart.

## Try it

```
$ node kelforth.js
kelforth stage 0 — the stack machine. Type `bye` to quit.
2 3 + . cr
5
 ok
```

Or run a file: `node kelforth.js examples/arithmetic.fs`

## The one idea: the stack

Forth has no expressions, no precedence, no parser worth the name. Instead it
has a stack of numbers, and every operation takes its inputs from the stack
and leaves its results on the stack.

```
2 3 +
```

- `2` — a number, so push it. Stack: `2`
- `3` — push it. Stack: `2 3`
- `+` — a word: pop two, push their sum. Stack: `5`

This is **postfix** (reverse Polish) notation. It feels backwards for about
an hour, and then it feels inevitable: because arguments are already on the
stack when an operation runs, operations compose by _concatenation_.
`(2 + 3) * (10 - 6)` is just:

```
2 3 + 10 6 - *
```

No parentheses, because there is nothing to disambiguate — evaluation order
is literally left to right, always.

## Stack-effect comments

Forth programmers document every word with a stack effect:
`( inputs -- outputs )`, top of stack on the **right**. These are comments,
not checked by anything — but they are the universal notation, and we use
them in the JavaScript source too:

```
+       ( a b -- a+b )     pop two, push sum
.       ( a -- )           pop and print
dup     ( a -- a a )       coming in stage 1
```

## How the code works

Read `kelforth.js` top to bottom — it's short. The pieces:

1. **The stack** — a plain array with `push`/`pop`. `pop` on an empty
   stack throws `stack underflow`, the most classic Forth error there is.

2. **The words** — a table from name to function. Note there is nothing
   special about `+` versus `.` versus `bye`: every word is just a named
   action. That uniformity is the whole design.

3. **The interpreter** — the entire "parser" is:

   ```js
   line.trim().split(/\s+/);
   ```

   For each token: if it's in the word table, run it; if it looks like an
   integer, push it; otherwise, `undefined word`. Three cases. Real Forths,
   including gforth, are exactly this loop at heart (they call it the
   **outer interpreter** or _text interpreter_).

4. **The REPL** — reads a line, interprets it, prints ` ok`. That laconic
   ` ok` is tradition: Forth acknowledges, it doesn't chatter. On error the
   stack is cleared, which is what real Forths do when they abort a line.

One deliberate anachronism: `\` line comments are supported already (a real
stage-0 Forth wouldn't have them) so the example files can explain themselves.

## Words in this stage

| word                  | stack effect   | meaning                                             |
| --------------------- | -------------- | --------------------------------------------------- |
| `+` `-` `*` `/` `mod` | `( a b -- c )` | integer arithmetic (`/` truncates)                  |
| `negate`              | `( a -- -a )`  | flip sign                                           |
| `.`                   | `( a -- )`     | pop and print, followed by a space                  |
| `.s`                  | `( -- )`       | show the stack, non-destructively: `<depth> values` |
| `cr`                  | `( -- )`       | print a newline                                     |
| `bye`                 | `( -- )`       | exit                                                |

## Play with it

In the REPL, try:

- `1 2 3 .s` — then `. . .` and watch them come off in reverse (last in, first out).
- `10 0 /` — errors are words' problem to raise, the interpreter just relays them.
- `+` on an empty stack — meet `stack underflow`.
- Compute your age in days, RPN style: `2026 1987 - 365 *` (adjust years).

## What's missing (on purpose)

You can compute `212 32 - 5 * 9 /` but you can't _name_ it. Every formula
must be retyped (see `examples/temperature.fs` suffering exactly this).
The single most important thing in Forth is `:` — the word that defines new
words. That's stage 1.
