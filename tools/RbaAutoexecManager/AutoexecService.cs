using System.Reflection;
using System.Security.Cryptography;

namespace RbaAutoexecManager;

internal enum LoaderState
{
  Disabled,
  Current,
  Outdated
}

internal sealed record LoaderStatus(
    LoaderState State,
    string Directory,
    string TargetPath,
    long InstalledBytes,
    string SourceHash,
    string? InstalledHash);

internal sealed record LoaderActionResult(bool Changed, string Message, string? BackupPath = null);

internal sealed class AutoexecService
{
  internal const string LoaderFileName = "rba_autoloader.lua";
  private const string LoaderResourceName = "RbaAutoexecManager.Resources.rba_autoloader.lua";
  private readonly byte[] _loaderBytes;
  private readonly string _sourceHash;

  internal AutoexecService()
  {
    using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream(LoaderResourceName)
        ?? throw new InvalidOperationException("The embedded RBA autoloader is missing from this build.");
    using var memory = new MemoryStream();
    stream.CopyTo(memory);
    _loaderBytes = memory.ToArray();
    _sourceHash = Hash(_loaderBytes);
  }

  internal static string DefaultDirectory(string executorName)
  {
    var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
    if (string.IsNullOrWhiteSpace(localAppData))
    {
      throw new InvalidOperationException("Windows did not provide a Local AppData directory.");
    }

    return Path.Combine(localAppData, executorName, "autoexec");
  }

  internal LoaderStatus GetStatus(string directory)
  {
    var normalized = NormalizeDirectory(directory);
    var targetPath = Path.Combine(normalized, LoaderFileName);
    if (!File.Exists(targetPath))
    {
      return new LoaderStatus(LoaderState.Disabled, normalized, targetPath, 0, _sourceHash, null);
    }

    var installed = File.ReadAllBytes(targetPath);
    var installedHash = Hash(installed);
    var state = CryptographicOperations.FixedTimeEquals(
        Convert.FromHexString(_sourceHash),
        Convert.FromHexString(installedHash))
        ? LoaderState.Current
        : LoaderState.Outdated;
    return new LoaderStatus(state, normalized, targetPath, installed.LongLength, _sourceHash, installedHash);
  }

  internal LoaderActionResult Enable(string directory)
  {
    var status = GetStatus(directory);
    if (status.State == LoaderState.Current)
    {
      return new LoaderActionResult(false, "The RBA autoloader is already enabled and current.");
    }

    Directory.CreateDirectory(status.Directory);
    string? backupPath = null;
    if (File.Exists(status.TargetPath))
    {
      backupPath = NextSidecarPath(status.TargetPath, "bak");
      File.Copy(status.TargetPath, backupPath, overwrite: false);
    }

    var temporaryPath = Path.Combine(
        status.Directory,
        $".{LoaderFileName}.{Environment.ProcessId}.{Guid.NewGuid():N}.tmp");

    try
    {
      File.WriteAllBytes(temporaryPath, _loaderBytes);
      File.Move(temporaryPath, status.TargetPath, overwrite: true);
    }
    finally
    {
      if (File.Exists(temporaryPath))
      {
        File.Delete(temporaryPath);
      }
    }

    var message = status.State == LoaderState.Outdated
        ? "The installed loader was backed up and updated."
        : "The RBA autoloader is enabled.";
    return new LoaderActionResult(true, message, backupPath);
  }

  internal LoaderActionResult Disable(string directory)
  {
    var status = GetStatus(directory);
    if (status.State == LoaderState.Disabled)
    {
      return new LoaderActionResult(false, "The RBA autoloader is already disabled.");
    }

    var disabledPath = NextSidecarPath(status.TargetPath, "disabled");
    File.Move(status.TargetPath, disabledPath);
    return new LoaderActionResult(
        true,
        "The loader was removed from active autoexec and kept as a recoverable disabled copy.",
        disabledPath);
  }

  internal static string NormalizeDirectory(string directory)
  {
    if (string.IsNullOrWhiteSpace(directory))
    {
      throw new ArgumentException("Choose an autoexec folder first.", nameof(directory));
    }

    var expanded = Environment.ExpandEnvironmentVariables(directory.Trim().Trim('"'));
    var fullPath = Path.GetFullPath(expanded)
        .TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
    var root = Path.GetPathRoot(fullPath)?.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
    if (string.Equals(fullPath, root, StringComparison.OrdinalIgnoreCase))
    {
      throw new ArgumentException("A drive root cannot be used as an autoexec folder.", nameof(directory));
    }

    return fullPath;
  }

  private static string NextSidecarPath(string targetPath, string kind)
  {
    var timestamp = DateTimeOffset.Now.ToString("yyyyMMdd-HHmmss");
    var candidate = $"{targetPath}.{kind}.{timestamp}";
    var suffix = 1;
    while (File.Exists(candidate))
    {
      candidate = $"{targetPath}.{kind}.{timestamp}.{suffix++}";
    }

    return candidate;
  }

  private static string Hash(byte[] value) => Convert.ToHexString(SHA256.HashData(value)).ToLowerInvariant();
}
