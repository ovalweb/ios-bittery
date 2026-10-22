#!/usr/bin/env python3
"""Set the block-maximum-size field of an LZ4 frame (and its header checksum).

  lz4-bd.py IN OUT [--bsid 7]

lz4 picks the smallest block size that fits a small input; the Pixel 3's
stock and TWRP kernels are frames with 4 MiB blocks (BD 0x70). The blocks
themselves stay valid: the field is only a maximum.
"""
import argparse, struct

P1, P2, P3, P4, P5 = 2654435761, 2246822519, 3266489917, 668265263, 374761393
M = 0xffffffff
rotl = lambda x, r: ((x << r) | (x >> (32 - r))) & M


def xxh32(data, seed=0):
    n, i = len(data), 0
    if n >= 16:
        v = [(seed + P1 + P2) & M, (seed + P2) & M, seed & M, (seed - P1) & M]
        while i + 16 <= n:
            for j in range(4):
                lane, = struct.unpack_from('<I', data, i + 4 * j)
                v[j] = (rotl((v[j] + lane * P2) & M, 13) * P1) & M
            i += 16
        h = (rotl(v[0], 1) + rotl(v[1], 7) + rotl(v[2], 12) + rotl(v[3], 18)) & M
    else:
        h = (seed + P5) & M
    h = (h + n) & M
    while i + 4 <= n:
        lane, = struct.unpack_from('<I', data, i)
        h = (rotl((h + lane * P3) & M, 17) * P4) & M
        i += 4
    while i < n:
        h = (rotl((h + data[i] * P5) & M, 11) * P1) & M
        i += 1
    h ^= h >> 15
    h = (h * P2) & M
    h ^= h >> 13
    h = (h * P3) & M
    return h ^ (h >> 16)


def header_checksum(descriptor):
    return (xxh32(descriptor) >> 8) & 0xff


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('src')
    ap.add_argument('dst')
    ap.add_argument('--bsid', type=int, default=7, choices=range(4, 8))
    a = ap.parse_args()
    data = bytearray(open(a.src, 'rb').read())
    if data[:4] != b'\x04\x22\x4d\x18':
        raise SystemExit(f'{a.src}: not an LZ4 frame')
    flg = data[4]
    if flg & 0x08 or flg & 0x01:
        raise SystemExit('content size or dictionary ID present: not handled')
    if data[6] != header_checksum(bytes(data[4:6])):
        raise SystemExit(f'{a.src}: header checksum does not match')
    data[5] = a.bsid << 4
    data[6] = header_checksum(bytes(data[4:6]))
    open(a.dst, 'wb').write(data)


if __name__ == '__main__':
    main()
