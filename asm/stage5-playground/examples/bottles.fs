\ bottles.fs — bottles of beer, with grammar. String output + early exit.

: .bottles ( n -- )
  dup 0= if ." no more bottles" drop exit then
  dup 1 = if ." 1 bottle"       drop exit then
  . ." bottles" ;

: verse ( n -- n-1 )
  dup .bottles ."  of beer on the wall, "
  dup .bottles ."  of beer." cr
  ." Take one down, pass it around, "
  1- dup .bottles ."  of beer on the wall." cr cr ;

: song ( n -- ) begin verse dup 0= until drop ;

5 song
