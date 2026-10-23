# Pixel 3 (blueline) port

Status (2026-10-21): **source port, not yet booted on hardware.** Everything
below builds from the same tree as sweet, and the same kernel binary serves
both phones: the board is picked by the Apple Device Tree that
`tools/mkadt.py --board blueline` generates. Sweet's ADT and kernel behaviour
are unchanged.

What was checked without a phone:

- The patch series 0001-0085 applies with `git apply` to a fresh
  xnu-8796.141.3 tree, exactly as the CI does (staging scripts first).
- The changed C drivers pass a `-Weverything` syntax check against stub
  kernel headers; the kernel itself still has to be built by the CI.
- `mkadt.py` produces byte-identical sweet ADTs (low, `--highmem`, `--qemu`)
  and a blueline ADT with the values below.
- The shim compiles for both boards; the host console render is 1080x2160.
- macOS (2026-10-21): the shim and boot.img build with `aarch64-elf-gcc` 16
  and `tools/mkbootimg.py` (round trip through `tools/unpack_bootv2.py`);
  `tools/ipsw-extract.py` takes the images and the D22AP DeviceTree out of
  the 16.6.1 IPSW; native APFS mounts, `newfs_hfs`, owners-on mounts,
  `rsync -aH` hard links and `fsck_hfs` were tried on a small HFS+ image (the
  full root build needs sudo and has not been run yet);
  `tools/pixel3-backup.sh` ran against a simulated phone.

What only the phone can tell: everything in [Open questions](#open-questions).

## Hardware map

Sources: Google's `android-msm-crosshatch-4.9` kernel (`arch/arm64/boot/dts/qcom/sdm845.dtsi`,
`google/sdm845-b1c1-*.dtsi`, `google/sdm845-b1-touch.dtsi`, `drivers/input/touchscreen/stm/`,
`drivers/gpu/drm/msm/sde/`), mainline `sdm845-google-blueline.dts`, `gcc-sdm845.c`,
`pinctrl-sdm845.c`, and `device/google/crosshatch/BoardConfig-common.mk`.

| | Pixel 3 (SDM845) | sweet (SM7150) |
| --- | --- | --- |
| CPU | 4x A55 (cpu@0-300) + 4x A75 (cpu@400-700), ARMv8.2, no PAC | 6x A55 + 2x A76 |
| RAM | 4 GiB; live `/memory` = `0x80000000` + `0xfe0a0000` (DDR for the OS ends at `0x17e0a0000`) | 6/8 GiB |
| Kernel RAM | `--highmem`: `0x100000000` + `0x7e000000` (2016 MiB). Low: `0xa2000000` + 1.25 GiB. Both checked against the live FDT | `0x100000000` + 3.95 GiB |
| Carve-outs | hyp `0x85700000` ... spss ends `0x99c00000`, splash `0x9d400000`-`0x9f800000`, ramoops/debug `0xa1800000`-`0xa1c11000`, rmtfs `0xf2700000` | all in the low bank |
| GIC | GICD `0x17a00000`, GICR `0x17a60000`, vtimer INTID 19 | same |
| PSCI / PSHOLD | SMC, `0xc264000` | same |
| IMEM restart reason | `0x146bf65c` | `0x146aa65c` |
| UFS | `ufshc@1d84000`, `userdata` on LUN 0 | same |
| Framebuffer | `cont_splash_region@9d400000`, 1080x2160, stride 4320, a8r8g8b8 | `0x9c000000`, 1080x2400 |
| Panel | LG SW43408, DSC **command mode** (needs MDP autorefresh) | video mode |
| MDP ping-pong | `0xae00000` + `0x71000`/`0x71800`/`0x72000`/`0x72800` | - |
| Touch | ST FingerTip FTM5 (`st,fts`), I2C `0x49`, QUP wrapper0 SE2 `0x888000` | Goodix GT9896 / Focaltech, SE7 |
| Touch pins | SDA/SCL gpio27/28 (EAST, qup2), IRQ gpio125 (EAST), reset gpio99 (NORTH), AP/SLPI bus switch gpio136 (NORTH, 1 = AP) | gpio6-9, 90 |
| Touch power | AVDD `pm8998_l19` 3.3 V (RPMh `ldoa19`), DVDD `l14a` 1.8 V (on for the panel) | `ldoc11` |
| Touch clocks | vote `0x5200c` bits 6, 7, 12; RCG `0x17294`; halt `0x17004`, `0x17008`, `0x17290` | wrapper1 SE7 |
| Touch I2C engine | SE2 FIFO interface fused off (`GENI_IF_DISABLE_RO` bit 0): GPI DMA `gpi_dma0` `0x800000`, GPII mask `0xfa`, SE id 2, TX channel 0 / RX 1 | SE FIFO |
| RPMh | apps RSC DRV2 `0x179e0000`, TCS `+0xd00`, cmd-db pointer `0xc3f000c` | `0x18220000`, same pointer |
| Buttons | PM8998 PON (PPID `0x008`): power, RESIN = volume down; volume up = PM8998 GPIO6 (PPID `0x0c5`, `0xc500`) | PM6150L GPIO2 |
| SPMI | `0xc440000` (core), `0xe600000` (obsrvr), `0xc40a000` (cnfg) | same |
| USB | DWC3 `0xa600000`, QUSB2 `0x88e2000`, GDSC `0xf004`; CBCRs master `0xf00c`, sleep `0xf010`, utmi `0xf014`, clkref `0x8c008` | `0xf010`/`0xf014`/`0xf018`/`0x8c010` |
| Boot image | header v2, base 0, 4 KiB pages, DTB in boot.img; ABL also wants an LZ4-framed kernel (4 MiB blocks), `text_offset` `0x80000` and an AVB hash footer (unsigned) padded to 64 MiB, or `fastboot boot` fails with "Unsupported" / "Invalid Parameter" | raw Image, no footer |

