#!/bin/bash
# Install SSH (dropbear) and a shell (dash) into the running iOS root over the
# kernel file server (tools/flame-files.py through FlameBridge), adapted from
# ios-flame's tools/flame-install-ssh.sh. Reboot afterwards: launchd reads its
# job cache at boot.
#
#   tools/install-ssh.sh
#
# Binaries: build/userland/stage (tools/build-userland.sh). Key:
# build/userland/ssh/id_ed25519 (ssh -i that -p 2222 root@127.0.0.1).
set -euo pipefail
cd "$(dirname "$0")/.."
F="python3 tools/flame-files.py"
U=../build/userland
[ -f $U/stage/dropbearmulti ] && [ -f $U/stage/dash ] || { echo "build/userland/stage incomplete (tools/build-userland.sh)" >&2; exit 1; }
$F mkdir /var/local 755 || true
$F mkdir /var/local/bin 755 || true
$F mkdir /private/etc/dropbear 700 || true
$F mkdir /var/root/.ssh 700 || true
# Remove before writing: rewriting a binary in place keeps the vnode and its
# old code signature, and launchd re-execs a crashing dropbear every 10 s
# (a reinstall over a running job reset the phone).
$F rm /var/local/bin/dropbearmulti 2>/dev/null || true
$F rm /var/local/bin/dash 2>/dev/null || true
$F put $U/stage/dropbearmulti /var/local/bin/dropbearmulti 755
$F put $U/stage/dash /var/local/bin/dash 755
if [ -f $U/stage/toybox ]; then
	$F rm /var/local/bin/toybox 2>/dev/null || true
	$F put $U/stage/toybox /var/local/bin/toybox 755
fi
$F rm /var/local/bin/dropbear 2>/dev/null || true
$F link /var/local/bin/dropbearmulti /var/local/bin/dropbear
$F link /var/local/bin/dropbearmulti /var/local/bin/scp || true
$F link /var/local/bin/dropbearmulti /var/local/bin/dbclient || true
$F link /var/local/bin/dash /bin/sh || echo "(/bin/sh exists)"
$F put $U/ssh/id_ed25519.pub /var/root/.ssh/authorized_keys 600

# launchd job, keyed under /System/Library/LaunchDaemons in the job cache
# (/System/Library/xpc/launchd.plist; the original is kept as .orig).
# The job is added to the untouched original (fetched once: 800 KB)
if [ ! -f $U/launchd.plist.orig ]; then
	$F get /System/Library/xpc/launchd.plist $U/launchd.plist.cur
	cp $U/launchd.plist.cur $U/launchd.plist.orig
fi
python3 - "$U/launchd.plist.orig" "$U/launchd.plist.new" <<'PY'
import plistlib, sys
p = plistlib.load(open(sys.argv[1], 'rb'))
p['LaunchDaemons']['/System/Library/LaunchDaemons/org.iosonpixel.dropbear.plist'] = {
    'Label': 'org.iosonpixel.dropbear',
    'ProgramArguments': ['/var/local/bin/dropbear', '-F', '-R', '-p', '22'],  # no -E: built without syslog, stderr is the default
    'RunAtLoad': True, 'KeepAlive': True, 'UserName': 'root',
    'EnvironmentVariables': {'PATH': '/var/local/bin:/usr/bin:/bin:/usr/sbin:/sbin', 'SHELL': '/bin/sh'},
    'StandardErrorPath': '/var/local/dropbear.log',
}
plistlib.dump(p, open(sys.argv[2], 'wb'), fmt=plistlib.FMT_BINARY)
print('launchd jobs:', len(p['LaunchDaemons']))
PY
$F put $U/launchd.plist.orig /System/Library/xpc/launchd.plist.orig 644 2>/dev/null || true
$F put $U/launchd.plist.new /System/Library/xpc/launchd.plist 644
echo "installed; reboot (python3 tools/flame-cmd.py reboot) and boot again: launchd starts dropbear"
