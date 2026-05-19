<#
.SYNOPSIS
One-click Windows installer for AI CLIs used by InstallTheCli.

.DESCRIPTION
Installs all supported AI CLIs (or one selected target) using official package sources:
- winget for Node.js, Python 3.14, and Ollama
- npm for Claude/Codex/Gemini/Grok/Qwen/Copilot
- uv/pip for Mistral Vibe

Also configures a hidden Scheduled Task (startup, logon, daily) unless disabled.

.PARAMETER Command
Subcommand: install-all (default), install, list, setup-updater, help.

.PARAMETER Target
Target for the install subcommand: claude, codex, gemini, grok, qwen, copilot, openclaw, ironclaw, mistral, ollama, all.

.PARAMETER NoAutoUpdate
Skips creation/update of the hidden scheduled auto-update task.

.PARAMETER DryRun
Prints commands without making changes.

.PARAMETER AutoUpdateTime
Daily Scheduled Task time (default: 3:00AM).

.PARAMETER Help
Shows help.

.EXAMPLE
.\install_all_windows.ps1

.EXAMPLE
.\install_all_windows.ps1 install codex -NoAutoUpdate

.EXAMPLE
.\install_all_windows.ps1 list

.EXAMPLE
Get-Help .\install_all_windows.ps1 -Detailed
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command = 'install-all',

    [Parameter(Position = 1)]
    [string]$Target = 'all',

    [switch]$NoAutoUpdate,
    [switch]$DryRun,

    [string]$AutoUpdateTime = '3:00AM',

    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$NodeWingetId = 'OpenJS.NodeJS.LTS'
$PythonWingetId = 'Python.Python.3.14'
$OllamaWingetId = 'Ollama.Ollama'
$RustupWingetId = 'Rustlang.Rustup'
$RtkGitUrl = 'https://github.com/rtk-ai/rtk'
$AutoUpdateTaskName = 'InstallTheCli - Update AI CLIs'
$LocalAppDataRoot = if ($env:LocalAppData) { $env:LocalAppData } else { Join-Path $HOME 'AppData\Local' }
$SupportDir = Join-Path $LocalAppDataRoot 'InstallTheCli'
$AutoUpdateScriptPath = Join-Path $SupportDir 'one_click_update_windows.ps1'
$AutoUpdateVbsPath = Join-Path $SupportDir 'one_click_update_windows.vbs'
$NpmFlags = @('--no-fund', '--no-audit', '--no-update-notifier', '--loglevel', 'error')
$PipFlags = @('--disable-pip-version-check', '--no-input', '--quiet')

$NpmCliSpecs = @{
    claude   = @{ Label = 'Claude CLI';  Packages = @('@anthropic-ai/claude-code') }
    codex    = @{ Label = 'Codex CLI';   Packages = @('@openai/codex') }
    gemini   = @{ Label = 'Gemini CLI';  Packages = @('@google/gemini-cli') }
    grok     = @{ Label = 'Grok CLI (Vibe Kit)'; Packages = @('@vibe-kit/grok-cli') }
    qwen     = @{ Label = 'Qwen CLI';    Packages = @('@qwen-code/qwen-code', 'qwen-code') }
    copilot  = @{ Label = 'GitHub Copilot CLI'; Packages = @('@github/copilot', '@githubnext/github-copilot-cli') }
    openclaw = @{ Label = 'OpenClaw CLI'; Packages = @('openclaw') }
    ironclaw = @{ Label = 'IronClaw CLI'; Packages = @('ironclaw') }
}

function Write-Log {
    param([string]$Message)
    Write-Host "[install] $Message"
}

function Write-WarnLog {
    param([string]$Message)
    Write-Warning $Message
}

function Throw-InstallError {
    param([string]$Message)
    throw $Message
}

function Test-CommandAvailable {
    param([string]$Name)
    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Quote-Arg {
    param([string]$Value)
    if ($Value -match '\s|"') {
        return '"' + ($Value -replace '"', '\"') + '"'
    }
    return $Value
}

function Invoke-ExternalCommand {
    param(
        [Parameter(Mandatory = $true)][string[]]$Args
    )
    $display = ($Args | ForEach-Object { Quote-Arg $_ }) -join ' '
    Write-Host "> $display"
    if ($DryRun) {
        return 0
    }
    $exe = $Args[0]
    $argList = @()
    if ($Args.Count -gt 1) {
        $argList = @($Args[1..($Args.Count - 1)])
    }
    & $exe @argList
    $exitCode = $LASTEXITCODE
    if ($null -eq $exitCode) { $exitCode = 0 }
    return [int]$exitCode
}

function Require-Admin {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Throw-InstallError 'Run this script in an elevated PowerShell session (Run as Administrator).'
    }
}

