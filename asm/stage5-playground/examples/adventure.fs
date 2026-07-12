\ adventure.fs — a two-room text adventure in ~30 lines.
\
\ The point: Forth programs become tiny languages. Once `look`, `north`,
\ `take` are words, PLAYING the game is just... typing Forth. Run this
\ file, then try it live in the REPL: paste everything above the
\ "scripted playthrough" line and type the commands yourself.

variable location
0 constant cave
1 constant forest
variable lamp-here    \ 1 = the lamp lies in the cave
variable has-lamp

: in-cave? ( -- flag ) location @ cave = ;

: look ( -- )
  in-cave?
  if   ." A dark cave. Water drips somewhere. A passage leads north."
       lamp-here @ if cr ." A brass lamp glints on the floor." then
  else ." A sunny forest clearing. A cave mouth yawns to the south."
  then cr ;

: north ( -- )
  in-cave?
  if   forest location ! ." You squeeze through the passage into daylight." cr look
  else ." The forest stretches on endlessly. You circle back." cr
  then ;

: south ( -- )
  in-cave?
  if   ." The cave wall is solid rock." cr
  else cave location ! ." You duck into the gloom." cr look
  then ;

: take ( -- )
  in-cave? lamp-here @ and
  if   0 lamp-here ! 1 has-lamp ! ." You take the brass lamp. It hums faintly."
  else ." There is nothing here to take."
  then cr ;

: inventory ( -- )
  has-lamp @
  if   ." You carry: one faintly humming lamp."
  else ." You carry nothing."
  then cr ;

\ ---- initial world state ----
cave location !
1 lamp-here !
0 has-lamp !

\ ---- a scripted playthrough (in the REPL, type these yourself) ----
look
take
inventory
north
take
south
look
