#!/usr/bin/env python3
"""Build the minimal Apple Device Tree that the SWEET xnu needs to boot.

Only what the early boot path actually reads (see NOTES.md); every MMIO
address comes from the phone's live FDT. Usage:
  mkadt.py OUT.adt [--board sweet|blueline] [--dump] [--qemu] [--highmem]

--board sweet (default) is the Redmi Note 10 Pro. --board blueline is the
Pixel 3 (SDM845, docs/PIXEL3.md): the same kernel reads the board's wiring
from the /sweet-keys, /sweet-touch, /sweet-rpmh and /sweet-usb nodes that
only that board emits (the kernel's built-in values are sweet's).
"""
import hashlib, os, struct, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import adt  # noqa: E402

# Kernel-managed RAM: above every Qualcomm XPU carve-out (see NOTES.md)
PHYS_BASE = 0xb0000000
MEM_SIZE = 0x4d000000
# --highmem (phone only): the whole upper DDR bank. The live FDT memory node is
# <0x80000000 2G>, <0x1_00000000 0xfcc00000>; every fixed reserved-memory
# carve-out is in the low bank and the dynamic pools are limited below 4G.
HIGH_PHYS_BASE = 0x100000000
HIGH_MEM_SIZE = 0xfcc00000
# /arm-io children are relative to this; it must not be 0 (serial_init bails)
SOC_BASE = 0x01000000

GICD, GICD_SIZE = 0x17a00000, 0x10000
GICR, GICR_SIZE = 0x17a60000, 0x100000
FB, FB_SIZE = 0x9c000000, 0x1700000
SWEET_ECID = 0x5357454554000001  # 'SWEET' + 1, synthetic
FB_W, FB_H, FB_STRIDE = 1080, 2400, 1080 * 4
# Internal UFS host (ufshc@1d84000 "ufs_mem"); QEMU virt has none
UFS, UFS_SIZE = 0x01d84000, 0x3000
TIMEBASE = 19200000
VTIMER_INTID = 19
# QEMU virt (-M virt,gic-version=3 -cpu cortex-a76): GICD/GICR and the generic timer's CNTFRQ
QEMU_GICD, QEMU_GICR, QEMU_TIMEBASE = 0x08000000, 0x080a0000, 62500000
QEMU_VTIMER_INTID = 27

BOOT_MANIFEST_HASH = hashlib.sha384(b'sweet boot manifest').digest()

