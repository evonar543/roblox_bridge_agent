[CmdletBinding()]
param(
    [switch]$SkipRootInstall,
    [switch]$SkipCompanionInstall,
    [switch]$StartInstanceManager,
    [switch]$ForceInstall
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$companionRoot = Join-Path $repoRoot 'integrations\roblox-instance-manager-src'

function Invoke-Step {
    param([string]$Label, [scriptblock]$Action)
    Write-Host "[RBA] $Label" -ForegroundColor Cyan
    & $Action
    if ($LASTEXITCODE -ne 0) {
        throw "$Label failed with exit code $LASTEXITCODE."
    }
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw 'Git is required but was not found on PATH.'
}
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    throw 'Node.js 20 or newer is required but was not found on PATH.'
}
$nodeMajor = [int]((node --version).TrimStart('v').Split('.')[0])
if ($nodeMajor -lt 20) {
    throw "Node.js 20 or newer is required; found $(node --version)."
}

Push-Location $repoRoot
try {
    Invoke-Step 'Initializing pinned integration source' { git submodule update --init --recursive }

    if (-not $SkipRootInstall) {
        if ($ForceInstall -or -not (Test-Path -LiteralPath (Join-Path $repoRoot 'node_modules\.package-lock.json'))) {
            Invoke-Step 'Installing RBA dependencies' { npm ci }
        } else {
            Write-Host '[RBA] RBA dependencies already installed; keeping them. Use -ForceInstall to refresh.' -ForegroundColor DarkGray
        }
        Invoke-Step 'Building RBA' { npm run build }
    }

    if (-not $SkipCompanionInstall) {
        # Upstream v1.0.1 references a missing scripts/copy-assets.mjs from its
        # prepare hook. Install without lifecycle scripts, compile, then perform
        # the intended static asset copy here without modifying the submodule.
        if ($ForceInstall -or -not (Test-Path -LiteralPath (Join-Path $companionRoot 'node_modules\.package-lock.json'))) {
            Invoke-Step 'Installing Roblox Instance Manager dependencies' { npm ci --ignore-scripts --prefix $companionRoot }
        } else {
            Write-Host '[RBA] Instance Manager dependencies already installed; keeping them. Use -ForceInstall to refresh.' -ForegroundColor DarkGray
        }
        Invoke-Step 'Compiling Roblox Instance Manager' { npx --prefix $companionRoot tsc -p (Join-Path $companionRoot 'tsconfig.json') }
        $sourceAssets = Join-Path $companionRoot 'src\http\assets'
        $destinationAssets = Join-Path $companionRoot 'dist\http\assets'
        if (-not (Test-Path -LiteralPath $sourceAssets)) {
            throw "Expected companion assets were not found at $sourceAssets."
        }
        New-Item -ItemType Directory -Force -Path $destinationAssets | Out-Null
        Copy-Item -Path (Join-Path $sourceAssets '*') -Destination $destinationAssets -Recurse -Force
    }

    if ($StartInstanceManager) {
        Write-Host '[RBA] Starting Roblox Instance Manager on its configured loopback port' -ForegroundColor Cyan
        Start-Process -FilePath 'npm.cmd' -ArgumentList @('start', '--prefix', $companionRoot) -WorkingDirectory $repoRoot -WindowStyle Hidden
    }

    Write-Host '[RBA] Integration setup complete.' -ForegroundColor Green
    Write-Host 'Use rba_list_integrations or the dashboard Connected Workflow section to verify live readiness.'
}
finally {
    Pop-Location
}
