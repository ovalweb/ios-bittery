# GPU (Metal) acceleration on the Pixel 3 (blueline): design study

Status (2026-10-21): **research only.** Nothing here is implemented or
tested on hardware, and the Pixel 3 port itself has not booted yet
([PIXEL3.md](PIXEL3.md)). This study covers how the Adreno 630 in the
Pixel 3 (SDM845) could render iOS's Metal work. It compares two bases:
this tree (iOS 16, xnu-8796) and [UniXNU](https://github.com/UniXNU/UniXNU)
(Darwin 23, iPadOS 17.7). Each step comes with the line the persistent
kernel log should show.

## Summary: is it realistic?

**Yes, but as a long project, and not on the current ios-sweet userland
without porting a large, fast-moving userspace stack.** The hardware half
is now well understood. The Metal half has exactly one working example,
and it is tied to iPadOS 17.

- **A working Metal-on-Adreno stack now exists, published since
  2026-10-19.** UniXNU reports that the iPadOS 17.7.11 render server
  composites the whole system UI through an Adreno 740 (Xiaomi Pad 6S Pro,
  SM8550). The chain is: an own Metal plugin (NativeMetal) → `metal2vulkan`
  (AIR to SPIR-V) → Mesa Turnip with a Darwin kernel backend → an own XNU
  driver (NativeAdreno) → GMU and CP. The source is public under MIT/BSD
  licences. Logs, screenshots and outside reproduction are not public, so
  this is credible but unverified (section 1).
- **Only the kernel bring-up in that chain depends on the GPU model.** Turnip, NIR/IR3,
  metal2vulkan and NativeMetal talk Vulkan or the NativeAdreno user-client
  ABI. The Adreno 630 is one of Turnip's longest-supported GPUs (the
  SDM845 was the early freedreno A6xx development target). What must be
  new for the Pixel 3 is the kernel part:
  - the legacy GMU start (HFI v1, firmware written into the GMU's on-chip
    instruction memory (ITCM), SPTPRAC, an RSC/PDC set up by the AP);
  - the A6xx command-processor (CP) init, ring framing and fences;
  - the power votes for SDM845;
  - the zap shader, loaded through TrustZone (section 2).
- **Mainline Linux enables this GPU on this phone**
  (`sdm845-google-common.dtsi` turns on `&gpu` with
  `qcom/sdm845/Google/blueline/a630_zap.mbn`, and pmOS packages that file).
  So every register write can be checked against a running Linux on the
  same phone, with the phone's own signed firmware.
- **The same legacy-GMU hardware has been half brought up under this very
  kernel.** `dipa-studio/ios-extra` (the Adreno 618 playground of this
  project, 2026-10-18/19) did 19 phone-tested patches on xnu-8796:
  - CX power, GMU clocks, the GMU firmware in on-chip memory (TCM);
  - a GPU SMMU context with 4 KiB tables (ATOS 29/29);
  - RSC/PDC wake/stop.

  It stopped before releasing the GMU processor. Nobody has yet run an
  A6xx legacy GMU, or any A6xx command, under XNU. The A618 is in the same
  mainline family as the A630 (same `a630_gmu.bin`, same `a630_sqe.fw`,
  same HFI v1).
- **The Metal side is the expensive, uncertain half.** NativeMetal is about
  520 KB of Objective-C++/Rust written against iPadOS 17's private Metal
  and QuartzCore behaviour. Both bases face it differently:
  - On ios-sweet (iOS 16.6.1, iPhone X build) it has to be ported and then
    maintained as a solo fork.
  - On UniXNU it is reused, but the Pixel 3 then has to be ported to
    UniXNU first. That means UEFI, UFS, display, touch and buttons again,
    and the phone becomes an **iPadOS** device: Darwin 23 has no non-PAC
    iPhone build, and the SDM845 has no PAC.
- **Recommendation:**
  1. Do the A630 hardware bring-up now on ios-sweet, as base-neutral C
     kits (stages 0-6 below). It is the base that can boot on the Pixel 3
     soonest, and the kernel work is the same either way.
  2. Plan the Metal layer (stages 7-8) on UniXNU, where it already works
     and where ios-sweet's author is taking the sibling A618 port.
  3. Stay on ios-sweet for Metal only if keeping iOS 16 with the iPhone UI
     is worth owning a NativeMetal fork (section 3).
- **Size:**
  - **Kernel driver, either base:** about 6,000-9,000 new or adapted
    lines (about 4,000 of them adapted from NativeAdreno).
  - **On top for ios-sweet:** the NativeMetal port to iOS 16, whose size
    is unknown.
  - **On top for UniXNU:** a whole Pixel 3 UniXNU port before the GPU
    work, comparable to the original Pixel 3 port.
  - **Phone tests:** expect 30-60 boot round trips for stages 1-6. ios-extra
    needed 19 just to reach the point before the GMU start.

