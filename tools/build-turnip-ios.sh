#!/bin/sh
# Build Turnip (Mesa's Vulkan driver for Adreno) for iOS 16 arm64 with the darwin kernel backend,
# without Xcode (tools/ios-cc, tools/ios-c++). Adapted from ios-flame's tools/build-turnip-ios.sh.
#   tools/build-turnip-ios.sh
# Source: ../build/gpu-userland/mesa = Mesa 85fda3b3 + UniXNU's patches/mesa (their order, see
# UniXNU scripts/data/adreno-compiler-inputs.json) + phone/turnip/patches. The backend
# (tu_knl_darwin.cc) talks to SweetAccelerator's v2 user client through phone/turnip/NativeAdrenoABI.h.
# Mesa picks the GPU (A630 on the Pixel 3) from the chip id the kernel reports.
# Output: ../build/gpu-userland/turnip-ios/src/freedreno/vulkan/libvulkan_freedreno.dylib
set -e
cd "$(dirname "$0")/.."
ROOT=$PWD
G=$(cd .. && pwd)/build/gpu-userland
out=$G/turnip-ios
export PATH=/opt/homebrew/opt/bison/bin:/opt/homebrew/opt/flex/bin:$PATH
opts="-Dgallium-drivers= -Dvulkan-drivers=freedreno -Dfreedreno-kmds=darwin -Dtu-darwin-abi-dir=$ROOT/phone/turnip
 -Dplatforms=macos -Dglx=disabled -Degl=disabled -Dgbm=disabled -Dopengl=false -Dgles1=disabled -Dgles2=disabled
 -Dllvm=disabled -Dshared-glapi=disabled -Dxmlconfig=disabled -Dshader-cache=disabled -Dtools= -Dbuild-tests=false
 -Dvideo-codecs= -Dvulkan-layers= -Dlibunwind=disabled -Dlmsensors=disabled -Dvalgrind=disabled -Dexpat=disabled
 -Dzstd=disabled -Dbuildtype=release -Db_ndebug=true"
cross=$G/ios16.cross
cat > "$cross" <<EOC
[binaries]
c = '$ROOT/tools/ios-cc'
cpp = '$ROOT/tools/ios-c++'
objc = '$ROOT/tools/ios-cc'
ar = '/usr/bin/ar'
strip = '/usr/bin/strip'
pkg-config = '/usr/bin/false'
[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'
[properties]
needs_exe_wrapper = true
[built-in options]
c_args = ['-fstack-protector-strong']
cpp_args = ['-fstack-protector-strong']
objc_args = ['-fstack-protector-strong']
EOC
unset CFLAGS CXXFLAGS CPPFLAGS LDFLAGS
export CC=/usr/bin/clang CXX=/usr/bin/clang++	# the build machine's compilers (generators)
if [ -f "$out/build.ninja" ]; then
	meson configure "$out" $opts >/dev/null
else
	meson setup "$out" "$G/mesa" --wrap-mode=nodownload --cross-file "$cross" $opts > "$G/configure-ios.log" 2>&1 ||
		{ tail -30 "$G/configure-ios.log"; exit 1; }
fi
ninja -C "$out" src/freedreno/vulkan/libvulkan_freedreno.dylib > "$G/build-ios.log" 2>&1 ||
	{ grep -E "error:|FAILED" "$G/build-ios.log" | head -30; exit 1; }
lib=$out/src/freedreno/vulkan/libvulkan_freedreno.dylib
nm -gU "$lib" | grep -q " T _vkGetInstanceProcAddr" || { echo "no vkGetInstanceProcAddr export" >&2; exit 1; }
# iOS 16 lacks symbols newer SDKs declare: weak imports resolve to NULL there (the strchrnul lesson)
nm -m "$lib" | grep "weak external" || true
ls -la "$lib"
