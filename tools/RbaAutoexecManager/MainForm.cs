using System.Diagnostics;
using System.Drawing.Drawing2D;
using System.Reflection;

namespace RbaAutoexecManager;

internal sealed class MainForm : Form
{
  private static readonly Color BackgroundColor = Color.FromArgb(15, 18, 27);
  private static readonly Color CardColor = Color.FromArgb(25, 30, 43);
  private static readonly Color MutedColor = Color.FromArgb(157, 167, 190);
  private static readonly Color AccentColor = Color.FromArgb(93, 214, 255);
  private static readonly Color GreenColor = Color.FromArgb(86, 224, 157);
  private static readonly Color AmberColor = Color.FromArgb(255, 190, 92);
  private static readonly Color RedColor = Color.FromArgb(255, 111, 132);

  private readonly AutoexecService _service;
  private readonly AppSettings _settings;
  private readonly ComboBox _targetSelector = new();
  private readonly TextBox _pathBox = new();
  private readonly Button _browseButton = new();
  private readonly Label _statusDot = new();
  private readonly Label _statusTitle = new();
  private readonly Label _statusDetail = new();
  private readonly Button _enableButton = new();
  private readonly Button _disableButton = new();
  private readonly Button _refreshButton = new();
  private readonly Button _openButton = new();
  private readonly System.Windows.Forms.Timer _refreshTimer = new() { Interval = 2500 };
  private bool _busy;

  internal MainForm(AutoexecService service, AppSettings settings)
  {
    _service = service;
    _settings = settings;

    Text = "RBA Autoexec Manager";
    ClientSize = new Size(660, 500);
    MinimumSize = new Size(620, 490);
    StartPosition = FormStartPosition.CenterScreen;
    BackColor = BackgroundColor;
    ForeColor = Color.White;
    Font = new Font("Segoe UI", 10F);
    AutoScaleMode = AutoScaleMode.Dpi;
    Padding = new Padding(28);

    LoadWindowIcon();
    BuildLayout();
    SelectSavedTarget();

    _targetSelector.SelectedIndexChanged += (_, _) => TargetChanged(saveSettings: true);
    _browseButton.Click += (_, _) => BrowseForDirectory();
    _pathBox.TextChanged += (_, _) =>
    {
      if (SelectedTargetKey() == "Custom")
      {
        _settings.CustomDirectory = _pathBox.Text;
        RefreshStatus();
      }
    };
    _enableButton.Click += async (_, _) => await RunActionAsync("Enabling autoloader…", () => _service.Enable(CurrentDirectory()));
    _disableButton.Click += async (_, _) => await RunActionAsync("Disabling autoloader…", () => _service.Disable(CurrentDirectory()));
    _refreshButton.Click += (_, _) => RefreshStatus();
    _openButton.Click += (_, _) => OpenDirectory();
    _refreshTimer.Tick += (_, _) => RefreshStatus();
    TargetChanged(saveSettings: false);
    FormClosing += (_, _) => SaveSettings();
    Shown += (_, _) =>
    {
      RefreshStatus();
      _refreshTimer.Start();
    };
  }