Sources are linked inline. "Mainline" means [torvalds/linux](https://github.com/torvalds/linux)
`master` (October 2026), `drivers/gpu/drm/msm/adreno/`. "AOSP 4.9" means
Google's [`android-msm-crosshatch-4.9-android12`](https://android.googlesource.com/kernel/msm/+/refs/heads/android-msm-crosshatch-4.9-android12)
kernel. Functions are named instead of line numbers because mainline moves.
GPL code (mainline msm, AOSP kgsl) is documentation only, as for UFS, GENI
and USB. Mesa's register XML and Turnip are MIT, and the UniXNU modules are
MIT or BSD-2-Clause-Patent, so those can be used directly.

---

## 1. UniXNU's GPU stack today

### 1.1 What it is

Pinned state read for this study: UniXNU `fb2bb31` (2026-10-21), NativeAdreno
`805c7e4` (2026-10-20), and NativeMetal, AirNir, AdrenoPM4, ArmSmmu4K and
NativeMobileDisplay at `main` on 2026-10-21. Local copies are in
`research/gpu/` (the umbrella's submodules are empty there, so the
components were read on GitHub).

```
iPadOS app / QuartzCore render server (backboardd)
  -> NativeMetal plugin (an _MTLDevice subclass, found through IOAcceleratorES + MetalPluginName)
  -> metal2vulkan (Rust, AIR -> SPIR-V, GPL-2.0+ OR LGPL-3.0+, linked unmodified)
  -> Turnip with the "darwin" KMD patch (patches/mesa/turnip-darwin-kmd.patch, 1,437 lines)
  -> NIR -> IR3 (Adreno shader compiler)
  -> NativeAdreno user client (NativeAdrenoABI.h v1: BO alloc/import/map, submit, fences, queues)
  -> NativeAdreno kernel: SMMU contexts (ArmSmmu4K), GMU cold start (AdrenoFirmware HFI), CP ring
  -> Adreno 740 -> GPU copy into the UEFI GOP scanout (NativeMobileDisplay)
```

How Metal finds the plugin: Metal enumerates `IOAcceleratorES` services,
reads `MetalPluginName`, and loads
`/System/Library/Extensions/<name>.bundle`. The bundle's principal class
must subclass `_MTLDevice`, and it receives `initWithAcceleratorPort:`
(`NativeAdrenoMetalPlugin.mm`). With `NativeAdrenoMetal.publish` present,
backboardd returns the native device and CARenderServer composites through
it. `NativeAdrenoMetal.clients` gives listed processes their own device.

**The same discovery path exists in iOS 16.** ios-extra disassembled it in
the 16.7.16 iPhone X shared cache: `MTLRegisterDevices` →
`getMetalPluginClassForService` → bundle at
`/System/Library/Extensions/<MetalPluginName>.bundle` → `_MTLDevice`
subclass check → `initWithAcceleratorPort:`
([GPU_API_RE.md](https://github.com/dipa-studio/ios-extra/blob/main/docs/GPU_API_RE.md)).
Our own log already shows backboardd polling for `IOAcceleratorES` and
finding nothing (`NOTES.md`, boot 0053s).

### 1.2 Claims and evidence

| Claim (UniXNU docs, `docs/drivers/native-adreno.md`, UniXNU-sheng README) | What the public material shows | What it does not show |
| --- | --- | --- |
| GMU cold start, HFI, CP commands work on the A740 | Complete source: NativeAdreno (6,623 lines, 21 host test files), AdrenoFirmware (modern HFI), sheng board code `package/ShengGmu*.c`, `GpuPowerBoard.h`, `ShengGpuSmmu.c` (~185 KB). Fixes cite on-device runs (`int-064..067`: CP stalled until the SRAM-init wait was added; ring prologue derived from `a740_sqe.fw` disassembly) | Device logs |
| Native 4 KiB SMMU context active | ArmSmmu4K kit (SMMUv2 stage-1 tables, live updates, TLB maintenance), also used for sheng's UFS | - |
| Metal discovery, render-server compositing, per-process devices, GPU-composited desktop | NativeMetal source (published mode, per-client devices, sandbox handling via the `AGXDeviceUserClient` class name, `CA_DISABLE_FRAMEBUFFER_COMPRESSION`), dated changelog with measured numbers (BO pool 1,536 MiB, peak 782 MiB; submission walk 0.65 ms) | No screenshot or video in the repositories (UniXNU-sheng has no image files); no outside reproduction |
| GPU frame copy into scanout, pixel-identical | `GpuScanoutClient.h` reads back and compares rows (`verified`, `mismatchRows`) | - |
| Cold-boot shader compilation ~40 s | `int-150`: 103 Metal pipelines in 40.1 s, 94 Vulkan pipelines 23.3 s; pipeline caches exported and re-imported on later boots | Numbers are on a Cortex-X3; the Pixel 3's Cortex-A75 cores are much slower |

Limits the authors state themselves:

- First-use shader compilation is slow, and there is no complete
  precompiled UI pack.
- There are no per-process GPU page tables. Client windows are enforced by
  the driver, not by the SMMU.
- There is no GPU reset path and no display vblank.
- The render server's user-client open needs a sandbox-grant XNU patch
  (`zzw-native-adreno-sandbox-grant`).
- The generic `NativeAdrenoService.cpp` still says in its header that power
  and GMU are "not implemented for Darwin yet". The live path is the sheng
  board code, which brings the GPU up and hands it to
  `NativeAdrenoPublish.cpp`.

**Assessment.** The code is too detailed and too consistent with real
hardware behaviour to be a mock-up: SQE-derived cache maintenance, measured
pool sizes, fixes for specific hangs. So the claim is credible. It is still
self-reported, from a project that went public two days ago.

### 1.3 What is Adreno 740-specific

| Component | A740-specific? | For the A630 |
| --- | --- | --- |
| NativeAdreno GMU path (`NativeAdrenoGmu*`, `ShengGmu*`, command-DB votes, ACD, IFPC) | **Yes**: modern GMU (firmware blocks in ITCM/DTCM/icache, `gmu_gen70200.bin`), modern HFI (three queues, 168-byte table), A7xx perf/bandwidth/ACD/core-start sequence, SM8550 votes | Write new: legacy start (section 2.4) |
| `NativeAdrenoCpInit`, `NativeAdrenoRing`, `NativeAdrenoPwrup`, `NativeAdrenoA740HwInit.h` | **Yes**: `a7xx_cp_init` (CP_THREAD_CONTROL, power-up register list), BR/BV thread framing, `CP_EVENT_WRITE7` fences, `a740_hwcg` / `a730_protect` tables | Adapt: `a6xx_cp_init`, single-thread ring, `CP_EVENT_WRITE` + `CACHE_FLUSH_TS`, `a630_hwcg` / `a630_protect` |
| `kits/AdrenoFirmware` | Modern transport only upstream | **Reuse** UniXNU-sweet's A618 legacy transport (`AdrenoHfiInitializeLegacyStopped`: two queues, 120-byte table, response type `0xa04`, word-granular indexes). The legacy startup messages are still missing |
| `kits/AdrenoPM4` | Packet encoders are generic; the state tables are A740 | Type-4/7 encoders reusable |
| `kits/ArmSmmu4K` | No (SMMUv2) | Reuse |
| NativeAdreno BO / VM / submit / fence / user client / publish | Mostly no (some A7xx assumptions in submit framing) | Adapt |
| Turnip darwin KMD, NIR/IR3 | No; Turnip picks the GPU from the chip ID | Reuse; report chip `0x06030002` (A630v2) |
| metal2vulkan, NativeMetal | Not GPU-specific; **iPadOS 17-specific** (private `_MTLDevice`, QuartzCore behaviour, metal2vulkan patches 0004/0005 tuned to iPadOS 17's QuartzCore uber-shaders) | Reuse on UniXNU; port on iOS 16 |
| `kits/AirNir` | Yes (offline AIR → IR3 for A740) | Not needed (offline tool, not the runtime path) |
| NativeMobileDisplay | No (GOP framebuffer) | ios-sweet has `SweetFramebuffer` instead |

Related work:

- **UniXNU-sweet** (`dipa-studio/UniXNU-sweet`, the ios-sweet author's
  UniXNU port to the A618) is at the platform stage. It has a source kernel
  that boots in QEMU, the legacy HFI transport and no GPU start. Its NOTES
  say the A740 startup "cannot run unchanged on the A618".
- **iOS16_on_mix2s** (another SDM845 phone, derived from ios-sweet) reached
  a custom PID 1 on 2026-10-21. It has not started GPU work.
- **edk2-Pixel3** (2021, old EDK2) boots Linux and WinPE with UFS. It is a
  hardware reference for a Pixel 3 UEFI, not a Mu-Silicium package.

---

## 2. Adreno 630 bring-up: what a kernel driver must do

### 2.1 Register bases and DT nodes

From mainline `sdm845.dtsi`, AOSP 4.9 `sdm845-gpu.dtsi` / `qcom_sdm845.dtsi`
(copies in `research/mainline`, `research/google-b1c1`), `gpucc-sdm845.c`
and `gcc-sdm845.c`. Confirm each value against the phone's live DT
(`dtb/live.dts`, PIXEL3.md stage 0).

| Block | Address | Notes |
| --- | --- | --- |
| GPU (`kgsl_3d0_reg_memory`) | `0x05000000`, `0x40000` | `qcom,adreno-630.2`; SPI 300; mainline `cx_mem` `0x0509e000`/`0x10`; downstream CX DBGC `0x05061000`/`0x800`; downstream `qcom,chipid = <0x06030000>` (mainline derives `0x06030002` from `630.2`) |
| Adreno SMMU (SMMUv2) | `0x05040000`, `0x10000` | Global SPI 229/231, context SPI 364-371. **Stream IDs:** GPU 0 (secure 1/2), GMU 5 (downstream also lists GMU user 4). Downstream: "CB5(ATOS) & CB5/6/7 are protected by HYP", `qcom,protect = <0x40000 0xc000>`, CB0 also visible to the CP at GPU `+0x48000` |
| GMU | `0x0506a000`, `0x30000` | SPI 304 (HFI) / 305 (GMU). The window reaches GPUCC: `GPU_CC_GX_GDSCR` is GMU `+0x2700c` = GPUCC `+0x100c` |
| GMU RSCC | `0x0508d000` (GMU `+0x23000`) | Mainline `gmu->rscc` for A630 |
| GPU PDC | cfg `0x0b280000`, seq `0x0b480000` (`0x10000` each) | Mainline names `gmu_pdc`, `gmu_pdc_seq`; downstream one window `0x0b200000`/`0x300000` |
| GPUCC | `0x05090000`, `0x9000` | CX GDSC `0x106c` (`gds_hw_ctrl` `0x1540`), GX GDSC `0x100c` (clamp `0x1508`, **never switched by the AP**: `gdsc_gx_do_nothing_enable`), GMU RCG `0x1120` (200 MHz = GPLL0 div / 1.5, 500 MHz = GPU PLL1), `cx_gmu` CBCR `0x1098`, `cxo` CBCR `0x109c`, PLL1 (Fabia) at `0x0` |
| GCC | `0x00100000` | `gpu_cfg_ahb` `0x71004`, `gpu_memnoc_gfx` `0x7100c`, `gpu_snoc_dvm_gfx` `0x71018`, `ddrss_gpu_axi` `0x44038`, `gpu_iref` `0x8c010`, GPLL0 / GPLL0-div gates `0x52004` bits 15/16 |
| Apps RSC (DRV2) | `0x179e0000`, TCS `+0xd00` | Already used by `sweet_rpmh.c` (patch 0062, 0083) |
| Command DB | locator `0x0c3f000c` → `0x85fe0000` (`0x20000`) | ARC aux tables for `gfx.lvl` / `cx.lvl` / `mx.lvl`; mainline's A630 PDC hard-codes the GX ARC at `0x30080` (A618: `0x30090`); read the real addresses |
| Zap carve-out | `0x8c415000`, `0x2000` | `gpu_mem` / `pil_gpu_mem`, inside the low-bank carve-outs the shim already avoids |
| Rails | CX `pm8998_s9`, MX `pm8998_s6`, **GX `pm8005_s1`** | GX is voted by the GMU through its own RSC/PDC, not by the AP |

OPPs:

- **GPU, mainline:** 710 / 675 / 596 / 520 / 414 / 342 / 257 MHz.
- **GPU, AOSP 4.9 levels:** 600 to 210 MHz.
- **GMU:** 200 / 400 MHz (downstream 200 / 500).
- **For bring-up:** stay at 257-342 MHz. There is no thermal management in
  this kernel.

Other facts:

- GMEM is 1 MiB.
- The GPU VA space is limited to 4 GiB (`ADRENO_QUIRK_4GB_VA`).
- The A630 uses VBIF, not GBIF (`a6xx_has_gbif()` is false).

### 2.2 Firmware and where it lives on the phone

| File | Source | Signed? | Loaded by |
| --- | --- | --- | --- |
| `a630_sqe.fw` (CP microcode) | linux-firmware `qcom/a630_sqe.fw` (34,188 bytes, SHA-256 `1c21b527…a90c` at commit `a2dcb924`, per ios-extra); the phone has its own copy in the vendor image (expected `/vendor/firmware/a630_sqe.fw`; compare hashes from the backup) | No (AP copies it into GPU memory) | Kernel: `CP_SQE_INSTR_BASE` |
| `a630_gmu.bin` (GMU Cortex-M3) | linux-firmware `qcom/a630_gmu.bin` (32,768 bytes, SHA-256 `da8d9b1b…173a6`) | No (AP writes it through registers into ITCM) | Kernel. **Use the linux-firmware copy with the mainline sequence.** The downstream driver uses `qcom,gpu-quirk-hfi-use-reg` and may expect a different firmware protocol; ios-extra made the same choice for the A618 |
| `a630_zap` (secure-mode switch) | **Phone-specific, Google-signed.** Vendor image as `a630_zap.mdt` + `.b00`... (downstream PIL name `a630_zap`, `qcom,pas-id = <13>`); pmOS ships it merged as `qcom/sdm845/Google/blueline/a630_zap.mbn` ([firmware-google-pixel3](https://gitlab.com/sdm845-mainline/firmware-google-pixel3), packaged by pmaports `firmware-google-blueline`) | Yes (TrustZone authenticates it) | Kernel copies segments into `0x8c415000`, then SCM PAS calls |

As in [WIFI.md](WIFI.md) section 1.3:

- Copy the files from the backup (`tools/pixel3-backup.sh` full mode
  includes `vendor`) into the HFS+ root, for example
  `/usr/standalone/firmware/sweet/`, and read them after the root is
  mounted.
- Keep them out of git.
- The SQE and GMU images are small enough to embed at build time instead
  (ios-extra staged `a630_gmu.bin` that way, `0086-stage-gpu-firmware.sh`).
  That allows GMU tests before the root mounts.

### 2.3 Power, clocks, RPMh

Order from mainline `a6xx_gmu_resume()` and ios-extra 0083-0085 (measured
on the A618):

1. **Rails.** Vote MX, then CX, to at least LOW_SVS through the apps RSC
   ARC resources (`mx.lvl`, `cx.lvl`). The values are **indexes** into the
   command-DB aux level table, not corner numbers. ios-extra measured raw
   tables `0,16,64,128,192,256` (CX/GFX) and `0,16,192,320,384` (MX) on
   SM7150. Read the SDM845 tables from the phone's command DB.
2. **GCC.** Enable `gpu_cfg_ahb`, `gpu_memnoc_gfx`, `ddrss_gpu_axi` and the
   GPLL0 / GPLL0-div gates. `memnoc` and `ddrss_axi` are shared, voted
   branches: own only the enable bit.
3. **GPUCC.** Turn on the CX GDSC (`0x106c`, poll PWR_ON). Set the GMU RCG
   to 200 MHz (`0x1124` CFG `0x602`, then CMD update). Enable `cx_gmu` and
   `cxo`. Do **not** touch the GX GDSC.
4. **DDR bandwidth.** Mainline votes `MASTER_GFX3D → SLAVE_EBI1` through the
   interconnect (BCM votes on the apps RSC). The A630 GMU does no bus
   scaling: its HFI bandwidth table is one "off" entry. Without an AP vote
   the GPU runs at whatever DDR level other masters keep. Add BCM votes
   (`MC0`, `SH0` from the command DB) once the GPU works, or if it is
   unexpectedly slow or hangs on memory.

### 2.4 GMU: legacy cold boot and HFI v1

Mainline (`a6xx_gmu_init()` → `a6xx_gmu_resume()` → `a6xx_gmu_fw_start()` →
`a6xx_hfi_start_v1()`), for `gmu->legacy` (the A630 family, including the
A618). GMU byte offsets = (`a6xx_gmu.xml` dword index − `0x1a800`) × 4.
ios-extra's
[GPU_GMU_BOOT.md](https://github.com/dipa-studio/ios-extra/blob/main/docs/GPU_GMU_BOOT.md)
lists the same offsets with readbacks measured on the A618, all taken with
the GMU still held in reset.

**Memory.** One GMU address space (SID 5) with:

- dummy page, 4 KiB at IOVA `0x60000000`;
- then, from `0x60001000`: debug 16 KiB (legacy only), log 16 KiB, HFI
  16 KiB.

All of it is write-combined. The A630 needs no icache/dcache regions
(mainline's comment on legacy GPUs).

**HFI table.** In the HFI page: a 6-word header (version, size 120,
qhdr0 offset, qhdr size, 2 queues, 2 active), two 12-word queue headers,
the command queue at +4 KiB (type `0xa00`) and the response queue at
+8 KiB (type `0xa04`). UniXNU-sweet's `AdrenoHfiInitializeLegacyStopped`
builds exactly this, with host tests.

**Cold boot:**

| Step | Register (GMU byte offset) | Value / check |
| --- | --- | --- |
| RSC/PDC init, once | RSCC `+0x23000` (`SLAVE_ID`, hidden TCS, `PDC_SEQ_START_ADDR 0x4520`, match `0x4510`/`0x4514`, sequencer `0xa7a506a0 0xa1e6a6e7 0xa2e081e1 0xe9a982e2 0x0020e8a8`); PDC seq memory `0xfebea1e1...`; TCS1/TCS3 commands to CX `0x30000`, MX `0x30010`, GX `0x30080`; `PDC_GPU_ENABLE_PDC = 0x80000001` | `a6xx_gmu_rpmh_init()`. ios-extra saw 9 of 48 writes read back differently (fixed fields) without breaking wake/stop |
| TCM retention | `GENERAL_7` (`+0x14730`) | 1 |
| GPU RSC wake | `RSCC_CONTROL_REQ` (`+0x24c1c`) = bit 1 | poll `RSCC_CONTROL_ACK` (`+0x24c20`) bit 1, RSCC `SEQ_BUSY_DRV0` = 0, then REQ = 0 |
| Firmware | ITCM `+0x3000` | whole `a630_gmu.bin` (≤ 32 KiB) as 32-bit writes; read back |
| Boot config | `CM3_FW_INIT_RESULT` (`+0x14070`) = 0, `CM3_BOOT_CONFIG` (`+0x14004`) = 2 | cold boot |
| HFI | `HFI_QTBL_ADDR` (`+0x14614`) = HFI IOVA, `HFI_QTBL_INFO` (`+0x14610`) = 1 | |
| Fence range | `AHB_FENCE_RANGE_0` (`+0x24c44`) | `BIT(31) \| 0xa << 18 \| 0xa0` |
| CM3 config | `CM3_CFG` (`+0x140b4`) | `0x4052` |
| Chip ID | `HFI_SFR_ADDR` (`+0x14608`) | `0x06030200` for chip `0x06030002` (GMU packing) |
| Log | `PWR_COL_CP_MSG` (`+0x14400`) | log IOVA \| (16 KiB / 4 KiB − 1) |
| Power config | `SYS_BUS_CONFIG`/`ICACHE_CONFIG`/`DCACHE_CONFIG` = 1, `PWR_COL_INTER_FRAME_CTRL` (`+0x14300`) = `0x09c40400`, `RPMH_CTRL` (`+0x143a0`) \|= `0xf11` | idle level ACTIVE (no IFPC on the A630) |
| Start | `CM3_SYSRESET` (`+0x14000`) 1, `PWR_COL_CP_RESP` 0, `CM3_SYSRESET` 0 | poll `FW_INIT_RESULT` = `0xbabeface` (or `& 0x1ff` = `0x100` when the firmware version word at DTCM dword `0xff8`, GMU `+0xafe0`, is above `0x20010004`), 10 ms |
| GX rail on (legacy) | `BOOT_SLUMBER_OPTION` (`+0x8fe0`) = 0; `GX_VOTE_IDX` / `MX_VOTE_IDX` (`+0x8fe4` / `+0x8fe8`) from the highest GX ARC vote; OOB `BOOT_SLUMBER` | OOB: write `1 << 22` to `HOST2GMU_INTR_SET` (`+0x14650`), poll `GMU2HOST_INTR_INFO` (`+0x14648`) bit 30, clear it |
| SPTPRAC | `GX_SPTPRAC_POWER_CONTROL` (`+0x204`) = `0x778000` | poll `SPTPRAC_PWR_CLK_STATUS` (`+0x14340`) `& 0x38 == 0x28` |
| HFI start | `HFI_CTRL_INIT` (`+0x14618`) = 1 | poll `HFI_CTRL_STATUS` (`+0x14600`) bit 0 |

**HFI v1 messages** (`a6xx_hfi_start_v1()`), each acknowledged by an
`F2H_MSG_ACK` (126) that carries the sequence number:

1. `INIT` (0): debug buffer IOVA and size, boot state.
2. `FW_VERSION` (1): supported version `1 << 28 | 1 << 19 | 1 << 17`.
3. `PERF_TABLE` (4): one GX vote and frequency (kHz) per GPU OPP and one CX
   vote per GMU OPP. Votes are built like
   `a6xx_gmu_rpmh_arc_votes_init()` from the command-DB `gfx.lvl` /
   `mx.lvl` / `cx.lvl` aux data. This is the one piece of SoC-specific
   arithmetic: get it wrong and GX never powers.
4. `BW_TABLE` (3): fixed for SDM845 (`a6xx_build_bw_table()`):
   - DDR commands at `0x50000`, `0x5005c`, `0x5000c` = `0x40000000`;
   - CNOC commands at `0x50034`, `0x5007c`, `0x5004c` with the two
     levels given there.
5. `TEST` (5).

After this, every GPU access is bracketed by OOB `GPU_SET`: request bit
16, ack bit 24, clear 24. Frequency changes use OOB `DCVS_SET` (23/31) and
the `GMU_DCVS_*` registers. They are optional; a fixed level is fine at
first.

### 2.5 SMMU contexts

The GMU needs a context for SID 5 before the CM3 starts. The GPU needs one
for SID 0 before the CP fetches the SQE.

- The A630's SMMU is SMMUv2. ios-extra programmed one with 4 KiB stage-1
  tables (ATOS checks correct) under xnu-8796. **The 16 KiB CPU page size
  does not dictate the SMMU granule.**
- On the A618 the global register pages (GR0/GR1) behaved as if a
  hypervisor emulated them:
  - 32-bit reads returned junk in the upper halves;
  - the SMMU refused to put `S2CR` and `CBAR` back to their fault/unused
    encodings;
  - `sCR0` had the global fault interrupts (GFIE, GCFGFIE) enabled.

  The Pixel 3 runs the same Qualcomm hypervisor, and AOSP 4.9 says CB5-7
  belong to it. Use banks 0-4, read `IDR0`/`IDR1` first, and never assume
  a reset value.
- Per-process page tables (TTBR switching through
  `CP_SMMU_TABLE_UPDATE` and the CB0 alias at GPU `+0x48000`) are not
  needed at first. NativeAdreno also runs one shared address space with
  windows enforced by the driver.

### 2.6 GPU core, SQE, zap shader, CP

Mainline `a6xx_hw_init()` for the A630, after OOB `GPU_SET`:

1. `RBBM_SECVID_TSB_CNTL` = 0, trusted base/size = 0. Turn on 64-bit
   addressing in every `*_ADDR_MODE_CNTL`.
2. Hardware clock gating from `a630_hwcg` (`a6xx_catalog.c`).
   `RBBM_VBIF_CLIENT_QOS_CNTL` = 3, `VBIF_GATE_OFF_WRREQ_EN` = 9.
3. UCHE:
   - write range, trap base and write-through base at the trap address;
   - GMEM range `0x100000` .. `+1 MiB − 1`;
   - `UCHE_FILTER_CNTL` = `0x804`, `UCHE_CACHE_WAYS` = 4.

   Then `CP_ROQ_THRESHOLDS_2/1` = `0x010000c0` / `0x8040362c`,
   `CP_MEM_POOL_SIZE` = 128, `PC_DBG_ECO_CNTL` = `0x00180000`,
   `CP_AHB_CNTL` = 1, the UBWC config, `RBBM_INTERFACE_HANG_INT_CNTL` =
   `1 << 30 | 0x1fffff` and `UCHE_CLIENT_PF`.
4. CP register protection: `CP_PROTECT_CNTL` and the 32 `a630_protect`
   entries. Then `RBBM_INT_0_MASK`.
5. **SQE:** copy `a630_sqe.fw` into GPU-visible memory and write the 64-bit
   `CP_SQE_INSTR_BASE` (dword `0x830`). Then set up the ring:
   - `CP_RB_BASE` (`0x800`);
   - `CP_RB_CNTL` (`0x802`) with `NO_UPDATE`, because the A630 has no
     extended APRIV. A read-pointer shadow then needs the `WHERE_AM_I`
     packet, which only a new enough SQE has; reading `CP_RB_RPTR` is
     enough at first.

   Start the CP with `CP_SQE_CNTL` (`0x808`) = 1.
6. **`a6xx_cp_init`:** one `CP_ME_INIT` with 8 words
   (`0x2f, 3, 0x20000000, 0, 0, 0, 0, 0`). There is no
   `CP_THREAD_CONTROL` and no power-up list on the A630. Wait for the ring
   to idle.
7. **Zap shader**, which leaves secure mode:
   1. Parse `a630_zap.mdt` and its segments (`qcom_mdt_load()`), and copy
      them into `0x8c415000`.
   2. `PAS_INIT_IMAGE` (SCM service 2, command 1; SMCCC ID `0x42000201`)
      with the metadata in physically contiguous memory.
   3. `PAS_MEM_SETUP` (`0x42000202`), only if the image is relocatable.
   4. `PAS_AUTH_AND_RESET` (`0x42000205`) with PAS ID 13.
   5. On success, submit `CP_SET_SECURE_MODE 0`.

   If TrustZone refuses, a retail phone has no fallback: the write to
   `RBBM_SECVID_TRUST_CNTL` is blocked. This SCM helper is the same one
   [WIFI.md](WIFI.md) stage 1 needs.
8. **Fence:** write the sequence number to `CP_SCRATCH(2)` (`0x885`) with
   a type-4 packet. Then `CP_EVENT_WRITE` `CACHE_FLUSH_TS` with the IRQ
   bit, the fence address and the value (`a6xx_submit()`).
   NativeAdrenoRing's A7xx `CP_EVENT_WRITE7` + `CACHE_CLEAN` and the BR/BV
   framing do not apply to the A630.
9. Clear OOB `GPU_SET`. The GPU stays on (idle level ACTIVE).

Interrupts: GPU SPI 300, GMU SPI 304/305. Poll first; ios-sweet's drivers
poll anyway. Hang and fault state to log:

- GPU: `RBBM_STATUS` (`0x210`), `RBBM_INT_0_STATUS` (`0x201`),
  `CP_RB_RPTR` / `CP_RB_WPTR` (`0x806` / `0x807`);
- CP: hardware fault and protect status;
- SMMU: `FSR` / `FAR` / `FSYNR0` of both context banks;
- GMU: `AO_HOST_INTERRUPT_STATUS` (`+0x24c14`), `GMU2HOST_INTR_INFO`, and
  the first bytes of the GMU log page.

---

## 3. Which base for GPU work

### 3.1 Option A: stay on ios-sweet, port NativeMetal to iOS 16

ios-sweet: iOS 16.6.1 iPhone X userland, xnu-8796, 16 KiB pages, drivers
built into the kernel, shim boot, HFS+ root, permissive AMFI and sandbox.

| Pros | Cons |
| --- | --- |
| The Pixel 3 port exists (patches 0082-0085, `mkadt.py --board blueline`) and is next in line to boot; the GPU work does not wait for a new platform | **NativeMetal must be ported to iOS 16's Metal and QuartzCore**: the private `_MTLDevice` base, the protocol surface QuartzCore calls, render-server preferences and MobileGestalt answers, framebuffer-compression switches, the device's GPU-family answers |
| Metal plugin discovery is identical in iOS 16 (disassembled by ios-extra) | The iPhone X is an Apple4-family GPU (A11): QuartzCore may take paths (tile shaders, imageblocks, raster order groups) that the A10X image never asked metal2vulkan for; answering Apple3 may or may not be accepted |
| No sandbox or code-signing fights: no sandbox-grant patch, no class-name trick, AMFI permissive | metal2vulkan patches 0004/0005 were tuned on iPadOS 17's QuartzCore uber-shaders; iOS 16's library differs. **Check first** that iOS 16.6.1's QuartzCore `default.metallib` contains AIR (the A740 path translates the AIR slice); if it holds only Apple GPU binaries, Option A is blocked |
| The kernel is ours: `IOAcceleratorES` can be a built-in class, no vtable compatibility with Apple's `IOGPUFamily` (UniXNU's `OriginalGPUProviderABI.h`) | 16 KiB pages: CPU-mappable BOs must be 16 KiB multiples (Turnip KMD `align_log2 = 12` → 14); NativeAdrenoMemory assumes 4 KiB CPU spans; IOKit and kernel-API differences between xnu-10063 and xnu-8796 |
| ios-extra's 0080-0098 (xnu-8796, legacy GMU sibling) can be ported almost directly; same log, boot-arg and test tooling | A solo fork of ~520 KB of NativeMetal plus the Turnip and metal2vulkan patches, against an upstream that changes daily; every upstream fix has to be re-ported |
| Phone-shaped iPhone UI, already working with CPU rendering (fit mode 997×2160) | 2 GiB of RAM for iOS (upper bank) minus the GPU pool (sheng uses 1.5 GiB; here ≤ 256-384 MiB) |
| GPU work is independent of Wi-Fi and modem work and shares only the SCM helper | ios-sweet's author has moved to UniXNU; no upstream for this combination |

Effort beyond the shared kernel work (section 3.3):

- IOKit and page-size adaptation of NativeAdreno: about 1,000-2,000
  changed lines.
- Built-in `IOAcceleratorES` service and plugin staging in the HFS+ root:
  small.
- NativeMetal and metal2vulkan port to iOS 16: **unknown**, plausibly
  several thousand changed lines plus reverse engineering of QuartzCore 16.
  NativeMetal reports every unimplemented selector through its `missing`
  callback, which turns the port into a measurable list.

### 3.2 Option B: move the Pixel 3 to UniXNU

UniXNU: Darwin 23 (xnu-10063.141.1), iPadOS 17.7.x, 4 KiB pages, Mu-Silicium
UEFI + DarwinBoot, Apple's own kexts prelinked (IOSurface, IOGPUFamily,
IOMobileGraphicsFamily, sandbox, AMFI), APFS images from the IPSW.

| Pros | Cons |
| --- | --- |
| The whole Metal half runs unchanged (NativeMetal, metal2vulkan, Turnip KMD, pipeline-cache export/import, per-process devices); only the device profile and pool sizes change | **The Pixel 3 port starts over**: no Mu-Silicium package for blueline (SDM845 = `NapaliPkg`; `polarisPkg` for the Mi Mix 2S is the nearest relative, edk2-Pixel3 has old board facts); the DSC command-mode panel must stay refreshed from UEFI GOP; NativeUfs is SM8550-only; FTM5 touch, PON/GPIO keys and USB must be rewritten as UniXNU drivers |
| Upstream is active, and the A618 sibling port (UniXNU-sweet) is in the same family: legacy HFI transport already there; the A6xx legacy start and CP work could be shared and upstreamed | **iPadOS, not iOS.** Darwin 23 needs a non-PAC userland (Kryo 385 has no PAC), and the only Darwin 23 builds for non-PAC SoCs are iPadOS 17 for A10/A10X iPads (sheng uses iPad7,1). An iPad UI on a 1080×2160 phone panel is untested |
| 4 KiB kernel pages match the SMMU; NativeAdreno memory code runs as written | Not proven on anything near the Pixel 3: UniXNU-sweet has not booted on its phone yet (QEMU only); only sheng (SM8550) runs |
| Real Apple IOSurface, sandbox, AMFI and APFS: closer to a real system than ios-sweet's stand-ins | The Darwin 23 kernel needs Xcode 26.2 for its IPC generators (UniXNU-sweet NOTES) |
| | The persistent UFS log and the `sweet-log-pull.sh` workflow must be recreated (sheng has its own `BootLog.c` on UFS) |

Effort beyond the shared kernel work:

- A full Pixel 3 UniXNU port, comparable in size to everything the ios-sweet
  Pixel 3 port needed, plus a Mu-Silicium device package.
- Then A630 support in NativeAdreno (the same kernel work as Option A,
  written once into the UniXNU module layout).
- The userland GPU stack: small.

### 3.3 Shared kernel work (either base)

| Piece | Basis | New or adapted lines |
| --- | --- | --- |
| Rail, clock and GDSC control, ARC/BCM votes from the command DB | ios-extra 0082-0085, `sweet_rpmh.c` | 600-1,000 |
| GMU legacy start + HFI v1 startup messages + OOB + SPTPRAC + RSC/PDC | ios-extra 0086, 0090-0097; UniXNU-sweet `AdrenoHfi.c`; mainline as documentation | 1,500-2,000 |
| SMMU contexts (GMU SID 5, GPU SID 0) | ArmSmmu4K (reuse), ios-extra 0087-0089, 0093 | 500-1,000 glue |
| Zap shader: MDT parser, SCM PAS calls | new (shared with Wi-Fi stage 1's SCM helper) | 400-700 |
| A6xx hardware init, SQE, ring, CP init, fences, IRQ / fault dump | NativeAdrenoRing / CpInit adapted to A6xx; `a630_hwcg` / `a630_protect` generated from Mesa's MIT register XML | 1,500-2,000 |
| BO, VM, submit, user client, publish | NativeAdreno (MIT), adapted | ~4,000 adapted |

Write the hardware parts the way UniXNU's kits are written: plain C with
`read32` / `write32` / `barrier` / `wait_us` callbacks and no IOKit inside.
Then the same files compile into either kernel.

### 3.4 Recommendation

1. **Now: ios-sweet.** Boot the Pixel 3 port (PIXEL3.md stages 1-3). Then
   do stages 0-6 below on xnu-8796, as base-neutral kits behind
   `sweetgpu=N`. This is the shortest path to the real unknowns: whether
   the hypervisor lets us own the GPU SMMU banks, whether TrustZone accepts
   the zap shader from XNU, and whether the GMU powers GX with our votes.
   None of these depends on the base. ios-sweet has the log, the tooling
   and the ios-extra patches for exactly this kernel.
2. **For Metal (stages 7-8): UniXNU**, unless keeping iOS 16 and the
   iPhone UI is a goal in itself. The Metal half is the largest and least
   predictable part, it only works on iPadOS 17, and its author keeps
   changing it. Offering the A630 kernel kits upstream (next to
   UniXNU-sweet's A618 work) is the cheapest way to share the
   legacy-A6xx maintenance.
3. **Decision point at stage 6.** If a Pixel 3 UniXNU boot is still far
   away by then, either:
   - start Option A's NativeMetal port, beginning with the AIR check and
     the `missing` selector list in a test process; or
   - wait and keep CPU rendering.

---

## 4. Staged plan

Each stage sits behind a boot-arg (`sweetgpu=N` runs stages 1..N; 0 = off,
the default). As in ios-extra, every stage undoes what it changed unless a
later stage needs it. The log is the persistent UFS ring at the end of
`userdata`, read from TWRP with `tools/sweet-log-pull.sh` (PIXEL3.md).
Boot GPU stages with `ufslogsecs=1`: a GMU, SMMU or XPU fault can reset the
SoC, and the last second before the reset is the interesting one. A USB
live log (`sweetusb=2`, patch 0077) would save the TWRP round trip if USB
device mode works on blueline.

| Stage | What | Proof in the persistent log |
| --- | --- | --- |
| 0 | **Facts and files, no kernel code.** From the backup:<br>• `a630_zap.mdt`/`.bNN`, `a630_sqe.fw`, `a630_gmu.bin` from the vendor image; hashes against linux-firmware and pmOS's `a630_zap.mbn`<br>• live DT GPU/GMU/SMMU nodes and `iommus`<br>• the command-DB dump (`gfx.lvl`, `cx.lvl`, `mx.lvl` aux tables, `MC0`/`SH0`)<br>• Android `dmesg` kgsl lines (chip ID, firmware versions)<br>Reference trace: pmOS on blueline with `drm.debug`, so every later stage can be compared write by write. For Option A also check that iOS 16.6.1 QuartzCore's `default.metallib` carries AIR. | n/a (host side) |
| 1 | **Read-only inventory** (port of ios-extra 0080-0082, 0087, 0090): GCC/GPUCC branches and GDSCs, SMMU `IDR0-2`, `sCR0`, `SMR`/`S2CR`/`CBAR` of every bank, RSC/PDC state, ARC tables. | `SWEET GPU: gpucc cx_gdscr=... gx_gdscr=... gmu_rcg=...`, `smmu idr0=... idr1=... banks=N scr0=...`, one `s2cr[i]=... smr[i]=...` per group, `arc gfx.lvl @0x300xx: ...` |
| 2 | **CX power and GMU clocks, firmware in ITCM** (0083-0086): MX/CX votes, CX GDSC, GMU RCG 200 MHz, branches, `a630_gmu.bin` written and read back; everything rolled back. | `SWEET GPU: cx gdsc on 0x...`, `gmu clk 200MHz cbcr=0x...`, `itcm 32768 bytes, 0 mismatches` |
| 3 | **GMU SMMU context and buffers** (0087-0089, 0093): SID 5 → a free bank (not 5-7), 4 KiB tables, dummy/debug/log/HFI at `0x60000000`..., ATOS on both ends of every page, HFI table built. | `SWEET GPU: gmu cb=N sid=5 ttbr0=0x... atos 29/29 fsr=0` |
| 4 | **GMU start** (new; ios-extra stopped before it): RSC/PDC init, RSC wake, cold boot, CM3 release, GX rail OOB, SPTPRAC, HFI start; HFI v1 INIT, FW_VERSION, PERF_TABLE, BW_TABLE, TEST. | `SWEET GPU: cm3 init result 0xbabeface in N us`, `oob boot_slumber ack`, `gx gdscr=0x... (on)`, `sptprac 0x28`, `hfi ready`, `hfi fw version 0x...`, `perf table ack (7 gpu, 2 gmu levels)`, `bw table ack`; on failure the GMU AO status, `FW_INIT_RESULT` and the first 64 bytes of the GMU log |
| 5 | **GPU core and CP:** OOB `GPU_SET`, `a6xx_hw_init` writes, GPU context SID 0, SQE, ring, `CP_ME_INIT`; then the zap shader through SCM PAS 13 and `CP_SET_SECURE_MODE 0`; one scratch write and one fence. | `SWEET GPU: rbbm_status=0x... chip 0x06030002`, `sqe 34188 bytes at iova 0x...`, `cp init idle`, `zap: init_image=0 auth_reset=0`, `secure mode off`, `fence 1 in N us scratch=0x...`; on failure `RBBM_STATUS`, `CP_RB_RPTR/WPTR`, CP fault, SMMU `FSR/FAR` |
| 6 | **Kernel render self-test:** `CP_MEM_WRITE` of a pattern, then a GMEM clear and resolve into a 256×256 buffer (a hand-made or Turnip-recorded command stream), checked by the CPU. Optionally show it on screen through `SweetFramebuffer`. | `SWEET GPU: memwrite ok`, `clear 256x256 crc=0x... expect 0x...`, `N submissions, 0 faults`; **decision point (section 3.4)** |
| 7 | **User client and Turnip** (base-specific): NativeAdreno ABI user client, an `IOAcceleratorES` service with `MetalPluginName`, Turnip (darwin KMD) built for the target OS; a command-line test runs Vulkan compute, a triangle and an IOSurface import (NativeMetal's self-test). | `SWEET GPU: client <proc> open`, `bo alloc/map N`, `submit fence N`, the self-test's per-step markers and `compute_bad=0 render_bad=0 import_bad=0` |
| 8 | **Metal in a test process, then backboardd:** plugin bundle in `/System/Library/Extensions`, first unpublished (test process only), then published to backboardd; frames go IOSurface → `SweetFramebuffer` (or GOP on UniXNU); pipeline cache export so later boots do not recompile. | Plugin status lines (`missing <class> <selector>` for every unimplemented call), `pipelines N compiled in N s`, `SWEET FB: swap ... gpu`, frame time; home screen drawn by the GPU |
| 9 | **Hardening:** GMU fault and hang IRQs, GPU recovery (GX off/on through the GMU), DCVS levels, GPU temperature (tsens) and a thermal cap, per-process page tables. | `SWEET GPU: hang detected rptr=... -> reset ok`, `dcvs level N`, `gpu temp N C` |

Notes:

- Stages 1-6 run before the root mounts (embedded SQE and GMU images, zap
  from the root only at stage 5). They can be tested with PIXEL3.md stage
  2's command line, without the iOS root.
- One stage per boot, and compare each with the mainline trace from stage 0.
  ios-extra's rule is worth keeping: a source reading, a green build and a
  phone result are three different things, and the log has to say which one
  it is.
- Shader compilation: sheng compiles about 100 pipelines in 40 s on a
  Cortex-X3. The Pixel 3's Cortex-A75 cores will be several times slower,
  so the first GPU-composited boot may spend minutes compiling. Exporting
  pipeline caches into the root (UniXNU's `m2vpack` path) is needed before
  this is usable.

### Risks

| Risk | Likelihood | Effect | Mitigation |
| --- | --- | --- | --- |
| The hypervisor owns or filters the Adreno SMMU (CB5-7 protected; emulated GR0/GR1 seen on the A618) | high that something is filtered, medium that it blocks | No GMU/GPU DMA | Stage 1 inventory first; use banks 0-4; mask 32-bit reads; global-fault containment before the first master (ios-extra's open item) |
| TrustZone refuses the zap shader from XNU (SCM calling convention, metadata buffer, carve-out ownership) | medium | GPU stays in secure mode; no fallback on a retail phone | Copy `qcom_scm_pas_init_image()`'s buffer layout; log each SCM return; the image itself authenticates under mainline on this phone |
| GMU never reports `0xbabeface`, or GX never powers (wrong ARC votes, PDC/RSC setup, `pdc_address_offset`) | medium | Stage 4 blocked | Votes from the command DB exactly as `a6xx_gmu_rpmh_arc_votes_init()`; compare with the pmOS trace; dump GMU log and AO status |
| GMU firmware choice (vendor `a630_gmu.bin` vs linux-firmware, register-based vs queue-based HFI) | low-medium | HFI never answers | Use linux-firmware with the mainline sequence; log `HFI_VERSION_INFO` and the `FW_VERSION` reply |
| No DDR bandwidth vote | medium | Slow GPU or bus stalls | BCM votes from the command DB (stage 5 if needed) |
| No thermal management; GPU always on | medium | Heat, throttling by the PMIC | Lowest useful OPP; tsens readout and a cap in stage 9 |
| Fault resets the SoC (XPU violation) | medium | Silent reboots | `ufslogsecs=1`; one write group per boot |
| Option A: iOS 16 QuartzCore needs Metal features metal2vulkan lacks (Apple4 family), or its metallib lacks AIR | medium (AIR: unknown) | Stage 8 blocked on ios-sweet | Check AIR at stage 0; use the `missing` callback list before committing to the port |
| Option B: Pixel 3 UniXNU port stalls (UEFI, DSC panel, UFS, iPadOS on a phone panel) | medium-high | No Metal base | Keep ios-sweet working; kernel kits are base-neutral |
| Upstream churn (UniXNU changed NativeAdreno and NativeMetal several times on 2026-10-20 alone) | certain | Re-porting work | Pin commits; contribute A630 kits upstream instead of forking |
| Shader compile time on the A75 cores | certain | Minutes of compiling on the first GPU boot | Pipeline-cache export/import; precompile on the host with Turnip's offline compiler (UniXNU's `probe-turnip-internal-compiler-host.py`) |
| Memory: 2 GiB for iOS (ios-sweet) or 4 GiB total (UniXNU) vs sheng's 1.5 GiB BO pool | certain | Out-of-memory in the render server | Pool ≤ 256-384 MiB; one client window |

### Not covered

- **OpenGL ES.** iOS 16's GLES runs on Metal (`AppleMetalGLRenderer`, per
  ios-extra), so it follows from Metal. A Mesa freedreno GLES backend was
  not evaluated.
- **Display controller (DPU) acceleration.** Scanout stays the ABL
  framebuffer copy (`SweetFramebuffer`). The fit scaling to 997×2160 could
  later be done by a GPU blit, like UniXNU's GPU scanout hand-off.
- **Video decode/encode** (Venus) and the Pixel Visual Core.

iOS is Apple's software. Installing it on non-Apple hardware is outside
Apple's license terms. Firmware files are proprietary and stay out of git.