function Get-WingetPath {
    $cmd = Get-Command winget -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Get-NodePath {
    foreach ($name in @('node.exe', 'node')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    }
    foreach ($candidate in @(
        (Join-Path ${env:ProgramFiles} 'nodejs\node.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'nodejs\node.exe'),
        (Join-Path $env:LocalAppData 'Programs\nodejs\node.exe')
    )) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    return $null
}

function Get-NpmPath {
    foreach ($name in @('npm.cmd', 'npm')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    }
    foreach ($candidate in @(
        (Join-Path ${env:ProgramFiles} 'nodejs\npm.cmd'),
        (Join-Path ${env:ProgramFiles(x86)} 'nodejs\npm.cmd'),
        (Join-Path $env:LocalAppData 'Programs\nodejs\npm.cmd')
    )) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    return $null
}

function Ensure-NodeAndNpm {
    $node = Get-NodePath
    $npm = Get-NpmPath
    if ($node -and $npm) {
        Write-Log "Node.js is already available: $node"
        Write-Log "npm is already available: $npm"
        return $npm
    }

    $winget = Get-WingetPath
    if (-not $winget) {
        Throw-InstallError 'winget was not found. Install Microsoft App Installer / winget first.'
    }

    Write-Log 'Installing Node.js LTS via winget (includes npm)...'
    $code = Invoke-ExternalCommand -Args @($winget, 'install', '--id', $NodeWingetId, '-e', '--accept-package-agreements', '--accept-source-agreements', '--silent', '--disable-interactivity')
    if ($code -ne 0) {
        Throw-InstallError "winget Node.js install failed with exit code $code."
    }

    $npm = Get-NpmPath
    if (-not $npm) {
        Throw-InstallError 'npm was not found after Node.js setup.'
    }
    Write-Log "npm is available: $npm"
    return $npm
}

function Get-Python314Prefix {
    if (Test-CommandAvailable 'py') {
        if ($DryRun) { return @('py', '-3.14') }
        & py -3.14 -c "import sys; raise SystemExit(0 if sys.version_info[:2]==(3,14) else 1)" *> $null
        if ($LASTEXITCODE -eq 0) { return @('py', '-3.14') }
    }
    foreach ($name in @('python3.14.exe', 'python3.14', 'python.exe', 'python')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if (-not $cmd) { continue }
        if ($DryRun) { return @($cmd.Source) }
        & $cmd.Source -c "import sys; raise SystemExit(0 if sys.version_info[:2]==(3,14) else 1)" *> $null
        if ($LASTEXITCODE -eq 0) { return @($cmd.Source) }
    }
    return $null
}

function Ensure-Python314ForMistral {
    $prefix = Get-Python314Prefix
    if ($prefix) {
        Write-Log "Python 3.14 is already available for Mistral Vibe: $($prefix -join ' ')"
        return $prefix
    }

    $winget = Get-WingetPath
    if (-not $winget) {
        Throw-InstallError 'winget was not found. Cannot install Python 3.14 for Mistral Vibe.'
    }
    Write-Log 'Installing Python 3.14 via winget for Mistral Vibe...'
    $code = Invoke-ExternalCommand -Args @($winget, 'install', '--id', $PythonWingetId, '-e', '--accept-package-agreements', '--accept-source-agreements', '--silent', '--disable-interactivity')
    if ($code -ne 0) {
        Throw-InstallError "winget Python 3.14 install failed with exit code $code."
    }
    $prefix = Get-Python314Prefix
    if (-not $prefix) {
        Throw-InstallError 'Python 3.14 was not found after installation.'
    }
    return $prefix
}

function Ensure-PipAndUvForMistral {
    param([string[]]$PythonPrefix)
    [void](Invoke-ExternalCommand -Args (@($PythonPrefix) + @('-m', 'pip', 'install', '--user', '--upgrade') + $PipFlags + @('pip')))
    [void](Invoke-ExternalCommand -Args (@($PythonPrefix) + @('-m', 'pip', 'install', '--user', '--upgrade') + $PipFlags + @('uv')))
}

function Install-MistralVibe {
    $pythonPrefix = Ensure-Python314ForMistral
    Ensure-PipAndUvForMistral -PythonPrefix $pythonPrefix

    $uvCmd = Get-Command uv -ErrorAction SilentlyContinue
    if ($uvCmd) {
        $code = Invoke-ExternalCommand -Args @($uvCmd.Source, 'tool', 'install', '--upgrade', 'mistral-vibe')
        if ($code -eq 0) {
            Write-Log 'Installed Mistral Vibe CLI using uv.'
            return
        }
        Write-WarnLog 'uv tool install failed; falling back to pip.'
    }

    $code = Invoke-ExternalCommand -Args (@($pythonPrefix) + @('-m', 'pip', 'install', '--user', '--upgrade') + $PipFlags + @('mistral-vibe'))
    if ($code -ne 0) {
        Throw-InstallError "Failed to install Mistral Vibe (exit code $code)."
    }
    Write-Log 'Installed Mistral Vibe CLI using pip.'
}

function Install-OllamaOfficial {
    $winget = Get-WingetPath
    if (-not $winget) {
        Throw-InstallError 'winget was not found. Cannot install Ollama.'
    }
    Write-Log 'Installing official Ollama via winget...'
    $code = Invoke-ExternalCommand -Args @($winget, 'install', '--id', $OllamaWingetId, '-e', '--accept-package-agreements', '--accept-source-agreements', '--silent', '--disable-interactivity')
    if ($code -ne 0) {
        Write-WarnLog "winget install failed (exit $code). Trying winget upgrade..."
        $code = Invoke-ExternalCommand -Args @($winget, 'upgrade', '--id', $OllamaWingetId, '-e', '--accept-package-agreements', '--accept-source-agreements', '--silent', '--disable-interactivity')
        if ($code -ne 0) {
            Throw-InstallError "Failed to install/update Ollama (exit code $code)."
        }
    }
    Write-Log 'Installed/updated Ollama (official).'
}

function Get-CargoPath {
    $cmd = Get-Command cargo -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $candidate = Join-Path $env:USERPROFILE '.cargo\bin\cargo.exe'
    if (Test-Path -LiteralPath $candidate) { return $candidate }
    return $null
}

function Ensure-RustToolchain {
    $cargo = Get-CargoPath
    if ($cargo) {
        Write-Log "Rust toolchain is already available: $cargo"
        return $cargo
    }
    $winget = Get-WingetPath
    if (-not $winget) {
        Throw-InstallError 'winget was not found. Install Microsoft App Installer / winget first, or install Rust manually from https://rustup.rs/.'
    }
    Write-Log 'Installing Rust toolchain (Rustup) via winget...'
    $code = Invoke-ExternalCommand -Args @($winget, 'install', '--id', $RustupWingetId, '-e', '--accept-package-agreements', '--accept-source-agreements', '--silent', '--disable-interactivity')
    if ($code -ne 0) {
        Throw-InstallError "winget Rustup install failed with exit code $code."
    }
    $cargoBin = Join-Path $env:USERPROFILE '.cargo\bin'
    if (-not ($env:PATH -split ';' | Where-Object { $_ -eq $cargoBin })) {
        $env:PATH = "$cargoBin;$env:PATH"
    }
    $cargo = Get-CargoPath
    if (-not $cargo) {
        Throw-InstallError 'cargo.exe was not found after Rustup install. Open a new shell and rerun.'
    }
    return $cargo
}

# Install RTK (Rust Token Killer) from git master via cargo. The cargo git
# checkout cache for the rtk repo is cleared first; without this, `cargo
# install --git --force` silently reuses a stale checkout and rebuilds the
# same old SHA when only the master ref has moved (we hit this stuck at
# 0.34.3 while master had moved to 0.40.0).
function Install-Rtk {
    $cargo = Ensure-RustToolchain
    $cargoBin = Split-Path -Parent $cargo
    $cargoGitDir = Join-Path $env:USERPROFILE '.cargo\git'
    foreach ($sub in @('checkouts', 'db')) {
        $root = Join-Path $cargoGitDir $sub
        if (Test-Path -LiteralPath $root) {
            Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like 'rtk-*' } |
                ForEach-Object {
                    Write-Log "Clearing cargo git cache: $($_.FullName)"
                    if (-not $DryRun) {
                        Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
                    }
                }
        }
    }

    Write-Log "Installing rtk from $RtkGitUrl (branch master) via cargo..."
    $code = Invoke-ExternalCommand -Args @($cargo, 'install', '--git', $RtkGitUrl, '--branch', 'master', '--force')
    if ($code -ne 0) {
        Throw-InstallError "cargo install rtk failed with exit code $code."
    }

    $rtkExe = Join-Path $cargoBin 'rtk.exe'
    if (-not $DryRun -and (Test-Path -LiteralPath $rtkExe)) {
        if (Get-Command claude -ErrorAction SilentlyContinue) {
            Write-Log 'Registering rtk hook for Claude Code'
            [void](Invoke-ExternalCommand -Args @($rtkExe, 'init', '-g', '--auto-patch'))
            Update-ClaudeRtkHookCommand
        }
        if (Get-Command codex -ErrorAction SilentlyContinue) {
            Write-Log 'Registering rtk for Codex CLI'
            [void](Invoke-ExternalCommand -Args @($rtkExe, 'init', '-g', '--codex'))
        }
        Write-Log "Installed rtk: $(& $rtkExe --version 2>&1)"
    }
}

# Claude Code on Windows runs PreToolUse hooks through Git Bash (/usr/bin/bash),
# whose PATH does NOT include the cargo bin dir. The bare `rtk hook claude`
# command that `rtk init --auto-patch` registers therefore fails with
# "command not found" from Git Bash. Rewrite the hook command in
# ~/.claude/settings.json to use the POSIX-style absolute path Git Bash
# can resolve, and dedupe any duplicate Bash-matcher blocks that repeated
# init runs leave behind.
function Update-ClaudeRtkHookCommand {
    if ($DryRun) { return }
    $settingsPath = Join-Path $env:USERPROFILE '.claude\settings.json'
    if (-not (Test-Path -LiteralPath $settingsPath)) { return }
    try {
        $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
        if (-not $settings.hooks -or -not $settings.hooks.PreToolUse) { return }
        $rtkPosix = '/c/Users/' + (Split-Path -Leaf $env:USERPROFILE) + '/.cargo/bin/rtk.exe'
        $want = "$rtkPosix hook claude"
        $changed = $false
        $seen = @{}
        $kept = @()
        foreach ($entry in $settings.hooks.PreToolUse) {
            if ($entry.matcher -ne 'Bash') { $kept += $entry; continue }
            foreach ($h in $entry.hooks) {
                if ($h.type -eq 'command' -and $h.command -match 'rtk(\.exe)?\s+hook\s+claude' -and $h.command -ne $want) {
                    $h.command = $want
                    $changed = $true
                }
            }
            $key = ($entry.hooks | ForEach-Object { $_.command }) -join '|'
            if ($seen.ContainsKey($key)) {
                $changed = $true
            } else {
                $seen[$key] = $true
                $kept += $entry
            }
        }
        if ($changed) {
            $settings.hooks.PreToolUse = $kept
            ($settings | ConvertTo-Json -Depth 20) | Set-Content -LiteralPath $settingsPath -Encoding utf8
            Write-Log 'Normalized Claude Code rtk hook to absolute Git-Bash path'
        }
    } catch {
        Write-WarnLog "Could not normalize Claude rtk hook: $($_.Exception.Message)"
    }
}

function Repair-ClaudeAfterFailedUpdate {
    param([Parameter(Mandatory = $true)][string]$NpmPath)

    if (-not (Test-Path -LiteralPath $NpmPath)) {
        return $false
    }

    try {
        $npmBin = & $NpmPath prefix -g 2>$null
        if (-not $npmBin) {
            return $false
        }
        $npmBin = $npmBin.Trim()
        $pkgDir = Join-Path $npmBin 'node_modules\@anthropic-ai\claude-code'
        $binDir = Join-Path $pkgDir 'bin'
        $claudeExe = Join-Path $binDir 'claude.exe'
        if (-not (Test-Path -LiteralPath $binDir)) {
            return (Test-Path -LiteralPath $claudeExe -PathType Leaf)
        }

        $orphans = @(Get-ChildItem -LiteralPath $binDir -Filter 'claude.exe.old.*' -File -ErrorAction SilentlyContinue)
        if ($orphans.Count -gt 0) {
            $orphans = $orphans | Sort-Object Name -Descending
            if (-not (Test-Path -LiteralPath $claudeExe -PathType Leaf)) {
                $latest = $orphans | Select-Object -First 1
                try {
                    Move-Item -LiteralPath $latest.FullName -Destination $claudeExe -Force -ErrorAction Stop
                    Write-Log "Restored Claude CLI executable from $($latest.Name)."
                    $orphans = $orphans | Where-Object { $_.FullName -ne $latest.FullName }
                } catch {
                    Write-WarnLog "Could not restore Claude CLI executable from orphan: $($_.Exception.Message)"
                }
            }
        }

        # Fallback: copy from the bundled native-arch package when bin/claude.exe
        # is still missing (no .old orphan to restore from, or restore failed).
        if (-not (Test-Path -LiteralPath $claudeExe -PathType Leaf)) {
            $nativeCandidates = @(
                (Join-Path $pkgDir 'node_modules\@anthropic-ai\claude-code-win32-x64\claude.exe'),
                (Join-Path $pkgDir 'node_modules\@anthropic-ai\claude-code-win32-arm64\claude.exe')
            )
            foreach ($native in $nativeCandidates) {
                if (Test-Path -LiteralPath $native -PathType Leaf) {
                    try {
                        Copy-Item -LiteralPath $native -Destination $claudeExe -Force -ErrorAction Stop
                        Write-Log "Restored Claude CLI executable by copying from native package: $native"
                        break
                    } catch {
                        Write-WarnLog "Could not copy native Claude binary $native : $($_.Exception.Message)"
                    }
                }
            }
        }

        foreach ($o in $orphans) {
            Remove-Item -LiteralPath $o.FullName -Force -ErrorAction SilentlyContinue
        }
        return (Test-Path -LiteralPath $claudeExe -PathType Leaf)
    } catch {
        Write-WarnLog "Claude CLI repair check failed: $($_.Exception.Message)"
        return $false
    }
}

function Get-CodexCliProcesses {
    try {
        return @(Get-CimInstance Win32_Process -Filter "name = 'codex.exe' or name = 'node.exe'" -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -ieq 'codex.exe' -or ([string]$_.CommandLine) -match '\\@openai\\codex\\bin\\codex\.js'
        })
    } catch {
        return @()
    }
}

