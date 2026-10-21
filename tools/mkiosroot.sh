#!/bin/bash
# Build the SWEET iOS root: one case-sensitive HFS+ image holding an iOS OS
# root filesystem plus its cryptexes, for the userdata partition (rd=ufsroot0).
#
#   mkiosroot.sh [--tweaks] OS.dmg SYSTEMOS.dmg APPOS.dmg OUT.img [SIZE]  (SIZE default 16G)
#
# Linux: apfs-fuse, hfsprogs and rsync, run as a user with sudo.
# macOS: nothing to install (hdiutil, newfs_hfs, fsck_hfs, rsync); run with sudo.
# tools/ipsw-extract.py takes the three images out of an IPSW. --tweaks also
# runs tools/sweet-root-tweaks.py on the new root before it is unmounted.
#
# The IPSW images are raw APFS with LZBITMAP-compressed files: they are read
# through apfs-fuse or the macOS APFS driver (both decompress), so the HFS+
# copy is uncompressed. On a device /private/preboot is its own volume
# holding the cryptexes, which /System/Cryptexes/{OS,App} link to; here they
# live inside the one volume. Owners, modes, symlinks and hard links are
# preserved (rsync -aH as root; no xattrs or file flags).
#
# The volume is journaled (XNU replays the journal after a panic; Linux only
# mounts it read-write with -o force and leaves the journal empty). SWEET
# additions: /System/Library/Caches/com.apple.dyld hard-links the SystemOS
# cryptex shared cache (ignition_level=1 looks there), and
# /private/var/keybags/systembag.kb is the plain-plist system keybag that
# keybagd reads with /defaults/no-effaceable-storage (tools/mkadt.py).
#
# The result is a raw image: Linux turns it into a sparse one with img2simg;
# fastboot also accepts it as is (fastboot -S 512M flash userdata OUT.img
# splits it and sends runs of zeros as fill chunks).
set -euo pipefail

tweaks=0
if [[ ${1:-} == --tweaks ]]; then
	tweaks=1
	shift
fi
[[ $# -ge 4 ]] || { sed -n '2,10p' "$0"; exit 2; }
abspath() { (cd "$(dirname "$1")" && echo "$(pwd -P)/$(basename "$1")"); }
os=$(abspath "$1") sysos=$(abspath "$2") appos=$(abspath "$3") out=$4 size=${5:-16G}
[[ ! -e $out ]] || { echo "refusing to overwrite $out" >&2; exit 1; }
here=$(cd "$(dirname "$0")" && pwd -P)

host=$(uname -s)
case $host in
Linux) need="apfs-fuse mkfs.hfsplus fsck.hfsplus rsync" ;;
Darwin) need="hdiutil newfs_hfs fsck_hfs rsync mkfile" ;;
*) echo "unsupported host $host" >&2; exit 1 ;;
esac
missing_tools=()
for tool in $need; do
	command -v "$tool" >/dev/null 2>&1 || missing_tools+=("$tool")
