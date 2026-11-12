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
    private readonly AirPlayService _service = new();
    private readonly bool _isMacOS;
    private IntPtr _videoViewHandle;
    private IntPtr _windowHandle;

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
        _service.ServerEvent += OnAirPlayEvent;
        // 视频视图嵌入窗口视图层级的最底部(悬浮层之下),见 airplay_attach_video_view
        var platformHandle = TryGetPlatformHandle();
        if (_isMacOS && platformHandle is { HandleDescriptor: "NSWindow" }) {
            _windowHandle = platformHandle.Handle;
            _videoViewHandle = _service.AttachVideoView(_windowHandle);
        }
        if (SettingsButton.Flyout is Flyout flyout) {
            flyout.Opened += (_, _) => _flyoutOpen = true;
            flyout.Closed += (_, _) => _flyoutOpen = false;
        }
    }

    protected override void OnClosing(WindowClosingEventArgs e) {
        _service.ServerEvent -= OnAirPlayEvent;
        _service.Dispose();
        if (_videoViewHandle != IntPtr.Zero) {
            _service.DetachVideoView(_videoViewHandle);
            _videoViewHandle = IntPtr.Zero;
        }
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
        // 光标随悬浮层一起隐藏,鼠标一动自动恢复(macOS 原生行为);仅全屏时才隐藏光标
        if (_isMacOS && WindowState == WindowState.FullScreen)
            _service.HideCursorUntilMouseMoves();
    }

    /// <summary>悬浮层在连接中即自动隐藏(全屏/窗口模式一致);光标隐藏是全屏专属,见 HideChrome。</summary>
    private bool ShouldAutoHideChrome => _mirroring;

    private void RefreshChromeVisibility() {
        _chromeTimer.Stop();
        ShowChrome();
        if (ShouldAutoHideChrome) _chromeTimer.Start();
    }

    // 进入全屏前的窗口位置尺寸,用于退出全屏时恢复(Avalonia 恢复的尺寸会少一截标题栏高度)
    private (Size size, PixelPoint pos)? _preFullscreenBounds;

    protected override void OnPropertyChanged(AvaloniaPropertyChangedEventArgs change) {
        base.OnPropertyChanged(change);
        if (change.Property != WindowStateProperty) return;
        var oldState = change.GetOldValue<WindowState>();
        var newState = change.GetNewValue<WindowState>();

        if (_isMacOS && newState == WindowState.FullScreen && oldState != WindowState.FullScreen)
            _preFullscreenBounds = (new Size(Width, Height), Position);

        // 退出全屏后 macOS 会把系统标题栏还给窗口;重新应用扩展标题栏设置,
        // 恢复窗口尺寸,并重置窗口为不透明 + 隐藏标题栏材质(见 airplay_window_chrome_fixup)
        if (_isMacOS && oldState == WindowState.FullScreen && newState != WindowState.FullScreen) {
            ExtendClientAreaToDecorationsHint = false;
            Dispatcher.UIThread.Post(() => {
                ExtendClientAreaToDecorationsHint = true;
                ExtendClientAreaTitleBarHeightHint = 28;
                if (_preFullscreenBounds is { } bounds) {
                    _preFullscreenBounds = null;
                    Position = bounds.pos;
                    Width = bounds.size.Width;
                    Height = bounds.size.Height;
                }
                if (_windowHandle != IntPtr.Zero)
                    _service.FixupWindowChrome(_windowHandle);
            }, DispatcherPriority.Loaded);
        }

        RefreshChromeVisibility();
    }

    protected override void OnPointerMoved(PointerEventArgs e) {
        base.OnPointerMoved(e);
        if (!_mirroring) return;
        ShowChrome();
        _chromeTimer.Stop();
        if (ShouldAutoHideChrome) _chromeTimer.Start();
    }

    // ---------- iPhone 投屏 ----------

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
        _service.SetGain(v);
        if (Math.Abs(_settings.Gain - v) > 0.001) {
            _settings.Gain = v;
            _settings.Save();
        }
    }

    private void OnMirrorToggleClicked(object? sender, RoutedEventArgs e) {
        var service = _service;
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
            var service = _service;
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
                RefreshChromeVisibility();
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

    private void OnBackgroundPointerPressed(object? sender, PointerPressedEventArgs e) {
        // 视频渲染在 Avalonia 之下的原生视图里,双击窗口任意位置都会到达这里
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
