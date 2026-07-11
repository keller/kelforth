\ array-sum.fs — there is no "array type". You just take some memory.
\ `create nums` names the current allocation point; each `,` compiles
\ one value into memory and advances it. Five commas = a 5-cell array.

create nums   10 , 20 , 30 , 40 , 50 ,

\ Element i lives at address nums+i:
: nth ( i -- value ) nums + @ ;

0 nth . cr              \ -> 10
4 nth . cr              \ -> 50

\ Sum with a counted loop over the indices:
: sum ( addr n -- total )
  0 swap                \ ( addr total n )
  0 do                  \ for i = 0 .. n-1
    over i + @ +        \ total += addr[i]
  loop
  nip ;                 \ drop addr, keep total

nums 5 sum . cr         \ -> 150

\ Writable, too — bump every element in place:
: bump-all ( addr n -- )
  0 do
    dup i + 1 swap +!   \ addr[i] += 1
  loop
  drop ;

nums 5 bump-all
nums 5 sum . cr         \ -> 155
