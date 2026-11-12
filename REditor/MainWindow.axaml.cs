using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Media;
using Avalonia.Styling;
using Avalonia.Threading;
using REditor.AirPlay;

namespace REditor;

public partial class MainWindow : Window {
    private readonly Settings _settings;
    private readonly bool _isMacOS;

    public MainWindow() {
        InitializeComponent();

        _settings = Settings.Load();
        FooterText.Text = $"Ready · {RuntimeInformation.OSDescription}";

        // 恢复持久化的设置
        GainSlider.Value = _settings.Gain;
        GainText.Text = $"{(int)(_settings.Gain * 100)}%";
        DeviceNameBox.Text = _settings.DeviceName;
        GuideDeviceNameText.Text = $"3. 选择「{_settings.DeviceName}」";
        Topmost = _settings.Topmost;
        UpdatePinButton();
        ApplySavedTheme();

        // 平台适配：仅在 macOS 启用扩展标题栏 + Vibrancy
        _isMacOS = RuntimeInformation.IsOSPlatform(OSPlatform.OSX);
        if (_isMacOS) {
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
        VideoHost.Service.ServerEvent += OnAirPlayEvent;
        VideoArea.SizeChanged += (_, _) => UpdateVideoHostSize();
        // 双击画面切换全屏(注意:NSView 区域的手势被原生视图消费,
        // 只有黑色留边区域能触发,全屏按钮是主要入口)
        VideoArea.PointerPressed += OnVideoAreaPointerPressed;
    }

    protected override void OnClosing(WindowClosingEventArgs e) {
        VideoHost.Service.ServerEvent -= OnAirPlayEvent;
        VideoHost.Service.Dispose();
        base.OnClosing(e);
    }

    // ---------- iPhone 投屏 ----------

    // 视频画面宽高比(w/h),0 表示未知(未连接时视频区填满)
    private double _videoAspect;

    private void OnGainChanged(object? sender, RangeBaseValueChangedEventArgs e) {
        GainText.Text = $"{(int)(e.NewValue * 100)}%";
        VideoHost.Service.SetGain(e.NewValue);
        if (Math.Abs(_settings.Gain - e.NewValue) > 0.001) {
            _settings.Gain = e.NewValue;
            _settings.Save();
        }
    }

    private void OnMirrorToggleClicked(object? sender, RoutedEventArgs e) {
        var service = VideoHost.Service;
        if (service.IsRunning) {
            service.Stop();
            return;
        }
        try {
            service.Start(_settings.DeviceName);
        } catch (Exception ex) {
            MirrorStatusText.Text = $"启动失败:{ex.Message}";
        }
    }

    private void OnApplyDeviceName(object? sender, RoutedEventArgs e) {
        var name = DeviceNameBox.Text?.Trim();
        if (string.IsNullOrEmpty(name)) return;

        _settings.DeviceName = name;
        _settings.Save();
        GuideDeviceNameText.Text = $"3. 选择「{name}」";
        SettingsButton.Flyout?.Hide();

        // 接收中改名:重启接收使新名字生效
        var service = VideoHost.Service;
        if (service.IsRunning) {
            service.Stop();
            try {
                service.Start(name);
            } catch (Exception ex) {
                MirrorStatusText.Text = $"启动失败:{ex.Message}";
            }
        }
    }

    private void OnAirPlayEvent(object? sender, AirPlayService.EventArgs e) {
        // 原生回调可能来自任意线程;先落盘诊断日志,再回 UI 线程
        LogAirPlayEvent(e);
        Dispatcher.UIThread.Post(() => ApplyAirPlayEvent(e));
    }

    private static readonly string AirPlayLogPath =
        System.IO.Path.Combine(System.IO.Path.GetTempPath(), "reditor_airplay.log");
    private static readonly object AirPlayLogLock = new();

    private static void LogAirPlayEvent(AirPlayService.EventArgs e) {
        try {
            lock (AirPlayLogLock) {
                System.IO.File.AppendAllText(AirPlayLogPath,
                    $"{DateTime.Now:HH:mm:ss.fff} [{e.Type}] {e.Info ?? ""} {e.Width}x{e.Height}\n");
            }
        } catch { /* 日志失败不影响功能 */ }
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

    /// <summary>空态引导页:未连接时显示,已连接时隐藏。</summary>
    private void UpdateEmptyState(bool visible, string title) {
        EmptyState.IsVisible = visible;
        EmptyStateTitle.Text = title;
    }

    private void ApplyAirPlayEvent(AirPlayService.EventArgs e) {
        switch (e.Type) {
            case AirPlayService.EventType.Waiting:
                MirrorStatusText.Text = "等待 iPhone 连接…";
                MirrorToggleButton.Content = "停止接收";
                MirrorResolutionText.Text = string.Empty;
                UpdateEmptyState(true, "正在等待 iPhone 连接…");
                break;
            case AirPlayService.EventType.Connected:
                MirrorStatusText.Text = $"已连接:{e.Info}";
                UpdateEmptyState(false, "");
                break;
            case AirPlayService.EventType.Disconnected:
                MirrorStatusText.Text = "等待 iPhone 连接…";
                MirrorResolutionText.Text = string.Empty;
                UpdateEmptyState(true, "正在等待 iPhone 连接…");
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
                UpdateEmptyState(true, "尚未开始接收");
                break;
        }
    }

    // ---------- 窗口模式:置顶 / 全屏 / 无边框 ----------

    private bool _borderless;

    private void OnToggleTopmost(object? sender, RoutedEventArgs e) {
        Topmost = !Topmost;
        _settings.Topmost = Topmost;
        _settings.Save();
        UpdatePinButton();
    }

    private void UpdatePinButton() => PinButton.Opacity = Topmost ? 1.0 : 0.45;

    private void OnToggleFullscreen(object? sender, RoutedEventArgs e) {
        WindowState = WindowState == WindowState.FullScreen
            ? WindowState.Normal
            : WindowState.FullScreen;
    }

    private void OnVideoAreaPointerPressed(object? sender, PointerPressedEventArgs e) {
        if (e.ClickCount == 2) OnToggleFullscreen(sender, e);
    }

    private void OnEnterBorderless(object? sender, RoutedEventArgs e) => SetBorderless(true);

    /// <summary>无边框展示模式:隐藏标题栏/控制栏/状态栏,视频区铺满窗口。</summary>
    private void SetBorderless(bool on) {
        _borderless = on;
        TitleBar.IsVisible = !on && _isMacOS;
        ControlBar.IsVisible = !on;
        StatusBar.IsVisible = !on;
        VideoCard.Margin = on ? new Thickness(0) : new Thickness(24, 16, 24, 16);
    }

    protected override void OnKeyDown(KeyEventArgs e) {
        base.OnKeyDown(e);
        if (e.Key != Key.Escape) return;
        // ESC 逐层退出:先退出全屏,再退出无边框
        if (WindowState == WindowState.FullScreen) {
            WindowState = WindowState.Normal;
            e.Handled = true;
        } else if (_borderless) {
            SetBorderless(false);
            e.Handled = true;
        }
    }

    // ---------- 主题 ----------

    private void ApplySavedTheme() {
        var app = Application.Current!;
        app.RequestedThemeVariant = _settings.Theme switch {
            "Dark" => ThemeVariant.Dark,
            "Light" => ThemeVariant.Light,
            _ => ThemeVariant.Default,
        };
    }

    private void OnToggleTheme(object? sender, RoutedEventArgs e) {
        var app = Application.Current!;
        bool toDark = ActualThemeVariant != ThemeVariant.Dark;
        app.RequestedThemeVariant = toDark ? ThemeVariant.Dark : ThemeVariant.Light;
        _settings.Theme = toDark ? "Dark" : "Light";
        _settings.Save();
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
