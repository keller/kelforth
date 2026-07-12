\ squares.fs — the whole point of Forth: name things, then build on the names.

: square ( n -- n^2 ) dup * ;

3 square . cr        \ -> 9
12 square . cr       \ -> 144

\ New words are made of old words. `cube` uses `square`:
: cube ( n -- n^3 ) dup square * ;

4 cube . cr          \ -> 64

\ And the temperature formula from stage 0, finally nameable:
: f>c ( fahrenheit -- celsius ) 32 - 5 * 9 / ;

212 f>c . cr         \ -> 100
-40 f>c . cr         \ -> -40
