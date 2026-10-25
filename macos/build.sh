#!/bin/zsh
# 构建 macOS 原生版：./build.sh [debug|release]，产物为 macos/build/NextWorkZone.app。
#
# 1. 编译 Rust 应用层（crates/ffi）为静态库；
# 2. 用 UniFFI 生成 Swift 绑定和 C 头文件；
# 3. 用 SwiftPM 编译界面（命令行工具即可，不需要 Xcode）；
# 4. 组装 .app 并签名。
set -euo pipefail
ROOT="${0:A:h:h}"
cd "${0:A:h}"
MODE="${1:-debug}"
export PATH="$HOME/.cargo/bin:$PATH"
SDK="${NWZ_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk}"
export SDKROOT="$SDK"
export MACOSX_DEPLOYMENT_TARGET=26.0

if [[ "$MODE" == "release" ]]; then
  cargo build --manifest-path "$ROOT/Cargo.toml" -p nextworkzone-ffi --release
  RUST_DIR="$ROOT/target/release"
  SWIFT_FLAGS=(-c release)
else
  cargo build --manifest-path "$ROOT/Cargo.toml" -p nextworkzone-ffi
  RUST_DIR="$ROOT/target/debug"
  SWIFT_FLAGS=(-c debug)
fi

# 绑定只在库变化后重新生成，避免每次都让 Swift 全量重编
GEN="$PWD/.build/uniffi"
mkdir -p "$GEN" Sources/NextWorkZone/Generated Sources/CoreFFI/include
if [[ ! -f "$GEN/stamp" || "$RUST_DIR/libnextworkzone_ffi.dylib" -nt "$GEN/stamp" ]]; then
  cargo run -q --manifest-path "$ROOT/Cargo.toml" -p nextworkzone-ffi --bin uniffi-bindgen -- \
    generate --library "$RUST_DIR/libnextworkzone_ffi.dylib" --language swift --out-dir "$GEN"
  cmp -s "$GEN/nextworkzone_ffi.swift" Sources/NextWorkZone/Generated/nextworkzone_ffi.swift || cp "$GEN/nextworkzone_ffi.swift" Sources/NextWorkZone/Generated/
  cmp -s "$GEN/nextworkzone_ffiFFI.h" Sources/CoreFFI/include/nextworkzone_ffiFFI.h || cp "$GEN/nextworkzone_ffiFFI.h" Sources/CoreFFI/include/
  sed 's/^module nextworkzone_ffiFFI/module nextworkzone_ffiFFI/' "$GEN/nextworkzone_ffiFFI.modulemap" > "$GEN/module.modulemap"
  cmp -s "$GEN/module.modulemap" Sources/CoreFFI/include/module.modulemap || cp "$GEN/module.modulemap" Sources/CoreFFI/include/
  touch "$GEN/stamp"
fi

# 命令行工具自带的 macOS 27 SDK 中 SwiftUI 的宏插件只随 Xcode 提供，因此用 26 的 SDK 编译（最低支持 26）
SDKROOT="$SDK" NWZ_RUST_LIB_DIR="$RUST_DIR" swift build --build-system native --sdk "$SDK" "${SWIFT_FLAGS[@]}"
BIN="$(SDKROOT="$SDK" NWZ_RUST_LIB_DIR="$RUST_DIR" swift build --build-system native --sdk "$SDK" "${SWIFT_FLAGS[@]}" --show-bin-path)/NextWorkZone"

APP="$PWD/build/NextWorkZone.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/NextWorkZone"
if [[ "$MODE" == "release" ]]; then
  BUNDLE_ID="com.nextworkzone.desktop"
else
  # 开发版使用独立标识和新的开发数据目录，可以和正式版同时运行
  BUNDLE_ID="com.nextworkzone.desktop.dev"
fi
sed -e "s/__BUNDLE_ID__/$BUNDLE_ID/" Resources/Info.plist > "$APP/Contents/Info.plist"
cp "$ROOT/src-tauri/icons/icon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/src-tauri/icons/tray-template.png" "$APP/Contents/Resources/tray-template.png"
cp "$ROOT/src-tauri/icons/128x128.png" "$APP/Contents/Resources/app-icon.png"

IDENTITY="${NWZ_SIGN_IDENTITY:-NextWorkZone Local Signing}"
# 固定的签名身份让辅助功能、钥匙串授权在重新编译后仍然有效；没有时用临时签名
codesign --force --sign "$IDENTITY" "$APP" 2>/dev/null || codesign --force --sign - "$APP"
echo "$APP"
