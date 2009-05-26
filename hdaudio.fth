\ Intel HD Audio driver (work in progress)  -*- forth -*-
\ Copyright 2009 Luke Gorrie <luke@bup.co.nz>

warning off

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
0 value corb-virt
0 value corb-phys
0 value corb-pos

: corb-dma-on  ( -- ) 2 corbctl rb! ;
: corb-dma-off ( -- ) 0 corbctl rb!  begin corbctl rb@  2 and 0= until ;

: init-corb ( -- )
    /corb dma-alloc  to corb-virt
    corb-virt /corb 0 fill
    corb-virt /corb true dma-map-in  to corb-phys
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
    corb-pos cells corb-virt + ! ( )
    corb-pos corbwp rw!
    wait-for-corb-sync
;

\\\ RIRB - Response Inbound Ring Buffer

d# 256 2* cells constant /rirb
0 value rirb-virt
0 value rirb-phys
0 value rirb-pos

: rirb-dma-off ( -- ) 0 rirbctl rb! ;
: rirb-dma-on  ( -- ) 2 rirbctl rb! ;

: init-rirb ( -- )
    rirb-dma-off
    /rirb dma-alloc  to rirb-virt
    rirb-virt /rirb 0 fill
    rirb-virt /corb true dma-map-in  to rirb-phys
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

0 value bdl-virt
0 value bdl-phys
d# 256 /bd * value /bdl

: alloc-bdl ( -- )
    /bdl dma-alloc to bdl-virt
    bdl-virt /bdl -1 lfill
    bdl-virt /bdl true dma-map-in to bdl-phys
;

\\\ Sound buffers
\ Sound buffers are allocated in contiguous memory.
0 value buffers-virt
0 value buffers-phys
h# 2000 value /buffer
d# 256 value #buffers
/buffer #buffers * constant /buffers

: buffer-descriptor ( n -- adr ) /bd * bdl-virt + ;
: buffer-virt ( n -- adr ) /buffer * buffers-virt + ;
: buffer-phys ( n -- adr ) /buffer * buffers-phys + ;

: alloc-sound-buffers ( -- )
   alloc-bdl
   /buffers dma-alloc to buffers-virt
   buffers-virt /buffers true dma-map-in to buffers-phys
   buffers-virt /buffers -1 fill
;

: init-sound-buffers ( -- )
   buffers-virt 0= if alloc-sound-buffers then
   #buffers 0 do
      i buffer-phys  i buffer-descriptor >bd-laddr !
                  0  i buffer-descriptor >bd-uaddr !
                  0  i buffer-descriptor >bd-ioc !
      /buffer  i buffer-descriptor >bd-len !
   loop
;

\\\ Starting and stopping channels

: assert-stream-reset   ( -- ) 1 sdctl rb!  begin sdctl rb@ 1 and 1 = until ;
: deassert-stream-reset ( -- ) 0 sdctl rb!  begin sdctl rb@ 1 and 0 = until ;

: reset-stream ( -- ) assert-stream-reset deassert-stream-reset ;
: stop-stream  ( -- ) 0 sdctl rb! begin sdctl rb@ 2 and 0=  until ;
: start-stream ( -- ) 2 sdctl rb! begin sdctl rb@ 2 and 0<> until ;

\\ DMA position buffer

0 value dma-pos-virt
0 value dma-pos-phys
d# 4096 value /dma-pos 

: init-dma-pos-buffer ( -- )
   /dma-pos dma-alloc to dma-pos-virt
   dma-pos-virt /dma-pos true dma-map-in to dma-pos-phys
   dma-pos-virt /dma-pos 0 fill
   dma-pos-phys 1 or  dplbase rl!
   0                  dpubase rl!
;

\\ Device open and close

: reset-status-regs ( -- )
   0 wakeen rw!  0 statests rw!
   8 0 do  i to sd#  1c sdsts rb!  loop
;

: init-all ( -- ) init-corb init-rirb init-sound-buffers ;

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

\\ Testing

\ Channel 0

2 constant /sample

: random ( -- n ) counter rl@ ;

: init-square-wave ( -- )
    buffers-virt /buffers d# 96 - bounds do
        i d# 48 bounds do
           c00 i * /buffers / 2 *   i w!
           -c00 i * /buffers / 2 * i d# 48 + w!
        2 +loop
    d# 96 +loop
;

: test-stream-output ( -- )
   reset-stream
   /buffers /sample / sdcbl rl! \ buffer length
\   /buffer  sdcbl rl! \ buffer length
   440000 sdctl rl!   \ stream 4
\   1 sdlvi rw!
   #buffers 2 / 1 -  sdlvi rw!
\   #buffers 1 -  sdlvi rw!
   bdl-phys     sdbdpl rl!
   0            sdbdpu rl!
   0011 sdfmt rw! \ 16-bit 
;

: blast-sound ( -- )
   4 to sd#
   init-square-wave
\   buffers-virt /buffers 0 fill
   init-widgets
   test-stream-output
   2 to node
   70640 cmd drop \ stream #
   20011 cmd drop \ format
   start-stream
   3b024 cmd drop \ volume (low)
;

: quiet ( -- )
   15 to node  3b080 cmd drop
;

: dma-positions ( -- )
   dma-pos-virt /dma-pos dump
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
   sweep buffers-virt /sweep move
;

: sweep-stream-output ( -- )
   reset-stream
   /sweep sdcbl rl! \ buffer length
\   /buffer  sdcbl rl! \ buffer length
   440000 sdctl rl!   \ stream 4
\   1 sdlvi rw!
   #buffers 1 -  sdlvi rw!
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
   2 to node
   70640 cmd drop \ stream #
   20011 cmd drop \ format
   copy-sweep
   start-stream
   copy-sweep
   3b024 cmd drop \ volume (low)
;   

[ifndef] hdaudio-loaded
select /hdaudio
[else]
close open
[then]

create hdaudio-loaded