done
if [[ ${#missing_tools[@]} -gt 0 ]]; then
	echo "Error: missing required host utilities: ${missing_tools[*]}" >&2
	echo "  Install instructions:" >&2
	echo "    Arch Linux:    sudo pacman -S apfs-fuse hfsprogs rsync" >&2
	echo "    Ubuntu/Debian: sudo apt install apfs-fuse hfsprogs rsync" >&2
	echo "    Fedora:        sudo dnf install apfs-fuse hfsplus-tools rsync" >&2
	exit 1
fi

work=$(cd "$(mktemp -d)" && pwd -P)
mounts=()

is_mounted() {
	if [[ $host == Darwin ]]; then
		mount | grep -qF " on $1 ("
	else
		mountpoint -q "$1"
	fi
}

unmount() {
	if [[ $host == Darwin ]]; then
		sudo hdiutil detach "$1" -quiet 2>/dev/null || sudo hdiutil detach "$1" -force -quiet 2>/dev/null || true
	else
		sudo umount "$1" 2>/dev/null || true
	fi
}

cleanup() {
	local busy=0 m
	for m in ${mounts[@]+"${mounts[@]}"}; do
		is_mounted "$m" && unmount "$m"
		is_mounted "$m" && busy=1
	done
	# Never recurse into a directory that is still mounted (the root is writable).
	if [[ $busy == 0 ]]; then
		rm -f "$work"/*.dmg
		rmdir "$work"/* "$work" 2>/dev/null || true
	else
		echo "still mounted under $work: left in place" >&2
	fi
}
trap cleanup EXIT

# Mount an APFS image read-only at $work/NAME; the volume root is
# $work/NAME (macOS) or $work/NAME/root (apfs-fuse), see vol_root.
apfs_mount() {
	mkdir "$work/$2"
	if [[ $host == Darwin ]]; then
		# The OS image is UDIF ("koly" trailer), the cryptexes are raw APFS.
		# Without -owners on every file reads as owned by the mounting user.
		local key=()
		[[ $(tail -c 512 "$1" | head -c 4) == koly ]] || key=(-imagekey diskimage-class=CRawDiskImage)
		sudo hdiutil attach -owners on -nobrowse -readonly -noverify -noautoopen \
			${key[@]+"${key[@]}"} -mountpoint "$work/$2" "$1" >/dev/null
	else
		# apfs-fuse splits its options on ',' (e.g. in iPhone10,3 paths): use
		# links. Keep the .dmg name: apfs-fuse only parses UDIF images (the OS
		# one is UDIF, the cryptexes are raw APFS) when it ends in .dmg.
		ln -s "$1" "$work/$2.dmg"
		# As root: a user's FUSE mount is unreadable to the root rsync below.
		sudo "$(command -v apfs-fuse)" "$work/$2.dmg" "$work/$2"
	fi
	mounts+=("$work/$2")
}
vol_root() {
	if [[ $host == Darwin ]]; then echo "$work/$1"; else echo "$work/$1/root"; fi
}
apfs_mount "$os" os
apfs_mount "$sysos" sysos
apfs_mount "$appos" appos

root="$work/root"
mkdir "$root"
if [[ $host == Darwin ]]; then
	# A bare HFS+ volume (no partition map) in a raw, sparse file. Owners are
	# honoured only when asked for (-owners on); never let Spotlight or
	# fseventsd write into it.
	mkfile -n "$(echo "$size" | tr 'A-Z' 'a-z')" "$out"
	dev=$(sudo hdiutil attach -nomount -noverify -imagekey diskimage-class=CRawDiskImage "$out" | awk 'NR == 1 { print $1 }')
	sudo newfs_hfs -s -J -v iOSRoot "$dev" >/dev/null
	sudo hdiutil detach "$dev" -quiet
	sudo hdiutil attach -owners on -nobrowse -noverify -noautoopen \
		-imagekey diskimage-class=CRawDiskImage -mountpoint "$root" "$out" >/dev/null
	mounts=("$root" ${mounts[@]+"${mounts[@]}"})
	sudo mdutil -i off "$root" >/dev/null 2>&1 || true
	sudo touch "$root/.metadata_never_index"
	sudo mkdir -p "$root/.fseventsd"
	sudo touch "$root/.fseventsd/no_log"
else
	truncate -s "$size" "$out"
	mkfs.hfsplus -s -J -v iOSRoot "$out"
	sudo mount -t hfsplus -o loop,force "$out" "$root"
	mounts=("$root" ${mounts[@]+"${mounts[@]}"})
fi

copy() {
	echo "copying $1 -> ${2#"$root"}"
	sudo mkdir -p "$2"
	sudo rsync -aH --numeric-ids "$1/" "$2/"
}
copy "$(vol_root os)" "$root"
copy "$(vol_root sysos)" "$root/private/preboot/Cryptexes/OS"
copy "$(vol_root appos)" "$root/private/preboot/Cryptexes/App"

# A volume mounted without owners (macOS default for disk images) would turn
# every file into the copying user's: stop before producing such an image.
owner() { if [[ $host == Darwin ]]; then sudo stat -f %u "$1"; else sudo stat -c %u "$1"; fi; }
if [[ $(owner "$root/private/var/mobile") != 501 || $(owner "$root/usr/libexec") != 0 ]]; then
	echo "Error: owners not preserved (var/mobile $(owner "$root/private/var/mobile"), usr/libexec $(owner "$root/usr/libexec"))" >&2
	exit 1
fi

# Shared cache where dyld looks at ignition level 1: hard links, no extra space.
dsc=private/preboot/Cryptexes/OS/System/Library/Caches/com.apple.dyld
sudo mkdir -p "$root/System/Library/Caches/com.apple.dyld"
for f in "$root/$dsc"/*; do
	sudo ln "$f" "$root/System/Library/Caches/com.apple.dyld/${f##*/}"
done

# dyld does not search the cryptexes at ignition level 1: hard-link every
# cryptex file that has no counterpart in the OS root (libobjc-trampolines,
# libffi-trampolines, libstdc++, ...) to its root path.
for c in OS App; do
	(cd "$root/private/preboot/Cryptexes/$c" && sudo find . ! -type d ! -path './System/Library/Caches/com.apple.dyld/*') |
	while IFS= read -r f; do
		f=${f#./}
		if ! sudo test -e "$root/$f" && ! sudo test -L "$root/$f"; then
			sudo mkdir -p "$root/$(dirname "$f")"
			src="$root/private/preboot/Cryptexes/$c/$f"
			# Linux hfsplus cannot hard-link symlinks: copy those (-RP: the link itself).
			if sudo test -L "$src"; then sudo cp -RP "$src" "$root/$f"; else sudo ln "$src" "$root/$f"; fi
			echo "linked $c:/$f"
		fi
	done
done

# logd's log stores, normally made at restore: it checks owner _logd (272)
# and mode, plus a .migrated marker, else asks a helper and crashes
# ("BUG IN LIBTRACE: Failed to migrate directory").
db="$root/private/var/db"
sudo install -d -o 272 -g 272 -m 0751 "$db/diagnostics"
sudo install -d -o 272 -g 272 -m 0755 "$db/uuidtext" "$db/diagnostics/timesync"
for d in diagnostics uuidtext diagnostics/timesync; do
	sudo install -o 272 -g 272 -m 0644 /dev/null "$db/$d/.migrated"
done

# System keybag for the built-in AppleKeyStore (no passcode).
sudo install -d -m 0700 -o 0 -g 0 "$root/private/var/keybags"
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
	'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	'<plist version="1.0"><dict><key>KeyBagKeys</key><data>U1dFRVQ=</data></dict></plist>' > "$work/systembag.kb"
sudo install -m 0600 -o 0 -g 0 "$work/systembag.kb" "$root/private/var/keybags/systembag.kb"
rm -f "$work/systembag.kb"

if [[ $tweaks == 1 ]]; then
	sudo python3 "$here/sweet-root-tweaks.py" "$root"
fi

df -h "$root"
if [[ $host == Darwin ]]; then
	sudo rm -rf "$root/.fseventsd" "$root/.Spotlight-V100" "$root/.Trashes" "$root/.metadata_never_index"
	sudo hdiutil detach "$root" -quiet
	dev=$(sudo hdiutil attach -nomount -noverify -imagekey diskimage-class=CRawDiskImage "$out" | awk 'NR == 1 { print $1 }')
	sudo fsck_hfs -f -y "$dev" || true
	sudo fsck_hfs -f -n "$dev"
	sudo hdiutil detach "$dev" -quiet
	# Hand the image back to the user who ran sudo.
	[[ -z ${SUDO_UID:-} ]] || chown "$SUDO_UID:${SUDO_GID:-0}" "$out"
else
	sudo umount "$root"
	# Linux hfsplus decomposes some non-ASCII names (localized Shortcuts examples)
	# differently from Apple's tables; let fsck_hfs rewrite them, then verify.
	fsck.hfsplus -f -y "$out" | grep -v 'Illegal name' || true
	fsck.hfsplus -f -n "$out"
fi
echo "$out: done"
