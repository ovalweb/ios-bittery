#!/bin/sh
# Build the native Metal bridge (phone/metal2/bridge/NativeMetalBridge.rs: UniXNU's bridge over the
# metal2vulkan runtime, MIT) as a static library for iOS 16 arm64, without Xcode. From ios-flame.
#   tools/build-m2v-bridge.sh
# Source: ../build/gpu-userland/metal2vulkan = github.com/steelbrain/metal2vulkan 720ef1ce (UniXNU's pin)
# + phone/metal2/bridge/patches. Needs rustup's 1.98.0 with aarch64-apple-ios, Homebrew llvm (llvm-as).
# Output: ../build/gpu-userland/m2v-bridge/ios/libnative_metal_bridge.a
set -e
cd "$(dirname "$0")/.."
ROOT=$PWD
G=$(cd .. && pwd)/build/gpu-userland
SRC=$G/metal2vulkan
OUT=$G/m2v-bridge
mkdir -p "$OUT"
export PATH=/opt/homebrew/opt/rustup/bin:$PATH
LLVM_AS=/opt/homebrew/opt/llvm/bin/llvm-as
"$LLVM_AS" -o "$OUT/runtime_examples.air" "$SRC/crates/metal2vulkan-validation/fixtures/public/examples/runtime_examples.ll"
"$LLVM_AS" -o "$OUT/function_constant.air" "$SRC/crates/metal2vulkan-validation/fixtures/public/kernel_function_constant_gate_fold.ll"
cat > "$OUT/Cargo.toml" <<EOC
[package]
name = "native-metal-bridge"
version = "0.1.0"
edition = "2024"
rust-version = "1.98"
[workspace]
[lib]
crate-type = ["staticlib"]
path = "$ROOT/phone/metal2/bridge/NativeMetalBridge.rs"
[dependencies]
metal2vulkan = { path = "$SRC/crates/metal2vulkan", features = ["ash"] }
metal2vulkan-runtime = { path = "$SRC/crates/metal2vulkan-runtime" }
libc = "0.2"
sha2 = { version = "0.10", features = ["asm"] }
[profile.release]
panic = "unwind"
debug = 1
EOC
# C pieces (cc-rs) go through tools/ios-cc; SDKROOT keeps cc-rs from asking xcrun for an iOS SDK
NMB_FIXTURE_AIR=$OUT/runtime_examples.air NMB_FC_AIR=$OUT/function_constant.air IPHONEOS_DEPLOYMENT_TARGET=16.0 \
	CC_aarch64_apple_ios="$ROOT/tools/ios-cc" CXX_aarch64_apple_ios="$ROOT/tools/ios-c++" AR_aarch64_apple_ios=/usr/bin/ar \
	SDKROOT="$(xcrun --show-sdk-path)" \
	cargo +1.98.0 build --release --manifest-path "$OUT/Cargo.toml" --target aarch64-apple-ios \
	--target-dir "$OUT/target" > "$OUT/build-ios.log" 2>&1 || { grep -E "^(error|warning: unused)" -A8 "$OUT/build-ios.log" | head -60; exit 1; }
mkdir -p "$OUT/ios"
cp "$OUT/target/aarch64-apple-ios/release/libnative_metal_bridge.a" "$OUT/ios/"
ls -la "$OUT/ios/libnative_metal_bridge.a"
