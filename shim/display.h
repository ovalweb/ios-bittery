#pragma once

/* Make the splash framebuffer reach the panel (board.h: command-mode panels). */
void display_prepare(void);
/* Show what display_prepare() found; needs the console. */
void display_report(void);