function Test-CodexCliRunning {
    return @(Get-CodexCliProcesses).Count -gt 0
}

function Stop-CodexCliForUpdate {
    $matches = @(Get-CodexCliProcesses)
    if ($matches.Count -eq 0) {
        return
    }
    $ids = @($matches | Select-Object -ExpandProperty ProcessId -Unique)
    Write-WarnLog "Codex CLI is currently running; closing process(es) before update: $($ids -join ', ')"
    foreach ($processId in $ids) {
        Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
    }
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline -and (Test-CodexCliRunning)) {
        Start-Sleep -Milliseconds 500
    }
    if (Test-CodexCliRunning) {
        Write-WarnLog 'Codex CLI is still running after the close request; npm may still hit a Windows file lock.'
    } else {
        Start-Sleep -Seconds 1
        Write-Log 'Codex CLI closed before update.'
    }
}

function Remove-CodexNpmTempDirs {
    param([Parameter(Mandatory = $true)][string]$NpmPath)

    if (-not (Test-Path -LiteralPath $NpmPath)) {
        return
    }

    try {
        $npmBin = & $NpmPath prefix -g 2>$null
        if (-not $npmBin) {
            return
        }
        $npmBin = $npmBin.Trim()
        $openAiRoot = Join-Path (Join-Path $npmBin 'node_modules') '@openai'
        if (-not (Test-Path -LiteralPath $openAiRoot)) {
            return
        }
        $rootFull = [System.IO.Path]::GetFullPath($openAiRoot).TrimEnd('\') + '\'
        Get-ChildItem -LiteralPath $openAiRoot -Force -Directory -Filter '.codex-*' -ErrorAction SilentlyContinue | ForEach-Object {
            $targetFull = [System.IO.Path]::GetFullPath($_.FullName)
            $isSafeTarget = $targetFull.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase) -and $_.Name.StartsWith('.codex-', [System.StringComparison]::OrdinalIgnoreCase)
            if ($isSafeTarget) {
                Remove-Item -LiteralPath $targetFull -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    } catch {
        Write-WarnLog "Codex npm temp cleanup skipped: $($_.Exception.Message)"
    }
}

function Install-NpmCliTarget {
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$NpmPath
    )
    if (-not $NpmCliSpecs.ContainsKey($Key)) {
        Throw-InstallError "Unknown npm target: $Key"
    }

    $spec = $NpmCliSpecs[$Key]
    $npmDir = Split-Path -Parent $NpmPath
    if ($npmDir) {
        $env:PATH = $npmDir + ';' + [string]$env:PATH
    }
    $env:npm_config_update_notifier = 'false'
    foreach ($pkg in $spec.Packages) {
        $isClaudePackage = $pkg -eq '@anthropic-ai/claude-code'
        $isCodexPackage = $pkg -eq '@openai/codex'
        if ($isClaudePackage) {
            [void](Repair-ClaudeAfterFailedUpdate -NpmPath $NpmPath)
        }
        if ($isCodexPackage) {
            Remove-CodexNpmTempDirs -NpmPath $NpmPath
            if (Test-CodexCliRunning) {
                Stop-CodexCliForUpdate
                if (Test-CodexCliRunning) {
                    Write-WarnLog 'Codex CLI could not be closed; aborting npm install/update to avoid locking codex.exe.'
                    continue
                }
            }
        }
        Write-Log "Trying npm package for $($spec.Label): $pkg"
        $code = Invoke-ExternalCommand -Args (@($NpmPath) + $NpmFlags + @('install', '-g', $pkg))
        $claudeHealthy = $false
        if ($isClaudePackage) {
            $claudeHealthy = Repair-ClaudeAfterFailedUpdate -NpmPath $NpmPath
        }
        if ($isCodexPackage) {
            Remove-CodexNpmTempDirs -NpmPath $NpmPath
        }
        if ($code -eq 0) {
            if ($isClaudePackage -and -not $claudeHealthy) {
                Write-WarnLog 'Claude npm install returned success, but claude.exe could not be found.'
                continue
            }
            Write-Log "Installed $($spec.Label) using package $pkg"
            return
        }
        if ($isCodexPackage -and (Test-CodexCliRunning)) {
            Write-WarnLog 'Codex npm install/update failed and Codex still appears to be running.'
        }
        if ($isClaudePackage -and $claudeHealthy) {
            Write-WarnLog 'Claude npm install/update failed, but an existing claude.exe was restored. Continuing with the recovered installation.'
            return
        }
    }
    Throw-InstallError "Failed to install $($spec.Label) via npm."
}

function Build-WindowsUpdaterScript {
@'
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$NpmFlags = @("--no-fund","--no-audit","--no-update-notifier","--loglevel","error")
$PipFlags = @("--disable-pip-version-check","--no-input","--quiet")

function Test-Cmd([string]$Name) { return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue) }
function Get-NpmPath() {
  $cmd = Get-Command npm -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  $candidates = @()
  if ($env:ProgramFiles) { $candidates += (Join-Path $env:ProgramFiles "nodejs\npm.cmd") }
  $pf86 = ${env:ProgramFiles(x86)}
  if ($pf86) { $candidates += (Join-Path $pf86 "nodejs\npm.cmd") }
  foreach ($candidate in $candidates) {
    if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
  }
  return $null
}
$npmPath = Get-NpmPath
if ($npmPath) {
  $npmDir = Split-Path -Parent $npmPath
  if ($npmDir) { $env:PATH = $npmDir + ';' + [string]$env:PATH }
}
$env:npm_config_update_notifier = 'false'

function Get-NpmPrefix {
  try {
    $prefix = & $npmPath prefix -g 2>$null
    if ($prefix) { return $prefix.Trim() }
  } catch { }
  return $null
}

function Remove-CodexNpmTempDirs {
  try {
    $prefix = Get-NpmPrefix
    if (-not $prefix) { return }
    $openAiRoot = Join-Path (Join-Path $prefix 'node_modules') '@openai'
    if (-not (Test-Path -LiteralPath $openAiRoot)) { return }
    $rootFull = [System.IO.Path]::GetFullPath($openAiRoot).TrimEnd('\') + '\'
    Get-ChildItem -LiteralPath $openAiRoot -Force -Directory -Filter '.codex-*' -ErrorAction SilentlyContinue | ForEach-Object {
      $targetFull = [System.IO.Path]::GetFullPath($_.FullName)
      $isSafeTarget = $targetFull.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase) -and $_.Name.StartsWith('.codex-', [System.StringComparison]::OrdinalIgnoreCase)
      if ($isSafeTarget) { Remove-Item -LiteralPath $targetFull -Recurse -Force -ErrorAction SilentlyContinue }
    }
  } catch { }
}

function Get-CodexCliProcesses {
  try {
    return @(Get-CimInstance Win32_Process -Filter "name = 'codex.exe' or name = 'node.exe'" -ErrorAction SilentlyContinue | Where-Object {
      $_.Name -ieq 'codex.exe' -or ([string]$_.CommandLine) -match '\\@openai\\codex\\bin\\codex\.js'
    })
  } catch {
    return @()
  }
}

function Test-CodexCliRunning {
  return @(Get-CodexCliProcesses).Count -gt 0
}

function Stop-CodexCliForUpdate {
  $matches = @(Get-CodexCliProcesses)
  if ($matches.Count -eq 0) { return }
  $ids = @($matches | Select-Object -ExpandProperty ProcessId -Unique)
  foreach ($processId in $ids) { Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue }
  $deadline = (Get-Date).AddSeconds(30)
  while ((Get-Date) -lt $deadline -and (Test-CodexCliRunning)) { Start-Sleep -Milliseconds 500 }
  if (-not (Test-CodexCliRunning)) { Start-Sleep -Seconds 1 }
}

function Test-ClaudeCliRunning {
  try {
    $matches = Get-CimInstance Win32_Process -Filter "name = 'claude.exe'" -ErrorAction SilentlyContinue | Select-Object -First 1
    return $null -ne $matches
  } catch {
    return $false
  }
}

# Claude's @anthropic-ai/claude-code postinstall (and Claude's own self-updater
# / the Claude desktop app's winget upgrade) rename bin/claude.exe ->
# bin/claude.exe.old.<ts> before swapping in a new binary. If the swap fails
# (claude running -> EBUSY, missing platform package, interrupted download),
# the install is left with no claude.exe and an orphan .old file. Restore the
# latest .old when claude.exe is missing; if no orphan is available but the
# native-arch package is, copy from there; clean up stale .old files (each
# ~250MB) once claude.exe is healthy.
function Repair-ClaudeAfterFailedUpdate {
  if (-not $npmPath) { return }
  try {
    $npmBin = & $npmPath prefix -g 2>$null
    if (-not $npmBin) { return }
    $npmBin = $npmBin.Trim()
    $pkgDir = Join-Path $npmBin 'node_modules\@anthropic-ai\claude-code'
    $binDir = Join-Path $pkgDir 'bin'
    if (-not (Test-Path -LiteralPath $binDir)) { return }
    $claudeExe = Join-Path $binDir 'claude.exe'
    $orphans = @(Get-ChildItem -LiteralPath $binDir -Filter 'claude.exe.old.*' -File -ErrorAction SilentlyContinue)
    if ($orphans.Count -gt 0) {
      # `.old.<timestamp>` is monotonic, so name-desc gives the newest first.
      $orphans = $orphans | Sort-Object Name -Descending
      if (-not (Test-Path -LiteralPath $claudeExe)) {
        $latest = $orphans | Select-Object -First 1
        try {
          Move-Item -LiteralPath $latest.FullName -Destination $claudeExe -Force -ErrorAction Stop
          $orphans = $orphans | Where-Object { $_.FullName -ne $latest.FullName }
        } catch { }
      }
    }
    if (-not (Test-Path -LiteralPath $claudeExe)) {
      $nativeCandidates = @(
        (Join-Path $pkgDir 'node_modules\@anthropic-ai\claude-code-win32-x64\claude.exe'),
        (Join-Path $pkgDir 'node_modules\@anthropic-ai\claude-code-win32-arm64\claude.exe')
      )
      foreach ($native in $nativeCandidates) {
        if (Test-Path -LiteralPath $native) {
          try {
            Copy-Item -LiteralPath $native -Destination $claudeExe -Force -ErrorAction Stop
            break
          } catch { }
        }
      }
    }
    foreach ($o in $orphans) {
      Remove-Item -LiteralPath $o.FullName -Force -ErrorAction SilentlyContinue
    }
  } catch { }
}

# Run Claude bin recovery upfront, before any npm work. The orphan can be
# left by ANY update path that touches @anthropic-ai/claude-code (the Claude
# desktop app's winget upgrade, a self-update from inside `claude`, a
# half-applied npm install). Repairing eagerly lets every startup/logon/daily
# trigger self-heal.
Repair-ClaudeAfterFailedUpdate

# `npm i -g <pkg>@latest` is more reliable than `npm update -g`, which can
# leave packages stale when their dist-tag pinning is unusual (codex / claude
# both showed this in practice).
function Update-NpmCli([string[]]$Candidates) {
  if (-not $npmPath) { return }
  foreach ($pkg in $Candidates) {
    if ($pkg -eq '@anthropic-ai/claude-code') { Repair-ClaudeAfterFailedUpdate }
    & $npmPath list -g --depth=0 $pkg *> $null
    if ($LASTEXITCODE -ne 0) { continue }
    if ($pkg -eq '@openai/codex') {
      Remove-CodexNpmTempDirs
      Stop-CodexCliForUpdate
      if (Test-CodexCliRunning) { return }
    }
    if ($pkg -eq '@anthropic-ai/claude-code') {
      if (Test-ClaudeCliRunning) { return }
    }
    & $npmPath @NpmFlags i -g ("$pkg@latest") *>&1 | Out-Null
    if ($pkg -eq '@openai/codex') { Remove-CodexNpmTempDirs }
    if ($pkg -eq '@anthropic-ai/claude-code') { Repair-ClaudeAfterFailedUpdate }
    return
  }
}

# Re-emit the gemini shim. Gemini's npm shim can break when the package layout
# under node_modules/@google changes between versions; rewriting it after each
# update keeps the `gemini` command working.
function Repair-GeminiShim() {
  if (-not $npmPath) { return }
  try {
    $npmBin = (& $npmPath prefix -g 2>$null)
    if (-not $npmBin) { return }
    $npmBin = $npmBin.Trim()
    if (-not (Test-Path -LiteralPath $npmBin)) { return }
    $cmd = "@ECHO off`r`nGOTO start`r`n:find_dp0`r`nSET dp0=%~dp0`r`nEXIT /b`r`n:start`r`nSETLOCAL`r`nCALL :find_dp0`r`n`r`nSET `"GEMINI_ENTRY=`"`r`nIF EXIST `"%dp0%node_modules\@google\gemini-cli\bundle\gemini.js`" (`r`n  SET `"GEMINI_ENTRY=%dp0%node_modules\@google\gemini-cli\bundle\gemini.js`"`r`n) ELSE IF EXIST `"%dp0%node_modules\@google\gemini-cli\dist\index.js`" (`r`n  SET `"GEMINI_ENTRY=%dp0%node_modules\@google\gemini-cli\dist\index.js`"`r`n) ELSE (`r`n  for /d %%D in (`"%dp0%node_modules\@google\.gemini-cli-*`") do (`r`n    IF EXIST `"%%~fD\bundle\gemini.js`" (`r`n      SET `"GEMINI_ENTRY=%%~fD\bundle\gemini.js`"`r`n      GOTO found`r`n    )`r`n    IF EXIST `"%%~fD\dist\index.js`" (`r`n      SET `"GEMINI_ENTRY=%%~fD\dist\index.js`"`r`n      GOTO found`r`n    )`r`n  )`r`n)`r`n`r`n:found`r`nIF NOT DEFINED GEMINI_ENTRY (`r`n  ECHO Gemini CLI package not found under `"%dp0%node_modules\@google`" 1>&2`r`n  EXIT /b 1`r`n)`r`n`r`nIF EXIST `"%dp0%node.exe`" (`r`n  SET `"_prog=%dp0%node.exe`"`r`n) ELSE (`r`n  SET `"_prog=node`"`r`n  SET PATHEXT=%PATHEXT:;.JS;=;%`r`n)`r`n`r`nendLocal & goto #_undefined_# 2>NUL || title %COMSPEC% & `"%_prog%`"  `"%GEMINI_ENTRY%`" %*`r`n"
    Set-Content -LiteralPath (Join-Path $npmBin 'gemini.cmd') -Value $cmd -Encoding ASCII
    $ps1Shim = Join-Path $npmBin 'gemini.ps1'
    if (Test-Path -LiteralPath $ps1Shim) { Remove-Item -LiteralPath $ps1Shim -Force -ErrorAction SilentlyContinue }
  } catch { }
}

