\ keyboard.fs — the input words.
\
\   key    ( -- char )         wait for one keypress, push its char code
\   accept ( addr max -- len ) read a whole line of input into memory
\
\ key is raw — no echo, no Enter needed. accept is cooked — the terminal
\ lets you edit the line, and hands it over when you press Enter.
\
\ Run it live (./kelforth examples/keyboard.fs) or piped — ../check.sh
\ pipes the sibling keyboard.in file as stdin, which is why this example
\ is testable at all.

\ three raw keypresses, echoed back in reverse
." press three keys: " key key key
." now in reverse: " emit emit emit cr

\ a whole line into pad (a scratch buffer) — and then it is just an
\ ( addr len ) string like any other
." your name? " pad 80 accept          ( -- len )
." hello, " pad swap type ." !" cr
