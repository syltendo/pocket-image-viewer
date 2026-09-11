#!/usr/bin/env python3
"""Convert a Quartus .rbf into the Pocket's bitstream.rbf_r.

The Pocket expects the raw binary bitstream with every byte bit-reversed
(verified against Analogue's core template: output/bitstream.rbf_r is
exactly ap_core.rbf with each byte's bits flipped).

Usage:
    python3 tools/rbf_to_rbf_r.py input.rbf output.rbf_r
"""
import sys

def bit_reverse_byte(b: int) -> int:
    r = 0
    for _ in range(8):
        r = (r << 1) | (b & 1)
        b >>= 1
    return r

TABLE = bytes(bit_reverse_byte(b) for b in range(256))

def main() -> None:
    if len(sys.argv) != 3:
        print(__doc__.strip().splitlines()[-3])
        sys.exit(2)
    src, dst = sys.argv[1], sys.argv[2]
    with open(src, "rb") as f:
        data = f.read()
    with open(dst, "wb") as f:
        f.write(data.translate(TABLE))
    print(f"wrote {dst} ({len(data)} bytes)")

if __name__ == "__main__":
    main()
