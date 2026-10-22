#!/bin/bash
# Back up a Pixel 3 before the iOS root replaces userdata. Linux or macOS.
#
#   tools/pixel3-backup.sh [-s SERIAL] [--essential] [--sdcard] [--with-userdata] [OUTDIR]
#
# The phone must give adb root: TWRP booted with `fastboot boot twrp.img`
# (nothing flashed), or Android rooted with Magisk (adb shell su). Only reads
# from the phone. Writes OUTDIR (default backup/<device>-<serial>-<date>):
#   <partition>.img   every partition except userdata (both A/B slots,
#                     persist and the modem file systems with the IMEI and
#                     calibration that exist nowhere else)
#   sdX-gpt-head.bin, sdX-gpt-tail.bin   first and last 64 KiB of each UFS LUN
#                     (the GPT; by-name also lists the whole LUNs sda..sdf,
#                     which are not copied: sda contains userdata)
#   live.dtb iomem.txt getprop.txt partitions.txt   for the port (docs/PIXEL3.md)
#   SHA256SUMS        checked against sha256sum on the phone
# --essential       skip system_*, system_ext_*, vendor_*, product_* (several GB;
#                   Google's factory image for blueline restores them)
# --sdcard          also `adb pull /sdcard` (photos, downloads; needs Android
#                   running and unlocked, not TWRP: there it is encrypted)
# --with-userdata   also the raw, encrypted userdata partition. It only
#                   decrypts on this phone with its keys still in place
#                   (`fastboot -w` or a factory reset destroys them): keep
#                   your files with --sdcard or Google backup instead.
set -euo pipefail

ADB=adb
sdcard=0 userdata=0 essential=0 out=
while [ $# -gt 0 ]; do
	case $1 in
	-s) ADB="adb -s ${2:?-s needs a serial}"; shift ;;
	--sdcard) sdcard=1 ;;
	--essential) essential=1 ;;
	--with-userdata) userdata=1 ;;
	-h|--help) sed -n '2,22p' "$0"; exit 0 ;;
	-*) echo "unknown option $1" >&2; exit 2 ;;
	*) out=$1 ;;
	esac
	shift
done
command -v adb >/dev/null || { echo "adb not found (macOS: brew install --cask android-platform-tools)" >&2; exit 1; }
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }

state=$($ADB get-state 2>/dev/null || true)
[ "$state" = device ] || [ "$state" = recovery ] || { echo "no phone in adb (state: ${state:-none})" >&2; exit 1; }

# Root shell: TWRP's adbd is root; Android needs su.
if [ "$($ADB shell id -u 2>/dev/null | tr -d '\r')" = 0 ]; then
	sh_root() { $ADB exec-out "$1"; }
elif [ "$($ADB shell "su -c 'id -u'" 2>/dev/null | tr -d '\r')" = 0 ]; then
	# Single quotes: the phone's outer shell must not expand $vars first.
	sh_root() { $ADB exec-out "su -c '$1'"; }
else
	echo "no root on the phone: boot TWRP (fastboot boot twrp.img) or use Magisk" >&2
	exit 1
fi

device=$(sh_root "getprop ro.product.device" | tr -d '\r')
serial=$($ADB get-serialno | tr -d '\r')
[ "$device" = blueline ] || echo "warning: ro.product.device is '$device', not blueline (Pixel 3)" >&2
out=${out:-backup/${device:-phone}-$serial-$(date +%Y%m%d-%H%M)}
mkdir -p "$out"

dir=$(sh_root 'for d in /dev/block/by-name /dev/block/bootdevice/by-name; do [ -d $d ] && echo $d && break; done' | tr -d '\r')
[ -n "$dir" ] || { echo "no by-name partition directory on the phone" >&2; exit 1; }
parts=$(sh_root "ls $dir" | tr -d '\r')

skip() {
	case $1 in
	userdata) [ $userdata = 0 ] ;;
	sd[a-z]) true ;;        # whole LUN: only its GPT is saved, below
	system_*|system_ext_*|vendor_*|product_*) [ $essential = 1 ] ;;
	*) false ;;
	esac
}

sh_root "cat /sys/firmware/fdt" > "$out/live.dtb"
sh_root "cat /proc/iomem" > "$out/iomem.txt"
sh_root "getprop" > "$out/getprop.txt"
: > "$out/partitions.txt"
total=0
for p in $parts; do
	size=$(sh_root "blockdev --getsize64 $dir/$p" | tr -d '\r')
	echo "$p $size $(sh_root "readlink -f $dir/$p" | tr -d '\r')" >> "$out/partitions.txt"
	skip "$p" && continue
	total=$((total + size))
done
echo "$device $serial: $(echo $parts | wc -w | tr -d ' ') partitions, $((total >> 20)) MiB to copy into $out"

: > "$out/SHA256SUMS"
for p in $parts; do
	if skip "$p"; then
		echo "skip $p"
		continue
	fi
	size=$(awk -v p="$p" '$1 == p { print $2 }' "$out/partitions.txt")
	printf '%-24s %8d MiB ... ' "$p" $((size >> 20))
	sh_root "dd if=$dir/$p bs=1048576 2>/dev/null" > "$out/$p.img"
	got=$(wc -c < "$out/$p.img" | tr -d ' ')
	[ "$got" = "$size" ] || { echo "short read ($got of $size bytes)"; exit 1; }
	want=$(sh_root "sha256sum $dir/$p" | tr -d '\r' | cut -d' ' -f1)
	have=$(sha256 "$out/$p.img")
	[ "$want" = "$have" ] || { echo "checksum mismatch"; exit 1; }
	echo "$have  $p.img" >> "$out/SHA256SUMS"
	echo ok
done

# Partition tables: primary GPT at the start, backup GPT at the end of each LUN.
for p in $parts; do
	case $p in sd[a-z]) ;; *) continue ;; esac
	size=$(awk -v p="$p" '$1 == p { print $2 }' "$out/partitions.txt")
	sh_root "dd if=$dir/$p bs=65536 count=1 2>/dev/null" > "$out/$p-gpt-head.bin"
	sh_root "dd if=$dir/$p bs=65536 skip=$((size / 65536 - 1)) count=1 2>/dev/null" > "$out/$p-gpt-tail.bin"
	for f in head tail; do echo "$(sha256 "$out/$p-gpt-$f.bin")  $p-gpt-$f.bin" >> "$out/SHA256SUMS"; done
	echo "$p: GPT saved ($((size >> 20)) MiB LUN)"
done

if [ $sdcard = 1 ]; then
	echo "pulling /sdcard (internal storage) ..."
	$ADB pull /sdcard/ "$out/sdcard"
fi
echo "done: $out (keep it off git and somewhere safe)"
