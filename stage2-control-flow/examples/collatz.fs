\ collatz.fs — if/else/then inside a while loop.
\ Collatz rule: even -> n/2, odd -> 3n+1. Conjecture: always reaches 1.

: even? ( n -- flag ) 2 mod 0= ;

: step ( n -- n' )
  dup even? if 2 / else 3 * 1 + then ;

: collatz ( n -- )
  begin dup . dup 1 <> while step repeat
  drop cr ;

6 collatz
7 collatz
27 collatz    \ the famous long one: 111 steps
