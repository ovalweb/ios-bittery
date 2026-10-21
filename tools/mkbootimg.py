#!/usr/bin/env python3
"""Android boot image v2 writer (the subset of AOSP mkbootimg the shim uses).

  mkbootimg.py --kernel K --ramdisk R --dtb D -o OUT [--base 0] [--kernel_offset 0x8000]
               [--ramdisk_offset 0x1000000] [--tags_offset 0x100] [--dtb_offset 0x1f00000]
               [--pagesize 4096] [--os_version 17.0.0] [--os_patch_level 2035-06]
               [--cmdline STR] [--header_version 2]

Same header and SHA-1 id as system/tools/mkbootimg for header version 2
(boot_img_hdr_v2: v0 fields, recovery DTBO size/offset, header size, DTB
size/address), so ABL sees the same image either tool writes. For hosts
without AOSP's mkbootimg, e.g. macOS.
"""
import argparse, hashlib, struct

HDR_V2_SIZE = 1660


def num(s):
    return int(s, 0)


def os_version(ver, patch):
    a, b, c = (list(map(int, ver.split('.'))) + [0, 0])[:3]
    y, m = map(int, patch.split('-')[:2])
    return (a << 25 | b << 18 | c << 11) | ((y - 2000) << 4 | m)


def pad(data, page):
    return data + b'\0' * (-len(data) % page)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--kernel', required=True)
    ap.add_argument('--ramdisk', required=True)
    ap.add_argument('--dtb', required=True)
    ap.add_argument('-o', '--output', required=True)
    ap.add_argument('--header_version', type=int, default=2)
    ap.add_argument('--base', type=num, default=0x10000000)
    ap.add_argument('--kernel_offset', type=num, default=0x00008000)
    ap.add_argument('--ramdisk_offset', type=num, default=0x01000000)
    ap.add_argument('--second_offset', type=num, default=0x00f00000)
    ap.add_argument('--tags_offset', type=num, default=0x00000100)
    ap.add_argument('--dtb_offset', type=num, default=0x01f00000)
    ap.add_argument('--pagesize', type=num, default=2048)
    ap.add_argument('--os_version', default='0.0.0')
    ap.add_argument('--os_patch_level', default='2000-01')
    ap.add_argument('--cmdline', default='')
    ap.add_argument('--board', default='')
    a = ap.parse_args()
    if a.header_version != 2:
        raise SystemExit('only header version 2 is implemented')

    kernel = open(a.kernel, 'rb').read()
    ramdisk = open(a.ramdisk, 'rb').read()
    dtb = open(a.dtb, 'rb').read()
    cmd = a.cmdline.encode()
    if len(cmd) > 512 + 1024 - 1:
        raise SystemExit('cmdline too long')

    sha = hashlib.sha1()
    for data in (kernel, ramdisk, None, None, dtb):    # kernel, ramdisk, second, recovery dtbo, dtb
        if data:
            sha.update(data)
        sha.update(struct.pack('<I', len(data) if data else 0))

    hdr = struct.pack('<8s10I16s512s32s1024s',
                      b'ANDROID!',
                      len(kernel), a.base + a.kernel_offset,
                      len(ramdisk), a.base + a.ramdisk_offset,
                      0, a.base + a.second_offset,
                      a.base + a.tags_offset, a.pagesize, a.header_version,
                      os_version(a.os_version, a.os_patch_level),
                      a.board.encode(), cmd[:512], sha.digest(), cmd[512:])
    hdr += struct.pack('<IQI', 0, 0, HDR_V2_SIZE)               # recovery dtbo, header size
    hdr += struct.pack('<IQ', len(dtb), a.base + a.dtb_offset)
    assert len(hdr) == HDR_V2_SIZE, len(hdr)

    with open(a.output, 'wb') as f:
        for part in (hdr, kernel, ramdisk, dtb):
            f.write(pad(part, a.pagesize))
    print(f'{a.output}: kernel {len(kernel)}, ramdisk {len(ramdisk)}, dtb {len(dtb)} bytes')


if __name__ == '__main__':
    main()
