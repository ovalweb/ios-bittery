#!/bin/sh
# Build vktest (Turnip smoke test) for the phone into phone/turnip/out, plus a signed copy of Turnip.
#   phone/turnip/build.sh        (Turnip itself: tools/build-turnip-ios.sh)
set -e
cd "$(dirname "$0")"
ROOT=$(cd ../.. && pwd)
G=$(cd ../../.. && pwd)/build/gpu-userland
mkdir -p out
: > out/shaders.h
for s in fill.comp:fill_comp tri.vert:tri_vert tri.frag:tri_frag; do
	glslangValidator -V --target-env vulkan1.2 --vn "${s#*:}" -o out/"${s#*:}".h shaders/"${s%%:*}" >/dev/null
	cat out/"${s#*:}".h >> out/shaders.h
done
"$ROOT/tools/ios-cc" -O2 -Wall -I out -I "$G/mesa/include" -o out/vktest vktest.c
codesign -f -s - out/vktest 2>/dev/null
cp "$G/turnip-ios/src/freedreno/vulkan/libvulkan_freedreno.dylib" out/
codesign -f -s - out/libvulkan_freedreno.dylib 2>/dev/null
ls -la out/vktest out/libvulkan_freedreno.dylib
