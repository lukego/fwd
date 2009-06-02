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
: dma-free    ( adr size -- )  " dma-free" $call-parent  ;
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
\ Default: 48kHz 16bit stereo
0 value scale-factor
0 value sample-base
0 value sample-mul
0 value sample-div
1 value sample-format
2 value #channels

: stream-format ( -- u )
   sample-base    d# 14 lshift     ( acc )
   sample-mul     d# 11 lshift  or ( acc )
   sample-div     d#  8 lshift  or ( acc )
   sample-format      4 lshift  or ( acc )
   #channels 1-                 or ( fmt )
;

: sample-rate! ( base mul div ) to sample-div to sample-mul to sample-base ;

:   48kHz ( -- ) 0 0 0 sample-rate! ;
: 44.1kHz ( -- ) 1 0 0 sample-rate! ;
:   96kHz ( -- ) 0 1 0 sample-rate! ;
:  192kHz ( -- ) 0 3 0 sample-rate! ;

:  8bit ( -- ) 0 to sample-format ;
: 16bit ( -- ) 1 to sample-format ;
: 20bit ( -- ) 2 to sample-format ;
: 24bit ( -- ) 3 to sample-format ;
: 32bit ( -- ) 4 to sample-format ;

\ Stream descriptor index. 
4 constant sd#
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

0 value amp

: connection0 ( -- n ) f0200 cmd ( connection-list ) ff and ;

: setup-widget ( -- )
   pin-widget? headphone? and if
      3b000 cmd drop \ unmute
      707c0 cmd drop \ pin widget: enable output, headphones
      connection0 to amp
   then
   pin-widget? speaker? builtin? and and if
      3b000 cmd drop \ unmute
      70740 cmd drop \ pin widget: enable output
   then
;

