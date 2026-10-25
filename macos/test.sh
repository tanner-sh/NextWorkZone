#!/bin/zsh
# 与应用构建使用同一 SDK；新 SwiftPM 的默认构建引擎会忽略外部 SDK 路径。
set -euo pipefail
cd "${0:A:h}"
SDK="${NWZ_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk}"
SDKROOT="$SDK" swift test --build-system native --sdk "$SDK" "$@"
