using System.Text.Json;

namespace RbaAutoexecManager;

internal sealed class AppSettings
{
  public string SelectedTarget { get; set; } = "Volt";
  public string CustomDirectory { get; set; } = string.Empty;

  private static string SettingsPath
  {
    get
    {
      var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
      return Path.Combine(localAppData, "RBA Autoexec Manager", "settings.json");
    }
  }

  internal static AppSettings Load()
  {
    try
    {
      if (!File.Exists(SettingsPath))
      {
        return new AppSettings();
      }

      return JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(SettingsPath)) ?? new AppSettings();
    }
    catch
    {
      return new AppSettings();
    }
  }

  internal void Save()
  {
    var path = SettingsPath;
    Directory.CreateDirectory(Path.GetDirectoryName(path)!);
    var temporaryPath = $"{path}.{Environment.ProcessId}.tmp";
    File.WriteAllText(temporaryPath, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
    File.Move(temporaryPath, path, overwrite: true);
  }
}
