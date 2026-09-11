# Pocket Image Viewer

An openFPGA core for the Analogue Pocket that displays images on the Pocket's
1600×1440 screen. No emulation, no CPU — just a BMP file reader, a frame
buffer, and a video scanout path.

**Status: scaffold.** The project builds end-to-end today (the placeholder
bitstream shows the APF template's test pattern). The image-viewer RTL is
being written next — see `docs/architecture.md`.

## How it builds (no local install needed)

Every push to `main` triggers the GitHub Actions workflow
(`.github/workflows/build.yml`), which:

1. Compiles the FPGA design with Intel Quartus Prime running in Docker
   (`raetro/quartus:21.1.1` — free Lite edition, Cyclone V support).
2. Converts the `.rbf` to the Pocket's `bitstream.rbf_r` format
   (byte-wise bit reversal, verified against Analogue's template).
3. Packages a ready-to-install release zip and uploads it as a build artifact.

Download the artifact from the Actions tab, unzip it onto your SD card root,
and the core appears in the Pocket's core list.

## Installing images

The core has 8 image slots, each holding one 24-bit BMP:

```
Assets/imageviewer/syltendo.imageviewer/common/img1.bmp
Assets/imageviewer/syltendo.imageviewer/common/img2.bmp
...
Assets/imageviewer/syltendo.imageviewer/common/img8.bmp
```

Convert anything to the right format with the included script
(requires `pip install pillow`):

```
python3 tools/bmp_convert.py photo.png "Assets/imageviewer/syltendo.imageviewer/common/img1.bmp"
```

Use left/right on the d-pad to switch between the loaded images.
Because the data slots are marked user-reloadable, you can swap images
from the Pocket's core menu without rebooting.

## Building locally (optional)

If you'd rather build on your own machine instead of CI:

1. Install Intel Quartus Prime Lite (free) with Cyclone V device support.
2. From a Quartus command shell: `make build && make package`

## Project layout

```
.github/workflows/build.yml   CI: Quartus-in-Docker build + packaging
Cores/syltendo.imageviewer/   APF core definition (JSONs + bitstream.rbf_r)
Platforms/imageviewer.json    Custom platform entry for the Library
Assets/imageviewer/...        Where img1.bmp..img8.bmp go on the SD card
src/fpga/                     Quartus project (Analogue APF template + our RTL)
  apf/                        Analogue Pocket Framework (do not modify)
  core/                       Our logic: core_top.v et al.
tools/                        rbf converter, bmp converter, packager
docs/architecture.md          How the viewer core works
```

## License

Our RTL and tooling: MIT (see LICENSE). The `src/fpga/apf/` framework files
are Analogue's APF, provided under their EULA for Pocket development.
