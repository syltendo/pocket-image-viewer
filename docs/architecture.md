# Image Viewer — Core Architecture

## Decisions (locked)

- **Format:** 24-bit uncompressed Windows BMP only. `tools/bmp_convert.py`
  converts anything Pillow opens (PNG/JPG/…) into that format, downsizing to
  a maximum of 1600×1440 so files stay within the RAM budget.
- **Navigation:** d-pad left/right (also A/B) steps through loaded images.
- **Scaling:** scale-to-fit into 800×720, aspect preserved, letterboxed.
- **Slots:** 8 data slots (ids 0–7). Each holds one BMP.

## Big picture

```
SD card ──[0082]──▶ bridge writes ──▶ data_loader (agg23, MIT)
                                              │ byte stream
                                              ▼
                                     bmp_parser (state machine)
                                              │ 800×720 RGB888, scale-to-fit
                                              ▼
                         ┌─────────────────────────────────┐
                         │ cram0 cellular PSRAM, 16 MB     │
                         │ 8 × framebuffer (1.73 MB each)  │
                         └─────────────────────────────────┘
                                              │ burst reads
                                              ▼
                                     video_scanout ──▶ 800×720@60 ──▶ Pocket scaler
                                                                              (2× → 1600×1440)
```

There is no CPU and no OS interaction beyond the APF bridge. Everything is
a small state machine.

## Why decode at boot, not on demand

The Pocket streams every populated data slot at boot (`[0082]` handshake,
then bridge writes starting at address `0x00000000`). Empty slots are
silently skipped, so boot time scales with the number of images loaded.
Each slot decodes **during its stream** straight into its own 800×720
framebuffer in PSRAM. Navigation is then just a base-address switch —
instant, no host round-trip.

8 slots × 800×720×3 bytes = 13.8 MB < 16 MB PSRAM. Fits with room to spare.

## Memory map (cram0)

| Range | Contents |
|---|---|
| `0x000000 + n*0x1A4000`, n = 0..7 | Framebuffer n: 800×720×24-bit (1,728,000 bytes used of 1,736,704) |

`0x1A4000 = 1,736,704` (1,728,000 rounded up to a 16 KB boundary).
Top ~2.4 MB of PSRAM is unused for now.

## BMP parser (`bmp_parser.v`)

Consumes the byte stream from `data_loader` (little-endian word order is
already handled there; note the core sets `bridge_endian_little = 0` and
data_loader byte-swaps accordingly — validated against the Rally-X core).

1. **Header (54 bytes):** check `BM` magic, read pixel-data offset,
   width, height (signed), planes==1, bpp==24, compression==0.
   Anything else → mark slot invalid (checkerboard placeholder pattern).
2. **Geometry:** `scale = min(800/W, 720/H)` in 16.16 fixed point.
   `dst_w = W*scale`, `dst_h = H*scale`, centered: `x0 = (800-dst_w)/2`,
   `y0 = (720-dst_h)/2`. Clear the framebuffer region first (letterbox).
3. **Pixel rows:** BMP rows are bottom-up when height > 0 (top-down when
   negative — supported by flipping the row counter), each padded to a
   4-byte boundary: `stride = (W*3 + 3) & ~3`. Pixels arrive BGR; emit RGB.
4. **Streaming scale:** for source pixel `(sx, sy)`, the destination rect is
   `[sx*dst_w/W, (sx+1)*dst_w/W) × [sy*dst_h/H, (sy+1)*dst_h/H)` offset by
   `(x0, y0)`. Fill the whole rect — this single pass handles both upscale
   (rect > 1 px) and downscale (rect ≤ 1 px, last-writer-wins ≈ nearest
   neighbor) correctly.

## PSRAM controller (`cram_ctrl.v`)

The cellular PSRAM has a multiplexed address/data bus (`cram0_a[21:16]` +
`cram0_dq[15:0]`, `ADV#`-latched). Two access types:

