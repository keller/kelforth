\ stack-juggling.fs — the shuffle words, one at a time.
\ Watch the stack with .s — it prints <depth> followed by the values,
\ deepest first (top of stack is on the right).

1 2 3 .s cr          \ <3> 1 2 3

dup .s cr            \ ( a -- a a )      <4> 1 2 3 3
drop .s cr           \ ( a -- )          <3> 1 2 3
swap .s cr           \ ( a b -- b a )    <3> 1 3 2
over .s cr           \ ( a b -- a b a )  <4> 1 3 2 3
rot .s cr            \ ( a b c -- b c a) <4> 1 2 3 3
nip .s cr            \ ( a b -- b )      <3> 1 2 3
tuck .s cr           \ ( a b -- b a b )  <4> 1 3 2 3
depth . cr           \ how deep are we?  4

\ Clean up:
drop drop drop drop .s cr    \ <0>

\ A practical use: emit prints a number as an ASCII character.
: shout ( -- ) 72 emit 73 emit 33 emit cr ;    \ H I !
shout
