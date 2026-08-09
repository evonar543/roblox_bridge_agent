[CmdletBinding()]
param(
    [string]$DotNet = "dotnet",
    [string]$OutputDirectory
)

$ErrorActionPreference = "Stop"
$projectDirectory = $PSScriptRoot
$repositoryRoot = (Resolve-Path (Join-Path $projectDirectory "..\..")).Path
$assetDirectory = Join-Path $projectDirectory "assets"
$iconPath = Join-Path $assetDirectory "rba-autoexec-manager.ico"
$projectPath = Join-Path $projectDirectory "RbaAutoexecManager.csproj"
$nugetConfigPath = Join-Path $projectDirectory "NuGet.Config"

if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $repositoryRoot "artifacts\rba-autoexec-manager\win-x64"
}

Add-Type -AssemblyName System.Drawing
$bitmap = [System.Drawing.Bitmap]::new(256, 256)
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$graphics.Clear([System.Drawing.Color]::Transparent)

$bounds = [System.Drawing.Rectangle]::new(12, 12, 232, 232)
$gradient = [System.Drawing.Drawing2D.LinearGradientBrush]::new(
    $bounds,
    [System.Drawing.Color]::FromArgb(79, 94, 255),
    [System.Drawing.Color]::FromArgb(58, 220, 214),
    45.0
)
$graphics.FillEllipse($gradient, $bounds)

$ring = [System.Drawing.Pen]::new([System.Drawing.Color]::White, 20)
$ring.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
$ring.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
$graphics.DrawArc($ring, 56, 56, 144, 144, 35, 270)

$boltPoints = [System.Drawing.PointF[]]@(
    [System.Drawing.PointF]::new(146, 48),
    [System.Drawing.PointF]::new(97, 126),
    [System.Drawing.PointF]::new(132, 126),
    [System.Drawing.PointF]::new(112, 204),
    [System.Drawing.PointF]::new(174, 108),
    [System.Drawing.PointF]::new(137, 108)
)
$graphics.FillPolygon([System.Drawing.Brushes]::White, $boltPoints)

$pngStream = [System.IO.MemoryStream]::new()
$bitmap.Save($pngStream, [System.Drawing.Imaging.ImageFormat]::Png)
$pngBytes = $pngStream.ToArray()
$iconStream = [System.IO.File]::Create($iconPath)
$writer = [System.IO.BinaryWriter]::new($iconStream)
$writer.Write([UInt16]0)
$writer.Write([UInt16]1)
$writer.Write([UInt16]1)
$writer.Write([Byte]0)
$writer.Write([Byte]0)
$writer.Write([Byte]0)
$writer.Write([Byte]0)
$writer.Write([UInt16]1)
$writer.Write([UInt16]32)
$writer.Write([UInt32]$pngBytes.Length)
$writer.Write([UInt32]22)
$writer.Write($pngBytes)
$writer.Dispose()
$pngStream.Dispose()
$ring.Dispose()
$gradient.Dispose()
$graphics.Dispose()
$bitmap.Dispose()

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
& $DotNet restore $projectPath `
    --runtime win-x64 `
    --configfile $nugetConfigPath

if ($LASTEXITCODE -ne 0) {
    throw "dotnet restore failed with exit code $LASTEXITCODE"
}

& $DotNet publish $projectPath `
    --configuration Release `
    --runtime win-x64 `
    --self-contained true `
    --output $OutputDirectory `
    --no-restore `
    -p:PublishSingleFile=true

if ($LASTEXITCODE -ne 0) {
    throw "dotnet publish failed with exit code $LASTEXITCODE"
}

$executable = Join-Path $OutputDirectory "RBA Autoexec Manager.exe"
if (-not (Test-Path $executable)) {
    throw "Expected executable was not produced: $executable"
}

Write-Host "Built: $executable"
