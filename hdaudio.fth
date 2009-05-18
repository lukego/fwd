\ Intel HD Audio driver (work in progress)
\ Copyright 2009 Luke Gorrie <luke@bup.co.nz>

." loading hdaudio" cr

[ifndef] hdaudio-loaded
 dev /pci8086,2668
 extend-package
 " hdaudio" name
  0 value au
[then]

\ Configuration space registers
my-address my-space encode-phys
0 encode-int encode+  0 encode-int encode+

0 0    my-space h# 0300.0010 + encode-phys encode+
0 encode-int encode+  h# 4000 encode-int encode+
" reg" property

: dma-alloc   ( len -- adr ) " dma-alloc" $call-parent ;
: dma-map-in  ( adr len flag -- adr ) " dma-map-in" $call-parent ;
: dma-map-out ( adr len -- ) " dma-map-out" $call-parent ;

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

0 value sd

: sd0ctl   h# 80 sd + au + ; \ 3-byte register.. wtf?
: sd0sts   h# 83 sd + au + ;
: sd0lpib  h# 84 sd + au + ;
: sd0cbl   h# 88 sd + au + ;
: sd0lvi   h# 8c sd + au + ;
: sd0fifos h# 90 sd + au + ;
: sd0fmt   h# 92 sd + au + ;
: sd0bdpl  h# 98 sd + au + ;
: sd0bdpu  h# 9c sd + au + ;

: sd0licba h# 2084 au + ;

: running? ( -- ? ) gctl @ 1 and 0<> ;
: reset ( -- ) 0 gctl ! ;
: start ( -- ) 1 gctl ! ;

: dma-on ( -- ) 2 corbctl c! ;
: dma-off ( -- ) 0 corbctl c!  begin corbctl c@ 2 and 0= until ;

\ Immediate command interface: This does not seem to work on my Asus EEE (?).
\ I use the CORB/RIRB interface below instead.

: command-ready? ( -- ? ) ics w@ 1 and 0= ;
: response-ready? ( -- ? ) ics w@ 2 and 0<> ;

: write-command ( c -- ) begin command-ready? until  icw ! ;
: read-response ( -- r ) begin response-ready? until  irr @ ;

: immediate-codec! ( chan nid verb -- )
    running? 0<> abort" hdaudio not running"
    -rot d# 28 lshift ( nid verb chan' )
    -rot d# 20 lshift ( verb chan' nid' )
    or or          ( command )
    write-command
    read-response
;

: get-parameter ( p -- u )
    h# f0000 or
    0 0 -rot immediate-codec!
;

\ CORB and RIRB command interface based on DMA buffers.

d# 1024 constant /corb
0 value corb-virt
0 value corb-phys
0 value corb-pos

: corb-dma-off ( -- )
    0 corbctl c!
    begin corbctl c@  2 and 0= until \ read value back
;

: corb-dma-on ( -- )
    2 corbctl c!       \ Enable DMA
;    

: init-corb ( -- )
    /corb dma-alloc  to corb-virt
    corb-virt /corb 0 fill
    corb-virt /corb true dma-map-in  to corb-phys
    corb-dma-off
    corb-phys corblbase !
    0 corbubase !
    2 corbsize c!      \ 256 entries
    corb-dma-on
;

: corb-tx-sync ( -- )
\    corbrp w@ corb-pos = if true else debug-me then
    begin corbrp w@ corb-pos = until
;

: corb-tx ( u -- )
    corb-pos 1+ d# 256 mod to corb-pos
    corb-pos cells corb-virt + ! ( )
    corb-pos corbwp w!
    corb-tx-sync
;

\ Response Inbound Ring Buffer (RIRB)

d# 256 2* cells constant /rirb
0 value rirb-virt
0 value rirb-phys
0 value rirb-pos

: rirb-dma-off ( -- ) 0 rirbctl c! ;
: rirb-dma-on  ( -- ) 2 rirbctl c! ;

: init-rirb ( -- )
    rirb-dma-off
    rirb-virt /rirb 0 fill
    /rirb dma-alloc  to rirb-virt
    rirb-virt /corb true dma-map-in  to rirb-phys
    rirb-phys rirblbase !
    0 rirbubase !
    2 rirbsize c! \ 256 entries
    rirb-dma-on
