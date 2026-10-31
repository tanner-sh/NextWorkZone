#!/bin/zsh
# 打包发布用的应用：./release.sh，产物为 macos/build.noindex/dist/NextWorkZone-<版本>-macos-arm64.zip 和对应的 .sha256。
#
# 版本号取自 Resources/Info.plist 的 CFBundleShortVersionString。
# 发布包用临时签名（ad-hoc）：没有 Developer ID 无法公证，用个人开发证书签名还会把证书中的邮箱带进签名；
# 下载的人第一次打开时需要按说明放行（见 README 的“安装”）。
set -euo pipefail
cd "${0:A:h}"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
if [[ -n "$(git status --porcelain)" ]]; then
  echo "工作区有未提交的修改，先提交再打包" >&2
  exit 1
fi

NWZ_SIGN_IDENTITY=- ./build.sh release >/dev/null
APP="$PWD/build.noindex/NextWorkZone.app"
codesign --verify --strict "$APP"

DIST="$PWD/build.noindex/dist"
NAME="NextWorkZone-$VERSION-macos-arm64.zip"
rm -rf "$DIST"
mkdir -p "$DIST"
# ditto 保留扩展属性和符号链接，是打包 .app 的标准做法
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/$NAME"
(cd "$DIST" && shasum -a 256 "$NAME" > "$NAME.sha256")
echo "$DIST/$NAME"
cat "$DIST/$NAME.sha256"
