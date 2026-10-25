#!/bin/zsh
# 与应用构建使用同一 SDK；新 SwiftPM 的默认构建引擎会忽略外部 SDK 路径。
set -euo pipefail
cd "${0:A:h}"
SDK="${NWZ_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
FLAGS=()
# 当前命令行工具的 SwiftPM 把测试框架路径当作普通头文件路径，显式补齐框架搜索和运行路径。
FRAMEWORKS="$DEVELOPER_DIR/Library/Developer/Frameworks"
if [[ -d "$FRAMEWORKS/Testing.framework" ]]; then
  FLAGS=(-Xswiftc "-F$FRAMEWORKS" -Xlinker "-F$FRAMEWORKS" -Xlinker -rpath -Xlinker "$FRAMEWORKS")
fi
SDKROOT="$SDK" swift test --build-system native --sdk "$SDK" "${FLAGS[@]}" "$@"