if ($npmPath) {
  Update-NpmCli @("@anthropic-ai/claude-code")
  Update-NpmCli @("@openai/codex")
  Update-NpmCli @("@google/gemini-cli")
  Update-NpmCli @("@vibe-kit/grok-cli")
  Update-NpmCli @("@qwen-code/qwen-code","qwen-code")
  Update-NpmCli @("@github/copilot","@githubnext/github-copilot-cli")
  Update-NpmCli @("openclaw")
  Update-NpmCli @("ironclaw")
  Repair-GeminiShim
}

if (Test-Cmd "py") {
  & py -3.14 -m pip install --user --upgrade @PipFlags pip *>&1 | Out-Null
  & py -3.14 -m pip install --user --upgrade @PipFlags uv *>&1 | Out-Null
}
if (Test-Cmd "uv") {
  & uv tool install --upgrade mistral-vibe *>&1 | Out-Null
} elseif (Test-Cmd "py") {
  & py -3.14 -m pip install --user --upgrade @PipFlags mistral-vibe *>&1 | Out-Null
}

if (Test-Cmd "winget") {
  & winget upgrade --id Ollama.Ollama -e --accept-package-agreements --accept-source-agreements --silent --disable-interactivity *>&1 | Out-Null
}

# Rebuild rtk from latest git master if it's already installed. Mirrors the
# install path: bust the cargo git checkout cache for the rtk repo (without
# this, `cargo install --git --force` silently reuses a stale checkout and
# rebuilds the same old SHA), then rebuild from --branch master. Refresh the
# rtk hook in Claude's settings.json so it survives `rtk init --auto-patch`
# re-registering the bare-name command (Claude Code runs PreToolUse hooks
# through Git Bash, which can't resolve bare `rtk` without cargo on PATH).
function Update-Rtk {
  $cargoBin = Join-Path $env:USERPROFILE '.cargo\bin'
  $cargo = Join-Path $cargoBin 'cargo.exe'
  $rtk = Join-Path $cargoBin 'rtk.exe'
  if (-not (Test-Path -LiteralPath $cargo) -or -not (Test-Path -LiteralPath $rtk)) { return }
  foreach ($sub in @('checkouts','db')) {
    $root = Join-Path $env:USERPROFILE ".cargo\git\$sub"
    if (Test-Path -LiteralPath $root) {
      Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'rtk-*' } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    }
  }
  & $cargo install --git https://github.com/rtk-ai/rtk --branch master --force *>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) { return }
  if (Test-Cmd 'claude') { & $rtk init -g --auto-patch *>&1 | Out-Null }
  if (Test-Cmd 'codex')  { & $rtk init -g --codex *>&1 | Out-Null }

  $settingsPath = Join-Path $env:USERPROFILE '.claude\settings.json'
  if (Test-Path -LiteralPath $settingsPath) {
    try {
      $s = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
      if ($s.hooks -and $s.hooks.PreToolUse) {
        $userLeaf = Split-Path -Leaf $env:USERPROFILE
        $want = "/c/Users/$userLeaf/.cargo/bin/rtk.exe hook claude"
        $changed = $false
        $seen = @{}
        $kept = @()
        foreach ($entry in $s.hooks.PreToolUse) {
          if ($entry.matcher -ne 'Bash') { $kept += $entry; continue }
          foreach ($h in $entry.hooks) {
            if ($h.type -eq 'command' -and $h.command -match 'rtk(\.exe)?\s+hook\s+claude' -and $h.command -ne $want) {
              $h.command = $want
              $changed = $true
            }
          }
          $key = ($entry.hooks | ForEach-Object { $_.command }) -join '|'
          if ($seen.ContainsKey($key)) { $changed = $true } else { $seen[$key] = $true; $kept += $entry }
        }
        if ($changed) {
          $s.hooks.PreToolUse = $kept
          ($s | ConvertTo-Json -Depth 20) | Set-Content -LiteralPath $settingsPath -Encoding utf8
        }
      }
    } catch { }
  }
}
Update-Rtk
'@
}

