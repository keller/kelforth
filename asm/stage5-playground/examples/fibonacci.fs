\ fibonacci.fs — recursion, two ways.

\ The classic doubly-recursive definition. Inside a definition the word's
\ own name is hidden (so redefining a word can use the old one), so you
\ recurse with... recurse. `exit` returns early.

: fib ( n -- fib[n] )
  dup 2 < if exit then          \ fib(0)=0, fib(1)=1
  1- dup recurse                \ fib(n-1)
  swap 1- recurse               \ fib(n-2)
  + ;

: .fibs ( n -- ) 0 do i fib . loop cr ;
11 .fibs                        \ 0 1 1 2 3 5 8 13 21 34 55

\ The iterative version: keep the pair (a, b), step it n times.
\ No recursion, no memory — just stack shuffling.

\ (The 0 guard matters: `0 0 do` still runs the body ONCE — do..loop
\ always executes at least one pass. Standard Forth has ?do for this;
\ we just exit early.)

: fib2 ( n -- fib[n] )
  dup 0= if exit then
  0 1 rot                       \ ( a b n )   a=fib(i), b=fib(i+1)
  0 do swap over + loop         \ step: ( a b -- b a+b )
  drop ;                        \ keep a

: .fibs2 ( n -- ) 0 do i fib2 . loop cr ;
11 .fibs2

\ Recursion depth is real: try `25 fib .` and feel the wait grow —
\ fib recomputes the same values exponentially many times. fib2 doesn't.
25 fib . cr
25 fib2 . cr