# Google Pixel 3 (blueline), Snapdragon 845, 4 GiB. Sources: Google's
# android-msm-crosshatch-4.9 DTS (sdm845.dtsi, sdm845-b1c1-*.dtsi,
# sdm845-b1-touch.dtsi) and mainline sdm845-google-blueline.dts.
SDM845_TLMM = 0x03400000
SDM845_TLMM_NORTH, SDM845_TLMM_EAST = SDM845_TLMM + 0x500000, SDM845_TLMM + 0x100000
BLUELINE = dict(
    name='google,blueline', soc='qcom,sdm845',
    # Low bank: every firmware carve-out ends below the splash at 0x9f800000,
    # Google's ramoops/debug regions end at 0xa1c11000, rmtfs sits at 0xf2700000.
    phys_base=0xa2000000, mem_size=0x50000000,
    # --highmem: the upper DDR bank below the firmware's top-of-DDR area. The
    # live FDT (TWRP, 2026-10-22) has /memory = <0x80000000 0xfe0a0000>, so
    # DDR handed to the OS ends at 0x17e0a0000; 0x7e000000 stays 2 MiB aligned.
    high_phys_base=0x100000000, high_mem_size=0x7e000000,
    # cont_splash_region@9d400000 (0x2400000), 1080x2160 a8r8g8b8; the LG SW43408
    # is a DSC command-mode panel: the shim turns on MDP autorefresh.
    fb=0x9d400000, fb_size=0x2400000, fb_w=1080, fb_h=2160,
    ecid=0x424c55454c494e01,  # 'BLUELIN' + 1, synthetic
    # cpu@0..3 Kryo 385 Silver (A55), cpu@400..700 Kryo 385 Gold (A75).
    # 'qcom,kryo470' stays: the SweetCPU personality matches it
    # (iokit/KernelConfigTables.cpp, patch 0018).
    cpu_compat=['qcom,kryo385', 'qcom,kryo470'],
    cpu_hz=lambda core: 2500000000 if core >= 4 else 1612800000,
    nodes=lambda: [
        # PM8998 (SID 0): PON (power, RESIN = volume down) and GPIO6 = volume up
        node('sweet-keys', [
            ('pon-ppid', u32(0x008)), ('volup-ppid', u32(0x0c5)), ('volup-base', u32(0xc500)),
        ]),
        # apps RSC DRV2 (mailbox@179e0000, TCS at +0xd00)
        node('sweet-rpmh', [('reg', u32(0x179e0000, 0x179e0d00))]),
        # gcc-sdm845.c: usb30_prim master/sleep/mock_utmi, cfg_noc/aggre axi,
        # usb_phy_cfg_ahb2phy, usb3_prim_clkref
        node('sweet-usb', [
            ('gcc-cbcr', u32(0xf00c, 0xf010, 0xf014, 0x502c, 0x8201c, 0x6a004, 0x8c008)),
        ]),
        # ST FTM5 (st,fts) at 0x49 on QUP wrapper0 SE2 (i2c@888000).
        # Pins: <tile pin function pull drive>, pull 0 none / 3 up, drive (mA/2 - 1).
        node('sweet-touch', [
            ('compatible', cstr('st,fts')),
            ('reg', u32(0x49)),
            ('se-reg', u32(0x00888000)),
            # APCS_CLOCK_BRANCH_ENA_VOTE_1: wrap0 m_ahb (6), s_ahb (7), s2 (12)
            ('gcc-vote', u32((1 << 6) | (1 << 7) | (1 << 12))),
            ('gcc-rcg', u32(0x17294)),                          # qupv3_wrap0_s2_clk_src
            ('gcc-branches', u32(0x17004, 0x17008, 0x17290)),
            # SE2's FIFO interface is fused off: I2C through GPI DMA (gpi_dma0),
            # the GPIIs open to the AP (qcom,gpii-mask) and the SE's id there
            ('gpi-reg', u32(0x00800000)), ('gpi-gpii-mask', u32(0xfa)), ('gpi-seid', u32(2)),
            # apps SMMU, gpi_dma0's stream and UFS's (ABL leaves UFS mapped)
            ('gpi-smmu', u32(0x15000000, 0x16, 0x100)),
            # a DMA page below 4 GiB for the GPI engine: free DDR (Android's iomem
            # "System RAM" from 0xa1c11000), outside the --highmem kernel RAM
            ('gpi-dma', u32(0xf1f00000, 0x4000)),
            ('sda', u32(SDM845_TLMM_EAST, 27, 1, 0, 0)),        # qup2, 2 mA, no pull
            ('scl', u32(SDM845_TLMM_EAST, 28, 1, 0, 0)),
            ('irq', u32(SDM845_TLMM_EAST, 125, 0, 0, 0)),       # ts_int_active
            ('reset', u32(SDM845_TLMM_NORTH, 99, 0, 3, 3)),     # ts_reset_active: 8 mA, pull-up
            ('bus-switch', u32(SDM845_TLMM_NORTH, 136, 0, 0, 0)),  # st,switch_gpio: 1 = AP
            ('avdd-supply', cstr('ldoa19')),                    # pm8998_l19, 3.3 V
            ('avdd-mv', u32(3300)),
            ('max-x', u32(1079)), ('max-y', u32(2159)),         # st,max-coords
            # the scaled iPhone X screen on the 5.5" 443 ppi panel (997x2160 px)
            ('surface-mm', u32(57, 124)),
        ]),
    ],
)

# The iOS userland is the iPhone X (iPhone10,3 / D22AP) IPSW. MobileGestalt
# derives product type, device class, home-button-less UI, artwork etc. from
# the root identity and /product of the real D22AP device tree. That tree is
# an Apple artifact (kept out of git): extract it from the IPSW with
#   tools/remotezip.py URL DeviceTree.d22ap.im4p DIR
#   ipsw img4 im4p extract DIR/Firmware/all_flash/DeviceTree.d22ap.im4p -o d22ap.adt
D22AP_ADT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '../research/ipsw-x/d22ap.adt')