  private void BuildLayout()
  {
    var root = new TableLayoutPanel
    {
      Dock = DockStyle.Fill,
      ColumnCount = 1,
      RowCount = 5,
      BackColor = BackgroundColor
    };
    root.RowStyles.Add(new RowStyle(SizeType.Absolute, 86));
    root.RowStyles.Add(new RowStyle(SizeType.Absolute, 114));
    root.RowStyles.Add(new RowStyle(SizeType.Absolute, 112));
    root.RowStyles.Add(new RowStyle(SizeType.Absolute, 62));
    root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
    Controls.Add(root);

    var header = new Panel { Dock = DockStyle.Fill };
    header.Controls.Add(new LogoControl { Location = new Point(0, 2), Size = new Size(66, 66) });
    header.Controls.Add(new Label
    {
      Text = "RBA Autoexec Manager",
      AutoSize = true,
      Location = new Point(80, 8),
      Font = new Font("Segoe UI Semibold", 18F),
      ForeColor = Color.White
    });
    header.Controls.Add(new Label
    {
      Text = "Install the bundled RBA loader into an executor's autoexec folder.",
      AutoSize = true,
      Location = new Point(82, 46),
      ForeColor = MutedColor
    });
    root.Controls.Add(header, 0, 0);

    var targetCard = MakeCard();
    targetCard.Controls.Add(MakeCaption("EXECUTOR TARGET", new Point(18, 13)));
    _targetSelector.DropDownStyle = ComboBoxStyle.DropDownList;
    _targetSelector.Items.AddRange(["Volt", "Potassium", "Custom"]);
    _targetSelector.Location = new Point(18, 38);
    _targetSelector.Width = 150;
    StyleInput(_targetSelector);
    targetCard.Controls.Add(_targetSelector);

    _pathBox.Location = new Point(178, 38);
    _pathBox.Width = 316;
    _pathBox.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right;
    StyleInput(_pathBox);
    targetCard.Controls.Add(_pathBox);

    _browseButton.Text = "Browse";
    _browseButton.Location = new Point(504, 36);
    _browseButton.Size = new Size(78, 32);
    _browseButton.Anchor = AnchorStyles.Top | AnchorStyles.Right;
    StyleButton(_browseButton, ghost: true);
    targetCard.Controls.Add(_browseButton);
    targetCard.Controls.Add(new Label
    {
      Text = $"The active file is always {AutoexecService.LoaderFileName}.",
      AutoSize = true,
      Location = new Point(18, 78),
      ForeColor = MutedColor,
      Font = new Font("Segoe UI", 8.8F)
    });
    root.Controls.Add(targetCard, 0, 1);

    var statusCard = MakeCard();
    _statusDot.Text = "●";
    _statusDot.AutoSize = true;
    _statusDot.Location = new Point(18, 17);
    _statusDot.Font = new Font("Segoe UI", 17F);
    _statusDot.ForeColor = MutedColor;
    statusCard.Controls.Add(_statusDot);
    _statusTitle.Text = "Checking status…";
    _statusTitle.AutoSize = true;
    _statusTitle.Location = new Point(52, 19);
    _statusTitle.Font = new Font("Segoe UI Semibold", 13F);
    statusCard.Controls.Add(_statusTitle);
    _statusDetail.Text = "Reading the selected autoexec folder.";
    _statusDetail.Location = new Point(54, 52);
    _statusDetail.Size = new Size(510, 43);
    _statusDetail.ForeColor = MutedColor;
    _statusDetail.AutoEllipsis = true;
    statusCard.Controls.Add(_statusDetail);
    root.Controls.Add(statusCard, 0, 2);

    var primaryActions = new FlowLayoutPanel
    {
      Dock = DockStyle.Fill,
      FlowDirection = FlowDirection.LeftToRight,
      WrapContents = false,
      Padding = new Padding(0, 8, 0, 8)
    };
    _enableButton.Text = "Enable autoloader";
    _enableButton.Size = new Size(170, 42);
    StyleButton(_enableButton, ghost: false);
    _disableButton.Text = "Disable safely";
    _disableButton.Size = new Size(145, 42);
    _disableButton.Margin = new Padding(10, 0, 0, 0);
    StyleButton(_disableButton, ghost: true);
    primaryActions.Controls.Add(_enableButton);
    primaryActions.Controls.Add(_disableButton);
    root.Controls.Add(primaryActions, 0, 3);

    var footer = new FlowLayoutPanel
    {
      Dock = DockStyle.Fill,
      FlowDirection = FlowDirection.LeftToRight,
      WrapContents = false,
      Padding = new Padding(0, 9, 0, 0)
    };
    _refreshButton.Text = "Refresh";
    _refreshButton.Size = new Size(92, 34);
    StyleButton(_refreshButton, ghost: true);
    _openButton.Text = "Open autoexec folder";
    _openButton.Size = new Size(170, 34);
    _openButton.Margin = new Padding(9, 0, 0, 0);
    StyleButton(_openButton, ghost: true);
    footer.Controls.Add(_refreshButton);
    footer.Controls.Add(_openButton);
    root.Controls.Add(footer, 0, 4);
  }

