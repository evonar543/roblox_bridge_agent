namespace RbaAutoexecManager;

internal static class Program
{
  [STAThread]
  private static int Main(string[] args)
  {
    var commandResult = CommandLine.TryRun(args);
    if (commandResult.HasValue)
    {
      return commandResult.Value;
    }

    ApplicationConfiguration.Initialize();
    Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
    Application.Run(new MainForm(new AutoexecService(), AppSettings.Load()));
    return 0;
  }
}
