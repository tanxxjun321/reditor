using System;
using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace REditor;

/// <summary>
/// 应用设置,持久化到 ~/Library/Application Support/REditor/settings.json。
/// 读取失败(文件缺失/损坏)时回落到默认值;写失败不影响功能。
/// </summary>
public sealed class Settings {
    /// <summary>设备名称:iPhone 屏幕镜像列表中显示的名字。</summary>
    public string DeviceName { get; set; } = "REditor";

    /// <summary>App 内音频增益,1.0 = 跟随手机音量。</summary>
    public double Gain { get; set; } = 1.0;

    /// <summary>"Dark" / "Light" / null = 跟随系统。</summary>
    public string? Theme { get; set; }

    private static string DirPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "REditor");
    private static string FilePath => Path.Combine(DirPath, "settings.json");

    public static Settings Load() {
        try {
            if (File.Exists(FilePath)) {
                return JsonSerializer.Deserialize(File.ReadAllText(FilePath),
                           SettingsJsonContext.Default.Settings) ?? new Settings();
            }
        } catch { /* 损坏则用默认值 */ }
        return new Settings();
    }

    public void Save() {
        try {
            Directory.CreateDirectory(DirPath);
            File.WriteAllText(FilePath,
                JsonSerializer.Serialize(this, SettingsJsonContext.Default.Settings));
        } catch { /* 保存失败不影响功能 */ }
    }
}

/// <summary>源生成序列化上下文,保证未来开启 Native AOT 时设置读写仍可用。</summary>
[JsonSourceGenerationOptions(WriteIndented = true)]
[JsonSerializable(typeof(Settings))]
internal partial class SettingsJsonContext : JsonSerializerContext;
