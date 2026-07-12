\ core.fs — kelforth's standard library, WRITTEN IN KELFORTH.
\
\ The AArch64 kernel gives us ~50 primitives. This file builds the rest
\ of the language out of them, and it loads before you get a prompt.
\ Read it top to bottom: the order matters, because each word can only use
\ what exists above it. This is a language pulling itself up by its
\ bootstraps.

\ ------------------------------------------------------ control flow
\ The crown jewels. if/else/then are not TypeScript — they are three
\ one-line Forth definitions.
\
\ The kernel gave us:
\   0branch   a runtime primitive: pop a flag, jump to the address in the
\             next cell if it was zero
\   branch    same, but always jump
\   [']       compile the xt of the next word as a literal
\   here ,    where code is being compiled, and how to append to it
\
\ `if` is IMMEDIATE: it runs while a definition is being COMPILED. It
\ appends a 0branch whose target cell is still a hole (0), and leaves the
\ hole's address on the stack. `then` pops that address and stores the
\ current position into it. Compile-time bookkeeping rides the ordinary
\ data stack.

: if      ( -- hole )        ['] 0branch , here 0 , ; immediate
: then    ( hole -- )        here swap ! ; immediate
: else    ( hole -- hole' )  ['] branch , here 0 ,
                             swap here swap ! ; immediate

\ Loops: begin just remembers where the loop starts. Jumping BACKWARDS
\ needs no hole — the target already exists.

: begin   ( -- dest )        here ; immediate
: until   ( dest -- )        ['] 0branch , , ; immediate
: again   ( dest -- )        ['] branch , , ; immediate
: while   ( dest -- hole dest ) ['] 0branch , here 0 , swap ; immediate
: repeat  ( hole dest -- )   ['] branch , , here swap ! ; immediate

\ Counted loops, from the kernel's (do)/(loop)/(unloop) runtime:

: do      ( -- dest )        ['] (do) , here ; immediate
: loop    ( dest -- )        ['] (loop) , ['] 0branch , , ['] (unloop) , ; immediate

\ ------------------------------------------------------ stack words
\ The kernel gave us dup drop swap over rot. Everything else is phrases:

: nip     ( a b -- b )       swap drop ;
: tuck    ( a b -- b a b )   swap over ;
: 2dup    ( a b -- a b a b ) over over ;
: 2drop   ( a b -- )         drop drop ;
: ?dup    ( n -- n n | 0 )   dup if dup then ;

\ ------------------------------------------------------ arithmetic & logic

: negate  ( n -- -n )        0 swap - ;
: abs     ( n -- |n| )       dup 0 < if negate then ;
: min     ( a b -- min )     2dup > if swap then drop ;
: max     ( a b -- max )     2dup < if swap then drop ;
: 1+      ( n -- n+1 )       1 + ;
: 1-      ( n -- n-1 )       1 - ;

: <>      ( a b -- flag )    = invert ;
: <=      ( a b -- flag )    > invert ;
: >=      ( a b -- flag )    < invert ;
: 0<      ( n -- flag )      0 < ;
: 0>      ( n -- flag )      0 > ;
: 0<>     ( n -- flag )      0= invert ;

: true    ( -- -1 )          -1 ;
: false   ( -- 0 )           0 ;

\ ------------------------------------------------------ memory
\ variable is just create-plus-one-initialized-cell. Not a kernel feature.

: variable ( "name" -- )     create 0 , ;
: +!      ( n addr -- )      dup @ rot + swap ! ;
: ?       ( addr -- )        @ . ;
: cells   ( n -- n )         ;      \ our cells are 1 slot wide
: cell+   ( addr -- addr+1 ) 1+ ;

\ ------------------------------------------------------ output niceties

: space   ( -- )             32 emit ;
: spaces  ( n -- )           begin dup 0> while space 1- repeat drop ;