: init-widgets ( -- ) ['] setup-widget do-tree ;

\\ Streams
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

: via-extra ( -- )
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
;

: init-all ( -- ) init-corb init-rirb init-widgets via-extra ;

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

: low-rate? ( Hz ) dup d# 48.000 <  swap d# 44.100 <>  and ;

: set-sample-rate ( Hz -- )
   dup low-rate? if
      48kHz  d# 48.000 swap / to scale-factor
   else
      1 to scale-factor
      d# 48.000 / case \ find nearest supported rate
         0   of 44.1kHz endof
         1   of   48kHz endof
         2   of   96kHz endof
         3   of   48kHz  2 to scale-factor endof
         dup of  192kHz endof
      endcase
   then
;

\\ Sound buffers

\\\ Sound buffer
\ Sound buffer contains the real sound samples for both playback and recording.

0 value sound-buffer
0 value sound-buffer-phys
0 value /sound-buffer

: install-sound-buffer ( adr len -- )
   2dup  to /sound-buffer  to sound-buffer
   true dma-map-in to sound-buffer-phys
;

0 value pad-buffer
0 value pad-buffer-phys
d# 2048 value /pad-buffer

: alloc-pad-buffer ( -- )
   /pad-buffer dma-alloc to pad-buffer
   pad-buffer /pad-buffer true dma-map-in to pad-buffer-phys
   pad-buffer /pad-buffer 0 fill
;

: free-pad-buffer ( -- )
   pad-buffer pad-buffer-phys /pad-buffer dma-map-out
   pad-buffer /pad-buffer dma-free
;

\\\ Buffer Descriptor List
 
struct ( buffer descriptor )
    4 field >bd-laddr
    4 field >bd-uaddr
    4 field >bd-len
    4 field >bd-ioc
constant /bd

0 value bdl
0 value bdl-phys
d# 256 /bd * value /bdl

: buffer-descriptor ( n -- adr ) /bd * bdl + ;

: allocate-bdl ( -- )
    /bdl dma-alloc to bdl
    bdl /bdl 0 fill
    bdl /bdl true dma-map-in to bdl-phys
;

: free-bdl ( -- ) bdl-phys /bdl dma-map-out   bdl /bdl dma-free ;

: setup-bdl ( -- )
   allocate-bdl
   sound-buffer-phys 0 buffer-descriptor >bd-laddr !  ( len )
   0                 0 buffer-descriptor >bd-uaddr !  ( len )
   /sound-buffer     0 buffer-descriptor >bd-len   !  ( )
   1                 0 buffer-descriptor >bd-ioc   !
   \ pad buffer
   alloc-pad-buffer
   pad-buffer-phys  1 buffer-descriptor >bd-laddr !
                 0  1 buffer-descriptor >bd-uaddr !
       /pad-buffer  1 buffer-descriptor >bd-len   !
                 0  1 buffer-descriptor >bd-ioc   !
;

: teardown-bdl ( -- )
   free-bdl
   free-pad-buffer
;

\\\ Stream descriptor (DMA engine)

: setup-stream ( -- )
   reset-stream
   /sound-buffer /pad-buffer + sdcbl rl! \ bytes of stream data
   440000 sdctl rl!               \ stream 4
   1 sdlvi rw!                    \ two buffers
   1c sdsts c!                    \ clear status flags
   bdl-phys sdbdpl rl!
   0        sdbdpu rl!
   stream-format sdfmt rw!
   \ FIXME
   10 to node  20000 stream-format or cmd  drop
;

: stream-done?     ( -- ) sdsts c@ 4 and 0<> ;
: wait-stream-done ( -- ) begin stream-done? until ;

\\\ Upsampling

0 value src
0 value /src
0 value dst
0 value /dst
0 value upsample-factor

: dst! ( value step# sample# -- )
   upsample-factor *  + ( value dst-sample# ) 4 * dst +  w!
;

\ Copy source sample N into a series of interpolated destination samples.
: copy-sample ( n -- )
   dup 4* src +              ( n src-adr )
   dup <w@  swap 4 + <w@     ( n s1 s2 )
   over - upsample-factor /  ( n s1 step )
   upsample-factor 0 do
      2dup i * +             ( n s1 step s )
      i  4 pick              ( n s1 step s i n )
      dst!
   loop
   3drop
;

: upsample-channel ( -- )
   /src 4 /  1 do
      i b3b0 = if i . cr then
      i copy-sample
   loop
;

: upsample ( adr len factor -- adr len )
   to upsample-factor  to /src  to src
   /src upsample-factor * to /dst
   /dst dma-alloc to dst
   upsample-channel \ left
   src 2+ to src  dst 2+ to dst
   upsample-channel \ right
   dst 2 -  /dst ( dst dst-len )
;

\\\ Audio interface

: upsampling? ( -- ? ) scale-factor 1 <> ;

: write ( adr len -- actual )
   48kHz
   upsampling? if scale-factor upsample then ( adr len )
   install-sound-buffer ( )
   setup-bdl
   setup-stream
   start-stream
   /sound-buffer        ( actual )
;

: release-sound-buffer ( -- )
   sound-buffer-phys /sound-buffer dma-map-out
   upsampling? if  sound-buffer /sound-buffer dma-free  then
;

: write-done ( -- )
   wait-stream-done
   stop-stream
   free-bdl
   release-sound-buffer
;

\\ Microphone

: open-in ( -- )
;

: record-stream ( -- )
   0 to sd#
   48kHz
   reset-stream
   /sound-buffer /pad-buffer + sdcbl rl! \ buffer length
   100000 sdctl rl!        \ stream 1, input
   1 sdlvi rw!             \ two buffers
   1c sdsts c!             \ clear status flags
   bdl-phys sdbdpl rl!
          0 sdbdpu rl!
   stream-format sdfmt rw!
   \ extra magic
   14 to node
   70610 cmd drop \ 
   20010 cmd drop \ stream format 48kHz, 16-bit, mono
\   17 to node  70101 cmd drop
   1a to node  70721 cmd drop
   1b to node  70721 cmd drop
   14 to node  37040 cmd drop

;

: start-recording ( adr len -- )
   install-sound-buffer   ( )
   alloc-pad-buffer       ( adr len )
   setup-bdl
   record-stream
   start-stream
;

0 value recbuf
0 value recbuf-phys
d# 65535 value /recbuf 

: audio-in ( adr len -- actual )
   debug-me
   start-recording
   wait-stream-done
\   release-sound-buffer
   free-pad-buffer
   /recbuf
;

: enable-mic ( node -- )
   to node
   70720 cmd drop
;

: config-audio-input ( -- )
   14 to node
   70610 cmd drop \ stream 1, channel 0
   20000 stream-format or cmd  drop \ stream format
;

: record-test ( n -- )
   to /recbuf
   /recbuf dma-alloc to recbuf
   recbuf /recbuf true dma-map-in to recbuf-phys
   recbuf-phys /recbuf audio-in
;

\\ Verifying pin sense

: can-pin-sense? ( -- ? ) f000c cmd 4 and 0<> ;
: pin-sense?     ( -- ? ) f0900 cmd 8000.0000 and 0<> ;
: sense-mic ( -- ) mic? can-pin-sense? and if node . pin-sense? . cr then ;
   


\\ Testing

\ d# 512 d# 1024 * constant /square-wave
100 constant /square-wave
create square-wave  /square-wave allot

: init-square-wave ( -- )
   square-wave /square-wave d# 96 - bounds do
      i d# 48 bounds do
         c00 i * /square-wave / 2 *   i w!
         -c00 i * /square-wave / 2 * i d# 48 + w!
      2 +loop
   d# 96 +loop
;

: play-square-wave ( -- )
   init-square-wave  square-wave /square-wave write  write-done
;

: shh ( -- ) 10 to node  3b080 cmd drop ;




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

: in-amp-caps ( -- u ) f000d cmd ;
: in-gain-steps ( -- n ) in-amp-caps  8 rshift 7f and  1+ ;
: in-step-size  ( -- n ) in-amp-caps  d# 16 rshift  7f and  1+ ;
: in-0dB-step   ( -- n ) in-amp-caps  7f and ;
: in-steps/dB ( -- #steps ) in-step-size 4 * ;

: .input-amp ( -- )
   ." gain steps: " in-gain-steps . cr
   ."  left gain:  " false true  gain/mute swap . if ." (muted)" then cr
   ." right gain:  " false false gain/mute swap . if ." (muted)" then cr
;


." loaded" cr

[ifndef] hdaudio-loaded
select /hdaudio
[else]
( close open ) select /hdaudio
[then]

create hdaudio-loaded

