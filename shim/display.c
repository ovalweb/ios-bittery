/*
 * Command-mode panels (board.h MDP_BASE): turn on PINGPONG autorefresh so the
 * MDP refetches the splash framebuffer on every tear-check (TE) event.
 *
 * ABL draws its splash and leaves the display pipe it set up running:
 * SSPP -> layer mixer -> ping-pong -> DSC -> DSI. On a video-mode panel
 * (sweet) the timing engine scans the buffer out continuously. On a
 * command-mode panel (Pixel 3) a frame is only sent when software kicks
 * the CTL, so nothing drawn after ABL would ever show. Linux keeps the
 * same thing in sde_hw_pingpong.c: PP_AUTOREFRESH_CONFIG (0x30) =
 * BIT(31) enable | frame count (1 = every TE).
 *
 * Only ping-pong blocks with tear check enabled (PP_TEAR_CHECK_EN, 0x00,
 * bit 0), i.e. driving a command-mode interface, are touched. MDSS is
 * powered and clocked because ABL is still showing its splash.
 */
#include <stdint.h>
#include "console.h"
#include "display.h"

#define PP_TEAR_CHECK_EN	0x000
#define PP_AUTOREFRESH_CONFIG	0x030
#define PP_AUTOREFRESH_EN	(1U << 31)

#if defined(MDP_BASE)
static const uint32_t pp_off[] = MDP_PP_OFFSETS;
#define NR_PP	(sizeof(pp_off) / sizeof(pp_off[0]))
static uint32_t pp_te[NR_PP], pp_before[NR_PP], pp_after[NR_PP];

static inline uint32_t rd32(uintptr_t a) { return *(volatile uint32_t *)a; }
static inline void wr32(uintptr_t a, uint32_t v) { *(volatile uint32_t *)a = v; }

void display_prepare(void)
{
	for (unsigned i = 0; i < NR_PP; i++) {
		uintptr_t pp = MDP_BASE + pp_off[i];
		pp_te[i] = rd32(pp + PP_TEAR_CHECK_EN);
		pp_before[i] = rd32(pp + PP_AUTOREFRESH_CONFIG);
		if ((pp_te[i] & 1) && !(pp_before[i] & PP_AUTOREFRESH_EN)) {
			wr32(pp + PP_AUTOREFRESH_CONFIG, PP_AUTOREFRESH_EN | 1);
			__asm__ volatile("dsb sy" ::: "memory");
		}
		pp_after[i] = rd32(pp + PP_AUTOREFRESH_CONFIG);
	}
}

void display_report(void)
{
	int active = 0;
	for (unsigned i = 0; i < NR_PP; i++) {
		char label[] = "PP0";
		label[2] = (char)('0' + i);
		if (!(pp_te[i] & 1))
			continue;
		active++;
		con_hex2(label, "auto=", pp_before[i], "now=", pp_after[i]);
	}
	if (!active)
		con_str("DISPLAY", "no tear-check PP: video mode?");
}
#else
void display_prepare(void)
{
}

void display_report(void)
{
}
#endif
