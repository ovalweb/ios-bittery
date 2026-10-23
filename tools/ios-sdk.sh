#!/bin/bash
# A link-only iOS 16 "SDK" without Xcode: text stubs (.tbd) for libSystem,
# libobjc, libc++ and some frameworks, generated from the iPhone X shared
# cache with ipsw (brew install ipsw). Headers come from the Command Line
# Tools' macOS SDK (tools/ios-cc). Enough for C tools, wland and small
# Objective-C helpers.
#
#   tools/ios-sdk.sh CACHE [OUT]     CACHE: .../dyld_shared_cache_arm64 (ipsw extract --dyld)
#                                    OUT:   build/iossdk (default)
set -euo pipefail
cache=${1:?usage: ios-sdk.sh CACHE [OUT]}
out=${2:-$(cd "$(dirname "$0")/../.." && pwd)/build/iossdk}
frameworks="Foundation CoreFoundation IOKit SystemConfiguration ImageIO CoreGraphics MobileCoreServices IOSurface Metal QuartzCore Security"
mkdir -p "$out/lib" "$out/Frameworks" "$out/tmp"

stub() {        # stub INSTALL_NAME DEST.tbd
	rm -f "$out"/tmp/*.tbd
	ipsw dyld tbd "$cache" "$1" -o "$out/tmp" >/dev/null 2>&1
	local f
	f=$(ls "$out"/tmp/*.tbd 2>/dev/null | head -1)
	[ -n "$f" ] || { echo "no stub for $1" >&2; return 1; }
	mv "$f" "$2"
	echo "$2"
}

stub /usr/lib/libSystem.B.dylib "$out/lib/libSystem.tbd"
stub /usr/lib/libobjc.A.dylib "$out/lib/libobjc.tbd"
stub /usr/lib/libc++.1.dylib "$out/lib/libc++.tbd"
for fw in $frameworks; do
	mkdir -p "$out/Frameworks/$fw.framework"
	stub "/System/Library/Frameworks/$fw.framework/$fw" "$out/Frameworks/$fw.framework/$fw.tbd" ||
		stub "/System/Library/PrivateFrameworks/$fw.framework/$fw" "$out/Frameworks/$fw.framework/$fw.tbd" || true
done
rmdir "$out/tmp" 2>/dev/null || true