function Test-AutoUpdateTaskExists {
    try {
        $existing = Get-ScheduledTask -TaskName $AutoUpdateTaskName -ErrorAction SilentlyContinue
        return $null -ne $existing
    } catch {
        return $false
    }
}

# Auto-upgrade path: if a previous version of InstallTheCli has already
# registered the hidden auto-update task on this machine, rewrite the
# embedded updater script and re-register the task in place using the
# CURRENT logic. This makes shipping fixes (like the Claude bin recovery
# additions) propagate the next time the user runs install-all OR opens
# the GUI, without forcing them to manually re-run setup-updater.
function Refresh-AutoUpdateTaskIfPresent {
    if ($NoAutoUpdate -or $DryRun) { return }
    if (-not (Test-AutoUpdateTaskExists)) { return }
    try {
        Ensure-HiddenAutoUpdateTask
        Write-Log 'Auto-upgraded existing hidden auto-update task in place.'
    } catch {
        Write-WarnLog "Auto-update task refresh skipped: $($_.Exception.Message)"
    }
}

function Ensure-HiddenAutoUpdateTask {
    if ($NoAutoUpdate) {
        Write-Log 'Hidden auto-update task disabled for this run.'
        return
    }
    if ($DryRun) {
        Write-Log "Dry-run: would configure hidden Scheduled Task '$AutoUpdateTaskName'."
        return
    }

    New-Item -ItemType Directory -Force -Path $SupportDir | Out-Null
    Set-Content -LiteralPath $AutoUpdateScriptPath -Value (Build-WindowsUpdaterScript) -Encoding UTF8

    # VBS wrapper -> powershell ensures the updater never flashes a console
    # window. `powershell -WindowStyle Hidden` directly is not actually hidden
    # at logon on some Windows builds.
    $vbsBody = "Set WshShell = CreateObject(`"WScript.Shell`")`r`nWshShell.Run `"powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"`"$AutoUpdateScriptPath`"`"`", 0, False`r`n"
    Set-Content -LiteralPath $AutoUpdateVbsPath -Value $vbsBody -Encoding ASCII

    $actionArgs = "`"$AutoUpdateVbsPath`" //nologo"
    $action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument $actionArgs
    $triggerStartup = New-ScheduledTaskTrigger -AtStartup
    $triggerLogon = New-ScheduledTaskTrigger -AtLogOn
    $triggerDaily = New-ScheduledTaskTrigger -Daily -At $AutoUpdateTime
    $settings = New-ScheduledTaskSettingsSet -Hidden -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $principal = New-ScheduledTaskPrincipal -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $AutoUpdateTaskName -Action $action -Trigger @($triggerStartup, $triggerLogon, $triggerDaily) -Settings $settings -Principal $principal -Description 'Hidden AI CLI auto-update task created by InstallTheCli one-click PowerShell script.' -Force | Out-Null
    Write-Log "Configured hidden auto-update task (startup, logon, daily $AutoUpdateTime)."
}

