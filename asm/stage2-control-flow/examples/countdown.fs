\ countdown.fs — begin/until: a post-tested loop.

: countdown ( n -- )
  begin
    dup . 1 -
    dup 0=
  until
  drop ." Liftoff!" cr ;

5 countdown

\ The same idea with begin/while/repeat — the test in the MIDDLE.
\ while exits the loop when the flag is false.
: countdown2 ( n -- )
  begin dup 0 > while
    dup . 1 -
  repeat
  drop ." Liftoff again!" cr ;

3 countdown2
