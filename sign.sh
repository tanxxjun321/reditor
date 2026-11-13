#!/usr/bin/env bash
# AirMirror 发布签名 + 公证 + stapling
#
# 前置条件:
#   1. 钥匙串中有 "Developer ID Application: <你的名字> (<TeamID>)" 证书
#      (Xcode → Settings → Accounts → Manage Certificates 可创建)
#   2. 已存入 notarytool 凭据(一次性):
#        xcrun notarytool store-credentials airmirror-notary \
#            --apple-id <Apple ID> --team-id <Team ID> --password <App 专用密码>
#
# 用法:
#   ./build.sh mac && ./sign.sh                 # 签名公证 publish 下所有 .app
#   ./sign.sh publish/AirMirror.app             # 只处理指定 app
#
# 环境变量覆盖:
#   SIGN_IDENTITY="Developer ID Application: ..."  签名证书(默认自动探测)
#   NOTARY_PROFILE=airmirror-notary                notarytool 凭据名
set -euo pipefail
cd "$(dirname "$0")"

SIGN_IDENTITY="${SIGN_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-airmirror-notary}"
ENTITLEMENTS="entitlements.plist"

if [[ -z "$SIGN_IDENTITY" ]]; then
    SIGN_IDENTITY=$(security find-identity -v -p codesigning \
        | awk -F'"' '/Developer ID Application/ {print $2; exit}')
    [[ -n "$SIGN_IDENTITY" ]] || { echo "错误: 钥匙串中找不到 Developer ID Application 证书" >&2; exit 1; }
fi
echo "签名证书: $SIGN_IDENTITY"
echo "公证凭据: $NOTARY_PROFILE"

sign_app() { # $1 = .app 路径
    local app="$1"
    echo "==> 签名 $app"

    # 先内后外:重签所有嵌套动态库与可执行文件(.NET 发布把 Homebrew 的
    # GStreamer dylib 拷进包里,它们的原始签名与我们的 Team ID 不同,必须重签)
    find "$app" -type f \( -name "*.dylib" -o -perm +111 \) | while read -r f; do
        codesign --force --options runtime --timestamp \
            --sign "$SIGN_IDENTITY" "$f" 2>/dev/null || true
    done

    # 主 app 携带 entitlements
    codesign --force --options runtime --timestamp \
        --entitlements "$ENTITLEMENTS" \
        --sign "$SIGN_IDENTITY" "$app"
    codesign --verify --deep --strict --verbose=1 "$app"

    echo "==> 公证 $app (notarytool,可能需要几分钟)"
    local zip="${app%.app}.zip"
    rm -f "$zip"
    ditto -c -k --keepParent "$app" "$zip"
    xcrun notarytool submit "$zip" --keychain-profile "$NOTARY_PROFILE" --wait
    rm -f "$zip"

    xcrun stapler staple "$app"
    spctl -a -vv "$app"
    echo "==> 完成: $app"
}

apps=("$@")
if [[ ${#apps[@]} -eq 0 ]]; then
    shopt -s nullglob
    apps=(publish/*.app)
    [[ ${#apps[@]} -gt 0 ]] || { echo "publish/ 下没有 .app,先运行 ./build.sh" >&2; exit 1; }
fi

for app in "${apps[@]}"; do
    sign_app "$app"
done
