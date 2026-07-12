\ strings.fs — strings are ( addr len ): an address and a count.
\ No string type — just two numbers pointing at characters in memory.

s" hello, forth" type cr

\ Because a string is addr+len on the stack, "operations" are just
\ arithmetic. First character? Fetch the address. Substring? Add and
\ subtract. No library needed.

: first-char ( addr len -- ch ) drop @ ;
: .first     ( addr len -- ) first-char emit cr ;

s" wizard" .first                 \ w

: tail ( addr len -- addr+1 len-1 ) swap 1+ swap 1- ;

s" wizard" tail type cr           \ izard

\ char gives you a character literal; [char] is its compile-time twin.
char Z emit cr

: box ( -- )
  [char] + emit [char] - emit [char] - emit [char] + emit cr ;
box

\ type a string n times:
: chant ( addr len n -- )
  0 do 2dup type space loop 2drop cr ;

s" ho" 3 chant
