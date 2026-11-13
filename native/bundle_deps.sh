#!/usr/bin/env bash
# bundle_deps.sh <AirMirror.app>
#
# 让 .app 脱离 Homebrew 环境运行:
#   1. libairplaybridge.dylib 的 Homebrew 动态库依赖(递归闭包)收进
#      Contents/Frameworks,绝对路径引用改写为 @rpath;
#   2. GStreamer 运行时按需 dlopen 的插件(otool 看不到!)和
#      gst-plugin-scanner 收进 Contents/Frameworks/gstreamer。
#      原生桥启动时检测到这个目录会自动设置 GST_PLUGIN_PATH/SCANNER。
#
# 只需在 make_app_bundle 里调用一次;codesign 在 sign.sh 里最后统一做。
set -euo pipefail

APP="$1"
MACOS="$APP/Contents/MacOS"
FW="$APP/Contents/Frameworks"
GSTPLUG="$FW/gstreamer"
BRIDGE="$MACOS/libairplaybridge.dylib"

BREW=/opt/homebrew
[[ -d /opt/homebrew ]] || BREW=/usr/local
GST_PLUGIN_SRC="$BREW/lib/gstreamer-1.0"
SCANNER_SRC="$BREW/opt/gstreamer/libexec/gstreamer-1.0/gst-plugin-scanner"

mkdir -p "$FW" "$GSTPLUG"
SEEN=" "   # 已处理的源路径(空格分隔,兼容 macOS 自带 bash 3.2)

# 某个 Mach-O 的 Homebrew 绝对路径依赖(不含自身 id 行)
deps_of() {
    otool -L "$1" | awk 'NR>1 {print $1}' | grep -E '^/(opt/homebrew|usr/local)/' || true
}

# 删掉 Mach-O 自带的 Homebrew LC_RPATH:它们排在新增的 @loader_path 之前,
# 在装有 Homebrew 的机器上会抢先命中系统库,导致包内/系统两份库混载
strip_homebrew_rpaths() {
    local rp
    while IFS= read -r rp; do
        [[ -z "$rp" ]] && continue
        install_name_tool -delete_rpath "$rp" "$1" 2>/dev/null || true
    done < <(otool -l "$1" | awk '/LC_RPATH/{f=1} f && /path /{print $2; f=0}' \
             | grep -E '^/(opt/homebrew|usr/local)/' || true)
}

# 把 $1 收进 $2 目录并递归处理依赖闭包。$3 = "exe" 时不设 id(可执行文件)
bundle_lib() {
    local src="$1" dest_dir="$2" kind="${3:-}"
    local base dest dep
    base=$(basename "$src")
    case "$SEEN" in *" $src "*) return 0 ;; esac
    SEEN="$SEEN$src "
    dest="$dest_dir/$base"
    if [[ "$src" != "$dest" ]]; then
        cp "$src" "$dest"
        chmod u+w "$dest"
    fi
    [[ "$kind" == "exe" ]] || install_name_tool -id "@rpath/$base" "$dest"
    strip_homebrew_rpaths "$dest"
    # rpath:Frameworks 顶层的库互相在同目录;gstreamer 子目录向上一层
    if [[ "$dest_dir" == "$FW" ]]; then
        install_name_tool -add_rpath "@loader_path" "$dest" 2>/dev/null || true
    else
        install_name_tool -add_rpath "@loader_path/.." "$dest" 2>/dev/null || true
    fi
    while IFS= read -r dep; do
        [[ -z "$dep" ]] && continue
        install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$dest"
    done < <(deps_of "$dest")
    # arm64 上签名被 install_name_tool 破坏的 Mach-O 会被内核拒绝加载,
    # 先补 adhoc 签名;正式发布时 sign.sh 再用 Developer ID 统一重签
    codesign --force --sign - "$dest" 2>/dev/null
    # 依赖统一收在 Frameworks 顶层(在改写引用前从源文件拿清单)
    while IFS= read -r dep; do
        [[ -z "$dep" ]] && continue
        bundle_lib "$dep" "$FW"
    done < <(deps_of "$src")
}

