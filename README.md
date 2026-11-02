# REditor

基于 Avalonia + .NET 10 的跨平台桌面 UI 程序，可编译 Windows 和 macOS 版本。

## 开发

```bash
cd REditor
dotnet build      # 编译
dotnet run        # 运行
```

## iPhone 投屏(AirPlay 接收端,仅 macOS)

应用内置 AirPlay 接收器:侧边栏「投屏」→「开始接收」后,iPhone(与 Mac 同一
WiFi)在 控制中心 → 屏幕镜像 中选择「REditor」,画面和声音即显示在应用窗口内。

实现方式:原生桥 `native/`(C/ObjC++)封装了 [UxPlay](https://github.com/FDH2/UxPlay)
的协议核心(vendored 于 `native/uxplay/`,GPLv3)与 GStreamer 渲染管线
(osxvideosink 硬解渲染进 Avalonia `NativeControlHost` 托管的 NSView,osxaudiosink
播放声音),C# 侧通过 P/Invoke 调用(`REditor/AirPlay/`)。

**首次构建原生桥需要 Homebrew 依赖:**

```bash
brew install cmake pkg-config gstreamer gst-plugins-base gst-plugins-good \
    gst-plugins-bad gst-libav libplist openssl@3
make bridge        # 或 ./native/build.sh,生成 native/build/libairplaybridge.dylib
```

注意:UxPlay 为 GPLv3 许可,链接它的 REditor 分发时需以 GPL 兼容方式开源。
首次使用如 iPhone 搜不到设备,请检查 系统设置 → 隐私与安全性 → 本地网络 权限。

## 发布（打包）

```bash
./build.sh          # 编译 Windows (win-x64) + macOS (osx-arm64) 全部版本
./build.sh win      # 仅 Windows → publish/win-x64/REditor.exe
./build.sh mac      # 仅 macOS Apple Silicon → publish/REditor.app
./build.sh mac-x64  # macOS Intel → publish/REditor-x64.app
```

已开启 **Native AOT**（`REditor.csproj` 中 `PublishAot=true`）：产物为原生机器码，
启动快、体积小，无需 .NET 运行时。注意 AOT 不能跨操作系统编译——macOS 版在 Mac 上
构建即 AOT 产物；Windows 版的 AOT 需在 Windows 机器上执行 `./build.sh win`（在非
Windows 主机会自动退回为自包含单文件 exe）。

## 说明

- **Windows**：直接双击 `REditor.exe` 即可运行。
- **macOS**：`.app` 未签名，首次运行如被 Gatekeeper 拦截，执行
  `xattr -dr com.apple.quarantine publish/REditor.app` 后再打开。
- UI 代码在 `REditor/MainWindow.axaml`（界面）和 `MainWindow.axaml.cs`（逻辑）。