  private static Panel MakeCard() => new()
  {
    Dock = DockStyle.Fill,
    BackColor = CardColor,
    Margin = new Padding(0, 3, 0, 9)
  };

  private static Label MakeCaption(string text, Point location) => new()
  {
    Text = text,
    AutoSize = true,
    Location = location,
    ForeColor = MutedColor,
    Font = new Font("Segoe UI Semibold", 8F)
  };

  private static void StyleInput(Control input)
  {
    input.BackColor = Color.FromArgb(36, 42, 58);
    input.ForeColor = Color.White;
    input.Font = new Font("Segoe UI", 10F);
  }

  private static void StyleButton(Button button, bool ghost)
  {
    button.FlatStyle = FlatStyle.Flat;
    button.FlatAppearance.BorderSize = 1;
    button.FlatAppearance.BorderColor = ghost ? Color.FromArgb(74, 84, 108) : AccentColor;
    button.BackColor = ghost ? Color.FromArgb(31, 37, 52) : Color.FromArgb(38, 132, 171);
    button.ForeColor = Color.White;
    button.Cursor = Cursors.Hand;
    button.Font = new Font("Segoe UI Semibold", 9.5F);
  }

  private void SelectSavedTarget()
  {
    var index = _settings.SelectedTarget switch
    {
      "Potassium" => 1,
      "Custom" => 2,
      _ => 0
    };
    _targetSelector.SelectedIndex = index;
  }

  private string SelectedTargetKey() => _targetSelector.SelectedItem?.ToString() ?? "Volt";

  private void TargetChanged(bool saveSettings)
  {
    var target = SelectedTargetKey();
    _settings.SelectedTarget = target;
    _pathBox.ReadOnly = target != "Custom";
    _browseButton.Enabled = target == "Custom";
    _pathBox.Text = target switch
    {
      "Potassium" => AutoexecService.DefaultDirectory("Potassium"),
      "Custom" => _settings.CustomDirectory,
      _ => AutoexecService.DefaultDirectory("Volt")
    };
    if (saveSettings)
    {
      SaveSettings();
    }
    RefreshStatus();
  }

  private string CurrentDirectory() => AutoexecService.NormalizeDirectory(_pathBox.Text);

  private void BrowseForDirectory()
  {
    using var dialog = new FolderBrowserDialog
    {
      Description = "Choose the executor's autoexec folder",
      UseDescriptionForTitle = true,
      ShowNewFolderButton = true,
      InitialDirectory = Directory.Exists(_pathBox.Text) ? _pathBox.Text : string.Empty
    };
    if (dialog.ShowDialog(this) == DialogResult.OK)
    {
      _pathBox.Text = dialog.SelectedPath;
      _settings.CustomDirectory = dialog.SelectedPath;
      SaveSettings();
    }
  }

  private void RefreshStatus()
  {
    if (_busy || !IsHandleCreated)
    {
      return;
    }

    try
    {
      var status = _service.GetStatus(CurrentDirectory());
      switch (status.State)
      {
        case LoaderState.Current:
          SetStatus(GreenColor, "Enabled and current", $"The bundled RBA autoloader is active ({status.InstalledBytes:N0} bytes).", false, true);
          _enableButton.Text = "Already enabled";
          break;
        case LoaderState.Outdated:
          SetStatus(AmberColor, "Enabled but outdated", "A different loader is installed. Enable will back it up and install this build's current RBA loader.", true, true);
          _enableButton.Text = "Update autoloader";
          break;
        default:
          SetStatus(RedColor, "Disabled", "rba_autoloader.lua is not active in this autoexec folder.", true, false);
          _enableButton.Text = "Enable autoloader";
          break;
      }
    }
    catch (Exception error)
    {
      SetStatus(RedColor, "Cannot check this folder", error.Message, false, false);
    }
  }