def d22ap_product(path=D22AP_ADT):
    """/product properties of the real D22AP tree, without the syscfg
    placeholders iBoot would fill in (flag bit set) and the node bookkeeping."""
    if not os.path.exists(path):
        print(f'warning: {path} missing, no /product node', file=sys.stderr)
        return None
    root, _ = adt.parse(open(path, 'rb').read())
    for c in root.children:
        if dict((k, v) for k, f, v in c.props).get('name') == b'product\0':
            return [(k, v) for k, f, v in c.props if not f and k not in ('name', 'AAPL,phandle')]
    raise SystemExit(f'{path}: no /product node')

u32 = lambda *v: struct.pack('<%dI' % len(v), *v)
u64 = lambda *v: struct.pack('<%dQ' % len(v), *v)
cstr = lambda s: s.encode() + b'\0'


def node(name, props=(), children=()):
    n = adt.Node()
    n.props = [('name', 0, cstr(name))] + [(k, 0, v) for k, v in props]
    n.children = list(children)
    return n


def build(seed=None, qemu=False, highmem=False, board=None):
    """qemu=True: same tree, but with QEMU virt's GIC addresses and CNTFRQ (tools/qemu-sweet.py).
    board: None for sweet, else a board dict such as BLUELINE."""
    if board is None:
        phys_base, mem_size = (HIGH_PHYS_BASE, HIGH_MEM_SIZE) if highmem else (PHYS_BASE, MEM_SIZE)
        fb, fb_size, fb_w, fb_h, ecid = FB, FB_SIZE, FB_W, FB_H, SWEET_ECID
        cpu_compat = ['qcom,kryo470']
        cpu_hz = lambda core: 2304000000 if core >= 6 else 1804800000
        names = ['xiaomi,sweet', 'qcom,sm7150']
    else:
        phys_base, mem_size = ((board['high_phys_base'], board['high_mem_size']) if highmem
                               else (board['phys_base'], board['mem_size']))
        fb, fb_size, fb_w, fb_h = board['fb'], board['fb_size'], board['fb_w'], board['fb_h']
        ecid, cpu_compat, cpu_hz = board['ecid'], board['cpu_compat'], board['cpu_hz']
        # 'xiaomi,sweet' stays: SweetPlatformExpert and the CPU driver match it.
        names = [board['name'], 'xiaomi,sweet', board['soc']]
    gicd, gicr, timebase = (QEMU_GICD, QEMU_GICR, QEMU_TIMEBASE) if qemu else (GICD, GICR, TIMEBASE)
    seed = seed if seed is not None else os.urandom(64)
    phandle = iter(range(1, 1000))
    ph = lambda: ('AAPL,phandle', u32(next(phandle)))

    chosen = node('chosen', [
        ph(),
        ('dram-base', u64(phys_base)),
        ('dram-size', u64(mem_size)),
        ('random-seed', seed),
        ('debug-enabled', u32(1)),
        ('firmware-version', cstr('sweet-shim')),
        ('system-firmware-version', cstr('sweet-shim')),
        # iBoot's SHA-384 of the boot manifest; /sbin/mount -P 1 exits unless
        # it exists (bind mounts /private/preboot/<hex>/usr/standalone/firmware,
        # tolerating a missing directory). Fixed stand-in value.
        ('boot-manifest-hash', BOOT_MANIFEST_HASH),
        # libimg4 (cryptexd) aborts "failed to get crypto algorithm" without
        # it; real A11+ device trees say sha2-384.
        ('crypto-hash-method', cstr('sha2-384')),
        # MobileGestalt's screen class: display-scale (u32, default 0) comes
        # from /chosen, the pixel size from IOMobileFramebuffer. Scale 0 makes
        # SpringBoard's FBSDisplayMode "infxinf@0x" invalid. 1080x2400 @3x =
        # 360x800 points (like iPhone X class devices).
        ('display-scale', u32(3)),
        # XNU derives IOPlatformUUID (gethostuuid) from these on arm; without
        # them CFPreferences cannot use kCFPreferencesCurrentHost (no ByHost
        # files), so e.g. DataMigration never records LastSystemVersion and
        # migrates on every boot. Synthetic ECID (not the phone's); chip-id
        # of the A11 that the iPhone X userland expects.
        ('unique-chip-id', struct.pack('<Q', ecid)),
        ('chip-id', u32(0x8015)),
        # Security status as on a dev-fused, undemoted board (tuple 0,0,1,1):
        # MobileGestalt reads these from /chosen, and mobileactivationd's
        # DeviceType then takes its native "Hactivation" branch (state
        # Activated without an activation record; no SEP, no baseband here).
        ('certificate-production-status', u32(0)),
        ('effective-production-status-ap', u32(0)),
        ('certificate-security-mode', u32(1)),
        ('effective-security-mode-sep', u32(1)),
    ], [node('memory-map', [ph()]),
        # Local boot policy (kern_csr.c): SIP relaxed like `csrutil disable`
        # (lp-sip0: untrusted kexts, unrestricted FS, task_for_pid, kernel
        # debugger, dtrace, nvram), lp-sip1: unauthenticated (unsealed) root.
        # The iOS shared cache is in no trust cache, so dyld can only map it
        # with CSR_ALLOW_UNRESTRICTED_FS (vm_unix.c shared region checks).
        node('asmb', [ph(), ('lp-sip0', u64(0x6f)), ('lp-sip1', u32(1))])])

    # SWEET SMP: all eight cores in physical-core order (0-5 Cortex-A55,
    # 6-7 Cortex-A76), one homogeneous cluster. The kernel defaults to one
    # and uses cpus=N to select an initial prefix (N <= 8).
    # QEMU retains its original single-CPU tree: its MPIDRs differ from sweet.
    cpu_nodes = []
    for core in range(1 if qemu else 8):
        cpu_nodes.append(node(f'cpu{core}', [
            ph(),
            ('device_type', cstr('cpu')),
            ('compatible', b''.join(cstr(c) for c in cpu_compat) + cstr('ARM,v8')),
            ('reg', u32(core << 8)),  # actual MPIDR Aff1:Aff0, NOT logical ID
            ('cpu-id', u32(core)),   # descriptive: XNU assigns IDs by DT order
            ('cluster-id', u32(0)),  # descriptive; see ml_parse_cpu_topology
            ('cluster-type', u32(0)),  # homogeneous CLUSTER_TYPE_SMP, not AMP
            ('die-cluster-id', u32(0)),
            ('cluster-core-id', u32(core)),
            ('l2-cache-id', u32(core)),  # distinct per-core L2 nodes in live FDT
            ('l3-cache-id', u32(0)),     # shared L3
            ('state', cstr('running' if core == 0 else 'stopped')),
            ('timebase-frequency', u32(timebase)),
            ('clock-frequency', u32(cpu_hz(core))),
            ('bus-frequency', u32(100000000)),
            ('memory-frequency', u32(1866000000)),
            ('peripheral-frequency', u32(timebase)),
            ('fixed-frequency', u32(timebase)),
        ]))
    cpus = node('cpus', [ph(), ('#address-cells', u32(1)),
                         ('#size-cells', u32(0))], cpu_nodes)

    gic = node('gic', [
        ph(),
        ('compatible', cstr('arm,gic-v3')),
        ('interrupt-controller', b''),
        ('virtual-timer-intid', u32(QEMU_VTIMER_INTID if qemu else VTIMER_INTID)),
        ('reg', u64(gicd - SOC_BASE, GICD_SIZE, gicr - SOC_BASE, GICR_SIZE)),
    ])
    arm_io = node('arm-io', [
        ph(),
        ('device_type', cstr('sweet-io')),
        ('compatible', cstr('sweet-io') + cstr('arm-io')),
        ('#address-cells', u32(2)),
        ('#size-cells', u32(2)),
        ('ranges', u64(0, SOC_BASE, 0x100000000 - SOC_BASE)),
    ], [gic,
        # No hardware: watchdogd checks IODeviceTree:/arm-io/wdt for no-pmu and
        # otherwise crashes trying to set the PMU boot stage (customer builds
        # ignore the -wdt_no_pmu boot-arg).
        node('wdt', [ph(), ('no-pmu', u32(1))]),
        # Main display: IOMobileFramebuffer.framework counts /arm-io children
        # with this device_type and reads the canvas size from the node
        # (the presented iPhone X size, see SweetFramebuffer.cpp);
        # the kernel's AppleCLCD matches the compatible string.
        node('disp0', [
            ph(),
            ('device_type', cstr('display-subsystem')),
            ('compatible', cstr('sweet,display')),
            ('canvas-width', u32(1125)),
            ('canvas-height', u32(2436)),
        ])])

    fbcon = node('sweet-fbcon', [
        ph(),
        ('reg', u64(fb, fb_size)),
        ('width', u32(fb_w)),
        ('height', u32(fb_h)),
        ('stride', u32(fb_w * 4)),
    ])

    # bsd/dev/sweet_ufs.c: the UFS host ABL leaves running (absolute physical reg).
    ufs = node('sweet-ufs', [
        ph(),
        ('compatible', cstr('qcom,ufshc')),
        ('reg', u64(UFS, UFS_SIZE)),
    ])

    # pmap_compute_max_asids requires the node even when no overrides are set.
    # An absent pmap-max-asids property selects XNU's own MAX_ASIDS default.
    # No effaceable storage: keybagd then reads /private/var/keybags/systembag.kb
    # as a plain plist instead of decrypting it with the effaceable key.
    defaults = node('defaults', [ph(), ('no-effaceable-storage', u32(1))])

    # MobileGestalt HomeButtonType = IODeviceTree:/buttons home-button-type
    # (D22AP: 2, no Home button; absent = 0 = Home-button device).
    buttons = node('buttons', [
        ph(),
        ('button-names', cstr('volup') + cstr('voldown') + cstr('hold')),
        ('home-button-type', u32(2)),
        ('opposed-power-vol-buttons', u32(1)),
    ])

    product_props = d22ap_product()
    product = [node('product', [ph()] + product_props)] if product_props else []

    # Board wiring the kernel would otherwise take from its sweet defaults.
    extra = [] if board is None or qemu else board['nodes']()
    for n in extra:
        k, v = ph()
        n.props.insert(1, (k, 0, v))

    # Identity of the iPhone X whose userland runs here: compatible[0] is
    # hw.model/hw.target (D22AP), model is hw.machine/hw.product
    # (iPhone10,3). 'xiaomi,sweet' stays for SweetPlatformExpert matching.
    return node('device-tree', [
        ph(),
        ('compatible', cstr('D22AP') + cstr('iPhone10,3') + b''.join(cstr(n) for n in names) + cstr('AppleARM')),
        ('model', cstr('iPhone10,3')),
        ('target-type', cstr('D22')),
        ('target-sub-type', cstr('D22AP')),
        ('manufacturer', cstr('Apple Inc.')),
        ('#address-cells', u32(2)),
        ('#size-cells', u32(2)),
    ], [chosen, defaults, cpus, arm_io, fbcon, buttons] + product + ([] if qemu else [ufs]) + extra)


BOARDS = {'sweet': None, 'blueline': BLUELINE}

if __name__ == '__main__':
    board = 'sweet'
    if '--board' in sys.argv:
        board = sys.argv[sys.argv.index('--board') + 1]
    if board not in BOARDS:
        raise SystemExit(f'unknown board {board!r}; known: {", ".join(BOARDS)}')
    root = build(qemu='--qemu' in sys.argv, highmem='--highmem' in sys.argv, board=BOARDS[board])
    blob = adt.serialize(root)
    open(sys.argv[1], 'wb').write(blob)
    if '--dump' in sys.argv:
        adt.dump(adt.parse(blob)[0])
    print(f'{sys.argv[1]}: {len(blob)} bytes', file=sys.stderr)
