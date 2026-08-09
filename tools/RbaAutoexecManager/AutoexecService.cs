using System.Reflection;
using System.Security.Cryptography;
using System.Text;

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
    string? InstalledHash,
    string StorageDirectory,
    IReadOnlyList<string> ResidualPaths);

internal sealed record LoaderActionResult(bool Changed, string Message, string? BackupPath = null);

internal sealed class AutoexecService
{
  internal const string LoaderFileName = "rba_autoloader.lua";
  private const string LoaderResourceName = "RbaAutoexecManager.Resources.rba_autoloader.lua";
  private readonly byte[] _loaderBytes;
  private readonly string _sourceHash;
  private readonly string _storageRoot;

  internal AutoexecService(string? storageRoot = null)
  {
    using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream(LoaderResourceName)
        ?? throw new InvalidOperationException("The embedded RBA autoloader is missing from this build.");
    using var memory = new MemoryStream();
    stream.CopyTo(memory);
    _loaderBytes = memory.ToArray();
    _sourceHash = Hash(_loaderBytes);
    _storageRoot = storageRoot ?? Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "RBA Autoexec Manager",
        "loader-storage");
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
    var residualPaths = GetManagedPaths(normalized)
        .Where(path => !path.Equals(targetPath, StringComparison.OrdinalIgnoreCase))
        .ToArray();
    var storageDirectory = GetStorageDirectory(normalized);
    if (!File.Exists(targetPath))
    {
      return new LoaderStatus(
          LoaderState.Disabled,
          normalized,
          targetPath,
          0,
          _sourceHash,
          null,
          storageDirectory,
          residualPaths);
    }

