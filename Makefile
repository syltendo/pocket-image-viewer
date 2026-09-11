# Local build (Windows PC with Quartus Prime installed).
# The GitHub Actions workflow (.github/workflows/build.yml) does all of this
# in the cloud; you only need this if you want to build locally.
#
# 1. Install Intel Quartus Prime Lite (free) with Cyclone V device support.
# 2. From a Quartus command shell ("Nios II Command Shell" on Windows):
#        make build
#        make package

QUARTUS_SH ?= quartus_sh
VERSION ?= 0.1.0-local

.PHONY: build package clean

build:
	cd src/fpga && "$(QUARTUS_SH)" --flow compile ap_core
	python tools/rbf_to_rbf_r.py src/fpga/output_files/ap_core.rbf Cores/syltendo.imageviewer/bitstream.rbf_r

package:
	python tools/package.py --version "$(VERSION)"

clean:
	rm -rf src/fpga/output_files src/fpga/db src/fpga/incremental_db
	rm -f Cores/syltendo.imageviewer/bitstream.rbf_r
	rm -rf dist/stage dist/*.zip
