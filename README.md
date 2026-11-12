# REditor(命名待定)

macOS 上的专业 AirPlay 投屏接收器:启动后,iPhone/iPad(与 Mac 同一 WiFi)
在 控制中心 → 屏幕镜像 中选择本机,画面和声音即显示在应用窗口内。

功能规划见 [PRD-airplay-mirror.md](PRD-airplay-mirror.md)。

## 功能

- AirPlay 屏幕镜像接收,H.264 硬解渲染,画面按比例居中
- 声音跟随系统默认输出设备,支持 App 内增益调节
- 自定义设备名称(设置面板),接收中改名自动重启接收
- 空态三步连接引导、深浅色主题、设置持久化
  (`~/Library/Application Support/REditor/settings.json`)

## 开发

```bash
cd REditor
dotnet build      # 编译
dotnet run        # 运行
```

## 实现方式

原生桥 `native/`(C/ObjC++)封装了 [UxPlay](https://github.com/FDH2/UxPlay)
的协议核心(vendored 于 `native/uxplay/`,GPLv3)与 GStreamer 渲染管线
(osxvideosink 硬解渲染进 Avalonia `NativeControlHost` 托管的 NSView,
osxaudiosink 播放声音),C# 侧通过 P/Invoke 调用(`REditor/AirPlay/`)。

**首次构建原生桥需要 Homebrew 依赖:**

```bash
brew install cmake pkg-config gstreamer gst-plugins-base gst-plugins-good \
    gst-plugins-bad gst-libav libplist openssl@3
make bridge        # 或 ./native/build.sh,生成 native/build/libairplaybridge.dylib
```

注意:UxPlay 为 GPLv3 许可,链接它的产物分发时需以 GPL 兼容方式开源。
首次使用如 iPhone 搜不到设备,请检查 系统设置 → 隐私与安全性 → 本地网络 权限。

## 发布(打包)

```bash
./build.sh mac      # macOS Apple Silicon → publish/REditor.app
./build.sh mac-x64  # macOS Intel → publish/REditor-x64.app
```

`./build.sh win` 的 Windows 打包目标为历史遗留,投屏功能仅 macOS 可用,
后续随 P4 发布阶段裁剪。

已开启 **Native AOT**(`REditor.csproj` 中 `PublishAot=true`,当前开发期注释):
产物为原生机器码,启动快、体积小,无需 .NET 运行时。

## 说明

- **macOS**:`.app` 未签名,首次运行如被 Gatekeeper 拦截,执行
  `xattr -dr com.apple.quarantine publish/REditor.app` 后再打开。
  (签名与公证在 P4 阶段解决。)
- UI 代码在 `REditor/MainWindow.axaml`(界面)和 `MainWindow.axaml.cs`(逻辑)。
