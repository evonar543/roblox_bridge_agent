namespace RbaAutoexecManager;

internal static class CommandLine
{
  internal static int? TryRun(string[] args)
  {
    if (args.Length == 0)
    {
      return null;
    }

    try
    {
      if (args.Contains("--self-test", StringComparer.OrdinalIgnoreCase))
      {
        return SelfTest();
      }

      var action = args.FirstOrDefault(value =>
          value.Equals("--status", StringComparison.OrdinalIgnoreCase)
          || value.Equals("--enable", StringComparison.OrdinalIgnoreCase)
          || value.Equals("--disable", StringComparison.OrdinalIgnoreCase));
      if (action is null)
      {
        return null;
      }

      var directory = ResolveDirectory(args);
      var service = new AutoexecService();
      switch (action.ToLowerInvariant())
      {
        case "--status":
          {
            var status = service.GetStatus(directory);
            Console.WriteLine($"{status.State}: {status.TargetPath}");
            return status.State == LoaderState.Current && status.ResidualPaths.Count == 0 ? 0 : 1;
          }
        case "--enable":
          {
            var result = service.Enable(directory);
            Console.WriteLine(result.Message);
            var status = service.GetStatus(directory);
            return status.State == LoaderState.Current && status.ResidualPaths.Count == 0 ? 0 : 1;
          }
        case "--disable":
          {
            var result = service.Disable(directory);
            Console.WriteLine(result.Message);
            var status = service.GetStatus(directory);
            return status.State == LoaderState.Disabled && status.ResidualPaths.Count == 0 ? 0 : 1;
          }
        default:
          return 2;
      }
    }
    catch (Exception error)
    {
      Console.Error.WriteLine(error.Message);
      return 2;
    }
  }

  private static string ResolveDirectory(string[] args)
  {
    var directoryIndex = Array.FindIndex(args, value => value.Equals("--directory", StringComparison.OrdinalIgnoreCase));
    if (directoryIndex >= 0)
    {
      if (directoryIndex + 1 >= args.Length)
      {
        throw new ArgumentException("--directory requires an autoexec folder path.");
      }

      return args[directoryIndex + 1];
    }

    var targetIndex = Array.FindIndex(args, value => value.Equals("--target", StringComparison.OrdinalIgnoreCase));
    var target = targetIndex >= 0 && targetIndex + 1 < args.Length ? args[targetIndex + 1] : "Volt";
    if (!target.Equals("Volt", StringComparison.OrdinalIgnoreCase)
        && !target.Equals("Potassium", StringComparison.OrdinalIgnoreCase))
    {
      throw new ArgumentException("--target must be Volt or Potassium. Use --directory for a custom folder.");
    }

    return AutoexecService.DefaultDirectory(target);
  }

  private static int SelfTest()
  {
    var scenarioRoot = Path.Combine(Path.GetTempPath(), "rba-autoexec-manager-selftest", Guid.NewGuid().ToString("N"));
    var testRoot = Path.Combine(scenarioRoot, "autoexec");
    var service = new AutoexecService(Path.Combine(scenarioRoot, "manager-storage"));
    try
    {
      var initial = service.GetStatus(testRoot);
      Require(initial.State == LoaderState.Disabled, "A new target should start disabled.");

      var enabled = service.Enable(testRoot);
      Require(enabled.Changed, "Enable should install the embedded loader.");
      Require(service.GetStatus(testRoot).State == LoaderState.Current, "Installed loader should be current.");

      File.AppendAllText(Path.Combine(testRoot, AutoexecService.LoaderFileName), "\n-- self-test mismatch");
      File.WriteAllText(Path.Combine(testRoot, $"{AutoexecService.LoaderFileName}.disabled.legacy"), "legacy sidecar");
      Require(service.GetStatus(testRoot).State == LoaderState.Outdated, "Modified loader should be outdated.");

      var repaired = service.Enable(testRoot);
      Require(repaired.Changed && repaired.BackupPath is not null && Directory.Exists(repaired.BackupPath), "Repair should preserve a backup outside autoexec.");
      var repairedStorage = repaired.BackupPath ?? throw new InvalidOperationException("Repair storage path is missing.");
      var repairedStatus = service.GetStatus(testRoot);
      Require(repairedStatus.State == LoaderState.Current, "Repaired loader should be current.");
      Require(repairedStatus.ResidualPaths.Count == 0, "Enable must evacuate every RBA sidecar from autoexec.");
      Require(!repairedStorage.StartsWith(testRoot, StringComparison.OrdinalIgnoreCase), "Backups must be outside autoexec.");

      var disabled = service.Disable(testRoot);
      Require(disabled.Changed && disabled.BackupPath is not null && Directory.Exists(disabled.BackupPath), "Disable should preserve a recoverable copy outside autoexec.");
      var disabledStatus = service.GetStatus(testRoot);
      Require(disabledStatus.State == LoaderState.Disabled, "Disabled loader should leave active autoexec.");
      Require(disabledStatus.ResidualPaths.Count == 0, "Disabled autoexec must contain no RBA-managed files.");
      Require(!Directory.EnumerateFiles(testRoot).Any(), "The self-test autoexec folder should be empty after disable.");

      var reenabled = service.Enable(testRoot);
      Require(reenabled.Changed, "Enable should restore the active loader after a complete disable.");
      Require(service.GetStatus(testRoot).State == LoaderState.Current, "Re-enabled loader should be current.");

      ApplicationConfiguration.Initialize();
      using var form = new MainForm(service, new AppSettings());
      Require(form.Handle != IntPtr.Zero, "The main GUI should construct and create its native window handle.");
      Console.WriteLine("RBA Autoexec Manager self-test passed.");
      return 0;
    }
    finally
    {
      var safeRoot = Path.Combine(Path.GetTempPath(), "rba-autoexec-manager-selftest")
          .TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
      var resolved = Path.GetFullPath(scenarioRoot);
      if (resolved.StartsWith(safeRoot, StringComparison.OrdinalIgnoreCase) && Directory.Exists(resolved))
      {
        Directory.Delete(resolved, recursive: true);
      }
    }
  }

  private static void Require(bool condition, string message)
  {
    if (!condition)
    {
      throw new InvalidOperationException(message);
    }
  }
}
