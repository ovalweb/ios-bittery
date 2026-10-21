#!/bin/bash
# Build the Pixel 3 (blueline) boot images of docs/PIXEL3.md. Linux or macOS.
#
#   tools/mkboot-blueline.sh shim|kernel|ios [EXTRA BOOT-ARGS...]
#
#   shim     stage 1: the shim alone (display autorefresh, UFS probe)
#   kernel   stage 2: xnu without the iOS root (one CPU, no touch/keys/USB)
#   ios      stage 3: iOS from the root in userdata (flash ios16-root.img first)
#
# Output: shim/out/blueline-STAGE.img, for `fastboot boot`. Extra boot-args
# are appended, e.g. `tools/mkboot-blueline.sh ios sweetkeys=1 sweettouch=1`
# (a later key=value wins). Inputs, overridable through the environment:
#   DTB     the stock DTB (default dtb/boot_unpacked/dtb from the phone's boot.img)
#   KERNEL  xnu/out/kernel.development.sweet (CI artifact)
#   ADT     shim/out/blueline.adt, made here with tools/mkadt.py --board blueline --highmem
set -euo pipefail
cd "$(dirname "$0")/.."

stage=${1:-}
[ $# -gt 0 ] && shift
extra="$*"
DTB=${DTB:-dtb/boot_unpacked/dtb}
KERNEL=${KERNEL:-xnu/out/kernel.development.sweet}
ADT=${ADT:-shim/out/blueline.adt}

base='debug=0xc serial=3 keepsyms=1 -enable_kprintf_spam -noprogress rd=ufsroot0 wdt=-1'
case $stage in
shim) ;;
kernel) args="$base cpus=1 sweettouch=0 sweetkeys=0 sweetusb=0" ;;
ios) args="$base cpus=1 unentitled_ios_sim_launch=1 ignition_level=1 wdt_test=no_user_checkin ufsrw=1 rootrw=1 launchd_unsecure_cache=1 sweetfb_hz=30 sweettouch=0 sweetkeys=0 sweetusb=0" ;;
*) sed -n '2,17p' "$0"; exit 2 ;;
esac
[ -f "$DTB" ] || { echo "no stock DTB at $DTB: see docs/PIXEL3.md stage 0 (DTB=path to override)" >&2; exit 1; }
DTB=$(cd "$(dirname "$DTB")" && pwd)/$(basename "$DTB")
mkdir -p shim/out

if [ "$stage" = shim ]; then
	BOARD=blueline DTB="$DTB" shim/build.sh
else
	[ -f "$KERNEL" ] || { echo "no kernel at $KERNEL: download the CI artifact (README step 1)" >&2; exit 1; }
	[ -f research/ipsw-x/d22ap.adt ] || echo "warning: research/ipsw-x/d22ap.adt missing: no /product node (tools/ipsw-extract.py)" >&2
	python3 tools/mkadt.py "$ADT" --board blueline --highmem
	args="$args${extra:+ $extra}"
	[ ${#args} -lt 608 ] || { echo "boot-args too long (${#args} of 607)" >&2; exit 1; }
	python3 tools/mkpayload.py "$KERNEL" "$ADT" shim/out/payload-blueline.bin --cmdline "$args" >/dev/null
	BOARD=blueline DTB="$DTB" shim/build.sh "$(pwd)/shim/out/payload-blueline.bin"
	echo "boot-args: $args"
fi
cp shim/out/shim-boot.img "shim/out/blueline-$stage.img"
echo "-> shim/out/blueline-$stage.img (fastboot boot shim/out/blueline-$stage.img)"
