#!/usr/bin/env python3
"""Unsigned AVB hash footer for boot images (what Pixel bootloaders expect).

  avbfooter.py add IMG [--partition-size 67108864] [--partition boot] [--prop KEY:VALUE ...]
  avbfooter.py info IMG

The Pixel 3's ABL refuses `fastboot boot` of an image without an AVB footer
("Error verifying the received boot.img: Unsupported"), even unlocked. Its
stock boot images and TWRP carry the form written here: the image padded to
the partition size, vbmeta (libavb 1.0, algorithm NONE, one SHA-256 hash
descriptor over salt + image) right after the 4 KiB-aligned image, and the
64-byte "AVBf" footer at the very end, as avbtool add_hash_footer makes it.
`info` prints a footer and checks its digest.
"""
import argparse, hashlib, os, struct, sys

BLOCK = 4096


def round_up(n, m):
    return (n + m - 1) // m * m


def hash_descriptor(partition, salt, digest, image_size):
    body = struct.pack('>Q32sIIII60x', image_size, b'sha256', len(partition), len(salt), len(digest), 0)
    body += partition + salt + digest
    body += b'\0' * (round_up(len(body), 8) - len(body))
    return struct.pack('>QQ', 2, len(body)) + body          # tag 2 = hash


def prop_descriptor(key, value):
    body = struct.pack('>QQ', len(key), len(value)) + key + b'\0' + value + b'\0'
    body += b'\0' * (round_up(len(body), 8) - len(body))
    return struct.pack('>QQ', 0, len(body)) + body          # tag 0 = property


def vbmeta(descriptors):
    aux = descriptors + b'\0' * (round_up(len(descriptors), 64) - len(descriptors))
    hdr = struct.pack('>4sIIQQIQQQQQQQQQQQII48s80x',
                      b'AVB0', 1, 0,                      # required libavb 1.0
                      0, len(aux),                        # auth block, aux block
                      0,                                  # algorithm NONE: unsigned
                      0, 0, 0, 0,                         # hash, signature
                      len(descriptors), 0,                # public key (none)
                      len(descriptors), 0,                # public key metadata (none)
                      0, len(descriptors),                # descriptors
                      0, 0, 0,                            # rollback index, flags, location
                      b'ios-sweet avbfooter')
    assert len(hdr) == 256
    return hdr + aux


def parse(data):
    """(original_image_size, vbmeta_offset, vbmeta_size, descriptors) or None."""
    if len(data) < 64 or data[-64:-60] != b'AVBf':
        return None
    _, _, _, orig, off, size = struct.unpack('>4sIIQQQ', data[-64:-28])
    v = data[off:off + size]
    f = struct.unpack('>4sIIQQIQQQQQQQQQQQII', v[:128])
    auth, d_off, d_size = f[3], f[14], f[15]
    blob = v[256 + auth:256 + auth + f[4]][d_off:d_off + d_size]
    descs, p = [], 0
    while p + 16 <= len(blob):
        tag, n = struct.unpack('>QQ', blob[p:p + 16])
        descs.append((tag, blob[p + 16:p + 16 + n]))
        p += 16 + n
    return orig, off, size, f[5], descs


def cmd_info(path):
    data = open(path, 'rb').read()
    r = parse(data)
    if r is None:
        print(f'{path}: no AVB footer')
        return 1
    orig, off, size, alg, descs = r
    print(f'{path}: {len(data)} bytes, image {orig}, vbmeta at {off:#x} ({size} bytes), algorithm {alg}')
    ok = True
    for tag, body in descs:
        if tag == 0:
            kl, vl = struct.unpack('>QQ', body[:16])
            print(f'  property {body[16:16 + kl].decode()} = {body[17 + kl:17 + kl + vl].decode()}')
            continue
        if tag != 2:
            print(f'  descriptor tag {tag} ({len(body)} bytes)')
            continue
        image_size, = struct.unpack('>Q', body[:8])
        pl, sl, dl = struct.unpack('>III', body[40:52])
        name = body[116:116 + pl]
        salt = body[116 + pl:116 + pl + sl]
        digest = body[116 + pl + sl:116 + pl + sl + dl]
        good = hashlib.sha256(salt + data[:image_size]).digest() == digest
        ok &= good
        print(f'  hash descriptor: partition {name.decode()}, image {image_size}, digest {"OK" if good else "MISMATCH"}')
    return 0 if ok else 1


def cmd_add(path, partition_size, partition, props=()):
    data = bytearray(open(path, 'rb').read())
    if parse(bytes(data)) is not None:
        raise SystemExit(f'{path}: already has an AVB footer')
    data += b'\0' * (round_up(len(data), BLOCK) - len(data))
    salt = os.urandom(32)
    digest = hashlib.sha256(salt + bytes(data)).digest()
    descs = b''.join(prop_descriptor(k.encode(), v.encode()) for k, v in props)
    meta = vbmeta(descs + hash_descriptor(partition.encode(), salt, digest, len(data)))
    if len(data) + round_up(len(meta), BLOCK) + 64 > partition_size:
        raise SystemExit(f'{path}: {len(data)} bytes do not fit a {partition_size}-byte partition')
    footer = struct.pack('>4sIIQQQ28x', b'AVBf', 1, 0, len(data), len(data), len(meta))
    out = bytes(data) + meta
    out += b'\0' * (partition_size - 64 - len(out)) + footer
    open(path, 'wb').write(out)
    print(f'{path}: AVB hash footer, image {len(data)} bytes, padded to {partition_size}')


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    sub = ap.add_subparsers(dest='cmd', required=True)
    a = sub.add_parser('add')
    a.add_argument('image')
    a.add_argument('--partition-size', type=lambda s: int(s, 0), default=64 << 20)
    a.add_argument('--partition', default='boot')
    a.add_argument('--prop', action='append', default=[], help='KEY:VALUE property descriptor')
    i = sub.add_parser('info')
    i.add_argument('image')
    args = ap.parse_args()
    if args.cmd == 'info':
        sys.exit(cmd_info(args.image))
    cmd_add(args.image, args.partition_size, args.partition,
            [tuple(p.split(':', 1)) for p in args.prop])


if __name__ == '__main__':
    main()