    var installed = File.ReadAllBytes(targetPath);
    var installedHash = Hash(installed);
    var state = CryptographicOperations.FixedTimeEquals(
        Convert.FromHexString(_sourceHash),
        Convert.FromHexString(installedHash))
        ? LoaderState.Current
        : LoaderState.Outdated;
    return new LoaderStatus(
        state,
        normalized,
        targetPath,
        installed.LongLength,
        _sourceHash,
        installedHash,
        storageDirectory,
        residualPaths);
  }

  internal LoaderActionResult Enable(string directory)
  {
    var status = GetStatus(directory);
    if (status.State == LoaderState.Current && status.ResidualPaths.Count == 0)
    {
      return new LoaderActionResult(false, "The RBA autoloader is already enabled and current.");
    }

    Directory.CreateDirectory(status.Directory);
    var pathsToMove = status.ResidualPaths.ToList();
    if (status.State == LoaderState.Outdated)
    {
      pathsToMove.Add(status.TargetPath);
    }

    var movedPaths = MoveOutsideAutoexec(status, pathsToMove, activeKind: "backup");

    var restoredFromStorage = false;
    if (status.State != LoaderState.Current)
    {
      restoredFromStorage = TryRestoreStoredLoader(status);
      if (!restoredFromStorage)
      {
        WriteActiveLoader(status);
      }
    }

    var message = status.State switch
    {
      LoaderState.Outdated => "The previous loader was moved outside autoexec and updated.",
      LoaderState.Current => "Unsafe RBA sidecars were moved outside autoexec; the current loader remains enabled.",
      _ when restoredFromStorage => "The RBA autoloader was restored from safe storage; all RBA sidecars remain outside autoexec.",
      _ => "The RBA autoloader is enabled and all RBA sidecars are outside autoexec."
    };
    return new LoaderActionResult(true, message, movedPaths.Count > 0 ? status.StorageDirectory : null);
  }

  internal LoaderActionResult Disable(string directory)
  {
    var status = GetStatus(directory);
    var pathsToMove = status.ResidualPaths.ToList();
    if (File.Exists(status.TargetPath))
    {
      pathsToMove.Add(status.TargetPath);
    }

    if (pathsToMove.Count == 0)
    {
      return new LoaderActionResult(false, "The RBA autoloader is already disabled.");
    }

    var movedPaths = MoveOutsideAutoexec(status, pathsToMove, activeKind: "disabled");
    return new LoaderActionResult(
        true,
        $"Disabled completely. Moved {movedPaths.Count} RBA-managed file(s) out of autoexec.",
        status.StorageDirectory);
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

  private void WriteActiveLoader(LoaderStatus status)
  {
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
  }

  private bool TryRestoreStoredLoader(LoaderStatus status)
  {
    if (!Directory.Exists(status.StorageDirectory))
    {
      return false;
    }

    var candidate = Directory.EnumerateFiles(status.StorageDirectory, $"{LoaderFileName}.disabled.*")
        .OrderByDescending(File.GetLastWriteTimeUtc)
        .FirstOrDefault(path => Hash(File.ReadAllBytes(path)) == _sourceHash);
    if (candidate is null)
    {
      return false;
    }

    var temporaryPath = Path.Combine(
        status.Directory,
        $".{LoaderFileName}.{Environment.ProcessId}.{Guid.NewGuid():N}.tmp");
    try
    {
      File.Copy(candidate, temporaryPath, overwrite: false);
      File.Move(temporaryPath, status.TargetPath, overwrite: true);
      try
      {
        File.Delete(candidate);
      }
      catch (IOException)
      {
        // The active copy is restored; retaining an outside-autoexec copy is safe.
      }

      return true;
    }
    finally
    {
      if (File.Exists(temporaryPath))
      {
        File.Delete(temporaryPath);
      }
    }
  }

  private List<string> MoveOutsideAutoexec(LoaderStatus status, IEnumerable<string> sourcePaths, string activeKind)
  {
    var paths = sourcePaths
        .Where(File.Exists)
        .Distinct(StringComparer.OrdinalIgnoreCase)
        .ToArray();
    if (paths.Length == 0)
    {
      return [];
    }

    Directory.CreateDirectory(status.StorageDirectory);
    var movedPaths = new List<string>(paths.Length);
    foreach (var sourcePath in paths)
    {
      var isActive = sourcePath.Equals(status.TargetPath, StringComparison.OrdinalIgnoreCase);
      var name = isActive
          ? $"{LoaderFileName}.{activeKind}.{DateTimeOffset.Now:yyyyMMdd-HHmmss-fff}"
          : Path.GetFileName(sourcePath);
      var destinationPath = NextAvailablePath(status.StorageDirectory, name);
      File.Move(sourcePath, destinationPath);
      movedPaths.Add(destinationPath);
    }

    return movedPaths;
  }

  private string GetStorageDirectory(string autoexecDirectory)
  {
    var identity = Convert.ToHexString(SHA256.HashData(
        Encoding.UTF8.GetBytes(autoexecDirectory.ToUpperInvariant())))
        .ToLowerInvariant()[..16];
    return Path.Combine(_storageRoot, identity);
  }

  private static IReadOnlyList<string> GetManagedPaths(string directory)
  {
    if (!Directory.Exists(directory))
    {
      return [];
    }

    return Directory.EnumerateFiles(directory, "*", SearchOption.TopDirectoryOnly)
        .Where(path => IsManagedFileName(Path.GetFileName(path)))
        .ToArray();
  }

  private static bool IsManagedFileName(string name) =>
      name.Equals(LoaderFileName, StringComparison.OrdinalIgnoreCase)
      || name.StartsWith($"{LoaderFileName}.", StringComparison.OrdinalIgnoreCase)
      || (name.StartsWith($".{LoaderFileName}.", StringComparison.OrdinalIgnoreCase)
          && name.EndsWith(".tmp", StringComparison.OrdinalIgnoreCase));

  private static string NextAvailablePath(string directory, string name)
  {
    var candidate = Path.Combine(directory, name);
    var suffix = 1;
    while (File.Exists(candidate))
    {
      candidate = Path.Combine(directory, $"{name}.moved.{suffix++}");
    }

    return candidate;
  }

  private static string Hash(byte[] value) => Convert.ToHexString(SHA256.HashData(value)).ToLowerInvariant();
}
