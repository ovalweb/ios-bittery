#!/bin/sh
# Build wland for iOS 16 arm64 into phone/wifi/out (signed ad hoc).
#   phone/wifi/build.sh             SM8150 (ios-flame, Pixel 4)
#   SOC=sdm845 phone/wifi/build.sh  SDM845 (Pixel 3: MBA modem boot, soc.h)
# From ios-flame (MIT); the radio code comes from ios-topaz, see CREDITS.md.
set -e
cd "$(dirname "$0")"
mkdir -p out
def=""
[ "${SOC:-}" = sdm845 ] && def="-DSOC_SDM845"
../../tools/ios-cc -O2 -Wall -Wextra -Wno-unused-parameter $def -o out/wland wland.c smem.c pmem.c glink.c link.c qmi.c rmtfs.c pdmapper.c tftp.c scm.c wlfw.c radio.c ipnet.c bridge.c
codesign -f -s - out/wland 2>/dev/null
ls -la out/wland