;

: rirb-data? ( -- ) rirb-pos rirbwp w@ <> ;

: rirb-read ( -- resp solicited? )
    begin rirb-data?  key? abort" key interrupt" until
    rirb-pos 1+ d# 256 mod to rirb-pos
    rirb-pos 2 * cells rirb-virt + ( adr )
    dup @                          ( adr resp )
    swap cell+ @                   ( resp resp-ex )
    h# 10 and 0=                   ( resp? solicited? )
;

: rirb-rx ( -- )
    begin
        rirb-read ( resp solicited? )
        if exit else ." unsolicited response: " . cr then
    again
;

: rirb-running? ( -- ? ) rirbctl c@  2 and 0<> ;

: encode-command ( codec node verb -- )
    -rot d# 20 lshift ( verb codec node' )
    -rot d# 28 lshift ( node' verb codec' )
    or or
;

: command ( codec node verb -- response ) encode-command corb-tx rirb-rx ;
: noop-command ( -- ) 0 corb-tx ;

0 value codec
0 value node

: set-node ( codec node -- ) to node to codec ;
: set-root ( -- ) 0 0 set-node ;

: cmd ( verb -- resp ) codec node rot command ;

\ Parameters

: param@ ( n -- u ) f0000 or cmd ;

: get-hex# ( "number" -- n )
    safe-parse-word  push-hex  $number abort" bad hex#"  pop-base
;

: param: ( "name" "id" -- value )
    get-hex# create ,
    does> @ param@
;

param: 00 vendor-id
param: 02 revision-id
param: 04 subnodes
param: 05 function-type
param: 08 function-caps
param: 09 widget-caps
param: 0a pcm-support
param: 0b stream-formats
param: 0c pin-caps
param: 0d amp-caps
param: 0e connections
param: 0f power-states
param: 10 processing-caps
param: 11 gpio-count
param: 13 volume-caps

: #subnodes     subnodes h# ff and ;
: first-subnode subnodes d# 16 rshift ;

: config-default ( -- c ) f1c00 cmd ;
: connection-select ( -- n ) f0100 cmd ;
: default-device ( -- d ) config-default d# 20 rshift  f and ;
: location       ( -- l ) config-default d# 24 rshift 3f and ;
: color          ( -- c ) config-default d# 12 rshift  f and ;
: connectivity   ( -- c ) config-default d# 30 rshift ;

\ Tree walking

' noop value do-xt
0 value do-tree-level

: do-subtree ( codec node -- )
    set-node       ( )
    do-xt execute  ( )
    codec  first-subnode #subnodes bounds ?do ( codec )
        do-tree-level 1 + to do-tree-level
        dup i recurse
        do-tree-level 1 - to do-tree-level
    loop ( codec )
    drop
;

: do-tree ( xt -- ) to do-xt  0 0 do-subtree ;

\ Main initialization

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

\ Channel 0

struct ( buffer descriptor )
    4 field >bd-uaddr
    4 field >bd-laddr
    4 field >bd-len
    4 field >bd-ioc
constant /bd

0 value bdl-virt
0 value bdl-phys
d# 256 /bd * value /bdl

: alloc-bdl ( -- )
    /bdl dma-alloc to bdl-virt
    bdl-virt /bdl 0 fill
    bdl-virt /bdl true dma-map-in to bdl-phys
;

0 value buffer1-virt
0 value buffer1-phys
0 value buffer2-virt
0 value buffer2-phys
d# 4096 value /buffer

: b-d ( n -- adr ) /bd * bdl-virt + ;

: init-buffers ( -- )
    /buffer dma-alloc to buffer1-virt
    buffer1-virt /buffer true dma-map-in to buffer1-phys
    buffer1-phys  0 b-d >bd-laddr !
    /buffer  0 b-d >bd-len !
    buffer1-virt /buffer -1 fill
    1  0 b-d >bd-ioc c! \ interrupt on completion

    /buffer dma-alloc to buffer2-virt
    buffer2-virt /buffer true dma-map-in to buffer2-phys
    buffer2-phys  1 b-d >bd-laddr !
    /buffer  1 b-d >bd-len !
    buffer2-virt /buffer -1 fill
    1  1 b-d >bd-ioc c! \ interrupt on completion
;

