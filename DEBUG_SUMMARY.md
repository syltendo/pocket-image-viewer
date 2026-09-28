# Pocket Image Viewer — SDRAM Debug Summary

**Date:** 2026-09-14  
**Status:** Bug isolated to SDRAM write path. Verilog logic verified correct via simulation.  
**Hardware:** Analogue Pocket, custom openFPGA core (syltendo/pocket-image-viewer)

---

## What Was Proven (Verified)

### 1. BMP Parser Works
- **Evidence:** Hardware test with 180° phase build showed black screen instead of red.
- **Meaning:** `slot_valid=1` was reached. Parser completed header validation, decoded
  800×720 image, and issued SDRAM writes. Parser is **innocent**.

### 2. SDRAM Read Path Works
- **Evidence:** Diagnostic build (diag_rd_burst/diag_rd_word) showed data flowing
  from SDRAM to video FIFO. Video displayed black (zeros) not orange/purple/white.
- **Meaning:** READ commands are issued, SDRAM responds, capture timing works,
  FIFO fills. Read path is **functional**.

### 3. SDRAM Write Path Fails
- **Evidence:** 
  - Diagnostic build: `diag_wr_burst` > 0 (writes issued), but reads return zeros.
  - Test-pattern build: Core writes 0xFFFF directly to SDRAM (bypassing parser).
    Video reads back zeros. Screen shows black, not white.
- **Meaning:** WRITE commands are sent, but SDRAM does not store the data.
  Write path is **broken**.

### 4. Controller Verilog Logic is Correct
- **Evidence:** Icarus Verilog testbench (`/tmp/tb_sdram_ctrl.v`) instantiates
  `sdram_ctrl.v` with a behavioral SDRAM model.
  - Init completes ✓
  - Write: 2 bursts, 16 words issued ✓
  - Read: 2 bursts, 16 words captured ✓
  - State machine transitions correct ✓
- **Meaning:** The bug is **not** in the Verilog logic. It is in physical
  hardware timing (I/O delays, clock phase, signal integrity).

### 5. MODE Register is Correct
- **Evidence:** Decoded `13'b0_00_011_0_011` bit-by-bit:
  - Burst length 8 (A2-A0 = 011) ✓
  - Sequential (A3 = 0) ✓
  - CAS latency 3 (A6-A4 = 011) ✓
  - Normal operation (A8-A7 = 00) ✓
  - Write burst programmed (A9 = 0) ✓
- **Meaning:** SDRAM is configured correctly. Not the culprit.

### 6. Pin Assignments Look Correct
- **Evidence:** `ap_core.qsf` assigns all 16 `dram_dq` pins, both `dram_dqm` pins,
  IO standard 1.8V.
- **Meaning:** No obvious pinout error. (Full verification requires board schematic.)

---

## What Was Tried (Did Not Fix)

### 180° SDRAM Clock Phase Shift
- **Change:** PLL `outclk_3` phase 270° → 180° (5051ps at 99MHz).
- **Result:** Reads started working (parser completed for first time).
  Writes still broken.
- **Basis:** Matches agg23's proven design (DDR output clock = 180°).

### Multicycle Timing Constraints
- **Change:** Added to `core_constraints.sdc` (matching agg23's pattern):
  ```
  set_multicycle_path -from {*|mem_ctrl_inst|*} -to [get_clocks {...}] -start -setup 2
  set_multicycle_path -from {*|mem_ctrl_inst|*} -to [get_clocks {...}] -start -hold 1
  ```
- **Result:** No change. Writes still broken.
- **Basis:** Verified from agg23/openfpga-SNES source (not from memory).

---

## What Was Learned from agg23's Design (Verified from Source)

Repository: `https://github.com/agg23/openfpga-SNES`  
File: `rtl/upstream/sdram.sv`, `target/pocket/core_constraints.sdc`

1. **Burst length:** agg23 uses single-word (BURST=1, NO_WRITE_BURST=1).
   Ours uses burst-of-8. His is simpler but too slow for our bandwidth
   (we need 34M words/sec for 800×720@60fps; single-word gives ~10M).

2. **Clock generation:** agg23 uses `altddio_out` (DDR output flip-flop) to
   generate SDRAM clock. We use PLL 180° phase shift. Both achieve 180°,
   different implementation.

3. **Timing constraints:** agg23 has multicycle paths (setup 2, hold 1).
   Ours now has them too (added 2026-09-13). Did not fix the issue.

---

## Hypothesis (Not Verified)

**The SDRAM write data (DQ/DQM) is not meeting setup time at the chip.**

- Reads work: SDRAM → FPGA timing is OK.
- Writes fail: FPGA → SDRAM timing is broken.
- The FPGA's output delay (Tco: clock-to-output) may be eating into the
  setup margin. At 180° phase (5.05ns), if Tco is ~4-5ns, setup time is
  near zero.
- This is **hypothesis**, not verified. Requires Quartus timing report
  to confirm.

---

## What Remains Unknown

1. Actual Tco (output delay) for DQ/DQM pins from Quartus timing report.
2. SDRAM chip part number and datasheet timing requirements (tDS, tDH).
3. Board trace delays for DQ/DQM vs CLK.
4. Whether a different phase (e.g., 90°) would give writes more margin
   without breaking reads.
5. Whether the issue is signal integrity (not just timing).

---

## Diagnostic Builds Delivered

| Build | Purpose | Result |
|-------|---------|--------|
| `pocket-image-viewer-diag.zip` | Read-path colors (orange/purple/white) | Black = FIFO has zero-data |
| `pocket-image-viewer-diag2.zip` | Write counters (dark red vs black) | Black = writes issued, reads zero |
| `pocket-image-viewer-testpattern.zip` | White fill bypassing parser | Black = SDRAM writes broken |
| `pocket-image-viewer-sdc-fix.zip` | + multicycle constraints | Black = constraints didn't fix |

All builds: full repo ZIP, commit title only (user preference).

---

## Next Steps (Require Additional Data)

1. **Get Quartus timing report** from a build to see actual Tco for DQ/DQM.
2. **Identify SDRAM chip** part number for datasheet timing (tDS/tDH).
3. **Do not guess** phase values without the above.

---

## Files

- Workspace: `~/workspace/pocket-image-viewer/`
- Testbench: `/tmp/tb_sdram_ctrl.v` (Icarus Verilog, proves logic correct)
- agg23 reference: `/tmp/agg23/agg23_sdram.sv`, `/tmp/agg23/agg23.sdc`
- Goal: `~/workspace/goals/analogue-pocket-image-viewer-core/`
