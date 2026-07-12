# Stage 1 — Words and the Dictionary in AArch64

Stage 0 could execute a fixed vocabulary. This stage lets the running system
learn new words:

```forth
: square ( n -- n^2 ) dup * ;
5 square . cr
25
```

The central Forth idea appears here: a user definition and an assembly
primitive share one dictionary and one lookup path. Once `square` exists, the
outer interpreter treats it just like `+`.

## Build and try it

```sh
make
./kelforth examples/squares.fs
./kelforth
```

Follow stack movement interactively with:

```forth
1 2 3 .s
dup .s
swap .s
over .s
```

## Change 1: a real dictionary entry

Every dictionary entry occupies 48 bytes:

| offset | field | purpose |
| ---: | --- | --- |
| 0 | name pointer | address of the word's bytes |
| 8 | name length | names do not require a trailing zero |
| 16 | flags | bit 0 is `immediate`, bit 1 is `hidden` |
| 24 | kind | primitive, colon word, created word, or constant |
| 32 | value | primitive code address, threaded-code address, or data |
| 40 | does-address | optional behavior used in stage 5 |

The primitive constructor writes those fields directly:

```asm
define_prim:                         // x0=name, x1=len, x2=fn, x3=flags
    LOAD x4, dict_count
    ldr  x5, [x4]
    LOAD x6, dictionary
    mov  x7, #48
    madd x6, x5, x7, x6             // dictionary + count * 48
    stp  x0, x1, [x6]
    stp  x3, xzr, [x6, #16]         // flags, primitive kind = 0
    str  x2, [x6, #32]
    // increment dict_count and return the entry index, its xt
```

An entry's index is its **execution token**, usually abbreviated `xt`. At this
stage that fact is mostly internal; stage 4 exposes execution tokens to Forth
programs themselves.

`find_word` searches backward from `dict_count - 1`, compares lengths, and
then compares ASCII bytes case-insensitively. Keeping old entries instead of
overwriting them is important for redefinition and, from stage 2 onward,
early binding.

## Change 2: input is a cursor

Words such as `:` and `(` need to consume more source themselves. The global
input cursor gives any primitive access to the remaining bytes:

```asm
source_ptr:  .quad 0
source_len:  .quad 0
source_pos:  .quad 0
```

That makes comments ordinary words:

```asm
prim_backslash:
    mov w0, #10                     // newline
    b   skip_to_char

prim_paren:
    mov w0, #')'
    b   skip_to_char
```

There is no comment rule in a lexer. `\` and `(` are dictionary entries whose
behavior happens to advance the input cursor. This is a very Forth-like
result: syntax becomes vocabulary.

## Change 3: `:` creates a hidden word

The colon primitive reads the next token as a name, records the current
compilation address, and enters compile state:

```asm
prim_colon:
    ENTER
    bl   next_token                 // x0/x1 = new name
    mov  x2, #1                     // kind 1: colon definition
    LOAD x3, here
    ldr  x3, [x3]                   // first body cell
    mov  x4, #-1
    mov  x5, #2                     // hidden flag
    bl   define_user
    LOAD x1, pending_xt
    str  x0, [x1]
    LOAD x1, state
    mov  x2, #1
    str  x2, [x1]
    LEAVE
```

The entry is hidden so its incomplete body cannot be found accidentally. `;`
appends the execution token of `exit`, clears the hidden bit, and returns to
interpret state:

```asm
prim_semicolon:
    LOAD x0, xt_exit
    ldr  x0, [x0]
    bl   compile_cell
    // clear hidden on pending_xt
    // state = 0
```

Hiding a definition while it is compiled becomes relevant again in stage 5:
the word being built cannot find itself by name, so recursion is requested
explicitly with `recurse`.

## String threading and late binding

Stage 1 deliberately retains the original lesson's late-binding behavior. A
body token is copied into stable name storage and compiled as three cells:

```text
xt of (token) | token-address | token-length
```

The assembly that emits this representation is:

```asm
compile_token:
    bl   copy_name
    mov  x20, x0
    LOAD x0, xt_token
    ldr  x0, [x0]
    bl   compile_cell
    mov  x0, x20                    // saved token address
    bl   compile_cell
    mov  x0, x19                    // token length
    bl   compile_cell
```

At runtime, `(token)` reads the saved address and length, calls `find_word`,
and invokes whatever definition is newest **then**. Numbers are parsed then as
well. This is string threading expressed through cells rather than a host
array of strings.

You can observe late binding:

```forth
: answer 1 ;
: report answer ;
: answer 2 ;
report . cr             \ stage 1 prints 2
```

Stage 2 replaces these saved names with execution tokens resolved when
`report` is compiled, so the same experiment prints 1 there.

## Stack-shuffling words

Without local variables, Forth programs arrange values explicitly:

| word | stack effect | assembly strategy |
| --- | --- | --- |
| `dup` | `( a -- a a )` | `dpeek 0`, then `dpush` |
| `drop` | `( a -- )` | one `dpop` |
| `swap` | `( a b -- b a )` | pop twice, push in reverse order |
| `over` | `( a b -- a b a )` | `dpeek 1`, then `dpush` |
| `rot` | `( a b c -- b c a )` | pop three, push in rotated order |
| `nip` | `( a b -- b )` | save top, discard next, restore top |
| `tuck` | `( a b -- b a b )` | pop two, push top/bottom/top |

For example:

```asm
prim_over:
    ENTER
    mov x0, #1
    bl  dpeek
    bl  dpush
    LEAVE
```

Tiny definitions are the Forth aesthetic. Since every word accepts and
returns the same implicit interface—the data stack—phrases compose without
call syntax or argument marshalling.

## Play with it

- Run `examples/stack-juggling.fs` and trace `dsp` after every word.
- Define `f>c`, `double`, and `cube` from smaller words.
- Repeat the late-binding experiment above, then try it in stage 2.
- Define a word that references an undefined word; define the missing word
  afterward, then execute the first word. Stage 1 can do this because lookup
  is deferred until runtime.
- Add a primitive `2dup` by following the structure of `prim_over`, then add a
  `REG` line inside the `STAGE >= 1` section.

## What is missing on purpose

A saved sequence of names is easy to execute, but awkward to jump through.
Decisions and loops force the next step: compile fixed execution tokens and
branch targets, distinguish interpreting from compiling, and let some words
run during compilation. That is stage 2.
