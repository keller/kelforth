# Exercises

Graded challenges, roughly easiest to hardest. The early ones are pure
Forth in the REPL; the later ones send you into `core.fs` and then into
the JavaScript kernel — which is the real graduation.

## Warm-ups (pure Forth)

1. **`squared` and friends.** Define `sq`, `cube`, and `**` — that last
   one is `( base exp -- base^exp )`, a loop and a multiply. Careful with
   exponent 0.
2. **`.sign`** — `( n -- )` print `negative`, `zero`, or `positive`.
   Three-way branching with only `if/else/then`.
3. **`gcd`** — `( a b -- gcd )` Euclid's algorithm. `begin ... until`
   and `mod` is all you need. Then rewrite it with `recurse`.
4. **`count-digits`** — `( n -- count )` how many decimal digits?

## Memory work

5. **A stack in memory.** `create mystack 10 allot  variable mysp` —
   define `mypush` and `mypop`. You've built the data structure this
   whole language runs on.
6. **`histogram`** — given rolls of a die (`create rolls 3 , 1 , 3 , ...`),
   count occurrences of each value into a 6-cell table, then print it as
   rows of `*`s (loop + `emit`).
7. **`bubble-sort`** — `( addr n -- )` sort cells in place. Nested
   `do..loop`s, `@`, `!`, and a swap-through-the-stack.

## Extending the compiler (the Forth specialty)

8. **`?do`** — a `do` that skips the loop entirely when limit = start
   (see the note in `examples/fibonacci.fs`). Model it on `do` in
   `core.fs`; you'll need a forward branch like `if` uses, plus a
   comparison compiled before `(do)`.
9. **`case`** — build `case / of / endof / endcase` as immediate words.
   This is the classic "prove you understand compile-time Forth" katas;
   everything you need is in core.fs's `if`/`else`/`then`.
10. **`array`** — a defining word: `10 array scores` so that `3 scores`
    pushes the address of element 3. One line with `create`/`does>`.
    Add bounds checking for extra credit.
11. **`constant` is in core.fs — where's `2constant`?** Define it.
    Then define `enum:` so `0 enum: cave enum: forest drop` numbers words
    automatically (parsing words: peek at how `variable` gets its name).

## Kernel work (edit the JavaScript)

12. **`roll`** — `( xu ... x0 u -- xu-1 ... x0 xu )`: `2 roll` = `rot`.
    `pick` in the kernel is the model; `roll` mutates the stack array.
13. **`.r`** — `( n width -- )` right-aligned number printing, for neat
    columns. Then reprint exercise 6's histogram as a table.
14. **`see`** — the decompiler: `see fib` walks the threaded code in
    memory and prints the names of the words it finds (mind the inline
    operands of `lit`, `branch`, `(.")`...). The single best tool for
    understanding what the compiler actually emits.
15. **`key` and a real game loop.** Add a `key` primitive that reads one
    keypress (Node: `process.stdin` in raw mode), then turn
    `examples/adventure.fs` into a live game that reads commands itself.

## Graduation

16. Pick any program you've ever written for fun, under ~100 lines, and
    write it in kelforth. Where the language fights you, that's not
    failure — extend the language until the program is easy. That loop
    is the whole Forth philosophy.
