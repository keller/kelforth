# Stage 3 — Memory in AArch64

Words can calculate and branch, but the data stack is temporary. This stage
exposes a flat array of cells and the tiny vocabulary needed to allocate,
fetch, and store persistent values.

```forth
variable count
7 count !
count @ . cr
7
```

There is no object model, allocator, or garbage collector. Forth gives the
program an address and makes the operation explicit.

## Build and try it

```sh
make
./kelforth examples/counter.fs
./kelforth examples/array-sum.fs
./kelforth examples/sieve.fs
```

The sieve is the first example that needs the whole language built so far:
definitions, loops, conditions, constants, allocation, and mutable cells.

## The memory model

The assembly reserves 65,536 64-bit cells:

```asm
here:          .quad 0
forth_memory:  .space 524288      // 65536 * 8 bytes
```

Forth-visible addresses are **cell indices**, not raw host pointers. Address 3
means the fourth 64-bit slot in `forth_memory`. The implementation converts a
cell index to a byte address with `lsl #3`:

```asm
memory_load:                        // x0 = cell index
    LOAD x1, forth_memory
    ldr  x0, [x1, x0, lsl #3]
    ret

memory_store:                       // x0 = cell index, x1 = value
    LOAD x2, forth_memory
    str  x1, [x2, x0, lsl #3]
    ret
```

Keeping logical cell addresses makes Forth programs easy to inspect: adjacent
cells are addresses 10 and 11, not byte addresses eight apart. The actual CPU
still performs aligned 8-byte loads and stores.

## `here`: allocation by moving one pointer

`here` is the first unused cell. Allocation is monotonic:

```asm
prim_here:                           // ( -- addr )
    LOAD x0, here
    ldr  x0, [x0]
    b    dpush

prim_allot:                          // ( n -- )
    bl   dpop
    LOAD x1, here
    ldr  x2, [x1]
    add  x2, x2, x0
    str  x2, [x1]
```

There is no corresponding `free`. `allot` claims `n` cells forever by moving
`here`. That simplicity is part of why a Forth system can be so small.

Comma stores one value at the current location and advances:

```asm
prim_comma:                          // ( n -- )
    bl dpop
    b  compile_cell
```

The same helper used to append threaded code therefore lays down user data.
In this native edition, code and data already share `forth_memory`; stage 4's
payoff will be making the compiler-building operations available to Forth so
control flow can move out of assembly.

## The core memory words

| word | stack effect | meaning |
| --- | --- | --- |
| `here` | `( -- addr )` | first unused cell |
| `allot` | `( n -- )` | reserve `n` cells |
| `,` | `( n -- )` | store at `here`, then advance |
| `@` | `( addr -- value )` | fetch a cell |
| `!` | `( value addr -- )` | store a cell |
| `+!` | `( n addr -- )` | add `n` to a cell |
| `?` | `( addr -- )` | fetch and print |
| `cells` | `( n -- n )` | convert a cell count; identity for logical indices |
| `cell+` | `( addr -- addr+1 )` | advance one logical cell |

Store illustrates how Forth's stack effect maps into register temporaries:

```asm
prim_store:                          // ( value addr -- )
    ENTER
    bl   dpop
    mov  x19, x0                    // addr was on top
    bl   dpop                       // x0 = value
    mov  x1, x0
    mov  x0, x19
    bl   memory_store
    LEAVE
```

The order `( value addr -- )` is chosen so an address-producing word can be
placed immediately before `!`: `7 count !`.

## Created words and constants

Dictionary entries already have a `kind` field. Stage 3 uses two new kinds:

- kind 2, **created word**: push the cell address stored in the entry;
- kind 3, **constant**: push the value stored in the entry.

Invocation dispatch is small:

```asm
    cmp x1, #2
    b.eq created
    cmp x1, #3
    b.eq constant

created:
    ldr x0, [entry, #32]            // data address
    bl  dpush

constant:
    ldr x0, [entry, #32]            // literal value
    bl  dpush
```

`create` reads a name and makes a kind-2 entry whose value is the current
`here`. It does **not** allocate:

```asm
prim_create:
    bl   next_token
    mov  x2, #2                     // created kind
    LOAD x3, here
    ldr  x3, [x3]
    mov  x4, #-1                    // no does> behavior yet
    mov  x5, #0
    bl   define_user
```

That is enough to build an array:

```forth
create nums 10 , 20 , 30 , 40 , 50 ,
nums 2 + @ . cr
30
```

There is no array type. `nums` pushes a base address, `2 +` performs address
arithmetic, and `@` fetches the selected cell.

`variable` is `create` plus one zero-initialized cell. The assembly version
creates the entry and calls `compile_cell` with zero. `constant` pops a value
and stores it directly in a kind-3 dictionary entry. Stage 4 will define
`variable` in Forth; stage 5 will use `does>` to define `constant` there too.

## Reading the sieve as a systems program

`examples/sieve.fs` allocates a flag cell for every candidate number:

```forth
100 constant limit
create flags limit allot

: composite! ( n -- ) flags + 1 swap ! ;
: prime?     ( n -- flag ) flags + @ 0= ;
```

Notice how little machinery “array access” needs. The rest of the program is
just address calculation plus the control flow from stage 2. This directness
is why Forth has traditionally been useful for firmware, bring-up tools, and
interactive work near hardware.

## Play with it

- Run `here . 10 allot here .` and predict the difference.
- Define two variables and print their addresses; confirm they occupy
  successive cells.
- Build `create point 10 , 20 , 30 ,` and define `x@`, `y@`, and `z@`.
- Define `2! ( a b addr -- )` and `2@ ( addr -- a b )` using `!`, `@`, and
  `cell+`.
- Trace `prim_plus_store` and identify which register holds the address, old
  value, and increment.
- Increase the sieve limit and watch the same Forth source use more of the
  native cell array without changing the interpreter.

## What is missing on purpose

The compiler is still assembled into the kernel: words such as `if`, `then`,
and `loop` are registered AArch64 primitives. Yet the language now has
everything required to express their work—execution tokens, `here`, comma,
and store. Stage 4 exposes the remaining compiler tools and rewrites much of
the language in Forth itself.
