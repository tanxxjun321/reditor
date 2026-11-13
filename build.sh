#!/usr/bin/env bash
# 编译 AirMirror 的 macOS 发布版本
# 用法: ./build.sh [mac|mac-x64|all]   默认 all(arm64 + x64)
set -euo pipefail
cd "$(dirname "$0")"

PROJECT=AirMirror/AirMirror.csproj
OUT=publish

publish() { # $1 = RID, $2 = 输出目录名
    echo "==> 发布 $1 (自包含单文件) ..."
    # 单文件 + 自包含:macOS 15 起 Contents/MacOS 只准放可签名代码,
    # 散落的 dll/json/pdb 会让 codesign 直接报错;同时免装 .NET 运行时。
    # 先清输出目录:增量发布曾出现单文件模式下漏拷原生 dylib 的情况
    rm -rf "$OUT/$2"
    dotnet publish "$PROJECT" -c Release -r "$1" --self-contained \
        -p:PublishSingleFile=true -o "$OUT/$2"
}

make_app_bundle() { # $1 = RID 输出目录, $2 = app 名
    local src="$OUT/$1"
    local app="$OUT/$2.app/Contents"
    echo "==> 打包 $2.app ..."
    rm -rf "$OUT/$2.app"
    mkdir -p "$app/MacOS" "$app/Resources"
    cp -R "$src"/. "$app/MacOS/"
    # 单文件模式下 deps/runtimeconfig 已嵌入 apphost,这些文件只是发布副产物;
    # 留在 MacOS 里会被 codesign 当作未签名代码拒绝
    find "$app/MacOS" -type f \( -name "*.json" -o -name "*.pdb" \) -delete
    find "$app/MacOS" -name "*.dSYM" -prune -exec rm -rf {} + 2>/dev/null || true
    cat > "$app/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$2</string>
    <key>CFBundleDisplayName</key><string>$2</string>
    <key>CFBundleIdentifier</key><string>com.airmirror.app</string>
    <key>CFBundleVersion</key><string>1.0.0</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>CFBundleExecutable</key><string>AirMirror</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>12.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF
    chmod +x "$app/MacOS/AirMirror"
    # 收进 Homebrew 动态库依赖 + GStreamer 插件,脱离开发机环境运行
    ./native/bundle_deps.sh "$OUT/$2.app"
}

build_mac() { publish osx-arm64 osx-arm64 && make_app_bundle osx-arm64 AirMirror; }
build_mac_x64() { publish osx-x64 osx-x64 && make_app_bundle osx-x64 AirMirror-x64; }

target="${1:-all}"
case "$target" in
    mac)     build_mac ;;
    mac-x64) build_mac_x64 ;;
    all)     build_mac; build_mac_x64 ;;
    *)
        echo "未知目标: $target (可选: mac | mac-x64 | all)" >&2
        exit 1
        ;;
esac

echo "完成,产物在 $OUT/ 目录(签名公证见 sign.sh)"
