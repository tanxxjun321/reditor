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

        // 平台适配：仅在 macOS 启用自定义窗口 Chrome + Vibrancy
        bool isMacOS = RuntimeInformation.IsOSPlatform(OSPlatform.OSX);
        if (isMacOS) {
            TitleBar.IsVisible = true;
            TrafficLights.IsVisible = true;

            // 启用 Vibrancy：无边框窗口 + 透明背景
            SystemDecorations = WindowDecorations.None;
            TransparencyLevelHint = new List<WindowTransparencyLevel> { WindowTransparencyLevel.AcrylicBlur };
            Background = new SolidColorBrush(Colors.Transparent, 0);
        } else {
            TitleBar.IsVisible = false;
            TrafficLights.IsVisible = false;
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

    private void OnCloseClick(object? sender, PointerPressedEventArgs e) {
        Close();
    }

    private void OnMinimizeClick(object? sender, PointerPressedEventArgs e) {
        WindowState = WindowState.Minimized;
    }

    private void OnMaximizeClick(object? sender, PointerPressedEventArgs e) {
        WindowState = WindowState == WindowState.Maximized
            ? WindowState.Normal
            : WindowState.Maximized;
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
