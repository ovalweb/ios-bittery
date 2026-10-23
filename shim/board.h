#pragma once
/*
 * Per-phone constants the shim needs before it reads any device tree.
 * build.sh BOARD=sweet (default) or BOARD=blueline (-DBOARD_BLUELINE).
 * Everything else (GIC, PSCI, UFS, PSHOLD) is the same on SM7150 and SDM845.
 */

#if defined(BOARD_BLUELINE)
/* Google Pixel 3, SDM845: sdm845.dtsi / sdm845-b1c1 DTS in android-msm-crosshatch-4.9 */
#define BOARD_NAME		"blueline"
#define FB_BASE			0x9d400000UL	/* reserved-memory cont_splash_region */
#define FB_W			1080
#define FB_H			2160
#define IMEM_RESTART_REASON	0x146bf65cUL	/* qcom,msm-imem@146bf000 restart_reason@65c */
/*
 * The LG SW43408 is a DSC command-mode panel: the MDP only sends a frame
 * when kicked, so writes to the splash buffer would never reach the glass.
 * display_prepare() sets PINGPONG autorefresh (sde_hw_pingpong.c,
 * PP_AUTOREFRESH_CONFIG = BIT(31) | frame count) on the ping-pong blocks
 * ABL left running, so the panel refetches the buffer on every TE like a
 * video-mode panel. qcom,sde-pp-off in sdm845-sde.dtsi, relative to mdp_phys.
 */
#define MDP_BASE		0x0ae00000UL
#define MDP_PP_OFFSETS		{0x71000, 0x71800, 0x72000, 0x72800}
/* Refuse to start xnu on RAM the live FDT does not show as free DDR. */
#define BOARD_STRICT_MEMCHECK	1
/*
 * Resets land in fastboot (ios-flame shim): PM8998 PON on SID 0, reason in
 * SOFT_RB_SPARE [7:1] (Linux qcom-pon gen2, bootloader = 2), PS_HOLD made a
 * hard reset; the APSS watchdog (qcom,apss-wdt-sdm845) bites a hung kernel,
 * which pets it while threads run (ADT /sweet-watchdog).
 */
#define BOARD_PON_REBOOT	1
#define WDT_BASE		0x17980000UL
#define WDT_BITE_S		30
#else
/* Xiaomi Redmi Note 10 Pro, SM7150 */
#define BOARD_NAME		"sweet"
#define FB_BASE			0x9c000000UL	/* reserved-memory cont_splash_region */
#define FB_W			1080
#define FB_H			2400
#define IMEM_RESTART_REASON	0x146aa65cUL	/* qcom,msm-imem restart_reason@65c */
/* Video-mode panel: no display preparation. Memory check reports only. */
#define BOARD_STRICT_MEMCHECK	0
#endif

#define FB_STRIDE		(FB_W * 4)	/* a8r8g8b8, matches mainline simplefb */
#define PSHOLD			0x0c264000UL
