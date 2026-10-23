#!/bin/bash
# Build the iOS userland tools (dropbear, dash) with tools/ios-cc into
# build/userland/stage, signed ad hoc. Sources are cloned into
# build/userland/src on first use.
#   tools/build-userland.sh
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
U=$(cd "$here/../.." && pwd)/build/userland
CC=$here/ios-cc
mkdir -p "$U/src" "$U/stage"
cd "$U/src"
[ -d dropbear ] || git clone -q --depth 1 --branch DROPBEAR_2024.86 https://github.com/mkj/dropbear.git dropbear
[ -d dash ] || git clone -q --depth 1 --branch v0.5.12 https://git.kernel.org/pub/scm/utils/dash/dash.git dash

# dropbear: root only, public keys only (iOS has no multi-user login records)
cd "$U/src/dropbear"
cat > localoptions.h <<'EOF'
#define DROPBEAR_SVR_MULTIUSER 0
#define DROPBEAR_SVR_PASSWORD_AUTH 0
#define DROPBEAR_SVR_PUBKEY_AUTH 1
#define DROPBEAR_X11FWD 0
#define DROPBEAR_PATH_SSH_PROGRAM "/var/local/bin/dbclient"
#define DEFAULT_PATH "/var/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
#define DSS_PRIV_FILENAME "/private/etc/dropbear/dropbear_dss_host_key"
#define RSA_PRIV_FILENAME "/private/etc/dropbear/dropbear_rsa_host_key"
#define ECDSA_PRIV_FILENAME "/private/etc/dropbear/dropbear_ecdsa_host_key"
#define ED25519_PRIV_FILENAME "/private/etc/dropbear/dropbear_ed25519_host_key"
#define IOSONPIXEL_SINGLE_ROOT 1
EOF
# The non-multiuser build insists on a kernel without getgroups() (ENOSYS) and
# drops every connection otherwise; XNU has it. Only root logs in here anyway.
sed -i '' 's/^#if !DROPBEAR_SVR_MULTIUSER$/#if !DROPBEAR_SVR_MULTIUSER \&\& !defined(IOSONPIXEL_SINGLE_ROOT)/' src/common-session.c
[ -f Makefile ] || CC=$CC ./configure --host=aarch64-apple-darwin --disable-zlib --disable-lastlog \
	--disable-utmp --disable-utmpx --disable-wtmp --disable-wtmpx --disable-pututline \
	--disable-pututxline --disable-syslog --disable-harden >/dev/null
# macOS headers declare login/logout; iOS has neither
sed -i '' -E 's/^#define (HAVE_LOGIN|HAVE_LOGOUT|HAVE_LOGWTMP|HAVE_UPDWTMP|HAVE_UPDWTMPX) 1/\/* #undef \1 *\//' config.h
make -j8 PROGRAMS="dropbear dbclient dropbearkey scp" MULTI=1 >/dev/null
cp dropbearmulti "$U/stage/"

# dash: iOS 16 has no strchrnul (the macOS SDK declares it: a weak import that crashes)
cd "$U/src/dash"
[ -f configure ] || ./autogen.sh >/dev/null
[ -f Makefile ] || CC=$CC CC_FOR_BUILD=clang ac_cv_func_strchrnul=no ./configure --host=aarch64-apple-darwin >/dev/null
make -j8 CC_FOR_BUILD=clang >/dev/null
cp src/dash "$U/stage/"

for b in "$U"/stage/*; do
	codesign -f -s - "$b" 2>/dev/null
	if nm -m "$b" | grep -q 'weak external'; then
		echo "warning: $b has weak imports (may be missing on iOS 16):" >&2
		nm -m "$b" | grep 'weak external' >&2
	fi
done
ls -la "$U/stage"
