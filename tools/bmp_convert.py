#!/usr/bin/env python3
"""Convert PNG/JPG/etc. images to the 24-bit BMP format the Image Viewer core reads.

The core's BMP parser handles uncompressed 24-bit BMPs only, so this script
normalizes anything Pillow can open into that exact format.

Usage:
    python3 tools/bmp_convert.py input.png output.bmp
    python3 tools/bmp_convert.py photo.jpg "Assets/imageviewer/syltendo.imageviewer/common/image.bmp"

Requires: pip install pillow
"""
import sys

def main() -> None:
    if len(sys.argv) != 3:
        print("usage: bmp_convert.py <input_image> <output.bmp>")
        sys.exit(2)
    src, dst = sys.argv[1], sys.argv[2]
    try:
        from PIL import Image
    except ImportError:
        print("error: pillow is required (pip install pillow)")
        sys.exit(1)
    img = Image.open(src).convert("RGB")
    img.save(dst, "BMP")
    print(f"wrote {dst} ({img.width}x{img.height})")

if __name__ == "__main__":
    main()
