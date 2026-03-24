;; Mirror Maze - Beam Tracer WASM Module
;; Handles grid state, beam tracing, and puzzle validation
;;
;; Memory layout:
;;   Bytes 0-1599:   Grid cells (20x20 grid, 4 bytes per cell)
;;                   Cell format: [type:u8, angle:u8, flags:u8, pad:u8]
;;   Bytes 1600-1603: Grid width (i32)
;;   Bytes 1604-1607: Grid height (i32)
;;   Bytes 1608-1611: Beam segment count
;;   Bytes 1612-1615: Source count
;;   Bytes 1616-1619: Target count
;;   Bytes 1620-1623: Targets hit count
;;   Bytes 2000-5999: Beam segments (up to 250 segments, 16 bytes each)
;;                    Segment: [x1:f32, y1:f32, x2:f32, y2:f32]
;;   Bytes 6000-6799: Source list (up to 50 sources, 16 bytes each)
;;                    Source: [x:i32, y:i32, dir:i32, color:i32]
;;   Bytes 7000-7799: Target hit flags (up to 200 targets, 4 bytes each)
;;                    [x:i32, y:i32] encoded as single i32: x*100+y ... 
;;                    Actually: store as [hit:i32] at index matching target order

(module
  (memory (export "memory") 2)

  ;; Constants for cell types
  ;; 0 = empty, 1 = wall, 2 = mirror_fwd (/), 3 = mirror_bwd (\),
  ;; 4 = source, 5 = target, 6 = splitter

  ;; Direction encoding: 0=right, 1=down, 2=left, 3=up

  ;; Grid metadata addresses
  (global $GRID_WIDTH_ADDR  i32 (i32.const 1600))
  (global $GRID_HEIGHT_ADDR i32 (i32.const 1604))
  (global $SEG_COUNT_ADDR   i32 (i32.const 1608))
  (global $SRC_COUNT_ADDR   i32 (i32.const 1612))
  (global $TGT_COUNT_ADDR   i32 (i32.const 1616))
  (global $TGT_HIT_ADDR     i32 (i32.const 1620))

  (global $SEG_BASE  i32 (i32.const 2000))
  (global $SRC_BASE  i32 (i32.const 6000))
  (global $TGT_BASE  i32 (i32.const 7000))

  (global $MAX_SEGS  i32 (i32.const 250))
  (global $MAX_DEPTH i32 (i32.const 200))

  ;; Initialize grid with given dimensions
  (func (export "init_grid") (param $w i32) (param $h i32)
    (local $i i32)
    (local $n i32)
    ;; Store dimensions
    (i32.store (global.get $GRID_WIDTH_ADDR)  (local.get $w))
    (i32.store (global.get $GRID_HEIGHT_ADDR) (local.get $h))
    (i32.store (global.get $SEG_COUNT_ADDR)   (i32.const 0))
    (i32.store (global.get $SRC_COUNT_ADDR)   (i32.const 0))
    (i32.store (global.get $TGT_COUNT_ADDR)   (i32.const 0))
    (i32.store (global.get $TGT_HIT_ADDR)     (i32.const 0))
    ;; Clear grid (w*h*4 bytes from offset 0)
    (local.set $n (i32.mul (local.get $w) (local.get $h)))
    (local.set $i (i32.const 0))
    (block $break
      (loop $loop
        (br_if $break (i32.ge_u (local.get $i) (local.get $n)))
        (i32.store
          (i32.mul (local.get $i) (i32.const 4))
          (i32.const 0))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)
      )
    )
    ;; Clear target hit flags
    (local.set $i (i32.const 0))
    (block $break2
      (loop $loop2
        (br_if $break2 (i32.ge_u (local.get $i) (i32.const 200)))
        (i32.store
          (i32.add (global.get $TGT_BASE) (i32.mul (local.get $i) (i32.const 4)))
          (i32.const 0))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop2)
      )
    )
    ;; Clear segment buffer
    (local.set $i (i32.const 0))
    (block $break3
      (loop $loop3
        (br_if $break3 (i32.ge_u (local.get $i) (i32.const 250)))
        (f32.store
          (i32.add (global.get $SEG_BASE) (i32.mul (local.get $i) (i32.const 16)))
          (f32.const 0))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop3)
      )
    )
  )

  ;; Compute cell address in grid
  (func $cell_addr (param $x i32) (param $y i32) (result i32)
    (local $w i32)
    (local.set $w (i32.load (global.get $GRID_WIDTH_ADDR)))
    ;; addr = (y * width + x) * 4
    (i32.mul
      (i32.add (i32.mul (local.get $y) (local.get $w)) (local.get $x))
      (i32.const 4))
  )

  ;; Set a cell: type (u8), rotation (u8)
  (func (export "set_cell") (param $x i32) (param $y i32) (param $type i32) (param $rot i32)
    (local $addr i32)
    (local $w i32)
    (local $h i32)
    (local.set $w (i32.load (global.get $GRID_WIDTH_ADDR)))
    (local.set $h (i32.load (global.get $GRID_HEIGHT_ADDR)))
    ;; bounds check
    (if (i32.or
          (i32.or (i32.lt_s (local.get $x) (i32.const 0))
                  (i32.lt_s (local.get $y) (i32.const 0)))
          (i32.or (i32.ge_s (local.get $x) (local.get $w))
                  (i32.ge_s (local.get $y) (local.get $h))))
      (then (return)))
    (local.set $addr (call $cell_addr (local.get $x) (local.get $y)))
    ;; Store: low byte = type, next byte = rot
    (i32.store8         (local.get $addr)                      (local.get $type))
    (i32.store8 (i32.add (local.get $addr) (i32.const 1))      (local.get $rot))
    ;; Register source/target
    (if (i32.eq (local.get $type) (i32.const 4))
      (then (call $register_source (local.get $x) (local.get $y) (local.get $rot))))
    (if (i32.eq (local.get $type) (i32.const 5))
      (then (call $register_target (local.get $x) (local.get $y))))
  )

  ;; Get cell type at (x,y)
  (func (export "get_cell_type") (param $x i32) (param $y i32) (result i32)
    (i32.load8_u (call $cell_addr (local.get $x) (local.get $y)))
  )

  ;; Get cell rotation at (x,y)
  (func (export "get_cell_rot") (param $x i32) (param $y i32) (result i32)
    (i32.load8_u
      (i32.add (call $cell_addr (local.get $x) (local.get $y)) (i32.const 1)))
  )

  ;; Register a laser source
  (func $register_source (param $x i32) (param $y i32) (param $dir i32)
    (local $idx i32)
    (local $addr i32)
    (local.set $idx (i32.load (global.get $SRC_COUNT_ADDR)))
    (if (i32.ge_u (local.get $idx) (i32.const 50)) (then (return)))
    ;; addr = SRC_BASE + idx*16
    (local.set $addr
      (i32.add (global.get $SRC_BASE) (i32.mul (local.get $idx) (i32.const 16))))
    (i32.store         (local.get $addr)                       (local.get $x))
    (i32.store (i32.add (local.get $addr) (i32.const 4))       (local.get $y))
    (i32.store (i32.add (local.get $addr) (i32.const 8))       (local.get $dir))
    (i32.store (local.get $addr) (local.get $x))
    (i32.store (global.get $SRC_COUNT_ADDR)
      (i32.add (local.get $idx) (i32.const 1)))
  )

  ;; Register a target
  (func $register_target (param $x i32) (param $y i32)
    (local $idx i32)
    (local $addr i32)
    (local.set $idx (i32.load (global.get $TGT_COUNT_ADDR)))
    (if (i32.ge_u (local.get $idx) (i32.const 200)) (then (return)))
    ;; Store target as packed i32: x | (y << 8)
    (local.set $addr
      (i32.add (global.get $TGT_BASE) (i32.mul (local.get $idx) (i32.const 4))))
    (i32.store (local.get $addr)
      (i32.or (local.get $x) (i32.shl (local.get $y) (i32.const 8))))
    (i32.store (global.get $TGT_COUNT_ADDR)
      (i32.add (local.get $idx) (i32.const 1)))
  )

  ;; Get target x from index
  (func (export "get_target_x") (param $idx i32) (result i32)
    (i32.and
      (i32.load
        (i32.add (global.get $TGT_BASE) (i32.mul (local.get $idx) (i32.const 4))))
      (i32.const 0xFF))
  )

  ;; Get target y from index
  (func (export "get_target_y") (param $idx i32) (result i32)
    (i32.shr_u
      (i32.load
        (i32.add (global.get $TGT_BASE) (i32.mul (local.get $idx) (i32.const 4))))
      (i32.const 8))
  )

  ;; Check if a target is hit
  (func (export "is_target_hit") (param $idx i32) (result i32)
    ;; Returns the beam color that hit it (0 = not hit)
    ;; We store hit state in a separate table at TGT_BASE + 200*4
    (i32.load
      (i32.add
        (i32.add (global.get $TGT_BASE) (i32.const 800))
        (i32.mul (local.get $idx) (i32.const 4))))
  )

  ;; Mark target at (x,y) as hit, with beam source index
  (func $mark_target_hit (param $x i32) (param $y i32) (param $src_idx i32)
    (local $i i32)
    (local $count i32)
    (local $tx i32)
    (local $ty i32)
    (local $addr i32)
    (local.set $count (i32.load (global.get $TGT_COUNT_ADDR)))
    (local.set $i (i32.const 0))
    (block $done
      (loop $find
        (br_if $done (i32.ge_u (local.get $i) (local.get $count)))
        ;; Load target packed data
        (local.set $addr
          (i32.add (global.get $TGT_BASE) (i32.mul (local.get $i) (i32.const 4))))
        (local.set $tx (i32.and (i32.load (local.get $addr)) (i32.const 0xFF)))
        (local.set $ty (i32.shr_u (i32.load (local.get $addr)) (i32.const 8)))
        (if (i32.and
              (i32.eq (local.get $tx) (local.get $x))
              (i32.eq (local.get $ty) (local.get $y)))
          (then
            ;; Mark hit
            (i32.store
              (i32.add
                (i32.add (global.get $TGT_BASE) (i32.const 800))
                (i32.mul (local.get $i) (i32.const 4)))
              (i32.add (local.get $src_idx) (i32.const 1)))
            (br $done)
          )
        )
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $find)
      )
    )
  )

  ;; Add a beam segment (x1,y1) -> (x2,y2) as float grid coords
  (func $add_segment (param $x1 f32) (param $y1 f32) (param $x2 f32) (param $y2 f32) (param $color i32)
    (local $idx i32)
    (local $addr i32)
    (local.set $idx (i32.load (global.get $SEG_COUNT_ADDR)))
    ;; Max 250 segs total but per-color interleaved, we use 20 bytes
    (if (i32.ge_u (local.get $idx) (i32.const 250)) (then (return)))
    ;; addr = SEG_BASE + idx * 20
    (local.set $addr
      (i32.add (global.get $SEG_BASE) (i32.mul (local.get $idx) (i32.const 20))))
    (f32.store         (local.get $addr)                       (local.get $x1))
    (f32.store (i32.add (local.get $addr) (i32.const 4))       (local.get $y1))
    (f32.store (i32.add (local.get $addr) (i32.const 8))       (local.get $x2))
    (f32.store (i32.add (local.get $addr) (i32.const 12))      (local.get $y2))
    (i32.store (i32.add (local.get $addr) (i32.const 16))      (local.get $color))
    (i32.store (global.get $SEG_COUNT_ADDR) (i32.add (local.get $idx) (i32.const 1)))
  )

  ;; Get segment count
  (func (export "get_seg_count") (result i32)
    (i32.load (global.get $SEG_COUNT_ADDR))
  )

  ;; Get segment x1
  (func (export "get_seg_x1") (param $idx i32) (result f32)
    (f32.load
      (i32.add (global.get $SEG_BASE) (i32.mul (local.get $idx) (i32.const 20))))
  )
  ;; Get segment y1
  (func (export "get_seg_y1") (param $idx i32) (result f32)
    (f32.load
      (i32.add
        (i32.add (global.get $SEG_BASE) (i32.mul (local.get $idx) (i32.const 20)))
        (i32.const 4)))
  )
  ;; Get segment x2
  (func (export "get_seg_x2") (param $idx i32) (result f32)
    (f32.load
      (i32.add
        (i32.add (global.get $SEG_BASE) (i32.mul (local.get $idx) (i32.const 20)))
        (i32.const 8)))
  )
  ;; Get segment y2
  (func (export "get_seg_y2") (param $idx i32) (result f32)
    (f32.load
      (i32.add
        (i32.add (global.get $SEG_BASE) (i32.mul (local.get $idx) (i32.const 20)))
        (i32.const 12)))
  )
  ;; Get segment color (source index)
  (func (export "get_seg_color") (param $idx i32) (result i32)
    (i32.load
      (i32.add
        (i32.add (global.get $SEG_BASE) (i32.mul (local.get $idx) (i32.const 20)))
        (i32.const 16)))
  )

  ;; Get target count
  (func (export "get_target_count") (result i32)
    (i32.load (global.get $TGT_COUNT_ADDR))
  )

  ;; Reflect direction based on mirror type
  ;; mirror_type: 2 = '/' mirror, 3 = '\' mirror
  ;; dir: 0=right, 1=down, 2=left, 3=up
  ;; Returns new direction
  (func $reflect (param $dir i32) (param $mirror_type i32) (result i32)
    ;; '/' mirror (type 2): right->up, down->left, left->down, up->right
    ;; '\' mirror (type 3): right->down, down->right, left->up, up->left
    (if (i32.eq (local.get $mirror_type) (i32.const 2))
      (then
        (if (i32.eq (local.get $dir) (i32.const 0)) (then (return (i32.const 3))))
        (if (i32.eq (local.get $dir) (i32.const 1)) (then (return (i32.const 2))))
        (if (i32.eq (local.get $dir) (i32.const 2)) (then (return (i32.const 1))))
        (return (i32.const 0))
      )
    )
    ;; '\' mirror (type 3)
    (if (i32.eq (local.get $dir) (i32.const 0)) (then (return (i32.const 1))))
    (if (i32.eq (local.get $dir) (i32.const 1)) (then (return (i32.const 0))))
    (if (i32.eq (local.get $dir) (i32.const 2)) (then (return (i32.const 3))))
    (i32.const 2)
  )

  ;; Trace a single beam starting at grid cell (cx,cy) in direction dir
  ;; src_idx is the source index (for coloring)
  ;; Adds segments to the segment buffer
  ;; Uses iterative approach with depth limit to avoid infinite loops
  (func $trace_beam (param $cx i32) (param $cy i32) (param $dir i32) (param $src_idx i32)
    (local $nx i32)
    (local $ny i32)
    (local $cell_type i32)
    (local $depth i32)
    (local $w i32)
    (local $h i32)
    (local $sx f32) ;; segment start x
    (local $sy f32) ;; segment start y
    (local $ex f32) ;; segment end x (center of next cell)
    (local $ey f32) ;; segment end y
    (local $new_dir i32)
    (local $cell_rot i32)

    (local.set $w (i32.load (global.get $GRID_WIDTH_ADDR)))
    (local.set $h (i32.load (global.get $GRID_HEIGHT_ADDR)))

    ;; Start position = center of source cell
    (local.set $sx
      (f32.add (f32.convert_i32_s (local.get $cx)) (f32.const 0.5)))
    (local.set $sy
      (f32.add (f32.convert_i32_s (local.get $cy)) (f32.const 0.5)))

    (local.set $depth (i32.const 0))

    (block $done
      (loop $step
        (br_if $done (i32.ge_s (local.get $depth) (global.get $MAX_DEPTH)))
        (br_if $done (i32.ge_u (i32.load (global.get $SEG_COUNT_ADDR)) (global.get $MAX_SEGS)))

        ;; Compute next cell based on direction
        ;; dir: 0=right(+x), 1=down(+y), 2=left(-x), 3=up(-y)
        (local.set $nx (local.get $cx))
        (local.set $ny (local.get $cy))

        (if (i32.eq (local.get $dir) (i32.const 0))
          (then (local.set $nx (i32.add (local.get $cx) (i32.const 1)))))
        (if (i32.eq (local.get $dir) (i32.const 1))
          (then (local.set $ny (i32.add (local.get $cy) (i32.const 1)))))
        (if (i32.eq (local.get $dir) (i32.const 2))
          (then (local.set $nx (i32.sub (local.get $cx) (i32.const 1)))))
        (if (i32.eq (local.get $dir) (i32.const 3))
          (then (local.set $ny (i32.sub (local.get $cy) (i32.const 1)))))

        ;; Check bounds
        (if (i32.or
              (i32.or (i32.lt_s (local.get $nx) (i32.const 0))
                      (i32.lt_s (local.get $ny) (i32.const 0)))
              (i32.or (i32.ge_s (local.get $nx) (local.get $w))
                      (i32.ge_s (local.get $ny) (local.get $h))))
          (then
            ;; Hit the boundary - draw segment to edge
            (local.set $ex
              (f32.add (f32.convert_i32_s (local.get $nx)) (f32.const 0.5)))
            (local.set $ey
              (f32.add (f32.convert_i32_s (local.get $ny)) (f32.const 0.5)))
            (call $add_segment
              (local.get $sx) (local.get $sy)
              (local.get $ex) (local.get $ey)
              (local.get $src_idx))
            (br $done)
          )
        )

        ;; Get cell type at next position
        (local.set $cell_type
          (i32.load8_u (call $cell_addr (local.get $nx) (local.get $ny))))

        ;; Compute entry point (center of next cell)
        (local.set $ex
          (f32.add (f32.convert_i32_s (local.get $nx)) (f32.const 0.5)))
        (local.set $ey
          (f32.add (f32.convert_i32_s (local.get $ny)) (f32.const 0.5)))

        ;; Add segment from current to next cell center
        (call $add_segment
          (local.get $sx) (local.get $sy)
          (local.get $ex) (local.get $ey)
          (local.get $src_idx))

        ;; Update position
        (local.set $cx (local.get $nx))
        (local.set $cy (local.get $ny))
        (local.set $sx (local.get $ex))
        (local.set $sy (local.get $ey))

        ;; Handle cell type
        (if (i32.eq (local.get $cell_type) (i32.const 1))
          (then (br $done))) ;; wall - stop

        (if (i32.eq (local.get $cell_type) (i32.const 5))
          (then
            ;; target - mark hit and stop
            (call $mark_target_hit (local.get $cx) (local.get $cy) (local.get $src_idx))
            (br $done)
          )
        )

        (if (i32.eq (local.get $cell_type) (i32.const 4))
          (then (br $done))) ;; another source - stop

        (if (i32.or
              (i32.eq (local.get $cell_type) (i32.const 2))
              (i32.eq (local.get $cell_type) (i32.const 3)))
          (then
            ;; Mirror - reflect
            (local.set $dir (call $reflect (local.get $dir) (local.get $cell_type)))
          )
        )

        (local.set $depth (i32.add (local.get $depth) (i32.const 1)))
        (br $step)
      )
    )
  )

  ;; Trace all beams from all sources
  ;; Returns number of beam segments generated
  (func (export "trace_all_beams") (result i32)
    (local $i i32)
    (local $count i32)
    (local $addr i32)
    (local $sx i32)
    (local $sy i32)
    (local $sdir i32)
    (local $tcount i32)
    (local $j i32)

    ;; Reset segment count
    (i32.store (global.get $SEG_COUNT_ADDR) (i32.const 0))

    ;; Reset target hit flags
    (local.set $tcount (i32.load (global.get $TGT_COUNT_ADDR)))
    (local.set $j (i32.const 0))
    (block $clr_done
      (loop $clr
        (br_if $clr_done (i32.ge_u (local.get $j) (local.get $tcount)))
        (i32.store
          (i32.add
            (i32.add (global.get $TGT_BASE) (i32.const 800))
            (i32.mul (local.get $j) (i32.const 4)))
          (i32.const 0))
        (local.set $j (i32.add (local.get $j) (i32.const 1)))
        (br $clr)
      )
    )

    ;; Trace each source
    (local.set $count (i32.load (global.get $SRC_COUNT_ADDR)))
    (local.set $i (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_u (local.get $i) (local.get $count)))
        (local.set $addr
          (i32.add (global.get $SRC_BASE) (i32.mul (local.get $i) (i32.const 16))))
        (local.set $sx   (i32.load         (local.get $addr)))
        (local.set $sy   (i32.load (i32.add (local.get $addr) (i32.const 4))))
        (local.set $sdir (i32.load (i32.add (local.get $addr) (i32.const 8))))
        (call $trace_beam (local.get $sx) (local.get $sy) (local.get $sdir) (local.get $i))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)
      )
    )

    (i32.load (global.get $SEG_COUNT_ADDR))
  )

  ;; Check if puzzle is solved (all targets hit)
  ;; Returns 1 if solved, 0 otherwise
  (func (export "check_solved") (result i32)
    (local $i i32)
    (local $count i32)
    (local.set $count (i32.load (global.get $TGT_COUNT_ADDR)))
    (if (i32.eq (local.get $count) (i32.const 0))
      (then (return (i32.const 0))))
    (local.set $i (i32.const 0))
    (block $done
      (loop $check
        (br_if $done (i32.ge_u (local.get $i) (local.get $count)))
        ;; If any target not hit, return 0
        (if (i32.eq
              (i32.load
                (i32.add
                  (i32.add (global.get $TGT_BASE) (i32.const 800))
                  (i32.mul (local.get $i) (i32.const 4))))
              (i32.const 0))
          (then (return (i32.const 0))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $check)
      )
    )
    (i32.const 1)
  )

  ;; Get source count
  (func (export "get_source_count") (result i32)
    (i32.load (global.get $SRC_COUNT_ADDR))
  )

  ;; Get source x
  (func (export "get_source_x") (param $idx i32) (result i32)
    (i32.load
      (i32.add (global.get $SRC_BASE) (i32.mul (local.get $idx) (i32.const 16))))
  )
  ;; Get source y
  (func (export "get_source_y") (param $idx i32) (result i32)
    (i32.load
      (i32.add
        (i32.add (global.get $SRC_BASE) (i32.mul (local.get $idx) (i32.const 16)))
        (i32.const 4)))
  )
  ;; Get source direction
  (func (export "get_source_dir") (param $idx i32) (result i32)
    (i32.load
      (i32.add
        (i32.add (global.get $SRC_BASE) (i32.mul (local.get $idx) (i32.const 16)))
        (i32.const 8)))
  )

  ;; Rotate a mirror at (x,y): toggles between type 2 and 3
  (func (export "rotate_mirror") (param $x i32) (param $y i32)
    (local $addr i32)
    (local $type i32)
    (local.set $addr (call $cell_addr (local.get $x) (local.get $y)))
    (local.set $type (i32.load8_u (local.get $addr)))
    (if (i32.eq (local.get $type) (i32.const 2))
      (then (i32.store8 (local.get $addr) (i32.const 3)))
      (else (if (i32.eq (local.get $type) (i32.const 3))
        (then (i32.store8 (local.get $addr) (i32.const 2)))))
    )
  )

  ;; Place a mirror at (x,y) if cell is empty; returns 1 if placed, 0 if not
  (func (export "place_mirror") (param $x i32) (param $y i32) (param $type i32) (result i32)
    (local $addr i32)
    (local $existing i32)
    (local.set $addr (call $cell_addr (local.get $x) (local.get $y)))
    (local.set $existing (i32.load8_u (local.get $addr)))
    (if (i32.eq (local.get $existing) (i32.const 0))
      (then
        (i32.store8 (local.get $addr) (local.get $type))
        (return (i32.const 1)))
    )
    (i32.const 0)
  )

  ;; Remove mirror at (x,y) - only removes mirrors (type 2 or 3)
  ;; Returns 1 if removed, 0 if not a removable mirror
  (func (export "remove_mirror") (param $x i32) (param $y i32) (result i32)
    (local $addr i32)
    (local $type i32)
    (local.set $addr (call $cell_addr (local.get $x) (local.get $y)))
    (local.set $type (i32.load8_u (local.get $addr)))
    (if (i32.or
          (i32.eq (local.get $type) (i32.const 2))
          (i32.eq (local.get $type) (i32.const 3)))
      (then
        (i32.store8 (local.get $addr) (i32.const 0))
        (return (i32.const 1)))
    )
    (i32.const 0)
  )

  ;; Get grid width
  (func (export "get_width") (result i32)
    (i32.load (global.get $GRID_WIDTH_ADDR))
  )

  ;; Get grid height
  (func (export "get_height") (result i32)
    (i32.load (global.get $GRID_HEIGHT_ADDR))
  )
)
