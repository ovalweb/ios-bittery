/*
 * SoC constants of the Wi-Fi stack. Default: SM8150 (ios-flame, Pixel 4).
 * -DSOC_SDM845: the Pixel 3 (values from its live FDT and mainline
 * sdm845.dtsi / sdm845-google-common.dtsi).
 */
#ifndef SOC_H
#define SOC_H

#if defined(SOC_SDM845)
#define SOC_NAME	"sdm845"
#define APCS_IPC	0x1799000cull	/* apss_shared (mailbox@17990000) + 12 */
#define MPSS_PA		0x8e000000ull	/* pil_modem_mem */
#define MPSS_SIZE	0x09800000ull
#define MBA_PA		0x98500000ull	/* pil_mba_mem */
#define MBA_SIZE	0x00200000ull
#define MDATA_PA	0xf0400000ull	/* modem metadata: free DDR below 4 GB (RMB registers are 32 bits) */
#define MSA_PA		0x8df00000ull	/* wlan_fw_region */
#define WLAN_SID	0x040		/* wifi@18800000 iommus <&apps_smmu 0x40 0x1> */
#define MSS_SELF_AUTH	1		/* qcom,pil-self-auth: MBA, not TrustZone PAS */
/* WCN3990 supplies (PM8998, PMIC4 LDO HPM = 7): cx-mx, xo, rfa, ch0 */
#define WLAN_LDOS	{ "ldoa5", 800 }, { "ldoa7", 1800 }, { "ldoa17", 1304 }, { "ldoa25", 3300 }
#define WLAN_QDSS_QMP	0		/* no QDSS clock message on SDM845 */
#else
#define SOC_NAME	"sm8150"
#define APCS_IPC	0x17c0000cull	/* apss_shared + 12: write BIT(n) */
#define MPSS_PA		0x8dc00000ull	/* flame modem_region */
#define MPSS_SIZE	0x0b400000ull
#define MSA_PA		0x8bc00000ull	/* pil_wlan_fw_region */
#define WLAN_SID	0x640
#define MSS_SELF_AUTH	0
#define WLAN_LDOS	{ "ldoa1", 752 }, { "ldoa7", 1800 }, { "ldoc2", 1304 }, { "ldoc11", 3104 }
#define WLAN_QDSS_QMP	1
#endif

#endif
