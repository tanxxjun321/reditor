using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Media;
using Avalonia.Styling;
using Avalonia.Threading;
using REditor.AirPlay;

namespace REditor;

public partial class MainWindow : Window {
    public MainWindow() {
        InitializeComponent();

        FooterText.Text = $"Ready · {RuntimeInformation.OSDescription}";

        // 平台适配：仅在 macOS 启用扩展标题栏 + Vibrancy
        bool isMacOS = RuntimeInformation.IsOSPlatform(OSPlatform.OSX);
        if (isMacOS) {
            TitleBar.IsVisible = true;

            // macOS 原生方案：保留 NSWindow（自带圆角、阴影、描边、交通灯按钮），
            // 内容扩展到标题栏，Vibrancy 用窗口级 AcrylicBlur，系统会把它裁剪到原生圆角内。
            // （控件级 ExperimentalAcrylicBorder 在 macOS 上没有模糊实现，不可用。）
            ExtendClientAreaToDecorationsHint = true;
            ExtendClientAreaTitleBarHeightHint = 28;
            TransparencyLevelHint = new List<WindowTransparencyLevel> { WindowTransparencyLevel.AcrylicBlur };
            Background = new SolidColorBrush(Colors.Transparent, 0);
        } else {
            TitleBar.IsVisible = false;
        }
    }

    protected override void OnOpened(EventArgs e) {
        base.OnOpened(e);
        UpdateThemeButton();
        VideoHost.Service.ServerEvent += OnAirPlayEvent;
        VideoArea.SizeChanged += (_, _) => UpdateVideoHostSize();
    }

    protected override void OnClosing(WindowClosingEventArgs e) {
        VideoHost.Service.ServerEvent -= OnAirPlayEvent;
        VideoHost.Service.Dispose();
        base.OnClosing(e);
    }

    // ---------- 页面导航 ----------

    private void OnNavSelectionChanged(object? sender, SelectionChangedEventArgs e) {
        bool mirror = NavList.SelectedIndex == 3;
        MirrorPage.IsVisible = mirror;
        EditorPage.IsVisible = !mirror;
    }

    // ---------- iPhone 投屏 ----------

    // 视频画面宽高比(w/h),0 表示未知(未连接时视频区填满)
    private double _videoAspect;

    private void OnMirrorToggleClicked(object? sender, RoutedEventArgs e) {
        var service = VideoHost.Service;
        if (service.IsRunning) {
            service.Stop();
            return;
        }
        try {
            service.Start("REditor");
        } catch (Exception ex) {
            MirrorStatusText.Text = $"启动失败:{ex.Message}";
        }
    }

    private void OnAirPlayEvent(object? sender, AirPlayService.EventArgs e) {
        // 原生回调可能来自任意线程
        Dispatcher.UIThread.Post(() => ApplyAirPlayEvent(e));
    }

    /// <summary>让视频宿主区保持与手机画面相同的宽高比(多余区域留黑)。</summary>
    private void UpdateVideoHostSize() {
        if (_videoAspect <= 0) {
            VideoHost.Width = double.NaN;
            VideoHost.Height = double.NaN;
            return;
        }
        double availW = VideoArea.Bounds.Width;
        double availH = VideoArea.Bounds.Height;
        if (availW <= 0 || availH <= 0) return;
        if (availW / availH > _videoAspect) {
            VideoHost.Height = availH;
            VideoHost.Width = availH * _videoAspect;
        } else {
            VideoHost.Width = availW;
            VideoHost.Height = availW / _videoAspect;
        }
    }

    private void ApplyAirPlayEvent(AirPlayService.EventArgs e) {
        switch (e.Type) {
            case AirPlayService.EventType.Waiting:
                MirrorStatusText.Text = "等待 iPhone 连接…";
                MirrorToggleButton.Content = "停止接收";
                MirrorResolutionText.Text = string.Empty;
                break;
            case AirPlayService.EventType.Connected:
                MirrorStatusText.Text = $"已连接:{e.Info}";
                break;
            case AirPlayService.EventType.Disconnected:
                MirrorStatusText.Text = "等待 iPhone 连接…";
                MirrorResolutionText.Text = string.Empty;
                break;
            case AirPlayService.EventType.VideoSize:
                MirrorResolutionText.Text = $"{e.Width} × {e.Height}";
                if (e.Width > 0 && e.Height > 0) {
                    _videoAspect = (double)e.Width / e.Height;
                    UpdateVideoHostSize();
                }
                break;
            case AirPlayService.EventType.Error:
                MirrorStatusText.Text = $"错误:{e.Info}";
                break;
            case AirPlayService.EventType.Stopped:
                MirrorStatusText.Text = "未启动";
                MirrorToggleButton.Content = "开始接收";
                MirrorResolutionText.Text = string.Empty;
                _videoAspect = 0;
                UpdateVideoHostSize();
                break;
        }
    }

    private void OnGreetClicked(object? sender, RoutedEventArgs e) {
        var input = InputBox.Text?.Trim();
        OutputText.Text = string.IsNullOrEmpty(input)
            ? "你还没有输入任何内容。"
            : $"你输入了：{input}";
        OutputCard.IsVisible = true;
    }

    private void OnClearClicked(object? sender, RoutedEventArgs e) {
        InputBox.Text = string.Empty;
        OutputCard.IsVisible = false;
    }

    private void OnToggleTheme(object? sender, RoutedEventArgs e) {
        var app = Application.Current!;
        app.RequestedThemeVariant = ActualThemeVariant == ThemeVariant.Dark
            ? ThemeVariant.Light
            : ThemeVariant.Dark;
        UpdateThemeButton();
    }

    private void UpdateThemeButton() {
        // 图标本身不变（太阳月亮合一）
    }

    private void OnTitleBarPointerPressed(object? sender, PointerPressedEventArgs e) {
        // 双击最大化/还原
        if (e.ClickCount == 2) {
            WindowState = WindowState == WindowState.Maximized
                ? WindowState.Normal
                : WindowState.Maximized;
            return;
        }

        // 拖拽移动窗口
        if (e.GetCurrentPoint(this).Properties.IsLeftButtonPressed) {
            BeginMoveDrag(e);
        }
    }
}
