\ snake.fs — snake, in forth. Everything here is stage-5 vocabulary:
\ key? steers, at-xy/page draw, ms is the clock. The one idea worth
\ stealing: the snake is a RING BUFFER of every cell the head has
\ visited, so each tick draws ONE new head and blanks ONE old tail —
\ nothing else on the screen is ever redrawn.
\
\   node kelforth.js examples/snake.fs      arrow keys steer, q quits

50 constant w   24 constant h        \ the field, in cells
variable dx   variable dy            \ current heading
variable hx   variable hy            \ where the head is
variable len                         \ snake length; grows when it eats
variable tick                        \ ticks so far — the head's ring index
variable food                        \ where the fruit is
variable dead
variable seed   7 seed !             \ same game every run; see below

\ drawing: field cell (x,y) sits inside a border, so +1 each way
: >pos    ( x y -- pos )   w * + ;                     \ pack into one number
: draw    ( char pos -- )  dup w mod 1+ swap w / 1+ at-xy emit ;

\ the ring: ring[t mod size] = where the head was at tick t. Segment i of
\ the snake is just "the head, i ticks ago". No shifting, no linked list —
\ the tail cell simply gets blanked when its turn is over.
1280 constant size                   \ must be >= w h * , or a very long snake wraps
create ring size allot
: ring!   ( pos t -- )     size mod ring + ! ;
: ring@   ( t -- pos )     size mod ring + @ ;

: body?   ( pos -- flag )            \ is this cell part of the snake?
  len @ 0 do
    dup tick @ i - ring@ = if drop true unloop exit then
  loop drop false ;

\ a tiny PRNG (the ZX81's!) — enough randomness for fruit. A fixed seed
\ means the same fruit every game; a real clock word is exercise material.
: rand      ( n -- 0..n-1 )  seed @ 75 * 74 + 65537 mod dup seed ! swap mod ;
: new-food  ( -- )
  begin w h * rand dup body? while drop repeat
  dup food !  [char] * swap draw ;

: score   ( -- )  0 h 2 + at-xy ." score: " len @ 1- . ;

: out?    ( n limit -- flag )  over swap >= swap 0< or ;   \ outside 0..limit-1?

: step    ( -- )                     \ one tick: move the head, settle the tail
  hx @ dx @ +  hy @ dy @ +           ( x y )
  2dup h out? swap w out? or if 2drop true dead ! exit then
  2dup hy ! hx !  >pos               ( pos )
  dup body? if drop true dead ! exit then
  1 tick +!  dup tick @ ring!
  [char] O over draw                 ( pos )
  food @ = if 1 len +!  new-food  score
  else bl tick @ len @ - ring@ draw  \ blank the cell the tail vacated
  then ;

: dir!    ( dx dy -- )  dy ! dx ! ;

\ an arrow key is not one character! In raw mode the terminal sends
\ three bytes: 27 (escape), 91 ([), then A B C D for up down right left.
\ We saw byte 27; the other two are already waiting in the buffer.
: arrow   ( -- )
  key 91 <> if exit then
  key
  dup 65 = if  0 -1 dir! then
  dup 66 = if  0  1 dir! then
  dup 67 = if  1  0 dir! then
  dup 68 = if -1  0 dir! then
  drop ;

: steer   ( -- )                     \ poll the keyboard; never blocks
  key? 0= if exit then
  key
  dup 27 = if arrow then
  dup [char] q = over 3 = or if true dead ! then   \ q or ctrl-c quits
  drop ;

: walls   ( -- )
  h 2 + 0 do [char] # 0 i at-xy emit  [char] # w 1+ i at-xy emit loop
  w 2 + 0 do [char] # i 0 at-xy emit  [char] # i h 1+ at-xy emit loop ;

: setup   ( -- )
  page walls
  1 len !  0 tick !  false dead !  1 0 dir!
  w 2 / hx !  h 2 / hy !
  hx @ hy @ >pos dup 0 ring!  [char] O swap draw
  new-food score ;

: park    ( -- )  hx @ 1+ hy @ 1+ at-xy ;  \ rest the cursor on the head

: play    ( -- )
  setup
  begin steer step park 100 ms dead @ until
  0 h 2 + at-xy ." game over! score: " len @ 1- . cr ;

play

\ ideas: forbid 180-degree turns / speed up as the snake grows /
\ let the tail cell count as free (it moves away this very tick)
