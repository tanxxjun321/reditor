using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Media;
using Avalonia.Styling;

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
