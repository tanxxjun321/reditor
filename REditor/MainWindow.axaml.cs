using System;
using System.Runtime.InteropServices;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Interactivity;
using Avalonia.Styling;

namespace REditor;

public partial class MainWindow : Window {
    public MainWindow() {
        InitializeComponent();
        FooterText.Text = $"{RuntimeInformation.FrameworkDescription} · {RuntimeInformation.OSDescription}";
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
        ThemeButton.Content = ActualThemeVariant == ThemeVariant.Dark
            ? "☀️ 浅色模式"
            : "🌙 深色模式";
    }
}