## What the port changes

| Piece | Change |
| --- | --- |
| `xnu/patches/0082` | Early console and stage-0 marker take the framebuffer from `boot_args->Video` instead of `0x9c000000`/1080x2400 |
| `xnu/patches/0083` | `bsd/dev/sweet_board.c`: optional ADT values. Keys (`/sweet-keys`), RPMh RSC base (`/sweet-rpmh`, LDO allowlist `ldoc11`, `ldoa19`), USB clock status registers (`/sweet-usb`) |
| `xnu/patches/0084` | Touch: GENI SE, GCC votes, per-pin TLMM tiles, AVDD from `/sweet-touch`; ST FTM5 protocol (FIFO command `0x86`, 8-byte events, sense on `A0 00 FF`); TX up to 8 bytes |
| `xnu/patches/0086` | Touch I2C over GPI DMA when the SE has no FIFO (ADT `gpi-reg`, `gpi-gpii-mask`, `gpi-seid`): polled GPII (event ring + TX/RX channels in one DMA page), CONFIG0/GO/DMA TREs as in the downstream GSI I2C driver, stop/reset/start after an error |
| `xnu/patches/0087` | GPI stream mapping: dumps the apps SMMU stream table; when `gpi_dma0`'s stream (`0x16`) has no SMR, gives it a free one with UFS's S2CR (ADT `gpi-smmu`); the write is opt-in (`sweettouchsmmu=1`) since the hypervisor resets the phone on it |
| `xnu/patches/0088` | Touch I2C bit-banged on gpio27/28 (GPIO function, open drain, ~100 kHz, clock stretching) when the SE has no FIFO; GPI DMA only with `sweettouchgpi=1` |
| `xnu/patches/0089`-`0092` | 0089: default volume quota/reserved sizes for HFS+. 0090: SMMU stream mapping the Linux way (bypass refused -> last context bank as bypass, no reset). 0091: IOKit busy report; GPI DMA page below 4 GiB (`gpi-dma`), which the GPI engine needs. 0092: no IOKit daemon on iOS, so the registry root is not held busy (configd's InterfaceNamer waited for IOKit quiet; Settings > About froze in `SCNetworkInterfaceCopyAll`) |
| `xnu/patches/0085` | `SweetDisplay.h`: one geometry for framebuffer and touch. New **fit** mode scales the 1125x2436 iPhone X screen to 997x2160 (nearest neighbour) instead of cutting 138 rows top and bottom (status bar, home indicator). Auto when cropping loses >4% of the height; `sweetfb_fit=0/1` forces it |
| `tools/mkadt.py --board blueline` | Memory, framebuffer, CPUs (`qcom,kryo385` + `qcom,kryo470` so `SweetCPU` still matches), ECID, and the four board nodes |
| `shim/board.h`, `BOARD=blueline shim/build.sh` | Framebuffer, IMEM; `display.c` turns on MDP autorefresh before drawing; `loader.c` checks the kernel RAM against the live FDT `/memory` and `/reserved-memory` and refuses to jump on blueline if it is not free DDR |

Without the new ADT nodes the kernel uses sweet's values, so an old sweet ADT
boots the new kernel exactly as before.

## Bring-up, in stages

You need: a Pixel 3 (`blueline`, not the 3 XL `crosshatch`) with an unlocked
bootloader, a Mac or a Linux PC, an iPhone X (`iPhone10,3`) IPSW, and a fork
of this repo for the CI kernel build (the kernel only builds on GitHub's
macOS runners). **Flashing the iOS root erases `userdata` (all Android
data).** Android itself (boot, system, vendor) is never written: see
[Back to Android](#back-to-android).

Host tools:

| | macOS | Linux |
| --- | --- | --- |
| adb, fastboot | `brew install --cask android-platform-tools` | distribution package |
| shim compiler | `brew install aarch64-elf-gcc` | `aarch64-linux-gnu-gcc` |
| boot.img | `tools/mkbootimg.py` (used when `mkbootimg` is missing) | `mkbootimg` or the same |
| iOS root image | built in (hdiutil, newfs_hfs, fsck_hfs, rsync) | `apfs-fuse`, `hfsprogs`, `rsync` |
| DeviceTree LZFSE | built in (libcompression) | `lzfse` |
| GitHub CI | `brew install gh` | `gh` |

The iOS base used here is **16.6.1 (20G81)**, the same iOS 16 line as the
16.7.16 sweet was brought up with; the kernel's stand-ins for Apple's
closed drivers (AppleKeyStore, IOSurface, IOMobileFramebuffer, HID) were
written against 16.7 and are expected to match. Everything version-specific
in the tools is read from the IPSW.

`tools/mkboot-blueline.sh shim|kernel|ios [boot-args...]` builds the boot
image of stages 1-3 below with their command lines (extra boot-args are
appended and win): `shim/out/blueline-<stage>.img`.

### 0. Backups and hardware dump

Boot TWRP for blueline temporarily (`fastboot boot twrp-*-blueline.img`;
nothing is flashed) or root Android with Magisk, then:

```sh
tools/pixel3-backup.sh                 # every partition except userdata, ~10 GB
tools/pixel3-backup.sh --essential     # without system/vendor/product (Google's image has them)
```

It only reads from the phone and checks every image against `sha256sum` on
the phone. `persist` and the modem file systems (`modemst1`, `modemst2`,
`fsg`, `fsc`) hold the IMEI and per-phone calibration that cannot be
downloaded anywhere: keep that backup somewhere safe. Your own files are
in `userdata`, which is encrypted with keys that a wipe destroys: copy them
off with Android running (`tools/pixel3-backup.sh --sdcard` pulls
`/sdcard`; app data needs Google backup or the apps' own export).

The backup also holds the live device tree and memory map. Unpack the stock
boot image for its DTB (`dtc` from `brew install dtc` to read the tree):

```sh
mkdir -p dtb && cp backup/blueline-*/{live.dtb,iomem.txt} dtb/
dtc -I dtb -O dts -o dtb/live.dts dtb/live.dtb
python3 tools/unpack_bootv2.py backup/blueline-*/boot_a.img dtb/boot_unpacked   # -> dtb/boot_unpacked/dtb
```

Compare with the hardware map: `memory` reg (expect `0x100000000` + 2 GiB),
`reserved-memory`, `cont_splash_region`, `restart_reason`, the touch node
(`st_fts@49`). If anything differs, fix `tools/mkadt.py` (BLUELINE) and
`shim/board.h` first.

### 1. Shim alone: display and UFS

```sh
BOARD=blueline shim/build.sh
fastboot boot shim/out/shim-boot.img
```

Expected: a red screen with `BOARD blueline`, one `PPn auto=... now=8000000x`
line per active ping-pong, `LOADER no SWEETXNU payload`, then the read-only
UFS probe. It resets after about 3 minutes.

- Screen keeps the bootloader picture: autorefresh did not take (see open
  question 1). The shim itself is running; continue to stage 2 and read the
  kernel log from TWRP instead of the screen.
- Instant reboot: a register access faulted. Comment out `display_prepare()`
  in `shim/shim.c` to tell display from UFS.

### 2. Kernel without the iOS root

Build the kernel on your fork (`gh workflow run xnu.yml`, see README) and
pack it with a first-boot command line (one core, no touch or keys):

```sh
python3 tools/mkadt.py shim/out/blueline.adt --board blueline --highmem
python3 tools/mkpayload.py xnu/out/kernel.development.sweet shim/out/blueline.adt shim/out/payload.bin \
    --cmdline 'debug=0xc serial=3 cpus=1 keepsyms=1 -enable_kprintf_spam -noprogress rd=ufsroot0 wdt=-1 sweettouch=0 sweetkeys=0 sweetusb=0'
BOARD=blueline shim/build.sh ../shim/out/payload.bin
fastboot boot shim/out/shim-boot.img
```

`wdt=-1` also turns off the DEVELOPMENT kernel's interrupt-latency panic,
as on the full boot line below.

Expected: `MEMCHECK kernel RAM is free DDR`, then xnu's coloured stage
bands and `SWEET EARLY` lines at the bottom of the screen, then kernel
messages. With Android's `userdata` still in place the root mount fails,
which is fine here: memory, interrupts, timer and UFS work.

- `MEMCHECK kernel RAM outside every DDR bank` / `overlaps reserved-memory`:
  pick the range from `dtb/iomem.txt` and change `high_phys_base`/
  `high_mem_size` in `tools/mkadt.py`.
- `ramdisk overlaps kernel memory`: ABL put the payload into the kernel's
  RAM; use the low range (drop `--highmem`) or a smaller one.

### 3. iOS root

From the IPSW (here `iPhone10,3,iPhone10,6_16.6.1_20G81_Restore.ipsw`) take
the OS image, both cryptexes and the D22AP DeviceTree, then build the HFS+
root and apply the bring-up changes in one go. Needs about 8 GB for the
images and 11 GB for the root (sparse 16 GB file); run as root because the
copy keeps iOS's owners:

```sh
python3 tools/ipsw-extract.py iPhone10,3,iPhone10,6_16.6.1_20G81_Restore.ipsw ipsw-out \
    --adt research/ipsw-x/d22ap.adt
sudo tools/mkiosroot.sh --tweaks ipsw-out/os.dmg ipsw-out/systemos.dmg ipsw-out/appos.dmg ios16-root.img
python3 tools/mkadt.py shim/out/blueline.adt --board blueline --highmem   # now with /product
```

`ios16-root.img` is raw; fastboot splits it and sends the empty space as
fill chunks, so no `img2simg` is needed. Then:

```sh
fastboot -S 512M flash userdata ios16-root.img
python3 tools/mkpayload.py xnu/out/kernel.development.sweet shim/out/blueline.adt shim/out/payload.bin \
    --cmdline 'debug=0xc serial=3 cpus=1 keepsyms=1 -enable_kprintf_spam -noprogress rd=ufsroot0 unentitled_ios_sim_launch=1 ignition_level=1 wdt_test=no_user_checkin ufsrw=1 rootrw=1 launchd_unsecure_cache=1 wdt=-1 sweetfb_hz=30 sweettouch=0 sweetkeys=0 sweetusb=0'
BOARD=blueline shim/build.sh ../shim/out/payload.bin
fastboot boot shim/out/shim-boot.img
```

Several minutes on the Apple logo, then the lock screen, scaled to fit with
black bars of 41 px left and right. Read the log with TWRP:
`tools/sweet-log-pull.sh logs/boot.txt`.

### 4. Buttons, touch, more cores

Working set (2026-10-23, touch and keys on): `tools/mkboot-blueline.sh ios cpus=2
sweetfb_noconsole=1 sweettouch=1 sweetkeys=1 ufslogsecs=1`.

Drop `sweetkeys=0` (look for `SWEET KEYS: ... pon-apid=... volup-apid=...`),
then `sweettouch=0` (look for `SWEET TOUCH: board st,fts`, `ftm5 ready=0
chip-id err=0 36 39`, `selected ST FTM5`; the GPI lines come first:
`gpi gpii N states ch 0/0 ev 0`, `gpi 0x800000 gpii N se 2 started`), then raise `cpus=` to 4 and 8.
Add `sweetfb_noconsole=1` once the kernel text is no longer needed on screen.

## Open questions

Ordered by how likely they are to stop the boot.

1. **Display.** Mainline Linux uses the splash buffer as `simple-framebuffer`
   on blueline, so ABL leaves it scanned out, but the panel is command mode.
   If PINGPONG autorefresh is not enough (no tear-check PP found, or the
   picture freezes), the next step is a kick per present: write `CTL_START`
   (`0xae02000` + n*0x200 + `0x1c`) after each copy in
   `SweetFramebuffer.cpp`.
2. **Upper DDR bank.** Settled from the live FDT (2026-10-22): ABL gives
   the OS DDR up to `0x17e0a0000`, so `--highmem` uses 2016 MiB from
   `0x100000000`, inside the bank and clear of every fixed reservation;
   the shim checks it again on every boot. iOS has about 2 GiB instead of
   the iPhone X's 3 GiB (the iPhone 8 runs iOS 16 with 2 GiB).
3. **ABL payload placement.** On sweet ABL put the ramdisk just below
   `hyp_mem` (`0x85700000`); the same reserved layout should give the same
   result here.
4. **UFS DMA through the SMMU.** Works on sweet with the SMMU state ABL
   leaves; SDM845 is assumed to behave the same.
5. **Touch.** FTM5 boot needs AVDD (`ldoa19`) and the bus switch on gpio136
   set to the AP; the IC firmware is not updated. The SE2 must have ABL/TZ
   loaded GENI I2C firmware (`proto=3` in the log). Polling at 100 kHz.
   Its FIFO is fused off, so every transfer is GPI DMA (0086). The GPI
   master (SMMU stream `0x16`) reaches DDR only with a stream mapping.
   First boot (0086 alone): channel 0 went to ERROR on its first TRE
   (`log=0x4006010`), nothing consumed, no events. The SMMU dump (0087)
   shows `sCR0.USFCFG=1` (unmatched streams fault), UFS `0x100` on SMR 5
   -> context bank 2, no SMR for `0x16`; writing one (S2CR, then SMR 6)
   reset the phone: the hypervisor keeps the stream table. So 0088
   bit-bangs the bus on the SE's pins instead.
6. **USB** (`sweetusb=1/2`): same controller addresses as sweet; untested.
7. **Battery**: keep the default static 100 %; `sweetbattery=1` reads
   PM6150 fuel-gauge registers and is wrong on PM8998/PMI8998.
8. **iOS 16.6.1 vs 16.7.** If a daemon that talks to one of the kernel's
   stand-in drivers crashes on an unknown selector (`SWEET ... selector`
   lines in the log), compare that framework between the two versions.

## Back to Android

Only `userdata` is ever written; boot, system, vendor, the bootloaders,
modem and `persist` stay as they are. To get Android back at any time:

```sh
fastboot -w          # erase userdata (the iOS root) and let Android format it
fastboot reboot      # Android starts like after a factory reset
```

Then restore your files (`adb push backup/blueline-*/sdcard/ /sdcard/`) and
sign in for Google's backup. If Android itself is ever damaged, flash
Google's factory image for blueline (developers.google.com/android/images,
`flash-all.sh` works on macOS) or individual images from your backup with
`fastboot flash <partition> <file>.img`. `persist` and the modem partitions
are written back only if they are damaged, from TWRP with
`adb push X.img /tmp/ && adb shell dd if=/tmp/X.img of=/dev/block/by-name/X`.
A raw `userdata` image (`--with-userdata`) only decrypts on the same phone
while its keys survive, which `fastboot -w` ends.

## Boot-args added by the port

| Boot-arg | Effect |
| --- | --- |
| `sweetfb_fit=0` | Crop the iPhone X screen to the panel (sweet behaviour) |
| `sweetfb_fit=1` | Scale the whole iPhone X screen onto the panel |

iOS is Apple's software. This repository does not distribute it; installing
it on non-Apple hardware is outside Apple's license terms.
