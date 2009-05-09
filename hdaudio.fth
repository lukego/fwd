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

0 0    my-space h# 0300.0010 + encode-phys encode+
0 encode-int encode+  h# 4000 encode-int encode+
" reg" property

: dma-alloc   ( len -- adr ) " dma-alloc" $call-parent ;
: dma-map-in  ( len -- adr ) " map-in" $call-parent ;
: dma-map-out ( adr len -- ) " map-out" $call-parent ;

: icw       h# 60 au + ; \ Immediate Command Write
: irr       h# 64 au + ; \ Immediate Response Read
: ics       h# 68 au + ; \ Immediate Command Status
: gctl      h# 08 au + ;
: wakeen    h# 0c au + ; \ Wake enable
: statests  h# 0e au + ; \ Wake status
: counter   h# 30 au + ; \ Wall Clock Counter
: corblbase h# 40 au + ;
: corbubase h# 44 au + ;
: corbwp    h# 48 au + ;  \ CORB write pointer (last valid command)
: corbrp    h# 4a au + ;  \ CORB read pointer (last processed command)
: corbctl   h# 4c au + ;
: corbsts   h# 4d au + ;
: corbsize  h# 4e au + ;
: rirblbase h# 50 au + ;
: rirbubase h# 54 au + ;
: rirbwp    h# 58 au + ;
: rirbctl   h# 5c au + ;
: rirbsts   h# 5d au + ;
: rirbsize  h# 5e au + ;

: running? ( -- ? ) gctl @ 1 and 0<> ;
: reset ( -- ) 0 gctl ! ;
: start ( -- ) 1 gctl ! ;

: dma-on ( -- ) 2 corbctl c! ;
: dma-off ( -- ) 0 corbctl c!  begin corbctl c@ 2 and 0= until ;

: command-ready? ( -- ? ) ics w@ 1 and 0= ;
: response-ready? ( -- ? ) ics w@ 2 and 0<> ;

\ CORB - Command interface towards codecs 

d# 1024 constant /corb
0 value corb-virt
0 value corb-phys
0 value corb-pos

: init-corb ( -- )
    /corb dma-alloc  to corb-virt
    corb-virt /corb true dma-map-in  to corb-phys
    \ Turn off DMA
    0 corbctl c!
    begin corbctl c@  2 and 0= until \ read value back
    corb-phys corblbase !
    0 corbubase !
    2 corbsize c!      \ 256 entries
    2 corbctl c!       \ Enable DMA
;

: corb-tx-sync ( -- )
    begin corbrp w@ corb-pos = until
;    

: corb-tx ( u -- )
    corb-pos 1+ d# 256 mod to corb-pos
    corb-pos cells corb-virt + ! ( )
    corb-pos corbwp w!
    corb-pos 0 = if        \ wrap around
        0 corbwp !
        h# 8000 corbrp w!  \ CORBRPRST=1
    then 
    corb-tx-sync
;

\ Response Inbound Ring Buffer (RIRB)

d# 1024 constant /rirb
0 value rirb-virt
0 value rirb-phys
0 value rirb-pos

: init-rirb ( -- )
    /rirb dma-alloc  to rirb-virt
    rirb-virt /corb true dma-map-in  to rirb-phys
    rirb-phys rirblbase !
    0 rirbubase !
    2 rirbsize c! \ 256 entries
;

: write-command ( c -- ) begin command-ready? until  icw ! ;
: read-response ( -- r ) begin response-ready? until  irr @ ;

: codec! ( chan nid verb -- )
    running? 0<> abort" hdaudio not running"
    -rot d# 28 lshift ( nid verb chan' )
    -rot d# 20 lshift ( verb chan' nid' )
    or or          ( command )
    write-command
    read-response
;

: get-parameter ( p -- u )
    h# f0000 or
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

: init ( -- ) ;

: open ( -- flag ) 
    map-regs
    reset
    0 wakeen w!  0 statests w!
    start
    begin running? until
    1 ms \ wait 250us for codecs to initialize
    statests w@ 1 <> if
        ." hdaudio: expected one codec but found this bitset: " statests w@ . cr
    then
    init-corb
    init-rirb
    true
;

: close ( -- )
    reset
;

