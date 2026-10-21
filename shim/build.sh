#!/bin/bash
# Build the shim and wrap it in a boot.img v2 that mirrors the stock boot.img header.
#   BOARD=sweet (default) | blueline      phone constants, shim/board.h
#   DTB=path                              stock DTB (default dtb/boot_unpacked/dtb in the repo)
#   CROSS=prefix                          toolchain (default: aarch64-linux-gnu-, else
#                                         aarch64-elf- as from `brew install aarch64-elf-gcc`)
# Both phones use header v2, base 0, 4K pages and the default mkbootimg offsets
# (Pixel 3: device/google/crosshatch BoardConfig-common.mk). Without AOSP's
# mkbootimg the same image comes from tools/mkbootimg.py. Linux or macOS.
set -euo pipefail
[ -z "${DTB:-}" ] || DTB=$(cd "$(dirname "$DTB")" && pwd)/$(basename "$DTB")
cd "$(dirname "$0")"
BOARD=${BOARD:-sweet}
DTB=${DTB:-../dtb/boot_unpacked/dtb}
case $BOARD in
sweet) BOARD_DEF= ;;
blueline) BOARD_DEF=-DBOARD_BLUELINE ;;
*) echo "error: unknown BOARD=$BOARD (sweet, blueline)" >&2; exit 1 ;;
esac
if [ -z "${CROSS:-}" ]; then
	for c in aarch64-linux-gnu- aarch64-elf- aarch64-none-elf-; do
		if command -v ${c}gcc >/dev/null 2>&1; then CROSS=$c; break; fi
	done
fi
[ -n "${CROSS:-}" ] || { echo "error: no aarch64 GCC (aarch64-linux-gnu-gcc, or brew install aarch64-elf-gcc)" >&2; exit 1; }
CC=${CROSS}gcc
OBJCOPY=${CROSS}objcopy
CFLAGS="-O2 -ffreestanding -nostdlib -fno-pic -mgeneral-regs-only -mstrict-align -fno-stack-protector -Wall -Wextra $BOARD_DEF"
OBJS="shim console mmu fdt loader ufs display"
mkdir -p out
for f in start.S shim.c console.c mmu.c fdt.c loader.c ufs.c display.c; do
	$CC $CFLAGS -c $f -o out/${f%.*}.o
done
# The image runs wherever ABL puts it with no relocation pass: only the
# header's image_size (start.o, linked at 0) may be an absolute address.
abs=$(${CROSS}readelf -r $(for o in $OBJS; do echo out/$o.o; done) | grep -c ABS64 || true)
[ "$abs" = 0 ] || { echo "error: $abs absolute relocations in C objects" >&2; exit 1; }
$CC $CFLAGS -static -T shim.ld -Wl,--build-id=none -Wl,--no-warn-rwx-segments -Wl,-N \
	out/start.o $(for o in $OBJS; do echo out/$o.o; done) -o out/shim.elf
$OBJCOPY -O binary out/shim.elf out/Image
# ABL copies the file; pad to image_size so .bss/stacks exist as zeroed bytes.
size=$((16#$(${CROSS}nm out/shim.elf | awk '$3=="_end"{print $1}')))
python3 -c 'import os, sys; os.truncate(sys.argv[1], int(sys.argv[2]))' out/Image "$size"
# Ramdisk: an xnu payload (tools/mkpayload.py) if given as $1, else an empty
# newc cpio (ABL dislikes a zero-size ramdisk on some builds) -> diagnostics.
if [ -n "${1:-}" ]; then
	cp "$1" out/ramdisk.bin
else
	(cd out && rm -rf rd && mkdir rd && cd rd && find . | cpio -o -H newc --quiet | gzip -9 > ../ramdisk.bin)
fi
MKBOOTIMG=mkbootimg
command -v mkbootimg >/dev/null 2>&1 || MKBOOTIMG="python3 ../tools/mkbootimg.py"
$MKBOOTIMG --header_version 2 --kernel out/Image --ramdisk out/ramdisk.bin \
	--dtb "$DTB" --base 0 --kernel_offset 0x8000 --ramdisk_offset 0x1000000 \
	--tags_offset 0x100 --dtb_offset 0x1f00000 --pagesize 4096 \
	--os_version 17.0.0 --os_patch_level 2035-06 \
	--cmdline "console=null" -o out/shim-boot.img
# Host render of the console layout.
cc -O1 -Wall $BOARD_DEF -o out/host_test console.c host_test.c && ./out/host_test
echo "board: $BOARD, toolchain: ${CROSS}gcc"
ls -l out/Image out/shim-boot.img