echo "==> 收集 Homebrew 依赖闭包 ..."
BRIDGE_DEPS=$(deps_of "$BRIDGE")
# 桥库引用改 @rpath,自身 rpath 指向 Frameworks;CMake 链接时烙进的
# Homebrew LC_RPATH 必须删掉,否则装有 Homebrew 的机器会优先命中系统库
strip_homebrew_rpaths "$BRIDGE"
while IFS= read -r dep; do
    [[ -z "$dep" ]] && continue
    install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$BRIDGE"
done <<< "$BRIDGE_DEPS"
install_name_tool -add_rpath "@loader_path/../Frameworks" "$BRIDGE" 2>/dev/null || true
codesign --force --sign - "$BRIDGE" 2>/dev/null   # 同上:改动后先补 adhoc 签名
while IFS= read -r dep; do
    [[ -z "$dep" ]] && continue
    bundle_lib "$dep" "$FW"
done <<< "$BRIDGE_DEPS"

echo "==> 收集 GStreamer 插件与 scanner ..."
# 渲染管线实际用到的插件(镜像 + 音频),前三个是 UxPlay gstreamer_init 硬性检查的:
PLUGINS=(
    libgstapp.dylib                 # appsrc(UxPlay 初始化检查 + 视频注入)
    libgstplayback.dylib            # playbin(UxPlay 初始化检查)
    libgstautodetect.dylib          # autodetect(UxPlay 初始化检查)
    libgstcoreelements.dylib        # queue 等基础元件
    libgstvideoparsersbad.dylib     # h264parse
    libgstlibav.dylib               # avdec_h264(软解)
    libgstvideoconvertscale.dylib   # videoconvert
    libgstopengl.dylib              # glimagesink
    libgstosxaudio.dylib            # osxaudiosink
    libgstaudioconvert.dylib
    libgstaudioresample.dylib
    libgstvolume.dylib
    libgstlevel.dylib               # 音频电平表(UxPlay 音频管线可选但默认带上)
)
for p in "${PLUGINS[@]}"; do
    [[ -f "$GST_PLUGIN_SRC/$p" ]] || { echo "缺少插件: $GST_PLUGIN_SRC/$p" >&2; exit 1; }
    bundle_lib "$GST_PLUGIN_SRC/$p" "$GSTPLUG"
done
bundle_lib "$SCANNER_SRC" "$GSTPLUG" exe

# Avalonia 原生库的 install name/自引用指向 /usr/local/lib(NuGet 包瑕疵),
# 不改写会触发残留校验;改成与文件名一致的 @rpath
AVN="$MACOS/libAvaloniaNative.dylib"
if [[ -f "$AVN" ]]; then
    install_name_tool -id "@rpath/libAvaloniaNative.dylib" "$AVN"
    install_name_tool -change /usr/local/lib/libAvalonia.Native.OSX.dylib \
        "@rpath/libAvaloniaNative.dylib" "$AVN" 2>/dev/null || true
    codesign --force --sign - "$AVN" 2>/dev/null
fi

# 验证:包内不应再有任何 Homebrew 绝对路径引用或 LC_RPATH
# (otool 输出带缩进,必须用 awk 取字段,不能 ^ 锚定 grep)
echo "==> 校验残留绝对路径引用 ..."
residual=0
while IFS= read -r f; do
    if otool -L "$f" 2>/dev/null | awk '{print $1}' | grep -qE '^/(opt/homebrew|usr/local)/'; then
        echo "  残留依赖: $f" >&2; residual=1
    fi
    if otool -l "$f" 2>/dev/null | awk '/LC_RPATH/{f=1} f && /path /{print $2; f=0}' \
            | grep -qE '^/(opt/homebrew|usr/local)/'; then
        echo "  残留 rpath: $f" >&2; residual=1
    fi
done < <(find "$APP/Contents" -type f \( -name "*.dylib" -o -perm +111 \))
[[ $residual -eq 0 ]] || { echo "依赖改写不完整" >&2; exit 1; }

echo "==> 完成: $(find "$FW" -type f | wc -l | tr -d ' ') 个文件收进 Frameworks"
