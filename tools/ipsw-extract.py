#!/usr/bin/env python3
"""Take what the port needs out of a local iPhone X IPSW (macOS or Linux).

  ipsw-extract.py IPSW OUTDIR [--device d22ap] [--adt PATH] [--no-dmgs]

From the "Erase" build identity of DEVICE (d22ap = iPhone10,3) it writes
  OUTDIR/os.dmg, systemos.dmg, appos.dmg   OS root and the two cryptexes,
                                            the inputs of tools/mkiosroot.sh
  PATH (default OUTDIR/d22ap.adt)           the decoded DeviceTree, whose
                                            /product node tools/mkadt.py copies
                                            (default location there:
                                            research/ipsw-x/d22ap.adt)
  OUTDIR/version.txt                        ProductVersion and build
The IPSW is a zip64; nothing else is needed (the DeviceTree's LZFSE payload
is decoded with the lzfse tool or, on macOS, libcompression).
"""
import argparse, os, plistlib, shutil, sys, zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import adt  # noqa: E402

PARTS = (('OS', 'os.dmg'), ('Cryptex1,SystemOS', 'systemos.dmg'), ('Cryptex1,AppOS', 'appos.dmg'))


def identity(manifest, device):
    for bi in manifest['BuildIdentities']:
        info = bi['Info']
        if info.get('DeviceClass') == device and info.get('RestoreBehavior') == 'Erase':
            return bi
    known = sorted({bi['Info'].get('DeviceClass') for bi in manifest['BuildIdentities']})
    raise SystemExit(f'no Erase identity for {device}; this IPSW has {", ".join(known)}')


def extract(z, member, dst):
    size = z.getinfo(member).file_size
    if os.path.exists(dst) and os.path.getsize(dst) == size:
        print(f'{dst}: present ({size >> 20} MiB)')
        return
    tmp = dst + '.part'
    with z.open(member) as src, open(tmp, 'wb') as out:
        shutil.copyfileobj(src, out, 16 << 20)
    os.replace(tmp, dst)
    print(f'{dst}: {member} ({size >> 20} MiB)')


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('ipsw')
    ap.add_argument('outdir')
    ap.add_argument('--device', default='d22ap')
    ap.add_argument('--adt', help='where to write the decoded DeviceTree')
    ap.add_argument('--no-dmgs', action='store_true', help='only the DeviceTree and version')
    a = ap.parse_args()

    os.makedirs(a.outdir, exist_ok=True)
    with zipfile.ZipFile(a.ipsw) as z:
        manifest = plistlib.loads(z.read('BuildManifest.plist'))
        bi = identity(manifest, a.device)
        version, build = manifest['ProductVersion'], manifest['ProductBuildVersion']
        print(f'{os.path.basename(a.ipsw)}: iOS {version} ({build}), {a.device}')

        path = bi['Manifest']['DeviceTree']['Info']['Path']
        raw, info = adt.im4p_payload(z.read(path))
        if info['encrypted']:
            raise SystemExit(f'{path}: encrypted payload')
        root, _ = adt.parse(raw)
        if not any(dict((k, v) for k, _f, v in c.props).get('name') == b'product\0'
                   for c in root.children):
            raise SystemExit(f'{path}: no /product node')
        out_adt = a.adt or os.path.join(a.outdir, f'{a.device}.adt')
        os.makedirs(os.path.dirname(os.path.abspath(out_adt)), exist_ok=True)
        with open(out_adt, 'wb') as f:
            f.write(raw)
        print(f'{out_adt}: {path} ({len(raw)} bytes)')

        with open(os.path.join(a.outdir, 'version.txt'), 'w') as f:
            f.write(f'{version} {build}\n')
        if a.no_dmgs:
            return
        for key, name in PARTS:
            if key not in bi['Manifest']:
                raise SystemExit(f'{key} missing from the {a.device} identity')
            extract(z, bi['Manifest'][key]['Info']['Path'], os.path.join(a.outdir, name))
    d = a.outdir
    print(f'next: sudo tools/mkiosroot.sh {d}/os.dmg {d}/systemos.dmg {d}/appos.dmg ios16-root.img')


if __name__ == '__main__':
    main()
