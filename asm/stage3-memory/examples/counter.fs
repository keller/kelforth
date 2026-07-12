\ counter.fs — variables: a named cell of memory.
\ `variable count` creates a word `count` that pushes an ADDRESS.
\ @ (fetch) reads a cell, ! (store) writes one, +! adds to one.

variable count

count @ . cr            \ starts at 0

7 count !               \ store 7 into it
count @ . cr            \ -> 7

1 count +!              \ increment in place
1 count +!
count @ . cr            \ -> 9

\ Factor the pattern into words — Forth style:
: tick   ( -- ) 1 count +! ;
: ticks? ( -- n ) count @ ;

tick tick tick
ticks? . cr             \ -> 12

\ `?` is shorthand for `@ .`:
count ? cr              \ -> 12

\ constants: a named value (pushes the VALUE, not an address)
365 constant days/year
days/year 4 * . cr      \ -> 1460
