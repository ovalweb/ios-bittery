#!/bin/sh
# Build pmem and gpu for iOS 16 arm64 into phone/gpu/out (signed ad hoc).
#   phone/gpu/build.sh              A640 (ios-flame, Pixel 4)
#   SOC=sdm845 phone/gpu/build.sh   A630 (Pixel 3)
# From ios-flame (MIT). gpu is the userland layer over the kernel's A6xx core
# (bsd/dev/sweet_a6xx.c, shared with the kernel): CORE is the patched xnu tree.
set -e
cd "$(dirname "$0")"
CC=../../tools/ios-cc
CORE=${CORE:-../../../build/xnu-merge/bsd/dev}
def=""
[ "${SOC:-}" = sdm845 ] && def="-DSOC_SDM845"
mkdir -p out
$CC -O2 -Wall -Wextra -Wno-unused-parameter -o out/pmem pmem_tool.c pmem.c
$CC -O2 -Wall -Wextra -Wno-unused-parameter $def -I$CORE -o out/gpu gpu_tool.c gpu.c pmem.c $CORE/sweet_a6xx.c
for b in out/pmem out/gpu; do
	codesign -f -s - "$b" 2>/dev/null
	if nm -m "$b" | /usr/bin/grep -q "weak external"; then
		echo "$b: weak imports (iOS 16 may lack them):"; nm -m "$b" | /usr/bin/grep "weak external"
	fi
done
ls -la out
