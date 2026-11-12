using System;
using System.Runtime.InteropServices;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Input;
using Avalonia.Interactivity;
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

        // 恢复持久化的设置
        GainSlider.Value = _settings.Gain;
        GainText.Text = $"{(int)(_settings.Gain * 100)}%";
        DeviceNameBox.Text = _settings.DeviceName;
        GuideDeviceNameText.Text = $"3. 选择「{_settings.DeviceName}」";
        ThemeCombo.SelectedIndex = _settings.Theme switch { "Light" => 1, "Dark" => 2, _ => 0 };
        ApplySavedTheme();
        Topmost = _settings.Topmost;
        UpdatePinButton();

        // 平台适配：仅在 macOS 启用扩展标题栏(内容延伸到交通灯按钮区域)
        _isMacOS = RuntimeInformation.IsOSPlatform(OSPlatform.OSX);
        if (_isMacOS) {
            ExtendClientAreaToDecorationsHint = true;
            ExtendClientAreaTitleBarHeightHint = 28;
        }

        // 悬浮层自动隐藏计时器:连接中鼠标静止一段时间后淡出
        _chromeTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2.5) };
        _chromeTimer.Tick += (_, _) => {
            _chromeTimer.Stop();
            if (_mirroring && !_flyoutOpen) HideChrome();
        };
    }

    protected override void OnOpened(EventArgs e) {
        base.OnOpened(e);
        VideoHost.Service.ServerEvent += OnAirPlayEvent;
        VideoArea.SizeChanged += (_, _) => UpdateVideoHostSize();
        VideoArea.PointerPressed += OnVideoAreaPointerPressed;
        if (SettingsButton.Flyout is Flyout flyout) {
            flyout.Opened += (_, _) => _flyoutOpen = true;
            flyout.Closed += (_, _) => _flyoutOpen = false;
        }
    }

    protected override void OnClosing(WindowClosingEventArgs e) {
        VideoHost.Service.ServerEvent -= OnAirPlayEvent;
        VideoHost.Service.Dispose();
        base.OnClosing(e);
    }

    // ---------- 悬浮层:自动隐藏/唤醒 ----------

    private readonly DispatcherTimer _chromeTimer;
    private bool _mirroring;   // 有设备连接时为 true,此时悬浮层才会自动隐藏
    private bool _flyoutOpen;  // 设置面板打开时不隐藏悬浮层

    private void ShowChrome() {
        if (!_borderless) {
            TopBar.Opacity = 1;
            TopBar.IsHitTestVisible = true;
        }
        Toolbar.Opacity = 1;
        Toolbar.IsHitTestVisible = true;
    }

    private void HideChrome() {
        TopBar.Opacity = 0;
        TopBar.IsHitTestVisible = false;
        Toolbar.Opacity = 0;
        Toolbar.IsHitTestVisible = false;
        // 光标随悬浮层一起隐藏,鼠标一动自动恢复(macOS 原生行为)
        if (_isMacOS) VideoHost.Service.HideCursorUntilMouseMoves();
    }

    protected override void OnPointerMoved(PointerEventArgs e) {
        base.OnPointerMoved(e);
        if (!_mirroring) return;
        ShowChrome();
        _chromeTimer.Stop();
        _chromeTimer.Start();
    }

    // ---------- iPhone 投屏 ----------

    // 视频画面宽高比(w/h),0 表示未知(未连接时视频区填满)
    private double _videoAspect;

    // 顶部状态文字的组成部分
    private string _statusText = "REditor";
    private string _resolutionText = "";

    private void OnGainChanged(object? sender, RangeBaseValueChangedEventArgs e) {
        double v = e.NewValue;
        // 吸附:拖进 100% 附近时归位,否则滑杆上很难精确选中 100%
        if (Math.Abs(v - 1.0) < 0.05) {
            if (Math.Abs(GainSlider.Value - 1.0) > 0.0001) {
                GainSlider.Value = 1.0; // 再次触发本事件,走 v == 1.0 分支
                return;
            }
            v = 1.0;
        }
        GainText.Text = $"{(int)Math.Round(v * 100)}%";
        VideoHost.Service.SetGain(v);
        if (Math.Abs(_settings.Gain - v) > 0.001) {
            _settings.Gain = v;
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
            SetStatus($"启动失败:{ex.Message}");
        }
    }

    private void OnApplySettings(object? sender, RoutedEventArgs e) {
        var name = DeviceNameBox.Text?.Trim();

        // 外观
        _settings.Theme = ThemeCombo.SelectedIndex switch { 1 => "Light", 2 => "Dark", _ => null };
        ApplySavedTheme();

        // 设备名称
        if (!string.IsNullOrEmpty(name) && name != _settings.DeviceName) {
            _settings.DeviceName = name;
            GuideDeviceNameText.Text = $"3. 选择「{name}」";

            // 接收中改名:重启接收使新名字生效
            var service = VideoHost.Service;
            if (service.IsRunning) {
                service.Stop();
                try {
                    service.Start(name);
                } catch (Exception ex) {
                    SetStatus($"启动失败:{ex.Message}");
                }
            }
        }

        _settings.Save();
        SettingsButton.Flyout?.Hide();
    }

    private void SetStatus(string text) => StatusText.Text = _statusText = text;

    private void RefreshStatus() =>
        StatusText.Text = string.IsNullOrEmpty(_resolutionText)
            ? _statusText
            : $"{_statusText} · {_resolutionText}";

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
                SetStatus("等待 iPhone 连接…");
                MirrorToggleButton.Content = "停止接收";
                _resolutionText = "";
                RefreshStatus();
                UpdateEmptyState(true, "正在等待 iPhone 连接…");
                break;
            case AirPlayService.EventType.Connected:
                _mirroring = true;
                SetStatus($"已连接:{e.Info}");
                UpdateEmptyState(false, "");
                _chromeTimer.Start();
                break;
            case AirPlayService.EventType.Disconnected:
                _mirroring = false;
                _chromeTimer.Stop();
                ShowChrome();
                SetStatus("等待 iPhone 连接…");
                _resolutionText = "";
                RefreshStatus();
                UpdateEmptyState(true, "正在等待 iPhone 连接…");
                break;
            case AirPlayService.EventType.VideoSize:
                _resolutionText = $"{e.Width} × {e.Height}";
                RefreshStatus();
                if (e.Width > 0 && e.Height > 0) {
                    _videoAspect = (double)e.Width / e.Height;
                    UpdateVideoHostSize();
                }
                break;
            case AirPlayService.EventType.Error:
                SetStatus($"错误:{e.Info}");
                break;
            case AirPlayService.EventType.Stopped:
                _mirroring = false;
                _chromeTimer.Stop();
                ShowChrome();
                SetStatus("REditor");
                MirrorToggleButton.Content = "开始接收";
                _resolutionText = "";
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
        // 视频视图是事件穿透的,双击画面任意位置都会到达这里
        if (e.ClickCount == 2) OnToggleFullscreen(sender, e);
    }

    private void OnEnterBorderless(object? sender, RoutedEventArgs e) => SetBorderless(true);

    /// <summary>无边框展示模式:隐藏顶部栏(悬浮工具栏仍随鼠标静止自动隐藏)。</summary>
    private void SetBorderless(bool on) {
        _borderless = on;
        TopBar.IsVisible = !on;
        if (!on) ShowChrome();
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