- **Async single writes** (BMP decode path, low bandwidth): latch address,
  drive data, pulse `WE#`. ~6 clocks at 74.25 MHz.
- **Synchronous burst reads** (video path): latch start address, then one
  16-bit word per clock. Required — 800×720@60 needs ~104 MB/s, far beyond
  async random-access rates.

A tiny fixed-priority arbiter gives the video FIFO-fill precedence over
decode writes (decode just stalls a few cycles; video must never underrun).

Clocking: memory controller runs on `clk_74a` (74.25 MHz). 16-bit words at
74.25 MHz = 148 MB/s raw, comfortably above the ~110 MB/s worst case.

## Video pipeline (`video_scanout.v`)

- **Mode:** 800×720 @ 60 Hz. Totals 880×750 → pixel clock 39.6 MHz from the
  PLL (`mf_pllbase` reconfigured from the template's 12.288 MHz).
- A `dcfifo` bridges the 74.25 MHz memory domain to the 39.6 MHz pixel
  domain. The memory side burst-fills whenever the FIFO has room; the
  scanout side pops one RGB888 pixel per clock during the active region.
- Outputs `video_rgb`, `video_de`, `video_vs`, `video_hs` per the APF
  template convention (`video_skip = 0`). The Pocket scaler integer-scales
  2× to the 1600×1440 panel.
- `video.json` declares the 800×720 mode (aspect 10:9) so the OSD shows it.

## Input

`cont1_key` bits: d-pad left/right (bits 2/3) and face A/B (bits 4/5) =
next/previous image; Start (bit 15) = re-decode current slot. Debounced,
edge-triggered. Slot validity is tracked in a small register file populated
during the `[0082]` phase.

## Boot sequence handling (`slot_mgr.v`)

1. `[0082]` per populated slot → record `(id, size)`, route the incoming
   stream through `bmp_parser` into that slot's framebuffer.
2. `[008F]` all complete → mark valid slots, select slot 0 (first valid),
   send `[0140] Ready to Run` (via the existing `core_bridge_cmd`
   `status_setup_done` path — the template already wires this).
3. `[008A]` (user reloads a slot from the menu at runtime): issue target
   command `0x0180` (`target_dataslot_read`) for that slot with
   `bridgeaddr = 0`; the stream flows through the same decode path into the
   slot's framebuffer; re-display if it's the visible slot.

## Files

| File | Purpose |
|---|---|
| `src/fpga/core/core_top.v` | Top: instantiates APF glue + all modules below |
| `src/fpga/core/slot_mgr.v` | Boot/navigation state machine, bridge command sequencing |
| `src/fpga/core/data_loader.v` | agg23's bridge-write → byte-stream FIFO (MIT, vendored) |
| `src/fpga/core/bmp_parser.v` | BMP header + streaming scale-to-fit decoder |
| `src/fpga/core/cram_ctrl.v` | Cellular PSRAM async-write / burst-read controller + arbiter |
| `src/fpga/core/video_scanout.v` | 800×720@60 timing generator + FIFO-driven pixel pump |

## Validation plan

1. **CI build** of the scaffold (template test pattern) — proves the
   Quartus-in-Docker toolchain end-to-end.
2. **Simulation** of `bmp_parser` + `cram_ctrl` with Verilator against a
   reference BMP (cheap, no hardware).
3. **Hardware:** load 8 BMPs, check each decodes, d-pad navigates, reload
   via menu works.

## Deliberately not in v1

- **True folder browsing** via `[0190]`/`[0192]` (get filename / open by
  name). Possible v2: read slot 0's path, probe sequential names. Needs the
  param-struct BRAM the template leaves unmapped.
- **PNG/JPEG decode in RTL.** Would need a soft-CPU + software decoder —
  an order of magnitude more complex. The converter script covers it.
- **1600×1440 native output.** 800×720 + 2× integer scale is visually
  near-identical on photos and halves every bandwidth number.
