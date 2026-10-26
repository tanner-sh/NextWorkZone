#!/bin/zsh
# 重新生成应用图标：./icon.sh。需要 Xcode（actool、Icon Composer 的 ictool）；普通构建不需要，生成的文件已在 Resources 中。
#
# 图标源文件为 Icon/AppIcon.icon（可用 Icon Composer 打开编辑）：渐变底色 + 玻璃材质的图形，
# 系统据此显示默认、深色、透明、着色几种外观。生成：
# - Resources/Assets.car：分层图标（macOS 26 起使用）
# - Resources/AppIcon.icns：不认识分层图标的地方使用的普通图标
# - Resources/app-icon.png：128 像素的预览图
set -euo pipefail
cd "${0:A:h}"
export DEVELOPER_DIR="${NWZ_XCODE:-/Applications/Xcode.app/Contents/Developer}"
ICTOOL="$DEVELOPER_DIR/../Applications/Icon Composer.app/Contents/Executables/ictool"
OUT="$(mktemp -d)"
xcrun actool Icon/AppIcon.icon --compile "$OUT" --platform macosx --minimum-deployment-target 26.0 \
  --app-icon AppIcon --output-partial-info-plist "$OUT/partial.plist" >/dev/null
cp "$OUT/Assets.car" "$OUT/AppIcon.icns" Resources/
"$ICTOOL" Icon/AppIcon.icon --export-image --output-file Resources/app-icon.png --platform macOS \
  --rendition Default --width 128 --height 128 --scale 1 >/dev/null
rm -rf "$OUT"
echo "已更新 Resources/Assets.car、AppIcon.icns、app-icon.png"
