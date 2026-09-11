#!/usr/bin/env python3
"""Assemble the installable release zip for the Image Viewer core.

The zip mirrors the Pocket SD card layout, per Analogue's packaging doc:

    Cores/syltendo.imageviewer/{core.json, data.json, ..., bitstream.rbf_r}
    Platforms/imageviewer.json
    Assets/imageviewer/syltendo.imageviewer/common/   (empty; user adds image.bmp)

Usage:
    python3 tools/package.py --version 0.1.0-20260911

Output: dist/syltendo.imageviewer_0.1.0-20260911.zip
"""
import argparse
import os
import shutil
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CORE = "syltendo.imageviewer"

# (source relative to ROOT, destination inside zip)
PAYLOAD = [
    (f"Cores/{CORE}/core.json", f"Cores/{CORE}/core.json"),
    (f"Cores/{CORE}/data.json", f"Cores/{CORE}/data.json"),
    (f"Cores/{CORE}/video.json", f"Cores/{CORE}/video.json"),
    (f"Cores/{CORE}/input.json", f"Cores/{CORE}/input.json"),
    (f"Cores/{CORE}/audio.json", f"Cores/{CORE}/audio.json"),
    (f"Cores/{CORE}/interact.json", f"Cores/{CORE}/interact.json"),
    (f"Cores/{CORE}/bitstream.rbf_r", f"Cores/{CORE}/bitstream.rbf_r"),
    ("Platforms/imageviewer.json", "Platforms/imageviewer.json"),
]


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--version", required=True)
    args = ap.parse_args()

    bitstream = os.path.join(ROOT, f"Cores/{CORE}/bitstream.rbf_r")
    if not os.path.isfile(bitstream):
        print(f"error: {bitstream} not found; run the Quartus build first")
        sys.exit(1)

    dist = os.path.join(ROOT, "dist")
    os.makedirs(dist, exist_ok=True)
    zip_name = f"{CORE}_{args.version}.zip"
    zip_path = os.path.join(dist, zip_name)

    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as z:
        for src_rel, dst_rel in PAYLOAD:
            src = os.path.join(ROOT, src_rel)
            if not os.path.isfile(src):
                print(f"warning: missing {src_rel}, skipping")
                continue
            z.write(src, dst_rel)
        # keep the asset folder present on install
        z.writestr("Assets/imageviewer/syltendo.imageviewer/common/.gitkeep", "")

    print(f"wrote {zip_path}")

    # also stage an unpacked tree for inspection
    stage = os.path.join(dist, "stage")
    shutil.rmtree(stage, ignore_errors=True)
    with zipfile.ZipFile(zip_path) as z:
        z.extractall(stage)
    print(f"staged unpacked tree at {stage}")


if __name__ == "__main__":
    main()
