\ sieve.fs — the Sieve of Eratosthenes, the traditional Forth benchmark.
\ A real program at last: memory + loops + decisions working together.

100 constant limit
create flags   limit allot      \ limit cells, all 0 ( 0 = maybe prime )

: composite! ( n -- ) flags + 1 swap ! ;   \ mark n as composite
: prime?     ( n -- flag ) flags + @ 0= ;  \ unmarked = prime

\ Strike out p*p, p*p+p, p*p+2p ... up to the limit.
\ (Starting at p*p is the classic trick: smaller multiples were already
\ struck by smaller primes.)
: strike-multiples ( p -- )
  dup dup *                     \ ( p m )  m = p*p
  begin dup limit < while
    dup composite!
    over +                      \ m += p
  repeat
  drop drop ;

: sieve ( -- )
  limit 2 do
    i prime? if i strike-multiples then
  loop ;

: .primes ( -- )
  limit 2 do
    i prime? if i . then
  loop cr ;

sieve
." Primes up to 100: " cr
.primes
