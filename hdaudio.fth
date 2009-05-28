\ Intel HD Audio driver (work in progress)  -*- forth -*-
\ Copyright 2009 Luke Gorrie <luke@bup.co.nz>

\ warning off

\ Section and subsection comments - for Emacs
: \\  postpone \ ; immediate
: \\\ postpone \ ; immediate

\\ Device node

." loading hdaudio" cr

[ifndef] hdaudio-loaded
\ dev /pci8086,2668
 dev /pci/pci1106,3288@14
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
: dplbase   h# 70 au + ;
: dpubase   h# 74 au + ;

: running? ( -- ? ) gctl rl@ 1 and 0<> ;
: reset ( -- ) 0 gctl rl!  begin running? 0= until ;
: start ( -- ) 1 gctl rl!  begin running? until ;

\\\ Stream Descriptors

\ Stream descriptor index. 
0 value sd#
: sd+ ( offset -- adr ) sd# h# 20 * + au + ;
: sd++ ( offset -- adr ) sd# h# 20 * + au + 80 + ;

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

: command-ready? ( -- ? ) ics rw@ 1 and 0= ;
: response-ready? ( -- ? ) ics rw@ 2 and 0<> ;

: write-command ( c -- ) begin command-ready? until  icw rl! ;
: read-response ( -- r ) begin response-ready? until  irr rl@ ;

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
0 value corb
0 value corb-phys
0 value corb-pos

: corb-dma-on  ( -- ) 2 corbctl rb! ;
: corb-dma-off ( -- ) 0 corbctl rb!  begin corbctl rb@  2 and 0= until ;

: init-corb ( -- )
    /corb dma-alloc  to corb
    corb /corb 0 fill
    corb /corb true dma-map-in  to corb-phys
    corb-dma-off
    corb-phys corblbase rl!
    0 corbubase rl!
    2 corbsize rb!      \ 256 entries
    corbrp rw@ to corb-pos
    corb-dma-on
;

: wait-for-corb-sync ( -- ) begin corbrp rw@ corb-pos = until ;

: corb-tx ( u -- )
    corb-pos 1+ d# 256 mod to corb-pos
    corb-pos cells corb + ! ( )
    corb-pos corbwp rw!
    wait-for-corb-sync
;

\\\ RIRB - Response Inbound Ring Buffer

d# 256 2* cells constant /rirb
0 value rirb
0 value rirb-phys
0 value rirb-pos

: rirb-dma-off ( -- ) 0 rirbctl rb! ;
: rirb-dma-on  ( -- ) 2 rirbctl rb! ;

: init-rirb ( -- )
    rirb-dma-off
    /rirb dma-alloc  to rirb
    rirb /rirb 0 fill
    rirb /corb true dma-map-in  to rirb-phys
    rirb-phys rirblbase rl!
    0 rirbubase rl!
    2 rirbsize rb! \ 256 entries
    rirbwp rw@ to rirb-pos
    rirb-dma-on
;

: rirb-data? ( -- ) rirb-pos rirbwp rw@ <> ;

: rirb-read ( -- resp solicited? )
    begin rirb-data?  key? abort" key interrupt" until
    rirb-pos 1+ d# 256 mod to rirb-pos
    rirb-pos 2 * cells rirb +      ( adr )
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
   codec d# 28 lshift  node d# 20 lshift  or or
;

: cmd ( verb -- resp ) encode-command corb-tx rirb-rx ;

\\\ Getting parameters

: config-default ( -- c ) f1c00 cmd ;
: default-device ( -- d ) config-default d# 20 rshift  f and ;
: connectivity   ( -- c ) config-default d# 30 rshift ;

: #subnodes     f0004 cmd  h# ff and ;
: first-subnode f0004 cmd  d# 16 rshift ;

: widget-type    ( -- u ) f0009 cmd  d# 20 rshift f and ;
: pin-widget?    ( -- ? ) widget-type 4 = ;
: builtin?       ( -- ? ) connectivity 2 = ;
: speaker?       ( -- ? ) default-device 1 = ;
: headphone?     ( -- ? ) default-device 2 = ;
: mic?           ( -- ? ) default-device h# a = ;

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

: setup-widget ( -- )
   pin-widget? headphone? and if
      3b000 cmd drop \ unmute
      707c0 cmd drop \ pin widget: enable output, headphones
   then
;

