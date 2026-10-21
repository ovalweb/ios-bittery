# Wi-Fi on the Pixel 3 (blueline): design study

Status (2026-10-21): **research only.** Nothing here is implemented or
tested on hardware. It describes what Wi-Fi would take on the Pixel 3
(SDM845, Qualcomm WCN3990) under this project's XNU kernel with the
iOS 16.6.1 iPhone X userland, and how each step could be checked from the
persistent kernel log.

## Summary: is it realistic?

**Internet over Wi-Fi: yes, but it is the largest job in this project so
far. The native iOS Wi-Fi experience (Settings → Wi-Fi, network list, join
sheet): no, not in any foreseeable plan.**

- The WCN3990 is not a self-contained Wi-Fi card. Its firmware
  (`wlanmdsp.mbn`) runs as a protection domain **on the modem DSP** (MSS,
  Hexagon Q6). Before the first Wi-Fi register can be touched, the kernel has
  to boot the modem, talk to it over SMEM/SMP2P/GLINK/QRTR/QMI, and serve the
  three things it asks for: its file system (rmtfs), a domain map
  (pd-mapper) and firmware files (TFTP). Only then does the modem publish
  the WLAN firmware service (`wlfw`), and only then can a driver like Linux's
  `ath10k_snoc` start.
- Mainline Linux does exactly this on the Pixel 3: postmarketOS ships Wi-Fi
  for `google-blueline` with the phone's own Google-signed firmware. So the
  path is proven on this phone and these firmware images, and every step can
  be checked against working code.
- The cheap iOS presentation is an **Ethernet-like `en0`** that configd sets
  up (DHCP or static, like the USB `ue0` attempt in patches 0075-0081), with
  the WPA2-PSK handshake done **inside the kernel** and the network name and
  passphrase coming from a file in the root image. iOS would see a wired
  network, so apps get internet, but the Wi-Fi page in Settings would stay
  off.
- The native path needs `IO80211Family` and `IOSkywalkFamily`, which are
  closed source. In iOS 16 wifid talks to the driver through IO80211 user
  clients on a Skywalk interface. Re-creating that is a reverse-engineering
  project bigger than the whole driver stack below it.
- Rough size of the Ethernet-style path: **15,000-20,000 new lines** of
  kernel code, or about 10,000 new lines plus about 15,000 lines ported from
  ISC/BSD-licensed sources (ath10k, OpenBSD net80211, linux-msm tools). For
  scale: everything the project has written itself so far
  (`bsd/dev/sweet_*.c`, `iokit/Kernel/arm/Sweet*.cpp`) is about 6,500 lines.
- The work has to be done in stages. Each stage ends with a log line that
  proves it worked, and the first stage (boot the modem) answers the biggest
  unknowns: whether TrustZone and the hypervisor accept our memory hand-over
  and whether the modem stays up without Android around it.
- **Prerequisite:** the Pixel 3 port must boot first (`docs/PIXEL3.md`), and
  the configd/IOKit problem of `ue0` (`NOTES.md`, 2026-10-18) must be solved,
  because the Wi-Fi `en0` needs exactly the same IOKit side.

