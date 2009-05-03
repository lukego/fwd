\ Intel HD Audio driver (work in progress)
\ Copyright 2009 Luke Gorrie <luke@bup.co.nz>

." loading hdaudio" cr

\ 0 [if] \ Only want to do these bits the first time..
 dev /pci8086,2668
 extend-package
 " hdaudio" name
  0 value au
\ [then]

\ Configuration space registers
my-address my-space encode-phys
0 encode-int encode+  0 encode-int encode+

0 0    my-space  0300.0010 + encode-phys encode+
0 encode-int encode+  h# 4000 encode-int encode+
" reg" property

: icw h# 60 au + ; \ Immediate Command Write
: irr h# 64 au + ; \ Immediate Response Read
: ics h# 68 au + ; \ Immediate Command Status
: gctl h# 08 au + ;
: wakeen h# 0c au + ;   \ Wake enable
: statests h# 0e au + ; \ Wake status
: counter h# 30 au + ;  \ Wall Clock Counter

: running? ( -- ? ) gctl @ 1 and 0<> ;
: reset ( -- ) 0 gctl ! ;
: start ( -- ) 1 gctl ! ;

: command-ready? ( -- ? ) ics w@ 1 and 0= ;
: response-ready? ( -- ? ) ics w@ 2 and 0<> ;

: write-command ( c -- ) begin command-ready? until  icw ! ;
: read-response ( -- r ) begin response-ready? until  irr @ ;

: codec! ( chan nid verb -- )
    running? not abort" hdaudio not running"
    -rot 28 lshift ( nid verb chan' )
    -rot 20 lshift ( verb chan' nid' )
    or or          ( command )
    write-command
    read-response
;

: get-parameter ( p -- u )
    f0000 or
    0 0 -rot codec!
;

: my-w@  ( offset -- w )  my-space +  " config-w@" $call-parent  ;
: my-w!  ( w offset -- )  my-space +  " config-w!" $call-parent  ;

: map-regs  ( -- adr )
   0 0 my-space h# 0300.0010 +  h# 4000  " map-in" $call-parent to au
   4 my-w@  6 or  4 my-w!
;
: unmap-regs  ( -- )
   4 my-w@  7 invert and  4 my-w!
   " map-out" $call-parent
;

: init ( -- )
    reset
    0 wakeen !  0 statests !
    start
    begin running? until
    1 ms \ wait 250us for codecs to initialize
    statests w@ 1 <> if
        ." hdaudio: expected only one codec but found this bitset: " statests w@ . cr
    then
;

: open ( -- flag ) true ;
: close ( -- ) ;

