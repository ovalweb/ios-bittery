#!/bin/bash
# Install the Wi-Fi stack (phone/wifi: wland, from ios-flame) and its
# firmware into the running iOS root over the kernel file server.
#
#   tools/install-wifi.sh FWDIR
#
# FWDIR (never in the repository) holds:
#   modem/   the radio's mba.mbn, modem.mdt, modem.bNN, modemr.jsn (modem_a)
#   wlan/    wlanmdsp.mbn, modemuw.jsn, bdwlan-blueline.bin (vendor /firmware)
#   rmtfs/   this phone's modemst1.img, modemst2.img, fsg.img, fsc.img
#            (IMEI and calibration: private, phone only)
# wland: SOC=sdm845 phone/wifi/build.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
FW=${1:?usage: tools/install-wifi.sh FWDIR}
F="python3 tools/flame-files.py"
W=phone/wifi/out/wland
[ -f $W ] || { echo "$W missing (SOC=sdm845 phone/wifi/build.sh)" >&2; exit 1; }
for d in /var/local /var/local/bin /var/local/fw /var/local/fw/modem /var/local/fw/rw; do
	$F mkdir $d 755 2>/dev/null || true
done
$F mkdir /var/local/fw/rmtfs 700 2>/dev/null || true
for f in "$FW"/modem/* "$FW"/wlan/wlanmdsp.mbn "$FW"/wlan/modemuw.jsn "$FW"/wlan/bdwlan-blueline.bin; do
	$F put "$f" /var/local/fw/modem/"$(basename "$f")" 644
done
for f in "$FW"/rmtfs/{modemst1,modemst2,fsg,fsc}.img; do
	$F put "$f" /var/local/fw/rmtfs/"$(basename "$f")" 600
done
# a fresh file, not a rewrite in place (see install-ssh.sh)
$F rm /var/local/bin/wland 2>/dev/null || true
$F put $W /var/local/bin/wland 755
echo "installed; on the phone: wland up 120 > /var/local/wland.log 2>&1"