Sources are linked inline. "AOSP 4.9" means Google's
[`android-msm-crosshatch-4.9-android12`](https://android.googlesource.com/kernel/msm/+/refs/heads/android-msm-crosshatch-4.9-android12)
kernel. "Mainline" means [torvalds/linux](https://github.com/torvalds/linux)
`master` (October 2026). Functions are named instead of line numbers because
mainline moves.

---

## 1. Hardware path on SDM845

### 1.1 The pieces

```
 AP (XNU)                                   MSS (Hexagon Q6 modem DSP)
 ────────                                   ──────────────────────────
 SCM: hyp-assign memory to the modem VM
 RPMh votes (cx/mx/mss levels, LDOs, RF clk)
 GCC clocks, AOSS/PDC resets, RMB regs  ──►  PBL → MBA (mba.mbn) → MPSS (modem.mdt/.bNN)
 SMP2P (ready / fatal / handover bits)  ◄──  root PD up
 SMEM + GLINK "IPCRTR" ─ QRTR ─ QMI     ◄─►  QRTR name service, QMI clients/servers
   rmtfs server (service 14)            ◄──  EFS: modemst1/modemst2/fsc/fsg
   pd-mapper (servreg locator 0x40)     ◄──  "where is wlan/fw?" → msm/modem/wlan_pd
   TFTP server (QRTR port 4096)         ◄──  RRQ /readonly/firmware/image/wlanmdsp.mbn
                                             WLAN PD starts, publishes wlfw (0x45)
   wlfw QMI client (ath10k qmi.c)       ◄─►  MSA, BDF, CE config, mission mode
 WCN3990 rails + RF clock (RPMh)
 SMMU stream 0x40, copy engines @0x18800000 ◄─► WLAN data path (HTC/WMI/HTT)
```

### 1.2 Register bases and DT nodes

From mainline `arch/arm64/boot/dts/qcom/sdm845.dtsi` and
`sdm845-google-common.dtsi` (Pixel 3 overrides), cross-checked with AOSP 4.9
`arch/arm64/boot/dts/qcom/sdm845.dtsi`, `sdm845-smp2p.dtsi`,
`sdm845-regulator.dtsi` and `google/sdm845-b1c1-memory.dtsi`.

| Block | Address / value | DT node |
| --- | --- | --- |
| MSS QDSP6SS | `0x04080000` (size `0x408`) | `mss_pil: remoteproc@4080000` reg `qdsp6` (AOSP: `qcom,mss@4080000`, `qcom,pil-q6v55-mss`) |
| MSS RMB (relay message buffer) | `0x04180000` (`0x48`); alt reset at `+0x44` | reg `rmb`; AOSP `rmb_base`, `alt_reset` `0x4180044` |
| AXI halt registers | `0x01f63000` (q6), `0x01f65000` (modem), `0x01f64000` (nc) | `qcom,halt-regs = <&tcsr_regs_1 0x3000 0x5000 0x4000>`, `tcsr_regs_1` at `0x1f60000` |
| MSS restart | `0x0c2b0000` | `aoss_reset` (`0xc2a0000`) + `0x10000` (`AOSS_CC_MSS_RESTART`) |
| PDC modem sync reset | `0x0b2e0100`, bit 9 | `pdc_reset` (`0xb2e0000`) + `0x100` |
| AOSS QMP mailbox | `0x0c300000`, IRQ SPI 389, doorbell `apss_shared` bit 0 | `aoss_qmp`; MSS uses it for `load_state` |
| APSS IPC doorbells | `0x1799000c`: bit 12 = GLINK modem, bit 14 = SMP2P modem, bit 0 = AOSS | `apss_shared: mailbox@17990000` (offset 12) |
| SMEM | `0x86000000`, 2 MiB; allocation lock = TCSR mutex 3 (`0x1f40000`) | `smem@86000000`, `tcsr_mutex` |
| SMP2P modem | SMEM items 435 / 428, IRQ SPI 451 (edge), doorbell bit 14 | `smp2p-mpss` |
| SMP2P bits | in: 0 fatal, 1 ready, 2 handover, 3 stop-ack, 7 shutdown-ack; out: 0 stop | `mss_pil` `interrupts-extended`, `qcom,smem-states` |
| GLINK modem edge | SMEM items 478 (descriptor), 479 (AP→modem FIFO), 480 (modem→AP FIFO); IRQ SPI 449; remote pid 1 | `mss_pil/glink-edge`; AOSP `qcom,glink-smem-native-xprt-modem` |
| MSS watchdog | IRQ SPI 266 | `mss_pil` `wdog` |
| MBA region | **`0x98500000`**, 2 MiB on blueline (generic SDM845: `0x96500000`) | `mba_region` override in `sdm845-google-common.dtsi`; AOSP `pil_mba_mem` |
| MPSS region | `0x8e000000`, `0x9800000` (152 MiB) on blueline | `mpss_region`; AOSP `pil_modem_mem` |
| WLAN MSA | `0x8df00000`, 1 MiB | `wlan_msa_mem` / AOSP `wlan_fw_region` |
| rmtfs shared buffer | `0xf2700000`, `0x202000` with guard pages, assigned to VMID 15 | `rmtfs_mem` in `sdm845-google-common.dtsi`; AOSP `qcom,rmtfs_sharedmem` (2 MiB, guard memory) |
| MPSS metadata buffer | any 16 KiB below 4 GiB (mainline allocates in `0xa0000000`-`0xc0000000`) | `mdata_mem` |
| WLAN copy engines | `0x18800000`, 8 MiB; CE*n* at `+0x240000 + n*0x1000` (n = 0..11), CE wrapper `+0x24c000` | `wifi@18800000` (`qcom,wcn3990-wifi`), AOSP `qcom,icnss@18800000`; offsets from `ath10k/hw.c` `wcn3990_regs` |
| WLAN IRQs | SPI 414-425, level high (one per CE) | same |
| Apps SMMU | `0x15000000` (MMU-500); WLAN stream ID `0x40`, mask `0x1` | `apps_smmu`, `iommus = <&apps_smmu 0x0040 0x1>` |
| GCC (MSS clocks) | base `0x00100000`: CBCRs `0x8a000` cfg_ahb, `0x8a154` q6_memnoc_axi, `0x8a150` snoc_axi, `0x8a004` mfab_axis; vote register `0x52004` bits 10 boot_rom_ahb, 13 prng_ahb, 17 gpll0_mss | `gcc-sdm845.c` |

RPMh resources (the kernel already votes `ldoa19` for touch through
`sweet_rpmh.c`; these would be new):

| Resource (cmd-db name) | Use | Value (Android) |
| --- | --- | --- |
| `cx.lvl`, `mx.lvl`, `mss.lvl` (ARC) | MSS proxy power domains `cx`, `mx`, `mss` | `RPMH_REGULATOR_LEVEL_TURBO` (AOSP `vdd_cx/mx/mss`); levels come from cmd-db aux data |
| `ldoa5` | WCN3990 `vdd-0.8-cx-mx` | 0.8 V |
| `ldoa7` | `vdd-1.8-xo` | 1.8 V |
| `ldoa17` | `vdd-1.3-rfa` | 1.304 V |
| `ldoa25` | `vdd-3.3-ch0` | 3.104-3.312 V (`qcom,vdd-3.3-ch0-config`) |
| `rfclka2` | WCN3990 `cxo_ref_clk_pin` (`RPMH_RF_CLK2`) | enable = 1 |
| S4A 1.8 V | `vddio` | no vote needed: mainline models it as a fixed, always-on supply (`vreg_s4a_1p8`) |

Mainline drives the four WCN3990 rails through a `qcom,wcn3990-pmu` power
sequencer (`vddxo` = l7a, `vddrf` = l17a, `vddch0` = l25a, `vddio` = s4a);
AOSP 4.9 lists them directly on the `icnss` node. Same rails either way.

### 1.3 Firmware and where it lives on the phone

All modem-side images must be the **phone's own Google-signed copies**; the
generic `qcom/sdm845/*.mbn` in linux-firmware are signed for open boards
(db845c) and will not authenticate on a retail Pixel 3.

| File | Location on the phone | Used by |
| --- | --- | --- |
| `mba.mbn` | `modem_a`/`modem_b` partition: FAT image labelled `NON-HLOS`, Android mounts it at `/vendor/firmware_mnt` (`device/google/crosshatch/fstab.hardware`), directory `image/` | AP copies it into the MBA region |
| `modem.mdt` + `modem.b00`..`bNN` | same `image/` | AP loads them into the MPSS region (pmOS merges them into `modem.mbn` with `pil-squasher`) |
| `wlanmdsp.mbn` | same `image/` | the **modem** fetches it over QRTR TFTP as `/readonly/firmware/image/wlanmdsp.mbn` (Android: `tftp_server`, mainline: `tqftpserv`) |
| `modemr.jsn`, `modemuw.jsn` | same `image/` | protection-domain lists for pd-mapper (can be hard-coded) |
| Board data `bdwlan.bin` | vendor image (Android's `cnss-daemon` sends it); exact path to be read from the backup | AP sends it with wlfw `BDF_DOWNLOAD`. pmOS keeps it as `wifi/bdwlan-blueline.bin`, matched by `bus=snoc,qmi-board-id=ff,qmi-chip-id=30214,variant=google_blueline` |
| `modemst1`, `modemst2`, `fsg`, `fsc` | raw partitions (check the GPT for A/B copies) | rmtfs: the modem's EFS (IMEI, RF calibration) |
| `ath10k/WCN3990/hw1.0/firmware-5.bin` | linux-firmware only | Linux feature flags (WMI-TLV op version); nothing to load, we hard-code the values |
| `/persist/WCNSS_qcom_wlan_nv.bin` | `persist` | Android's qcacld driver only; not needed |

Sources:
[pmaports `firmware-google-blueline`](https://gitlab.postmarketos.org/postmarketOS/pmaports/-/tree/main/device/testing/firmware-google-blueline)
(packages `mba.mbn`, `modem.mbn`, `wlanmdsp.mbn`, `modemr.jsn`... under
`qcom/sdm845/Google/blueline/`, and notes "it has working Wifi"),
[sdm845-mainline/firmware-google-pixel3](https://gitlab.com/sdm845-mainline/firmware-google-pixel3)
(`wifi/blueline-board.json`, "pulled from downstream and processed with
pil-squasher"), and
[linux-firmware `WHENCE`](https://gitlab.com/kernel-firmware/linux-firmware/-/blob/main/WHENCE)
(`ath10k/WCN3990/hw1.0/*`). Android starts `rmt_storage`, `tftp_server`,
`pd-mapper`, `cnss-daemon` and `irsc_util` for this
([`device/google/crosshatch/init.hardware.rc`](https://android.googlesource.com/device/google/crosshatch/+/refs/heads/android12-release/init.hardware.rc)).

`tools/pixel3-backup.sh` already copies every partition except `userdata`
(with `--essential` it skips `system`, `vendor` and `product`, so the board
data file needs the full backup or Google's factory image). The simplest plan is to copy
the files the kernel needs into the HFS+ root (for example
`/usr/standalone/firmware/sweet/`, added by the root build like the other
tweaks) and read them with vnode I/O after the root is mounted. Then the
kernel never has to read or write the modem partitions itself. These files
carry the IMEI and calibration data: keep them out of git like the other
backups.

### 1.4 What Linux does, step by step

**A. Boot the modem (MSS)**: mainline `drivers/remoteproc/qcom_q6v5_mss.c`,
`sdm845_mss` (`need_mem_protection = true`, `has_alt_reset = true`,
`version = MSS_SDM845`); AOSP 4.9 `pil-q6v5-mss.c` + `pil-msa.c`
(`qcom,pil-self-auth`, `qcom,mem-protect-id = <0xF>`).

On SDM845 the modem is **not** started through TrustZone's PAS interface
(`qcom_scm_pas_auth_and_reset`). PAS is what the ADSP, CDSP and SLPI use
(`qcom,pil-tz-generic`, `qcom,pas-id`). The modem is "self-authenticating":
its boot ROM (PBL) checks the **MBA** image, and the MBA checks the modem
image and programs the memory protection units (XPUs). TrustZone and the
hypervisor are involved only through **hyp-assign** SCM calls that move
memory between the HLOS virtual machine and the modem's.

1. `qcom_q6v5_prepare()`: interconnect vote, then the AOSS QMP message
   `{class: image, res: load_state, name: modem, val: on}` (AOSP:
   `qcom,signal-aop`, `mboxes = <&qmp_aop 0>`).
2. Proxy votes: power domains `cx`, `mx`, `mss` (RPMh ARC); proxy clocks
   `xo` (RPMh CXO), `prng`.
3. Reset clocks `iface` (mss_cfg_ahb), `snoc_axi`; then
   `q6v5_reset_deassert()` with the SDM845 alternate sequence: assert the PDC
   sync reset, write 1 to `RMB+0x44`, pulse the AOSS MSS restart, write 0,
   release the PDC reset.
4. Active clocks `bus` (q6_memnoc_axi), `mem` (boot_rom_ahb), `gpll0_mss`,
   `mnoc_axi`.
5. `q6v5_xfer_mem_ownership()` → `qcom_scm_assign_mem()`: give the MPSS
   region and the MBA region from `QCOM_SCM_VMID_HLOS` (3) to
   `QCOM_SCM_VMID_MSS_MSA` (15). This is SCM service `MP` (`0x0c`), command
   `ASSIGN` (`0x16`), i.e. SMCCC function ID `0x42000c16`, with source
   VMIDs, memory ranges and destination VMID/permission lists passed in a
   physically contiguous buffer (`qcom_scm_assign_mem()` in
   `drivers/firmware/qcom/qcom_scm.c`).
6. Copy `mba.mbn` (at most 1 MiB) into the MBA region; write its physical
   address to `RMB_MBA_IMAGE` (`+0x00`).
7. `q6v5proc_reset()`, SDM845 branch: set `CLKEN` in `QDSP6SS_SLEEP`
   (`+0x3c`) and wait for `CLKOFF` to clear; write 1 to
   `QDSP6SS_BOOT_CORE_START` (`+0x400`) and to `QDSP6SS_BOOT_CMD`
   (`+0x404`); poll `RMB_MBA_MSS_STATUS` (`+0x40`) bit 0 (boot FSM done);
   then poll `RMB_PBL_STATUS` (`+0x04`) for non-zero (1 = success).
8. Poll `RMB_MBA_STATUS` (`+0x0c`) for 1 (XPU unlocked) or 2 (unlocked,
   scribbled), at most 5 s. Negative values are MBA error codes.
9. `q6v5_mpss_init_image()`: copy the `.mdt` (ELF and program headers plus
   the hash/signature segment) into a buffer **below 4 GiB** (the RMB
   registers are 32-bit), hyp-assign it to the modem, write its address to
   `RMB_PMI_META_DATA` (`+0x10`), write 1 (`META_DATA_READY`) to
   `RMB_MBA_COMMAND` (`+0x08`), wait for status 3 (`META_DATA_AUTH_SUCCESS`),
   take the buffer back.
10. `q6v5_mpss_load()`: share the MPSS region (HLOS + MSS), copy each
    `PT_LOAD` segment (`modem.bNN`) to its `p_paddr`, zero-fill
    `p_memsz - p_filesz`. Before the first segment write the start address to
    `RMB_PMI_CODE_START` (`+0x14`) and 2 (`LOAD_READY`) to the command
    register; after each segment write the running total to
    `RMB_PMI_CODE_LENGTH` (`+0x18`) and check the status for a negative error.
11. Give the MPSS region to the modem only; wait for status 4
    (`AUTH_COMPLETE`), at most 10 s.
12. `qcom_q6v5_wait_for_start()`: SMP2P inbound bit 1 (`ready`) within 5 s;
    on bit 2 (`handover`) drop the proxy votes; reclaim the MBA region. If
    bit 0 (`fatal`) or the watchdog IRQ fires, the modem's crash reason is a
    string in **SMEM item 421** (`MPSS_CRASH_REASON_SMEM`).

**B. Transport**: mainline `drivers/soc/qcom/smem.c`, `smp2p.c`,
`drivers/rpmsg/qcom_glink_smem.c` + `qcom_glink_native.c`, `net/qrtr/`,
`drivers/soc/qcom/qmi_interface.c` + `qmi_encdec.c`; AOSP 4.9
`glink_smem_native_xprt.c`, `ipc_router_glink_xprt.c` (`qcom,ch-name =
"IPCRTR"`, `qcom,node-id = <1>`).

13. SMEM: header and partition table at `0x86000000`; the private partition
    between host 0 (apps) and host 1 (modem); allocations under TCSR mutex 3.
14. SMP2P: AP-owned outbound entry (`master-kernel`, bit 0 = stop) and the
    modem-owned inbound entry (`slave-kernel`, the bits above); AOSP also
    has an inbound `wlan` entry (bit 0 force-fatal, bit 1 early crash
    indication) that `icnss` watches.
15. GLINK: the AP allocates item 478 (32-byte descriptor) and item 479
    (16 KiB AP→modem FIFO); the modem provides item 480. Commands:
    `VERSION`/`VERSION_ACK`, `OPEN`/`OPEN_ACK` for channel `IPCRTR`,
    `INTENT`/`RX_INTENT_REQ` (receive buffers), `TX_DATA`/`TX_DATA_CONT`,
    `RX_DONE`. Doorbell bit 12, IRQ SPI 449.
16. QRTR on `IPCRTR`: version-1 packet header; control messages
    (`HELLO`, `NEW_SERVER`, `DEL_SERVER`, `NEW_LOOKUP`, `BYE`) to port
    `0xfffffffe`. The AP (node 1) runs the name service (`net/qrtr/ns.c`)
    and announces its own servers.
17. QMI on top: header (type 0 request / 2 response / 4 indication,
    transaction ID, message ID, length) and TLVs.

**C. Services the modem expects from the AP.** Android:
`rmt_storage`, `tftp_server`, `pd-mapper`. Mainline:
[linux-msm/rmtfs](https://github.com/linux-msm/rmtfs),
[tqftpserv](https://github.com/linux-msm/tqftpserv),
[pd-mapper](https://github.com/linux-msm/pd-mapper) (now also in-kernel,
`drivers/soc/qcom/qcom_pd_mapper.c`). All three linux-msm tools are
BSD-licensed C, 1,500-2,100 lines each.

18. **rmtfs**, QMI service 14 v1: `OPEN` with `/boot/modem_fs1`,
    `/boot/modem_fs2`, `/boot/modem_fsc`, `/boot/modem_fsg` → partitions
    `modemst1`, `modemst2`, `fsc`, `fsg`; `ALLOC_BUFF` answers with the
    physical address of the shared buffer (`rmtfs_mem`, hyp-assigned to
    VMID 15); `RW_IOVEC` copies sectors between partition and buffer. rmtfs
    has a read-only mode that keeps the modem's writes in RAM shadow
    buffers.
19. **Service locator** (pd-mapper), QMI service `0x40` v`0x101`:
    `GET_DOMAIN_LIST("wlan/fw")` must answer `msm/modem/wlan_pd`, instance
    180 (`sdm845_domains` in `qcom_pd_mapper.c`; the modem's own `.jsn`
    files hold the same).
20. **TFTP over QRTR**, port/service 4096 v1: read requests for
    `/readonly/firmware/image/wlanmdsp.mbn` (and others), write requests
    under `/readwrite/` (for example `server_check.txt`).

The modem then starts the WLAN protection domain, which publishes QMI
service `WLFW` (`0x45`, version 1).

**D. WLAN**: mainline `drivers/net/wireless/ath/ath10k/snoc.c`, `qmi.c`,
`qmi_wlfw_v01.c`, `ce.c`, `htc.c`, `wmi-tlv.c`, `htt_*.c`; AOSP 4.9
`drivers/soc/qcom/icnss.c` (Android's WLAN driver itself, qcacld-3.0, lives
outside the kernel tree).

21. Power up WCN3990: the four rails above plus `RPMH_RF_CLK2`
    (`ath10k_hw_power_on()`). No reset GPIO.
22. `qmi_add_lookup(WLFW, v1)`; on `NEW_SERVER` connect (client ID
    `0x4b4e454c`).
23. `ath10k_qmi_event_server_arrive()`: `IND_REGISTER` (`0x20`) →
    `HOST_CAP` (`0x34`; blueline needs `qcom,snoc-host-cap-8bit-quirk`) →
    `MSA_INFO` (`0x2d`, MSA at `0x8df00000` + 1 MiB; the firmware returns its
    memory regions) → sleep 20 ms (the driver notes that an earlier XPU
    update "crashes SDM845 due to a security violation") → hyp-assign each
    region from HLOS to `MSS_MSA` (15), `WLAN` (`0x18`) and, if not secure,
    `WLAN_CE` (`0x19`) → `MSA_READY` (`0x2e`).
24. On `MSA_READY_IND` (`0x2b`): `CAP` (`0x24`: chip ID, board ID `0xff`,
    SoC ID, firmware build) → `BDF_DOWNLOAD` (`0x25`, chunks of up to
    6 KiB) → `CAL_REPORT` (`0x26`). On Android `icnss.c` has no BDF code;
    `cnss-daemon` does this part.
25. `FW_READY_IND` (`0x21`).
26. `ath10k_snoc_hif_power_up()`: `WLAN_CFG` (`0x23`: target CE pipe
    configuration, service-to-pipe map, shadow registers) + `WLAN_MODE`
    (`0x22`, `MISSION`), then CE init and interrupts.
27. Copy engines: 12 rings at the addresses above, ring memory in DDR
    reached through SMMU stream `0x40`; CE read indices live in DDR
    (`rri_on_ddr`); shadow registers instead of direct writes.
28. HTC → WMI (TLV variant: service ready, ready event), HTT for data.
    From here on it is a normal ath10k station: scan, auth/assoc frames
    built by the host (mac80211), peer/vdev WMI commands, key installation,
    HTT TX/RX. Hardware parameters: `wcn3990 hw1.0` in `ath10k/core.c`
    (`target_64bit`, `shadow_reg_support`, `rri_on_ddr`,
    `n_cipher_suites = 11`).

**SMMU.** Mainline gives the WLAN device an IOVA domain on the apps SMMU;
AOSP 4.9 uses stage-1 bypass (`qcom,smmu-s1-bypass`) and an IOVA window at
`0xa0000000` (`smmu_iova_base`, 256 MiB). XNU has no SMMU driver yet (UFS
works without one because its node has no `iommus`). The minimum is one
stream match (SMR id `0x40`, mask `0x1`) pointing at a context bank with
translation off. On Qualcomm firmware the hypervisor may turn a "bypass"
S2CR write into "fault"; mainline's `qcom_smmu_cfg_probe()` detects that and
emulates bypass with a reserved context bank (`SCTLR = 0`,
`CBAR_TYPE_S1_TRANS_S2_BYPASS`). Copying that logic is about 200-300 lines.

**Physical addresses.** On blueline the kernel uses only the upper DDR bank
(`--highmem`, `0x100000000` + 2 GiB). Everything the modem must address
through 32-bit RMB registers (MBA, metadata, MPSS) has to be in the low bank,
and the fixed carve-outs above already are. The rest of the low bank (between
`0xa1c11000` and `0xf2700000`, minus whatever ABL used for the payload) is
not touched by XNU, so the driver can keep a private DMA pool there for QMI
buffers, CE rings and RX buffers. That also avoids any doubt about the WLAN
DMA address width. Memory handed to the modem must never be accessed by
the AP afterwards: the hypervisor's stage-2 tables fault the access.

**Interrupts.** No ios-sweet driver uses interrupts yet; UFS, touch, keys
and USB are all polled. Polling SMP2P and the GLINK FIFO indices every
1-10 ms is enough for bring-up; the copy engines can be polled as well at
first. Real GIC SPI wiring can come later.

---

## 2. The iOS side

### 2.1 What the iPhone X has

- Wi-Fi is a **Broadcom BCM4357** module (`module-instance = 'herculese'`)
  on PCIe (`/arm-io/apcie`, port 3, behind DART `dart-apcie3`), with
  Bluetooth on a UART. The D22AP device tree (`research/ipsw-x/d22ap.adt`)
  has `/arm-io/uart*/wlan` (`compatible = 'wlan-pcie-uart,bcm4357'`,
  `local-mac-address` filled by iBoot from syscfg `WMac`, about 30 `wlan.*` and
  `bcom.*` tuning properties) and `/arm-io/apcie/.../wlan`
  (`compatible = 'wlan-pcie,bcm4357'`). `/product` has
  `wifi-chipset = '4357'`, `/chosen` a `mac-address-wifi0` placeholder.
- The 16.6.1 kernelcache (`kernelcache.release.iphone10b` in the IPSW)
  contains `com.apple.iokit.IO80211Family`, `com.apple.iokit.IOSkywalkFamily`,
  `com.apple.iokit.IONetworkingFamily`, `com.apple.driver.AppleBCMWLANCore`
  (+ `AppleBCMWLANCoreV3`), `AppleBCMWLANBusInterfacePCIe` and
  `BCMWLANFirmware4357`, with classes such as `IO80211Controller`,
  `IO80211SkywalkInterface`, `IO80211InfraInterface`,
  `IO80211VirtualInterface`, `IO80211APIUserClient`,
  `IO80211AsyncEventUserClient` and `AppleBCMWLANSkywalkInterface`. Our
  kernel is built from xnu source and loads none of Apple's kexts.

### 2.2 How userspace finds and drives Wi-Fi

From the 16.6.1 binaries (`/usr/sbin/wifid` load commands, strings in the
dyld shared cache) and configd's source:

- **wifid** links `IO80211.framework` (the Apple80211 API:
  `Apple80211Open`, `Apple80211BindToInterface(WithParams)`,
  `Apple80211Get`/`Set`, `Apple80211EventMonitoringInit`), plus
  `MobileWiFi`, `CoreWiFi`, `WiFiPolicy` and `EAP8021X`.
- **IO80211.framework** looks the driver up with
  `IOServiceGetMatchingServices("IO80211Controller")` and recognises it by
  `IOClass` (`AppleBCMWLANCore`, `AirPort_BrcmNIC` or `ACIWiFiDriver`),
  falling back to DriverKit matching ("No Matches for IO80211Controller,
  trying dk matching"). Its `io80211.iouc` logging and the kernel's
  `IO80211APIUserClient` / `IO80211AsyncEventUserClient` classes suggest
  that requests and events go through IOKit user clients rather than only
  through the old `SIOCGA80211`/`SIOCSA80211` ioctls (not yet confirmed by
  disassembly). The exact selectors would have to be reversed like the
  IOMobileFramebuffer and IOSurface ones were.
- **CoreWiFi** watches for interfaces with
  `IO80211InterfaceRole = Infrastructure` (`IOServiceMatched` /
  `IOPropertyMatch` / `IOServiceTerminate`).
- **MobileWiFi** decides "WiFi: no WiFi Hardware!" from the
  `IOPlatformExpertDevice` properties `software-behavior` /
  `no-sdio-devices` and the presence of an `IO80211Controller`.
- **configd** (`SCNetworkInterface.c` in
  [configd-1241.140.6](https://github.com/apple-oss-distributions/configd/blob/configd-1241.140.6/SystemConfiguration.fproj/SCNetworkInterface.c)):
  network interfaces come from IOKit `IONetworkInterface` objects
  (`IOInterfaceType`, `BSD Name`, `IOInterfaceNamePrefix`,
  `IOInterfaceUnit`, `IOBuiltin`, `IOPrimaryInterface`, and the
  controller's `IOMACAddress`). An `IFT_ETHER` interface counts as Wi-Fi
  (`kSCNetworkInterfaceTypeIEEE80211`) only if its controller conforms to
  `IO80211Controller`, `AirPortPCI` or `AirPortDriver`; otherwise it is
  Ethernet. This is the same lookup that currently ignores `ue0`
  (`NOTES.md`, image v15).
- **WPA.** Apple's stack expects the driver/firmware side to run the WPA-PSK
  4-way handshake once wifid hands it the network and key through Apple80211;
  802.1X/EAP runs in `EAP8021X`/eapolclient. (Inferred from the macOS
  re-implementation in [OpenIntelWireless/itlwm](https://github.com/OpenIntelWireless/itlwm),
  whose `AirportItlwm` does the handshake in the driver with OpenBSD net80211;
  not verified on iOS 16.)

### 2.3 Option A: native Wi-Fi (`IO80211Controller`)

What it takes:

1. Either reimplement the parts of `IO80211Family` and `IOSkywalkFamily`
   that wifid, CoreWiFi, configd and the network stack touch (controller,
   Skywalk infrastructure interface, both user clients, the event and
   request formats), or load Apple's own kext binaries from the kernelcache
   into our kernel (needs a kext linker for the fileset format and exact
   symbol and structure compatibility with our xnu-8796 build, which has
   Skywalk's BSD side compiled in but no IOKit side).
2. Then write an `AppleBCMWLANCore`-like `IO80211Controller` subclass on top
   of the WCN3990 driver that answers hundreds of Apple80211 request types
   (`apple80211_ioctl.h` in itlwm alone is 48 KB of reversed definitions)
   and handles scanning, joining, roaming, power saving and WPA.

The closest precedent is `AirportItlwm` on macOS, which runs with Apple's
real IO80211 kexts present and still needed a large rework for the
Skywalk-based family in macOS 14. **Verdict: not before Option B works, and
probably never.** It adds nothing to connectivity, only the Settings UI.

### 2.4 Option B: Ethernet-like `en0` (recommended)

- **Kernel network interface.** An `IFT_ETHER` ifnet named `en0`, created
  like `ue0` in `sweet_usb.c` (patch 0075/0076: `ifnet_allocate_extended`,
  legacy output, one cluster mbuf per received frame, link events from
  0081). The WLAN driver converts frames: TX 802.3 → 802.11 (or lets the
  firmware do it: ath10k's `frame_mode=2` sets the vdev parameter
  `tx_encap_type` to Ethernet), RX native-Wi-Fi → 802.3 (strip the 802.11
  header and LLC/SNAP, rebuild the Ethernet header).
- **IOKit.** The same stand-ins `ue0` needs: an `IOEthernetController`-like
  controller with a MAC address and an `IONetworkInterface`/
  `IOEthernetInterface` child carrying `IOInterfaceType` 6, `BSD Name`
  `en0`, `IOInterfaceNamePrefix` `en`, `IOInterfaceUnit` 0, `IOBuiltin`
  true. Two ways: port Apple's
  open-source [IONetworkingFamily-188](https://github.com/apple-oss-distributions/IONetworkingFamily)
  as was done for IOHIDFamily (patch 0058), or write minimal classes with
  just the properties configd reads. Solve it for `ue0` first; Wi-Fi then
  reuses it unchanged.
- **IP configuration.** configd's preferences (`preferences.plist`, as in
  image v15) with an Ethernet service on `en0`, DHCP by default. iOS already
  supports USB Ethernet adapters as wired networks, so apps get a working
  default route. The Wi-Fi page in Settings stays off because there is no
  `IO80211Controller`; wifid keeps reporting "no WiFi Hardware" (harmless;
  its launchd job can be removed like CommCenter's if it loops).
- **Choosing the network and WPA.** No iOS UI, so the SSID and passphrase
  come from a root-owned plist in the image (for example
  `/private/var/preferences/sweet-wifi.plist`, written by
  `sweet-root-tweaks.py` from a host-side argument and never committed), or
  a boot-arg during bring-up. Two ways to do the handshake:
  - **In the kernel (recommended):** OpenBSD's net80211 (ISC/BSD license)
    already has station MLME, the 802.1X PAE (`ieee80211_pae_input.c`/
    `_output.c`: 4-way and group-key handshakes) and PSK derivation, and
    itlwm has ported it to the XNU environment (`itl80211/openbsd/net80211`,
    about 33,000 lines in total, of which maybe half is needed: no AP mode,
    mesh or rate-control variants). Keys go to the hardware with WMI
    `VDEV_INSTALL_KEY` (CCMP is done by the hardware).
  - **In userspace:** a port of `wpa_supplicant` (BSD license) with BPF for
    EAPOL frames and a private ioctl for keys. That means building and
    launching our own iOS binary, which nothing in this project does yet.
  Open networks first, then WPA2-PSK. WPA3-SAE and 802.1X are out of scope.

---

## 3. Staged plan

Each stage is separate kernel code behind a boot-arg (for example
`sweetwlan=N` = run up to stage N, 0 = off). Sizes are new lines of C/C++
in the kernel and rough. "Port" means adapting ISC/BSD-licensed code.

**Licensing.** ath10k (ISC), OpenBSD net80211 (ISC/BSD) and the
linux-msm tools rmtfs, pd-mapper, tqftpserv, qrtr and the QMI IDL compiler
qmic (BSD) can be ported into the APSL kernel. Linux's
`qcom_q6v5_mss.c`, `smem.c`, `smp2p.c`, GLINK, QRTR and `qmi_encdec.c` are
GPL-2.0: use them as documentation and write our own code, as was done for
UFS, GENI and USB.

| Stage | What | Size | Proof in the persistent log |
| --- | --- | --- | --- |
| 0 | **Facts and files, no kernel code.** From the backup: extract `mba.mbn`, `modem.mdt/.bNN`, `wlanmdsp.mbn`, `*.jsn` from the `modem_a` FAT image, locate `bdwlan.bin` in the vendor image; check the live DT for `qcom,mss@4080000`, `qcom,icnss@18800000`, `rmtfs_sharedmem` and the reserved-memory addresses above; save Android's `dmesg` after a fresh boot (icnss/PIL lines, board/chip ID). Root build copies the files into the image. | ~100 lines of shell/Python | n/a (host side) |
| 1 | **Modem boots.** SMC helper + hyp-assign; RPMh ARC votes (`cx.lvl`, `mx.lvl`, `mss.lvl`, needs the cmd-db aux level table) and the new LDO/RF-clock resources in `sweet_rpmh.c`; GCC clock votes; AOSS QMP message; resets; MBA and MPSS loading through the RMB; read-only SMP2P and SMEM item 421. | 1,500-2,500 | `SWEET MSS: assign mpss/mba ok` (SCM return codes), `pbl status 0x1`, `mba status 0x1`, `meta auth 0x3`, `auth complete 0x4`, `smp2p in 0x2` (ready) then `0x6` (handover); on failure `crash reason: <string from item 421>` or the first negative RMB status |
| 2 | **Transport.** SMEM partition reader/allocator with the TCSR mutex; SMP2P; GLINK over SMEM with intents; QRTR with the name service; a table-driven QMI TLV encoder/decoder (or qmic-generated code from the linux-msm `.qmi` files). | 2,500-3,500 | `SWEET GLINK: version 1 features ...`, `open IPCRTR`; `SWEET QRTR: hello from node 0`; one `NEW_SERVER service S version V instance I node N port P` line per modem service; no `fatal` bit for 10 minutes |
| 3 | **AP services.** rmtfs server (files from the root, writes kept in RAM like rmtfs's read-only mode, so the real EFS is never written), service locator with the SDM845 domain table, TFTP server for `/readonly/firmware/image/*` from the firmware directory and an in-memory `/readwrite/`. | 1,500-2,000 (port of the BSD tools) | `SWEET RMTFS: open /boot/modem_fs1 → id 1`, `iovec read N sectors`; `SWEET PDM: wlan/fw → msm/modem/wlan_pd 180`; `SWEET TFTP: RRQ /readonly/firmware/image/wlanmdsp.mbn N bytes`; then **`NEW_SERVER service 0x45`** (WLAN firmware is up) |
| 4 | **WLAN firmware ready.** Rails + RF clock; wlfw client (IND_REGISTER, HOST_CAP 8-bit quirk, MSA_INFO + hyp-assign, MSA_READY, CAP, BDF, CAL_REPORT, WLAN_CFG, WLAN_MODE); SMMU stream `0x40`; copy engines (polled); HTC; WMI-TLV init up to service ready / ready event. | 4,000-6,000 (port of ath10k `snoc.c`, `qmi*.c`, `ce.c`, `htc.c`, parts of `wmi-tlv.c`) | `SWEET WLAN: cap chip 0x30214 board 0xff soc ... fw <build>`, `bdf N bytes ok`, `fw ready`, `htc ready`, `wmi service ready: fw <version> ...`, `wmi ready mac xx:xx:...` |
| 5 | **Station mode.** WMI scan and management RX; auth/assoc; vdev/peer setup; HTT TX/RX; key install; WPA2-PSK through net80211; `en0` ifnet with 802.3 conversion. | 3,000-5,000 own + ~15,000 ported (net80211 subset) | `SWEET WLAN: scan: <ssid> ch C rssi R` per network; `assoc <bssid> ok aid N`; `eapol 4/4 done, ptk installed`; then the existing `SWEET NET:` lines (0080) show the address and default route on `en0` |
| 6 | **iOS integration.** IOKit controller/interface for `en0` (shared with `ue0`); configd preferences with DHCP; SSID/passphrase plist; disable wifid's job if it crash-loops. | 500-1,500 (much less if `ue0` is already done) | `SWEET NET: configd route add 0.0.0.0 gw ... ifindex <en0>`; DHCP traffic visible on the router; a page loads in Safari |

Notes on verification:

- Read the log with TWRP and `tools/sweet-log-pull.sh` as in
  `docs/PIXEL3.md`. The log is flushed every `ufslogsecs` seconds
  (default 10, patch 0069), so for stages 1-4 boot with `ufslogsecs=1`:
  modem failures can reset the whole SoC (XPU violations), and the last
  seconds before a reset are the interesting ones.
- If USB device mode works on blueline (`docs/PIXEL3.md`, open question 6),
  the live UDP log of patch 0077 (`sweetusb=2`, `tools/sweet-usbnet.sh`)
  removes the TWRP round-trip from every test. Worth checking before
  stage 1.
- The modem does not write to our console. Its view of a failure is
  the RMB status, the SMP2P bits and the crash-reason string in SMEM item
  421; log all three. A QMI DIAG client for modem logs is not planned.
- Stages 1-3 can be compared line by line with mainline Linux on the
  same phone (pmOS `google-blueline`, `dmesg` with `qcom_q6v5_mss`,
  `qrtr`, `ath10k_snoc` debug enabled): same firmware, same order.
- Stage 1 alone answers the biggest open question. If the hypervisor or
  MBA refuses us there, nothing after it matters.

### Risks

| Risk | Likelihood | Effect | Mitigation |
| --- | --- | --- | --- |
| Hyp-assign SCM calls fail or are refused from XNU (calling convention, argument buffer layout, or memory the hypervisor thinks is mapped) | medium | Stage 1 blocked | Copy `qcom_scm_assign_mem()`'s buffer layout exactly; buffers below 4 GiB; log the SMC return values; compare with Linux's sequence on the same phone |
| MBA refuses to boot or authenticate (`RMB` status negative, PBL timeout), e.g. a missed clock/power vote or the SDM845 alt-reset order | medium | Stage 1 blocked | Follow `q6v5_mba_load()` step by step; dump `QDSP6SS`/`RMB` registers; the images themselves are the phone's own and do authenticate under Linux |
| XPU/security violation resets the SoC (ath10k has a 20 ms "HACK" sleep for one such case) | medium | Silent reboots | `ufslogsecs=1`, one step per boot, same delays as Linux |
| The modem wants more AP services than rmtfs, pd-mapper and TFTP (Android also runs `cnss-daemon`, `irsc_util`, `modem_svc`, IPA, SSCTL/sysmon) and crashes after a while | medium | Unstable modem | Log every `NEW_LOOKUP` the modem sends; answer with stubs. Mainline/pmOS runs rmtfs, tqftpserv and pd-mapper, with IPA enabled in the blueline DT (IPA may need a stub) |
| RPMh ARC level votes wrong (cmd-db aux data, MSS needs `TURBO`) | medium | Modem hangs at PBL/MBA | Read the level table from cmd-db like `rpmhpd.c`; vote the maximum during bring-up |
| SMMU: the hypervisor blocks the stream-0x40 programming or bypass | medium | No WLAN DMA | Bypass context bank as in mainline's quirk; fall back to a real stage-1 table identity-mapping the private DMA pool |
| QMI/GLINK/QRTR complexity (fragmentation, intents, nested TLVs, 6 KiB BDF messages) | high effort, low risk | Time | Table-driven codec or qmic-generated code; test the codec on the host against captured messages |
| EFS corruption (IMEI/calibration) through a buggy rmtfs | low with the read-only design | Permanent damage to radio data | Serve copies from the root, keep writes in RAM, never open the real partitions; backups from `pixel3-backup.sh` |
| 2 GiB of RAM for iOS minus the private DMA pool | low | Memory pressure | Pool of 32-64 MiB in the low bank, outside XNU's memory |
| iOS side: configd still ignores the interface (the `ue0` problem) | high until `ue0` is solved | No IP on `en0` | Solve it for `ue0` first (stage 6 depends on it, not on Wi-Fi) |
| Native Wi-Fi UI expected by users | certain | Settings shows Wi-Fi off | Document it; Option A only as a separate research project |
| Regulatory | low | Transmitting outside the allowed channels | Use the phone's own BDF (it carries Google's regulatory data) and set the country code from the firmware's default; start with scanning only |

### Not covered

- **Bluetooth.** WCN3990's Bluetooth is a separate path: UART6 (HCI) with
  its own firmware (`crbtfw21.tlv`, `crnv21.bin`), sharing only the power
  rails. It does not need the modem. On the iOS side, bluetoothd expects
  Apple's Bluetooth controller, which is a separate study.
- **Cellular** uses the same modem bring-up (stages 1-3), plus IPA and the
  QMI services CommCenter would need. Stages 1-3 would be the shared
  foundation for both.
- **GPU** (Adreno 630 Metal driver): judged unrealistic, see
  `site/future.html`.
