\ Intel HD Audio driver (work in progress)
\ Copyright 2009 Luke Gorrie <luke@bup.co.nz>

\ Section and subsection comments - for Emacs
: \\  postpone \ ; immediate
: \\\ postpone \ ; immediate

\\ Device node

." loading hdaudio" cr

[ifndef] hdaudio-loaded
 dev /pci8086,2668
 extend-package
 " hdaudio" name
  0 value au
[then]

\\ DMA setup

my-address my-space encode-phys
0 encode-int encode+  0 encode-int encode+

0 0    my-space h# 0300.0010 + encode-phys encode+
0 encode-int encode+  h# 4000 encode-int encode+
" reg" property

: my-w@  ( offset -- w )  my-space +  " config-w@" $call-parent  ;
: my-w!  ( w offset -- )  my-space +  " config-w!" $call-parent  ;

: map-regs  ( -- )
    0 0 my-space h# 0300.0010 +  h# 4000  " map-in" $call-parent to au
    4 my-w@  6 or  4 my-w!
;
: unmap-regs  ( -- )
    4 my-w@  7 invert and  4 my-w!
    au h# 4000 " map-out" $call-parent
;

: dma-alloc   ( len -- adr ) " dma-alloc" $call-parent ;
: dma-map-in  ( adr len flag -- adr ) " dma-map-in" $call-parent ;
: dma-map-out ( adr len -- ) " dma-map-out" $call-parent ;

\\ Register definitions

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

: reset ( -- ) 0 gctl ! ;
: start ( -- ) 1 gctl ! ;
: running? ( -- ? ) gctl @ 1 and 0<> ;

\\\ Stream Descriptors

\ Stream descriptor index. 
0 value sd#
: sd+ ( offset -- adr ) sd# h# 20 * + au + ;

: sdctl   h# 80 sd+ ;
: sdsts   h# 83 sd+ ;
: sdlpib  h# 84 sd+ ;
: sdcbl   h# 88 sd+ ;
: sdlvi   h# 8c sd+ ;
: sdfifos h# 90 sd+ ;
: sdfmt   h# 92 sd+ ;
: sdbdpl  h# 98 sd+ ;
: sdbdpu  h# 9c sd+ ;
: sdlicba h# 2084 sd+ ;

\\ Immediate command interface
\ XXX The spec makes the immediate command registers optional and my
\ EEE doesn't seem to support them.

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

\\ CORB/RIRB command interface
\ DMA-based circular command / response buffers.

\ XXX I have hard-coded the buffers to be the maximum number of
\ entries. That's all my EEE supports and I was too lazy to make a
\ dynamic selection. -luke

\\\ CORB - Command Output Ring Buffer

d# 1024 constant /corb
0 value corb-virt
0 value corb-phys
0 value corb-pos

: corb-dma-on  ( -- ) 2 corbctl c! ;
: corb-dma-off ( -- ) 0 corbctl c!  begin corbctl c@  2 and 0= until ;

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

: wait-for-corb-sync ( -- ) begin corbrp w@ corb-pos = until ;

: corb-tx ( u -- )
    corb-pos 1+ d# 256 mod to corb-pos
    corb-pos cells corb-virt + ! ( )
    corb-pos corbwp w!
    wait-for-corb-sync
;

\\\ RIRB - Response Inbound Ring Buffer

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

\\ Commands to codecs

0 0  value codec value node  \ current target for commands

: encode-command ( codec node verb -- )
    -rot d# 20 lshift ( verb codec node' )
    -rot d# 28 lshift ( node' verb codec' )
    or or
;

: command ( codec node verb -- response ) encode-command corb-tx rirb-rx ;

\ Send 
: cmd ( verb -- resp ) codec node rot command ;

\\\ Getting parameters
\ The use of CREATE DOES here is probably gratuitious. But how will I
\ learn if I never use it? -luke

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

\\ Widget graph
\\\ Traversal

' noop value do-xt
0 value do-tree-level

: do-subtree ( xt codec node -- )
    to node to codec ( )
    do-xt execute    ( )
    codec  first-subnode #subnodes bounds ?do ( codec )
        do-tree-level 1 + to do-tree-level
        dup i recurse
        do-tree-level 1 - to do-tree-level
    loop ( codec )
    drop
;

: do-tree ( xt -- ) to do-xt  0 0 do-subtree ;

\\\ Find and setup the interesting widgets

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

\\\ Inspecting widgets

: .node ( -- )
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
    endcase
    cr
;

\\ Streams
\\\ Stream descriptors

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

\ XXX just using the (minimum) two sound buffers.
\ FIXME: simpler to allocate all the sound buffers from contiguous memory.
0 value buffers-virt
0 value buffers-phys
d# 4096 value /buffer
      2 value #buffers
/buffer #buffers * value /buffers

: buffer-descriptor ( n -- adr ) /bd * bdl-virt + ;
: buffer-virt ( n -- adr ) /buffer * buffers-virt + ;
: buffer-phys ( n -- adr ) /buffer * buffers-phys + ;

: alloc-sound-buffers ( -- )
    /buffers dma-alloc to buffers-virt
    buffers-virt /buffers true dma-map-in to buffers-phys
    buffers-virt /buffers -1 fill
;

: init-sound-buffers ( -- )
    buffers-virt 0= if alloc-sound-buffers then
    #buffers 0 do
        i buffer-phys  i buffer-descriptor >bd-laddr !
        /buffer  i buffer-descriptor >bd-len !
    loop
;

\\\ Starting and stopping channels

: assert-stream-reset   ( -- ) 1 sdctl c!  begin sdctl c@ 1 and 1 = until ;
: deassert-stream-reset ( -- ) 0 sdctl c!  begin sdctl c@ 1 and 0 = until ;

: reset-stream ( -- ) assert-stream-reset deassert-stream-reset ;
: stop-stream  ( -- ) 0 sdctl c! begin sdctl c@ 2 and 0=  until ;
: start-stream ( -- ) 2 sdctl c! begin sdctl c@ 2 and 0<> until ;

\\ Device open and close

: init-all ( -- ) init-corb init-rirb init-sound-buffers ;

\ FIXME: open count

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
    init-all
    true
;

: close ( -- )
    reset
    unmap-regs
;

\\ Testing

\ Channel 0

: random ( -- n ) counter @ ;

: randomize-sound-buffers ( -- )
    buffers-virt /buffers bounds do random i c! loop
;

: test-stream-output ( -- )
    4 to sd#     \ first output stream
    reset-stream
    randomize-sound-buffers
    h# 18 sdctl 2 + c!       \ channel 1, output - do this first
    h# 00 sdctl 1 + c!
    h# 1C sdctl 3 + c!       \ clear flags
    d# 1000 sdcbl !          \ number of samples (fixme)
    1 sdlvi c!               \ #1 is last valid entry
    0 sdfmt !                \ 48KHz
    bdl-phys sdbdpl !        \ install buffer descriptor list
    0        sdbdpu !
    start-stream
;

: submitted? ( -- ) sdlpib w@ ;
: beat-into-submission ( -- )
    begin
        test-stream-output
        close open
        key? abort" keyboard interrupt"
    submitted? until
;

[ifndef] hdaudio-loaded
select /hdaudio
[then]

create hdaudio-loaded
