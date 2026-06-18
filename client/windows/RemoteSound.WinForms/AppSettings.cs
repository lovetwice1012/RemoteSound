using System.Text.Json;
using System.Text.Json.Serialization;

namespace RemoteSound.WinForms;

internal sealed class AppSettings
{
    public string ServerUrl { get; set; } = "ws://192.168.1.10:8080";
    public List<string> RecentServerUrls { get; set; } = [];
    public string SourceName { get; set; } = Environment.MachineName + " Speaker";
    public string ClientId { get; set; } = Guid.NewGuid().ToString();
    public string? LastRenderDeviceId { get; set; }
    public int GainPercent { get; set; } = 100;
    public bool AutoReconnect { get; set; } = true;

    [JsonIgnore]
    public float Gain => Math.Clamp(GainPercent, 0, 300) / 100f;
}

internal static class SettingsStore
{
    private static readonly JsonSerializerOptions Options = new()
    {
        WriteIndented = true,
        ReadCommentHandling = JsonCommentHandling.Skip,
        AllowTrailingCommas = true,
    };

    public static string SettingsDirectory => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "RemoteSound",
        "WinFormsClient");

    public static string SettingsPath => Path.Combine(SettingsDirectory, "settings.json");

    public static AppSettings Load()
    {
        try
        {
            if (!File.Exists(SettingsPath))
            {
                return new AppSettings();
            }

            var json = File.ReadAllText(SettingsPath);
            var settings = JsonSerializer.Deserialize<AppSettings>(json, Options) ?? new AppSettings();
            Normalize(settings);
            return settings;
        }
        catch
        {
            return new AppSettings();
        }
    }

    public static void Save(AppSettings settings)
    {
        Normalize(settings);
        Directory.CreateDirectory(SettingsDirectory);
        File.WriteAllText(SettingsPath, JsonSerializer.Serialize(settings, Options));
    }

    public static void RememberServerUrl(AppSettings settings, string url)
    {
        url = url.Trim();
        if (url.Length == 0)
        {
            return;
        }

        settings.ServerUrl = url;
        settings.RecentServerUrls.RemoveAll(x => string.Equals(x, url, StringComparison.OrdinalIgnoreCase));
        settings.RecentServerUrls.Insert(0, url);
        if (settings.RecentServerUrls.Count > 12)
        {
            settings.RecentServerUrls.RemoveRange(12, settings.RecentServerUrls.Count - 12);
        }
    }

    private static void Normalize(AppSettings settings)
    {
        settings.ServerUrl = string.IsNullOrWhiteSpace(settings.ServerUrl)
            ? "ws://192.168.1.10:8080"
            : settings.ServerUrl.Trim();

        settings.SourceName = string.IsNullOrWhiteSpace(settings.SourceName)
            ? Environment.MachineName + " Speaker"
            : settings.SourceName.Trim();

        settings.ClientId = Guid.TryParse(settings.ClientId, out _)
            ? settings.ClientId
            : Guid.NewGuid().ToString();

        settings.GainPercent = Math.Clamp(settings.GainPercent, 0, 300);

        settings.RecentServerUrls = settings.RecentServerUrls
            .Where(x => !string.IsNullOrWhiteSpace(x))
            .Select(x => x.Trim())
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .Take(12)
            .ToList();

        if (!settings.RecentServerUrls.Contains(settings.ServerUrl, StringComparer.OrdinalIgnoreCase))
        {
            settings.RecentServerUrls.Insert(0, settings.ServerUrl);
        }
    }
}