: init-widgets ( -- ) ['] setup-widget do-tree ;

\\ Streams
\\\ Buffer Descriptor List
 
struct ( buffer descriptor )
    4 field >bd-laddr
    4 field >bd-uaddr
    4 field >bd-len
    4 field >bd-ioc
\    d# 16 field >pad
constant /bd

0 value bdl
0 value bdl-phys
d# 256 /bd * value /bdl

: alloc-bdl ( -- )
    /bdl dma-alloc to bdl
    bdl /bdl 0 fill
    bdl /bdl true dma-map-in to bdl-phys
;

\\\ Sound buffers
\ Sound buffers are allocated in contiguous memory.
0 value buffers
0 value buffers-phys
h# 80000 constant /buffers

: buffer-descriptor ( n -- adr ) /bd * bdl + ;
\ : buffer ( n -- adr ) /buffer * buffers + ;
\ : buffer-phys ( n -- adr ) /buffer * buffers-phys + ;

: alloc-sound-buffers ( -- )
   alloc-bdl
   /buffers dma-alloc to buffers
   buffers /buffers true dma-map-in to buffers-phys
   buffers /buffers -1 fill
;

: init-sound-buffers ( -- )
   buffers 0= if alloc-sound-buffers then
   \ first descriptor is whole buffer
   buffers-phys 0 buffer-descriptor >bd-laddr !
   0            0 buffer-descriptor >bd-uaddr !
   0            0 buffer-descriptor >bd-len !
   0            0 buffer-descriptor >bd-ioc !
   \ second descriptor is 'dummy' - one word
   buffers-phys 0 buffer-descriptor >bd-laddr !
   0            0 buffer-descriptor >bd-uaddr !
   4            0 buffer-descriptor >bd-len !
   0            0 buffer-descriptor >bd-ioc !
;   

: sound-len! ( u -- ) 0 buffer-descriptor >bd-len ! ;

\\\ Starting and stopping channels

: assert-stream-reset   ( -- ) 1 sdctl rb!  begin sdctl rb@ 1 and 1 = until ;
: deassert-stream-reset ( -- ) 0 sdctl rb!  begin sdctl rb@ 1 and 0 = until ;

: reset-stream ( -- ) assert-stream-reset deassert-stream-reset ;
: stop-stream  ( -- ) 0 sdctl rb! begin sdctl rb@ 2 and 0=  until ;
: start-stream ( -- ) 2 sdctl rb! begin sdctl rb@ 2 and 0<> until ;

\\ DMA position buffer

0 value dma-pos
0 value dma-pos-phys
d# 4096 value /dma-pos 

: init-dma-pos-buffer ( -- )
   /dma-pos dma-alloc to dma-pos
   dma-pos /dma-pos true dma-map-in to dma-pos-phys
   dma-pos /dma-pos 0 fill
   dma-pos-phys 1 or  dplbase rl!
   0                  dpubase rl!
;

\\ Module interface
\\\ Device open and close

: reset-status-regs ( -- )
   0 wakeen rw!  0 statests rw!
   8 0 do  i to sd#  1c sdsts rb!  loop
;

: via-hack ( -- )
    2 to node  70500 cmd drop
   11 to node  70500 cmd drop
   19 to node  70500 cmd drop
;

: init-all ( -- ) init-corb init-rirb init-sound-buffers via-hack ;

: init ( -- ) ;

: restart-controller ( -- )
   reset
   init-dma-pos-buffer
   start
   1 ms \ allow 250us for codecs to initialize
;

: sanity-check ( -- )
   statests rw@ 1 <> if
      ." hdaudio: expected one codec but found this bitset: " statests rw@ . cr
   then
;

: open ( -- flag ) 
   map-regs  restart-controller  sanity-check  init-all  true
;

: close ( -- )
    reset  unmap-regs
;

\\\ Audio API

2 value amp

: gain/mute! ( gain mute? -- )
    if h# 80 or then  ( gain/mute )
    h# 3f000 or       \ set output, input, left, right
    cmd
;

: unmute-in  ( -- ) h# 37000 cmd drop ;
: unmute-out ( -- ) h# 3b000 cmd drop ;

: amp-caps ( -- u ) f0012 cmd ;

: gain-steps ( -- n ) amp-caps  8 rshift 7f and  1+ ;
: step-size  ( -- n ) amp-caps  d# 16 rshift  7f and  1+ ;
: 0dB-step   ( -- n ) amp-caps  7f and ;

: steps/dB ( -- #steps ) step-size 4 * ;

: dB>steps ( dB -- #steps ) 4 *  step-size / ;

: set-volume ( dB -- )
   amp to node
   dB>steps  0dB-step +  false gain/mute!
;

\\ Testing

\ Channel 0

2 constant /sample

: random ( -- n ) counter rl@ ;

: init-square-wave ( -- )
    buffers /buffers d# 96 - bounds do
        i d# 48 bounds do
           c00 i * /buffers / 2 *   i w!
           -c00 i * /buffers / 2 * i d# 48 + w!
        2 +loop
    d# 96 +loop
;

: test-stream-output ( -- )
   reset-stream
   /buffers sound-len!
   /buffers sdcbl rl! \ buffer length
   440000 sdctl rl!   \ stream 4
   1 sdlvi rw!
\   #buffers 2 / 1 -  sdlvi rw!
\   #buffers 1 -  sdlvi rw!
   bdl-phys     sdbdpl rl!
   0            sdbdpu rl!
   0011 sdfmt rw! \ 16-bit 
;

: via-extra ( -- )
[ifdef] oinkoink
   01 to node 705 8 lshift 0 or  cmd drop \ set power state
   10 to node 705 8 lshift 0 or  cmd drop \ ...
   11 to node 705 8 lshift 0 or  cmd drop 
   12 to node 705 8 lshift 0 or  cmd drop 
   14 to node 705 8 lshift 0 or  cmd drop 
   15 to node 705 8 lshift 0 or  cmd drop 
   16 to node 705 8 lshift 0 or  cmd drop 
   17 to node 705 8 lshift 0 or  cmd drop 
   18 to node 705 8 lshift 0 or  cmd drop 
   19 to node 705 8 lshift 0 or  cmd drop 
   1a to node 705 8 lshift 0 or  cmd drop 
   1b to node 705 8 lshift 0 or  cmd drop 
   1c to node 705 8 lshift 0 or  cmd drop 
   1d to node 705 8 lshift 0 or  cmd drop 
   1e to node 705 8 lshift 0 or  cmd drop 
   1f to node 705 8 lshift 0 or  cmd drop 
   20 to node 705 8 lshift 0 or  cmd drop 
   21 to node 705 8 lshift 0 or  cmd drop 
   22 to node 705 8 lshift 0 or  cmd drop 
   23 to node 705 8 lshift 0 or  cmd drop 
   24 to node 705 8 lshift 0 or  cmd drop 
[then]
   14 to node 300 8 lshift 6006 or  cmd drop \ set volume
   14 to node 300 8 lshift 5006 or  cmd drop \ ...
   23 to node 300 8 lshift 6004 or  cmd drop 
   23 to node 300 8 lshift 5004 or  cmd drop 
   17 to node 300 8 lshift a004 or  cmd drop 
   17 to node 300 8 lshift 9004 or  cmd drop 
   18 to node 300 8 lshift a004 or  cmd drop 
   18 to node 300 8 lshift 9004 or  cmd drop 
   14 to node 300 8 lshift 6200 or  cmd drop 
   14 to node 300 8 lshift 5200 or  cmd drop 
   10 to node 300 8 lshift a03e or  cmd drop 
   10 to node 300 8 lshift 903e or  cmd drop 
   10 to node 706 8 lshift 40 or  cmd drop   \ converter stream (4)
   10 to node 200 8 lshift 11 or  cmd drop   \ converter format
[ifdef] oinkoink
   7  to node 300 8 lshift 701d or cmd  drop \ get connection list
   18 to node 300 8 lshift 7003 or cmd  drop \ volume = 3
   18 to node 707 8 lshift 24 or   cmd  drop \ pin control
   24 to node 701 8 lshift 0 or    cmd  drop \ set connection
   24 to node 300 8 lshift 7000 or cmd  drop \ set volume
   24 to node 300 8 lshift b000 or cmd  drop \ set volume
   c  to node 701 8 lshift 0 or    cmd  drop \ set connection
   c  to node 300 8 lshift 7000 or cmd  drop \ set volume
   c  to node 300 8 lshift b000 or cmd  drop \ set volume
   14 to node 701 8 lshift 0 or    cmd  drop \ set connection
   14 to node 300 8 lshift 7000 or cmd  drop \ set volume
   14 to node 300 8 lshift b000 or cmd  drop \ set volume
   14 to node 300 8 lshift b000 or cmd  drop \ set volume
   14 to node 707 8 lshift 40 or   cmd  drop \ pin control
   c  to node 701 8 lshift 0 or    cmd  drop \ set connection
   c  to node 300 8 lshift 7000 or cmd  drop \ set volume
   c  to node 300 8 lshift b000 or cmd  drop \ set volume
\[then]
   15 to node 701 8 lshift 0 or    cmd  drop \ set connection
   15 to node 300 8 lshift 7000 or cmd  drop \ set volume
   15 to node 300 8 lshift b000 or cmd  drop \ set volume
   15 to node 300 8 lshift b000 or cmd  drop \ set volume
   15 to node 707 8 lshift c0 or   cmd  drop \ pin control
\[ifdef] oinkoink
   7  to node 701 8 lshift 0 or    cmd  drop \ set connection
\[then]
   1  to node 705 8 lshift 0 or    cmd  drop \ set power state
   2  to node 706 8 lshift 40 or   cmd  drop \ converter stream (4)
   2  to node 200 8 lshift 11 or   cmd  drop \ converter format
\   2  to node 706 8 lshift 0 or    cmd  drop \ converter stream
\   2  to node 200 8 lshift 0 or    cmd  drop 
[then]
\   70640 cmd drop \ stream #
\   20011 cmd drop \ format
;

: blast-sound ( -- )
   4 to sd#
   init-square-wave
   init-widgets
   test-stream-output
   10 to node
\   70640 cmd drop \ stream #
\   20011 cmd drop \ format
   via-extra
   start-stream
\   3b024 cmd drop \ volume (low)
;

: quiet ( -- )
   15 to node  3b080 cmd drop
;

: dma-positions ( -- )
   dma-pos /dma-pos dump
;

\ sweep

0 value sweep
0 value /sweep

: load-sweep ( -- )
   " sweep" find-drop-in  0= abort" can't find sweep drop-in"
   to /sweep to sweep
;

: copy-sweep ( -- )
   sweep 0= if  load-sweep  then
   sweep buffers /sweep move
;

: sweep-stream-output ( -- )
   reset-stream
   /sweep sound-len!
   /sweep sdcbl rl! \ buffer length
   440000 sdctl rl!   \ stream 4
   1 sdlvi rw!
\   #buffers 1 -  sdlvi rw!
\   #buffers 1 -  sdlvi rw!
   bdl-phys     sdbdpl rl!
   0            sdbdpu rl!
   0011 sdfmt rw! \ 16-bit 
;

: play-sweep ( -- )
   4 to sd#
   copy-sweep
   init-widgets
   copy-sweep
   sweep-stream-output
   copy-sweep
   10 to node
   70640 cmd drop \ stream #
   20011 cmd drop \ format
   copy-sweep
   start-stream
   copy-sweep
   3b024 cmd drop \ volume (low)
;   

[ifndef] hdaudio-loaded
dend
select /hdaudio
[else]
dev /hdaudio close open
[then]

create hdaudio-loaded





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
\ param: 0d amp-caps
param: 0e connections
param: 0f power-states
param: 10 processing-caps
param: 11 gpio-count
param: 13 volume-caps


: connection0 ( -- n ) f0200 cmd ( connection-list ) ff and ;
: config-default ( -- c ) f1c00 cmd ;
: connection-select ( -- n ) f0100 cmd ;
: default-device ( -- d ) config-default d# 20 rshift  f and ;
: location       ( -- l ) config-default d# 24 rshift 3f and ;
: color          ( -- c ) config-default d# 12 rshift  f and ;
: connectivity   ( -- c ) config-default d# 30 rshift ;

: gain/mute ( output? left? -- gain mute? )
    0 swap if h# 2000 or then
    swap   if h# 8000 or then
    h# b0000 or  cmd
    dup h# 7f and      ( res gain )
    swap h# 80 and 0<> ( gain mute? )
;

\\\ Inspecting widgets

: .connectivity ( -- )
    case connectivity
        0 of ." external " endof
        1 of ." unused " endof
        2 of ." builtin " endof
        3 of ." builtin/external " endof
    endcase
;

: .color ( -- )
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
;

: .location ( -- )
    case location
        1 of ." rear " endof
        2 of ." front " endof
        3 of ." left " endof
        4 of ." right " endof
        5 of ." top " endof
        6 of ." bottom " endof
        7 of ." special " endof
    endcase
;    

: .default-device ( -- )
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
;

: .node ( -- )
    do-tree-level spaces
    codec . ." / " node .
    f0200 cmd lbsplit 4 0 do <# u# u# u#> type space loop 2 spaces
    widget-type case
        0   of ." audio output"   endof
        1   of ." audio input"    endof
        2   of ." audio mixer"    endof
        3   of ." audio selector" endof
        4   of ." pin widget (" .connectivity .color .location .default-device endof
        5   of ." power widget"   endof
        6   of ." volume knob"    endof
        7   of ." beep generator" endof
        dup of                    endof
    endcase
    cr  exit? abort" "
;

." loaded" cr

