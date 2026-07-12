# kelforth — AArch64 edition

This is the same six-stage kelforth progression implemented as native
ARM64/AArch64 assembly. Each stage builds a standalone executable and accepts
the same Forth programs as its JavaScript counterpart.

```sh
cd asm
make
make check                       # example outputs + runtime-error parity

cd stage2-control-flow
./kelforth examples/fizzbuzz.fs
./kelforth                         # interactive REPL
```

The stages preserve the original conceptual boundaries:

| stage | new layer |
| --- | --- |
| `stage0-stack-machine` | data stack, arithmetic, token interpreter |
| `stage1-words` | dictionary and colon definitions |
| `stage2-control-flow` | compiler state, immediate words, branches and loops |
| `stage3-memory` | unified cell memory and defining words |
| `stage4-forth-in-forth` | threaded code plus a Forth-defined core |
| `stage5-playground` | `create ... does>`, recursion, strings, keyboard input and terminal games |

Each stage has a complete, standalone `kelforth.s`. There are no interpreter
includes: stage 1 is a copy of stage 0 plus words and colon definitions, stage
2 adds the compiler and control flow, and so on. This intentionally duplicates
the low-level host and stack machinery so opening any stage shows 100% of that
interpreter, just like the JavaScript edition. Stages 4 and 5 embed and
interpret their local `core.fs` at startup.

## Runtime errors

A JavaScript kernel gets `throw` for free; assembly does not. When `dpop`
hits an empty stack deep inside nested primitives, no error *return value*
can get back to the interpreter — so each stage carries a tiny exception
mechanism (see `Lforth_throw` in any `kelforth.s`): `interpret` saves its
stack pointer in `err_sp` on entry, and a fault prints its message, resets
`sp` to that saved point — abandoning every frame in between, a bare-metal
`longjmp` — and returns 1 from `interpret`. This is also roughly how `ABORT`
works in real Forths.

The guards cover what a learner actually hits, with the same messages and
exit codes as the JavaScript edition (`check-errors.sh` proves it): data and
return stack underflow, division by zero, and out-of-range memory addresses
in stages 3–5, where the address checks live in the three routines all
memory traffic funnels through (`memory_load`, `memory_store`,
`compile_cell`). The JavaScript edition also catches stack *overflow*, bad
execution tokens, and loop-stack misuse (`i` outside a loop); those crash
here. Porting them is a good exercise — each is a compare, a branch to a
`Lthrow_*` stanza, and a message, following any existing guard as a model.

The assembly targets Mach-O on Apple Silicon Macs—specifically the M1 machine
used to build this project. It uses Apple's leading-underscore C symbols,
Mach-O sections, and `@PAGE`/`@PAGEOFF` relocations directly. The small host
boundary uses libc for files, terminal polling and timing.