function Show-Targets {
    @(
        'claude', 'codex', 'gemini', 'grok', 'qwen', 'copilot', 'openclaw', 'ironclaw', 'mistral', 'ollama', 'rtk', 'all'
    ) | ForEach-Object { Write-Host $_ }
}

function Show-Usage {
@"
Usage:
  .\install_all_windows.ps1 [command] [target] [-NoAutoUpdate] [-DryRun] [-AutoUpdateTime "3:00AM"]

Commands:
  install-all              Install all supported CLIs (default)
  install <target>         Install one target (claude/codex/gemini/grok/qwen/copilot/openclaw/ironclaw/mistral/ollama/rtk/all)
  setup-updater            Configure hidden auto-update Scheduled Task only
  list                     List supported targets
  help                     Show help (or use: Get-Help .\install_all_windows.ps1 -Detailed)
"@ | Write-Host
}

function Install-Target {
    param([Parameter(Mandatory = $true)][string]$NormalizedTarget)
    switch ($NormalizedTarget) {
        'claude'   { $npm = Ensure-NodeAndNpm; Install-NpmCliTarget -Key 'claude' -NpmPath $npm }
        'codex'    { $npm = Ensure-NodeAndNpm; Install-NpmCliTarget -Key 'codex' -NpmPath $npm }
        'gemini'   { $npm = Ensure-NodeAndNpm; Install-NpmCliTarget -Key 'gemini' -NpmPath $npm }
        'grok'     { $npm = Ensure-NodeAndNpm; Install-NpmCliTarget -Key 'grok' -NpmPath $npm }
        'qwen'     { $npm = Ensure-NodeAndNpm; Install-NpmCliTarget -Key 'qwen' -NpmPath $npm }
        'copilot'  { $npm = Ensure-NodeAndNpm; Install-NpmCliTarget -Key 'copilot' -NpmPath $npm }
        'openclaw' { $npm = Ensure-NodeAndNpm; Install-NpmCliTarget -Key 'openclaw' -NpmPath $npm }
        'ironclaw' { $npm = Ensure-NodeAndNpm; Install-NpmCliTarget -Key 'ironclaw' -NpmPath $npm }
        'mistral' { Install-MistralVibe }
        'mistral-vibe' { Install-MistralVibe }
        'vibe'    { Install-MistralVibe }
        'ollama'  { Install-OllamaOfficial }
        'rtk'     { Install-Rtk }
        'all'     { Install-AllTargets }
        default   { Throw-InstallError "Unknown target: $NormalizedTarget" }
    }
}

