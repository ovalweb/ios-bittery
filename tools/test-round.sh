#!/bin/bash
# One unattended Pixel 3 test round:
#   test-round.sh SERIAL IMAGE LOG [MINUTES]
# RAM-boots IMAGE (phone must be in fastboot), waits up to MINUTES (default 8)
# for the phone to come back in fastboot (a crash or reset ends there), then
# RAM-boots TWRP, pulls the kernel log ring into LOG and returns the phone to
# the bootloader. If the phone is still running iOS at the deadline, it stops
# and says so: put it in the bootloader by hand and run with MINUTES=0.
set -euo pipefail
S=$1 IMG=$2 LOG=$3 MIN=${4:-8}
REPO=$(cd "$(dirname "$0")/.." && pwd)
TWRP=$REPO/recovery/twrp-3.7.1_12-0-blueline.img

in_fastboot() { fastboot devices | grep -q "^$S"; }
in_adb() { adb devices | grep -q "^$S[[:space:]]*recovery"; }

if [ "$MIN" != 0 ]; then
	in_fastboot || { echo "phone $S not in fastboot" >&2; exit 1; }
	fastboot -s "$S" boot "$IMG" | tail -1
	echo "booted $(basename "$IMG") at $(date +%H:%M:%S); waiting up to $MIN min for a return to fastboot"
	sleep 30        # it leaves fastboot right away
	end=$(( $(date +%s) + MIN * 60 ))
	until in_fastboot; do
		if [ "$(date +%s)" -ge "$end" ]; then
			echo "still running after $MIN min (no reset): put it in the bootloader, then: $0 $S $IMG $LOG 0"
			exit 2
		fi
		sleep 5
	done
	echo "back in fastboot at $(date +%H:%M:%S)"
fi
fastboot -s "$S" boot "$TWRP" | tail -1
for _ in $(seq 1 60); do in_adb && break; sleep 3; done
in_adb || { echo "TWRP adb did not come up" >&2; exit 1; }
"$REPO/tools/sweet-log-pull.sh" -s "$S" "$LOG" 2>&1 | tail -1
adb -s "$S" reboot bootloader
for _ in $(seq 1 30); do in_fastboot && break; sleep 2; done
echo "log: $LOG ($(wc -l < "$LOG") lines); phone in fastboot: $(in_fastboot && echo yes || echo no)"
