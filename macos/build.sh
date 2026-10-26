#!/bin/zsh
# 构建应用：./build.sh [debug|release]，产物为 macos/build.noindex/NextWorkZone.app。
#
# 用 SwiftPM 编译（命令行工具即可，不需要 Xcode），再组装 .app 并签名。
set -euo pipefail
cd "${0:A:h}"
MODE="${1:-debug}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
SDK="${NWZ_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk}"
export SDKROOT="$SDK"
export MACOSX_DEPLOYMENT_TARGET=26.0

if [[ "$MODE" == "release" ]]; then
  SWIFT_FLAGS=(-c release)
  BUNDLE_ID="com.nextworkzone.desktop"
else
  SWIFT_FLAGS=(-c debug)
  # 开发版使用独立标识和开发数据目录，可以和正式版同时运行
  BUNDLE_ID="com.nextworkzone.desktop.dev"
fi

# 命令行工具自带的 macOS 27 SDK 中 SwiftUI 的宏插件只随 Xcode 提供，因此用 26 的 SDK 编译（最低支持 26）；
# 新的默认构建引擎会忽略外部 SDK 路径，所以用 native
swift build --build-system native --sdk "$SDK" "${SWIFT_FLAGS[@]}" --product NextWorkZone
BIN="$(swift build --build-system native --sdk "$SDK" "${SWIFT_FLAGS[@]}" --show-bin-path)/NextWorkZone"

# 目录名以 .noindex 结尾：聚焦搜索不收录，构建出的应用不会出现在“应用程序”中，与安装的版本混在一起
APP="$PWD/build.noindex/NextWorkZone.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/NextWorkZone"
sed -e "s/__BUNDLE_ID__/$BUNDLE_ID/" Resources/Info.plist > "$APP/Contents/Info.plist"
# 图标：Assets.car 为分层图标（由 ./icon.sh 从 Icon/AppIcon.icon 生成），AppIcon.icns 供不认识分层图标的地方使用
cp Resources/Assets.car Resources/AppIcon.icns Resources/tray-template.png Resources/app-icon.png "$APP/Contents/Resources/"

IDENTITY="${NWZ_SIGN_IDENTITY:-NextWorkZone Local Signing}"
# 固定的签名身份让辅助功能、钥匙串授权在重新编译后仍然有效；没有时用临时签名
codesign --force --sign "$IDENTITY" "$APP" 2>/dev/null || codesign --force --sign - "$APP"
echo "$APP"