function Install-AllTargets {
    $npm = Ensure-NodeAndNpm
    foreach ($key in @('claude','codex','gemini','grok','qwen','copilot','openclaw','ironclaw')) {
        Install-NpmCliTarget -Key $key -NpmPath $npm
    }
    Install-MistralVibe
    Install-OllamaOfficial
}

function Normalize-Subcommand {
    param([string]$Value)
    $normalizedValue = if ([string]::IsNullOrWhiteSpace($Value)) { 'install-all' } else { $Value.ToLowerInvariant() }
    switch ($normalizedValue) {
        '' { 'install-all' }
        'all' { 'install-all' }
        'install-all' { 'install-all' }
        'install' { 'install' }
        'setup-updater' { 'setup-updater' }
        'setup-auto-update' { 'setup-updater' }
        'updater' { 'setup-updater' }
        'list' { 'list' }
        'help' { 'help' }
        '?' { 'help' }
        default { $normalizedValue }
    }
}

function Main {
    if ($Help) {
        Show-Usage
        return
    }

    $normalizedCommand = Normalize-Subcommand $Command
    $normalizedTarget = if ([string]::IsNullOrWhiteSpace($Target)) { 'all' } else { $Target.ToLowerInvariant() }

    switch ($normalizedCommand) {
        'help' { Show-Usage; return }
        'list' { Show-Targets; return }
        default { }
    }

    if (-not $DryRun) {
        Require-Admin
    }
    Write-Log 'Windows one-click AI CLI installer started.'
    Write-Log "Subcommand: $normalizedCommand"
    if ($normalizedCommand -eq 'install') { Write-Log "Target: $normalizedTarget" }
    if ($DryRun) { Write-Log 'Dry-run enabled. Commands will be printed only.' }

    # Auto-upgrade an existing hidden auto-update task to the current
    # updater script. Runs for every subcommand that does real work, so
    # users who already configured the task in a prior release pick up
    # fixes (e.g. Claude bin recovery improvements) automatically the
    # next time they run install-all or any install/setup-updater
    # subcommand. Idempotent: does nothing if the task isn't registered.
    Refresh-AutoUpdateTaskIfPresent

    switch ($normalizedCommand) {
        'install-all' {
            Install-AllTargets
            Ensure-HiddenAutoUpdateTask
        }
        'install' {
            Install-Target -NormalizedTarget $normalizedTarget
            Ensure-HiddenAutoUpdateTask
        }
        'setup-updater' {
            Ensure-HiddenAutoUpdateTask
        }
        default {
            Throw-InstallError "Unknown command: $Command"
        }
    }

    Write-Log 'Done.'
}

try {
    Main
}
catch {
    Write-Error $_
    exit 1
}
