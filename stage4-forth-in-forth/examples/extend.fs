\ extend.fs — in this stage, control flow is USER SPACE.
\ if/else/then live in core.fs, written in Forth. Which means you can
\ write your own words of the same rank. Here's `unless` — an if with
\ the test flipped:

: unless  postpone 0=  postpone if  ; immediate

\ postpone compiles compilation: at compile time of `report`, below,
\ `unless` appends a call to 0= and then does exactly what `if` would.

: report ( n -- )
  dup . 10 > unless ." is not big" then cr ;

5 report
15 report

\ Execution tokens: ' (tick) looks up a word and pushes its xt — a word
\ as a VALUE. `execute` calls it. Higher-order Forth:

: add1 ( n -- n+1 ) 1+ ;
: apply-twice ( n xt -- n' ) dup >r execute r> execute ;

10 ' add1 apply-twice . cr    \ -> 12

\ And since the loop words are just words too, an `n times ... loop`:
\ `5 times` should mean `5 0 do`. postpone only works on WORDS, so to
\ compile the 0 we push it (at compile time!) and hand it to `literal`,
\ the immediate word that compiles a push-a-constant.

: times  ( n -- )  0 postpone literal  postpone do ; immediate

: cheer ( n -- ) times ." hip " loop ." hooray!" cr ;

3 cheer
