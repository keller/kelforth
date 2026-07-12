\ fizzbuzz.fs — the classic, in Forth style: factored into tiny words.

: fizz? ( n -- flag ) 3 mod 0= ;
: buzz? ( n -- flag ) 5 mod 0= ;

: fizzbuzz ( n -- )
  dup fizz? over buzz? and if drop ." FizzBuzz" else
  dup fizz?                if drop ." Fizz"     else
  dup buzz?                if drop ." Buzz"     else
  .
  then then then cr ;

\ do/loop: `16 1 do` runs the body with i = 1..15.
: run ( -- ) 16 1 do i fizzbuzz loop ;

run