  private void SetStatus(Color color, string title, string detail, bool canEnable, bool canDisable)
  {
    _statusDot.ForeColor = color;
    _statusTitle.Text = title;
    _statusDetail.Text = detail;
    _enableButton.Enabled = canEnable && !_busy;
    _disableButton.Enabled = canDisable && !_busy;
    _refreshButton.Enabled = !_busy;
    _openButton.Enabled = !_busy && !string.IsNullOrWhiteSpace(_pathBox.Text);
  }

  private async Task RunActionAsync(string progress, Func<LoaderActionResult> action)
  {
    if (_busy)
    {
      return;
    }

    _busy = true;
    _refreshTimer.Stop();
    SetStatus(AccentColor, progress, "This usually takes less than a second.", false, false);

    try
    {
      var result = await Task.Run(action);
      var detail = result.BackupPath is null
          ? result.Message
          : $"{result.Message} Saved copy: {result.BackupPath}";
      SetStatus(GreenColor, result.Changed ? "Done" : "No change needed", detail, false, false);
      await Task.Delay(650);
    }
    catch (UnauthorizedAccessException)
    {
      SetStatus(RedColor, "Permission denied", "This executor folder is protected. Choose its user autoexec folder or run the manager with the needed permission.", false, false);
      MessageBox.Show(this, "Windows denied access to that folder.", "RBA Autoexec Manager", MessageBoxButtons.OK, MessageBoxIcon.Warning);
    }
    catch (Exception error)
    {
      SetStatus(RedColor, "Action failed", error.Message, false, false);
      MessageBox.Show(this, error.Message, "RBA Autoexec Manager", MessageBoxButtons.OK, MessageBoxIcon.Error);
    }
    finally
    {
      _busy = false;
      RefreshStatus();
      _refreshTimer.Start();
    }
  }

  private void OpenDirectory()
  {
    try
    {
      var directory = CurrentDirectory();
      Directory.CreateDirectory(directory);
      Process.Start(new ProcessStartInfo
      {
        FileName = "explorer.exe",
        UseShellExecute = true,
        ArgumentList = { directory }
      });
    }
    catch (Exception error)
    {
      MessageBox.Show(this, error.Message, "RBA Autoexec Manager", MessageBoxButtons.OK, MessageBoxIcon.Error);
    }
  }

  private void SaveSettings()
  {
    try
    {
      _settings.Save();
    }
    catch
    {
      // Settings are convenience-only; loader actions remain available.
    }
  }

  private void LoadWindowIcon()
  {
    try
    {
      using var stream = Assembly.GetExecutingAssembly()
          .GetManifestResourceStream("RbaAutoexecManager.Resources.rba-autoexec-manager.ico");
      if (stream is not null)
      {
        using var loadedIcon = new Icon(stream);
        Icon = (Icon)loadedIcon.Clone();
      }
    }
    catch
    {
      // Windows will use the executable's native icon if the resource cannot be read.
    }
  }
}

internal sealed class LogoControl : Control
{
  internal LogoControl()
  {
    SetStyle(
      ControlStyles.UserPaint
      | ControlStyles.AllPaintingInWmPaint
      | ControlStyles.OptimizedDoubleBuffer
      | ControlStyles.SupportsTransparentBackColor,
      true);
    BackColor = Color.Transparent;
  }

  protected override void OnPaint(PaintEventArgs e)
  {
    base.OnPaint(e);
    e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
    var bounds = new RectangleF(3, 3, Width - 7, Height - 7);
    using var background = new LinearGradientBrush(bounds, Color.FromArgb(79, 94, 255), Color.FromArgb(58, 220, 214), 45F);
    e.Graphics.FillEllipse(background, bounds);
    using var ring = new Pen(Color.FromArgb(225, 255, 255, 255), 5F) { StartCap = LineCap.Round, EndCap = LineCap.Round };
    e.Graphics.DrawArc(ring, 17, 17, Width - 34, Height - 34, 35, 270);
    using var bolt = new SolidBrush(Color.White);
    e.Graphics.FillPolygon(bolt,
    [
        new PointF(36, 16), new PointF(23, 36), new PointF(33, 36),
            new PointF(28, 52), new PointF(47, 30), new PointF(37, 30)
    ]);
  }
}