: prepare ( -- )
    alloc-bdl
    init-buffers
;

: blast ( -- )
    h# 00 sd0ctl    c!       \ turn off
    h# 18 sd0ctl 2 + c!       \ channel 1, output - do this first
    h# 00 sd0ctl 1 + c!
    h# 1C sd0ctl 3 + c!       \ clear flags
\    h# 1C100000 sd0ctl ! \ stream 1
    d# 1000 sd0cbl !      \ number of samples (fixme)
    1 sd0lvi c!          \ #1 is last valid entry
    0 sd0fmt !           \ 48KHz
    bdl-phys sd0bdpl !   \ install buffer descriptor list
    0        sd0bdpu !
    2 sd0ctl c!          \ run
;

: .node ( -- )
\    widget-caps d# 20 rshift  7 and  4 <> if exit then
    codec .d ." / " node .d
    connections .
    config-default .
    widget-caps d# 20 rshift  7 and ( type )
    case
        0   of ." audio output"   endof
        1   of ." audio input"    endof
        2   of ." audio mixer"    endof
        3   of ." audio selector" endof
        4   of ." pin widget ("
               case connectivity
                   0 of ." external " endof
                   1 of ." unused " endof
                   2 of ." builtin " endof
                   3 of ." builtin/external " endof
               endcase
               case color
                   1 of ." black " endof
                   2 of ." grey " endof
                   3 of ." blue " endof
                   4 of ." green " endof
                   5 of ." red " endof
                   6 of ." orange " endof
                   7 of ." yellow " endof
                   8 of ." purple " endof
                   9 of ." pink " endof
                   e of ." white " endof
               endcase
               case location
                   1 of ." rear " endof
                   2 of ." front " endof
                   3 of ." left " endof
                   4 of ." right " endof
                   5 of ." top " endof
                   6 of ." bottom " endof
                   7 of ." special " endof
               endcase
               case default-device
                   0 of ." line out)" endof
                   1 of ." speaker)"  endof
                   2 of ." HP out)"   endof
                   3 of ." CD)"       endof
                   4 of ." SPDIF out)" endof
                   5 of ." digital other out)" endof
                   6 of ." modem line side)" endof
                   7 of ." modem handset side)" endof
                   8 of ." line in)" endof
                   9 of ." aux)" endof
                   a of ." mic in)" endof
                   b of ." telephony)" endof
                   c of ." SPDIF in)" endof
                   d of ." digital other in)" endof
                   dup of ." unknown)" endof
               endcase
            endof
        5   of ." power widget"   endof
        6   of ." volume knob"    endof
        7   of ." beep generator" endof
        dup of exit               endof
\        dup of ." unknown"        endof
    endcase
    cr
;

\ Hardware discovery

0 value speaker
0 value speaker-output

: widget-type ( -- u ) widget-caps d# 20 rshift 7 and ;
: pin-widget? ( -- ? ) widget-type 4 = ;
: builtin?    ( -- ? ) connectivity 2 = ;
: speaker?    ( -- ? ) default-device 1 = ;
: mic?        ( -- ? ) default-device h# a = ;
: connection0 ( -- n ) f0200 cmd ( connection-list ) ff and ;

: init-speaker ( -- )
    node to speaker
    \ FIXME: Assumptions -
    \ Connection #0 is selected by default
    \ Connection #0 is an Output Converter
    connection0 to speaker-output

    speaker-output to node
    h# 70610 cmd drop         \ stream 1, channel 0
    h# a0000 cmd drop         \ format - 48khz 8-bit mono
;

: discover-pins ( -- )
    pin-widget? if
        builtin? speaker? and if
            init-speaker
        then
    then
;

\ Testing

: testit ( -- )
    bdl-virt 0= if
        alloc-bdl
        init-buffers
        ['] discover-pins do-tree
    then
    blast
    d# 5 0 do
        sd0sts c@ 0<> if
            ." sd: " sd . ." link position: " sd0lpib w@ . ." status: " sd0sts c@ . cr
            unloop exit
        then
        d# 2 ms
    loop
;

: testem ( -- )
    0 to sd
    d# 20 0 do
        testit
        h# 20 sd + to sd
    loop
;

[ifndef] hdaudio-loaded
select /hdaudio
[else]
close open
[then]

create hdaudio-loaded
