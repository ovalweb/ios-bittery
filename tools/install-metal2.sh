#!/bin/sh
# Install phone/metal2/out/SweetMetal2.bundle (metal2vulkan + Turnip) into /System/Library/Extensions
# on the phone; boot with sweetgpu=1 sweetmtl=2 to use it. Adapted from ios-flame's flame-metal2-install.sh.
#   tools/install-metal2.sh
set -e
cd "$(dirname "$0")/.."
B=phone/metal2/out/SweetMetal2.bundle
for f in SweetMetal2 libvulkan_freedreno.dylib Info.plist _CodeSignature/CodeResources; do
	[ -s "$B/$f" ] || { echo "incomplete bundle: no $B/$f (phone/metal2/build.sh)" >&2; exit 1; }
done
tools/phone-ssh 'rm -rf /var/local/tmp/m2 && mkdir -p /var/local/tmp/m2 && : >> /var/local/mtl2.log && chmod 666 /var/local/mtl2.log'
COPYFILE_DISABLE=1 tar --no-mac-metadata --no-xattrs --uid 0 --gid 0 --uname root --gname wheel -czf - -C phone/metal2/out \
	SweetMetal2.bundle | tools/phone-ssh 'toybox zcat | toybox tar -xpf - -C /var/local/tmp/m2'
# a fresh directory, not files rewritten in place (cached code signatures: see install-ssh.sh)
tools/phone-ssh 'E=/System/Library/Extensions; rm -rf $E/SweetMetal2.bundle.old; [ -d $E/SweetMetal2.bundle ] &&
	mv $E/SweetMetal2.bundle $E/SweetMetal2.bundle.old; mv /var/local/tmp/m2/SweetMetal2.bundle $E/ &&
	rm -rf $E/SweetMetal2.bundle.old; ls -la $E/SweetMetal2.bundle; sync'
