\ cgc.fth -- Conservative Garbage Collector for Openfirmware.
\ Copyright 2009 Luke Gorrie <luke@bup.co.nz>   (BSD LICENSE)

\ The interface to this module is simple:
\   /cgc     ( /block #blocks -- size )  How much space to allocate for the heap.
\   init-cgc ( /block #blocks adr --  )  Initialize with the heap allocated at ADR.
\   alloc    ( #bytes      -- address )  Allocate a block of memory. GC if needed.
\ Extension interface:
\   defer scan-extra-roots ( -- )  \ Hook to scan additional roots.
\   scan ( adr -- )                \ Scan adr as a root.

\ The heap is treated as an array of fixed-size blocks. Each
\ allocation uses one or more whole consecutive blocks. The blocks
\ don't contain any metadata -- that's kept separately in sets of free
\ blocks, marked blocks, etc (see below).

\ If you care about efficiency then maybe you should stop reading here :-)

create cgc			   \ Label for FORGET

0 value /block   \ the size of each memory block
0 value #blocks  \ the number of blocks in the heap
0 value base     \ base memory address for GC metadata and the heap

\ Four sets of flags for each block (freed, marked, scanned, run-on).
\ The sets are each byte-arrays with the Nth element representing block N.
: freed   ( -- set ) base ;                \ free and available for allocation
: marked  ( -- set ) base #blocks + ;      \ marked as reachable during GC
: scanned ( -- set ) base #blocks 2 * + ;  \ scanned for pointers during GC
: run-on  ( -- set ) base #blocks 3 * + ;  \ continues a multi-block allocation
: heap    ( -- adr ) base #blocks 4 * + ;  \ .. the heap itself follows these sets.

\ Set operations.
: is?   ( value set -- ? ) + c@ 0<> ;	   \ membership
: set   ( value set --   ) + 1 swap c! ;   \ add
: unset ( value set --   ) + 0 swap c! ;   \ remove
: none  ( set       --   ) /block 0 fill ; \ remove all
: all   ( set       --   ) /block 1 fill ; \ add all

: /heap   #blocks /block * ;
: /cgc    ( /block #blocks -- size ) dup 4 * -rot * + ;

\ Setup the garbage collector with a heap to allocate from.
: init-cgc ( /block #blocks adr -- )
    to base  to #blocks  to /block
    base   #blocks /block /cgc  0 fill
    freed all  run-on none
;

\ Conversion between blocks, bytes, and addresses.
\ Most of the program represents blocks by index (block#).

: blocks ( #bytes -- #blocks ) /block + 1- /block / ;
: bytes  ( #blocks -- #bytes ) /block * ;
: address ( block# -- adr )  bytes heap + ;
: block ( adr -- block# ) heap - /block / ;

: prepare-for-collection    ( -- ) marked none  scanned none ;

: >heap? ( adr -- ? ) block #blocks u< ;   \ Does adr point into the heap?

\ Scanning and marking
: scan       ( word   -- ) dup >heap? IF block marked set ELSE drop THEN ;
: scan-block ( block# -- ) address /block bounds DO  i @ scan  4 +LOOP ;

\ Handle multi-block objects here: if one block is scanned then so are the rest.
: >start ( block# -- block# ) BEGIN dup run-on is? WHILE 1- REPEAT ;
: scan-object ( block# -- )
    >start      ( start-block# )
    BEGIN       ( block# )
	dup scan-block  dup marked set  dup scanned set
    1+ dup run-on is? not UNTIL  drop
;

: needs-scan? ( block# -- ? ) dup marked is?  swap scanned is? not and ;
: scan-block? ( block# -- ? ) dup needs-scan? IF scan-object true ELSE drop false THEN ;

defer scan-extra-roots  ' noop is scan-extra-roots

: scan-stack     ( -- ) sp0 @ sp@ ?DO  i @ scan  4 +LOOP ;
\ NOTE: I don't think we need to scan machine registers -- the stack is enough.
: scan-roots ( -- ) scan-stack scan-extra-roots ;

: gc-loop ( -- )
    BEGIN
	false ( progress? ) #blocks 0 DO i scan-block? or LOOP
    0= UNTIL
;

: reclaim-block ( block# -- ) dup freed set  run-on unset ;
: can-reclaim?  ( block# -- ) dup marked is? not  swap freed is? not and ;
: reclaim ( -- ) #blocks 0 DO  i can-reclaim? IF i reclaim-block THEN  LOOP ;

\ Perform garbage collection
: gc ( -- )
    prepare-for-collection  \ Reset mark/scan state
    scan-roots	            \ Scan the root set and make initial marks
    gc-loop	            \ Keep on marking while making progress
    reclaim                 \ Free unmarked pages
;

\ Allocation
0 value alloc-search-start \ Optimization: look for free space here first.

: try-alloc ( #blocks -- adr )
    0  #blocks alloc-search-start ?DO ( #blocks free-run )
	2dup = IF ( #blocks #blocks )
	    \ Now we have found the right number of blocks.
	    i to alloc-search-start
	    drop              ( #blocks )
	    negate i +        ( first-block )
	    i over            ( first-block last-block first-block )
	    DO                ( first-block )
		i freed unset ( first-block )
		dup i <> IF i run-on set THEN
	    LOOP ( first-block )
	    address           ( adr )
	    unloop exit
	THEN
	i freed is? IF 1+ ELSE drop 0 THEN
    LOOP ( blocks free-run )
    alloc-search-start 0= IF
	\ Out of memory
	2drop 0
    ELSE \ Search again - this time from the beginning.
	0 to alloc-search-start
	drop recurse
    THEN
;

: alloc ( bytes -- adr )
    blocks dup ( blocks blocks )
    try-alloc ?dup 0= IF
	gc
	try-alloc ?dup 0= IF
	    true abort" out of memory"
	THEN
    ELSE
	nip
    THEN
;

\ Testing

: test-setup ( -- )
    d# 1024 d# 10240 2dup /cgc allocate 
    abort" couldn't allocate heap"    ( /block #blocks adr )
    init-cgc
;

: is-free  ( block# -- ) freed is? not abort" error" ;
: is-taken ( block# -- ) freed is? abort" error" ;

\ Test some simple scenarios with references on the stack and in the heap.
: test ( -- )
    heap /heap 0 fill  clear  gc
    ." check 0: " #blocks 0 DO i is-free LOOP  cr

    0 to alloc-search-start
    3 0 DO 1 alloc LOOP        ( b0 b1 b2 )
    ." check A: " 0 is-taken 1 is-taken 2 is-taken  cr

    nip gc                     ( b0 b2 )
    ." check B: " 0 is-taken 1 is-free 2 is-taken  cr

    2drop gc                   ( )
    ." check C: " 0 is-free 1 is-free 2 is-free    cr

    \ Let's make a little graph:
    \ b4->b0 b0->b1 b0->b3
    \ then with b4 on the stack we should free only b2.
    0 to alloc-search-start
    5 0 DO 1 alloc drop LOOP    ( )
    0 address 4 address !       \ b4->b0
    1 address 0 address !       \ b0->b1
    3 address 0 address cell+ ! \ b0->b3
    4 address                   ( b4 )
    gc
    ." check D: " 0 is-taken 1 is-taken 2 is-free 3 is-taken  cr

    \ Now free them all
    clear gc    ( )
    ." check E: "  4 0 DO i is-free LOOP  cr

    ." she'll be right mate" cr
;

: test2 ( -- ) d# 102400 0 DO d# 1024 alloc drop LOOP ." not dead yet" cr ;

\ Test multi-block objects.
: test3 ( -- )
    heap /heap 0 fill  clear  gc
    ." check 0: " #blocks 0 DO i is-free LOOP  cr

    0 to alloc-search-start
    /block alloc 2 /block * alloc 3 /block * alloc   ( b0 b1 b3 )
    gc
    ." check A: "  6 0 DO i is-taken LOOP  9 6 DO i is-free LOOP  cr
    ." looking good" cr
;

: run-tests ( -- ) test-setup test test2 test3 ;

