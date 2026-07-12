# kelforth — AArch64 edition

This is the same six-stage kelforth progression implemented as native
ARM64/AArch64 assembly. Each stage builds a standalone executable and accepts
the same Forth programs as its JavaScript counterpart.

```sh
cd asm
make
make check

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
| `stage5-playground` | `create ... does>`, recursion and strings |

Each stage has a complete, standalone `kelforth.s`. There are no interpreter
includes: stage 1 is a copy of stage 0 plus words and colon definitions, stage
2 adds the compiler and control flow, and so on. This intentionally duplicates
the low-level host and stack machinery so opening any stage shows 100% of that
interpreter, just like the JavaScript edition. Stages 4 and 5 embed and
interpret their local `core.fs` at startup.

The assembly targets Mach-O on Apple Silicon Macs—specifically the M1 machine
used to build this project. It uses Apple's leading-underscore C symbols,
Mach-O sections, and `@PAGE`/`@PAGEOFF` relocations directly. Libc is used only
for operating-system I/O (`open`, `read`, `write`, `close`, and `exit`).
