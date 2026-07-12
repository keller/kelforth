\ arithmetic.fs — RPN warm-up.
\ In Forth you put values on the stack FIRST, then apply the operation.
\ `.` pops and prints the top of the stack; `cr` prints a newline.

2 3 + . cr          \ (2 + 3)            -> 5
10 4 - . cr         \ (10 - 4)           -> 6
6 7 * . cr          \ (6 * 7)            -> 42
22 7 / . cr         \ integer division   -> 3
22 7 mod . cr       \ remainder          -> 1
5 negate . cr       \ sign flip          -> -5

\ Operations nest by just... happening in order. No parentheses needed:
\ (2 + 3) * (10 - 6)
2 3 + 10 6 - * . cr

\ `.s` shows the whole stack without consuming it: <depth> values
1 2 3 .s cr
