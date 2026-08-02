#!/usr/bin/env bash
# 编译 REditor 的 Windows 和 macOS 发布版本（Native AOT）
# 用法: ./build.sh [win|mac|mac-x64|all]   默认 all
# 注意: Native AOT 不能跨操作系统编译，Windows 版的 AOT 产物需在 Windows 上构建。
set -euo pipefail
cd "$(dirname "$0")"

PROJECT=REditor/REditor.csproj
OUT=publish

on_windows() { [[ "${OS:-}" == "Windows_NT" || "$(uname -s)" == MINGW* || "$(uname -s)" == MSYS* ]]; }

publish() { # $1 = RID, $2 = 输出目录名
    echo "==> 发布 $1 (Native AOT) ..."
    dotnet publish "$PROJECT" -c Release -r "$1" -o "$OUT/$2"
}

publish_win_fallback() { # 非 Windows 主机: AOT 无法交叉编译，退回自包含单文件
    echo "==> 发布 win-x64 (非 Windows 主机，退回自包含单文件，非 AOT) ..."
    dotnet publish "$PROJECT" -c Release -r win-x64 --self-contained \
        -p:PublishAot=false -p:PublishSingleFile=true -o "$OUT/win-x64"
}

make_app_bundle() { # $1 = RID 输出目录, $2 = app 名
    local src="$OUT/$1"
    local app="$OUT/$2.app/Contents"
    echo "==> 打包 $2.app ..."
    rm -rf "$OUT/$2.app"
    mkdir -p "$app/MacOS" "$app/Resources"
    cp -R "$src"/. "$app/MacOS/"
    find "$app/MacOS" -name "*.dSYM" -prune -exec rm -rf {} + 2>/dev/null || true
    cat > "$app/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$2</string>
    <key>CFBundleDisplayName</key><string>$2</string>
    <key>CFBundleIdentifier</key><string>com.reditor.app</string>
    <key>CFBundleVersion</key><string>1.0.0</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>CFBundleExecutable</key><string>REditor</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>12.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF
    chmod +x "$app/MacOS/REditor"
}

build_win() {
    if on_windows; then publish win-x64 win-x64; else publish_win_fallback; fi
}
build_mac() { publish osx-arm64 osx-arm64 && make_app_bundle osx-arm64 REditor; }
build_mac_x64() { publish osx-x64 osx-x64 && make_app_bundle osx-x64 REditor-x64; }

target="${1:-all}"
case "$target" in
    win)     build_win ;;
    mac)     build_mac ;;
    mac-x64) build_mac_x64 ;;
    all)     build_win; build_mac ;;
    *)
        echo "未知目标: $target (可选: win | mac | mac-x64 | all)" >&2
        exit 1
        ;;
esac

echo "完成，产物在 $OUT/ 目录"
