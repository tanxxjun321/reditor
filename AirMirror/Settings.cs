using System;
using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace AirMirror;

/// <summary>
/// 应用设置,持久化到 ~/Library/Application Support/AirMirror/settings.json。
/// 首次启动时从旧目录 REditor 迁移。读取失败(文件缺失/损坏)时回落到默认值;
/// 写失败不影响功能。
/// </summary>
public sealed class Settings {
    /// <summary>设备名称:iPhone 屏幕镜像列表中显示的名字。</summary>
    public string DeviceName { get; set; } = "AirMirror";

    /// <summary>App 内音频增益,1.0 = 跟随手机音量。</summary>
    public double Gain { get; set; } = 1.0;

    /// <summary>窗口置顶。</summary>
    public bool Topmost { get; set; }

    /// <summary>"Dark" / "Light" / null = 跟随系统。</summary>
    public string? Theme { get; set; }

    /// <summary>连接密码(UxPlay 原生摘要认证);空字符串 = 不需要密码。</summary>
    public string Password { get; set; } = "";

    /// <summary>设备接入/断开时发送 macOS 通知。</summary>
    public bool NotifyOnConnection { get; set; } = true;

    private static string DirPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "AirMirror");
    private static string FilePath => Path.Combine(DirPath, "settings.json");
    private static string LegacyFilePath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "REditor", "settings.json");

    public static Settings Load() {
        try {
            // 改名前的旧设置目录,做一次只读迁移
            var path = File.Exists(FilePath) ? FilePath
                     : File.Exists(LegacyFilePath) ? LegacyFilePath
                     : null;
            if (path != null) {
                var s = JsonSerializer.Deserialize(File.ReadAllText(path),
                            SettingsJsonContext.Default.Settings) ?? new Settings();
                // 旧默认设备名跟随产品改名(用户显式改过的名字不受影响)
                if (s.DeviceName == "REditor") s.DeviceName = "AirMirror";
                return s;
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
