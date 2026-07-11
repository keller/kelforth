\ average.fs — small words composing into slightly bigger words.

: average ( a b -- avg ) + 2 / ;

7 3 average . cr         \ -> 5
100 50 average . cr      \ -> 75

\ Factoring: Forth style is MANY tiny words, each trivially correct.
: double ( n -- 2n ) 2 * ;
: halve  ( n -- n/2 ) 2 / ;

: average2 ( a b -- avg ) + halve ;
9 5 average2 . cr        \ -> 7
