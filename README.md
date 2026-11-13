# AirMirror

macOS 上的专业 AirPlay 投屏接收器:启动后,iPhone/iPad(与 Mac 同一 WiFi)
在 控制中心 → 屏幕镜像 中选择本机,画面和声音即显示在应用窗口内。

功能规划见 [PRD-airplay-mirror.md](PRD-airplay-mirror.md)。

## 功能

- AirPlay 屏幕镜像接收,H.264 解码渲染,画面按比例居中留黑
- 声音跟随系统默认输出设备,支持 App 内增益调节
- 窗口即画面:悬浮工具栏自动隐藏、双击全屏、窗口置顶、无边框展示模式
- 实时统计:分辨率 / 帧率 / 码率显示在顶部状态栏
- 连接密码保护(UxPlay 原生摘要认证,防止同 WiFi 下误投)
- 设备接入/断开的 macOS 通知(可在设置中关闭)
- 自定义设备名称(设置面板),接收中改名自动重启接收
- 空态三步连接引导 + 本地网络权限直达按钮、深浅色主题、设置持久化
  (`~/Library/Application Support/AirMirror/settings.json`)

## 开发

```bash
make bridge       # 构建原生桥(首次需要,见下方依赖)
make run          # dotnet run
```

**首次构建原生桥需要 Homebrew 依赖:**

```bash
brew install cmake pkg-config gstreamer gst-plugins-base gst-plugins-good \
    gst-plugins-bad gst-libav libplist openssl@3
```

注意:首次使用如 iPhone 搜不到设备,请检查 系统设置 → 隐私与安全性 →
本地网络 权限(空态页有直达按钮)。

## 实现方式

原生桥 `native/`(C/ObjC++)封装了 [UxPlay](https://github.com/FDH2/UxPlay)
的协议核心(vendored 于 `native/uxplay/`,GPLv3)与 GStreamer 渲染管线:
镜像流走 `h264parse ! avdec_h264(软解,规避 vtdec 尾帧滞留) !
videoconvert ! glimagesink`,渲染进窗口视图层级最底部的 NSView(黑底兼作
窗口背景,自动留黑边),Avalonia 悬浮层透明叠加其上;声音走 osxaudiosink。
C# 侧通过 P/Invoke 调用(`AirMirror/AirPlay/`)。

## 发布

```bash
./build.sh mac       # Apple Silicon → publish/AirMirror.app
./build.sh mac-x64   # Intel       → publish/AirMirror-x64.app
./sign.sh            # Developer ID 签名 + 公证 + stapling(前置见脚本注释)
```

`sign.sh` 需要钥匙串中的 Developer ID Application 证书和
`xcrun notarytool store-credentials` 存入的公证凭据;未签名直接分发时,
用户需执行 `xattr -dr com.apple.quarantine publish/AirMirror.app` 才能打开。

## 许可

本项目以 [GPLv3](LICENSE) 开源:它静态链接 GPLv3 许可的 UxPlay 协议核心,
依据 GPL 要求,分发产物时整体以 GPL 兼容协议提供源码。
