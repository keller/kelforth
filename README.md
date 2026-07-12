# kelforth

Learn Forth by building one — six times.

Each `stageN-*` directory is a **complete, self-contained Forth
interpreter**, built on the previous stage plus one new conceptual layer.
The base language is plain JavaScript — zero dependencies, no build step,
just `node`; by stage 4, most of the Forth is written **in
Forth**. The progression lives in the directories, not in git history:
open any stage and 100% of its code is in front of you, or diff two stages
side by side to see exactly what a concept costs.

```
cd stage0-stack-machine
node kelforth.js                    # a REPL, with the traditional laconic "ok"
node kelforth.js examples/arithmetic.fs
```

Same commands in every stage. Each stage has a `README.md` explaining how
we got there and what to play with, plus commented `examples/*.fs`.

## The stages

| stage                                           | you build                                           | you learn                                                                                                  |
| ----------------------------------------------- | --------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| [stage0-stack-machine](stage0-stack-machine/)   | an RPN calculator                                   | the data stack, postfix notation, why Forth has no parser                                                  |
| [stage1-words](stage1-words/)                   | the dictionary and `:`                              | defining words, factoring, comments-are-words, `dup swap over rot`                                         |
| [stage2-control-flow](stage2-control-flow/)     | a real compiler                                     | interpret vs compile **state**, IMMEDIATE words, how `if` compiles a hole and `then` patches it, `do/loop` |
| [stage3-memory](stage3-memory/)                 | the data space                                      | cells, `@ ! , here allot`, why `variable`/`constant`/`create` aren't magic                                 |
| [stage4-forth-in-forth](stage4-forth-in-forth/) | a kernel + [core.fs](stage4-forth-in-forth/core.fs) | threaded code, execution tokens, the return stack — and `if/then/loop` **defined in Forth**                |
| [stage5-playground](stage5-playground/)         | a comfortable Forth                                 | `create…does>`, strings, `recurse` — then real programs, and [exercises](stage5-playground/EXERCISES.md)   |

Suggested pace: one stage at a sitting. Read the stage README, then the
source (each is a single file, ordered for reading), run the examples, do
the "play with it" prompts in the REPL, and only then move on.

## Verifying

```
node check.js            # run every stage's examples against expected output
node check.js stage2     # just one stage
```

The expected outputs are the `examples/*.out` files. Stage 4's suite
includes the stage 2 and 3 example files _unchanged_ — proof that the
bootstrapped Forth is the same language.

## Why Forth?

Forth is what you get when you refuse all machinery: no parser, no types,
no syntax beyond whitespace, and the compiler is ~50 lines that you can
extend _from inside the language while it compiles your code_. Building
one is the fastest way to understand what interpreters, compilers, and
calling conventions actually do — and it fits in your head, all of it,
at once.

The design here follows the classic lineage (indirect-threaded code, an
outer and inner interpreter, a bootstrap file) — the same architecture as
[jonesforth](https://github.com/nornagon/jonesforth) and, at heart,
[gforth](https://gforth.org/). Stage 5's README has the reading list.
