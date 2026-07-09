<#
.SYNOPSIS
One-click Windows installer for AI CLIs used by InstallTheCli.

.DESCRIPTION
Installs all supported AI CLIs (or one selected target) using official package sources:
- winget for Node.js, Python 3.14, Ollama, Antigravity, and Visual Studio Code
- npm for Claude/Codex/Grok/Qwen/Copilot
- uv/pip for Mistral Vibe

Also configures a hidden Scheduled Task (startup, logon, daily) unless disabled.

.PARAMETER Command
Subcommand: install-all (default), install, list, setup-updater, help.

.PARAMETER Target
Target for the install subcommand: claude, codex, antigravity, vscode, grok, qwen, copilot, openclaw, ironclaw, mistral, ollama, all.

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
$AntigravityWingetId = 'Google.Antigravity'
$AntigravityCliInstallPs1 = 'https://antigravity.google/cli/install.ps1'
$AntigravityIdeWingetId = 'Google.AntigravityIDE'
$VSCodeWingetId = 'Microsoft.VisualStudioCode'
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
    & $exe @argList 2>&1 | ForEach-Object { Write-Host $_ }
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
            Ensure-WindowsCliPathEntries
            if (Test-AnyCommandAvailable -CommandNames @('ollama')) {
                Write-WarnLog "winget returned exit code $code, but ollama is available. Continuing with the installed CLI."
                return
            }
            Throw-InstallError "Failed to install/update Ollama (exit code $code)."
        }
    }
    if (-not $DryRun) { Ensure-WindowsCliPathEntries }
    Write-Log 'Installed/updated Ollama (official).'
}

function Install-WingetApp {
    param(
        [string]$Label,
        [string]$WingetId,
        [string[]]$CommandNames = @()
    )
    $winget = Get-WingetPath
    if (-not $winget) {
        Throw-InstallError "winget was not found. Cannot install $Label."
    }
    Write-Log "Installing $Label via winget ($WingetId)..."
    $code = Invoke-ExternalCommand -Args @($winget, 'install', '--id', $WingetId, '-e', '--accept-package-agreements', '--accept-source-agreements', '--silent', '--disable-interactivity')
    if ($code -ne 0) {
        Write-WarnLog "winget install failed (exit $code). Trying winget upgrade..."
        $code = Invoke-ExternalCommand -Args @($winget, 'upgrade', '--id', $WingetId, '-e', '--accept-package-agreements', '--accept-source-agreements', '--silent', '--disable-interactivity')
        if ($code -ne 0) {
            Ensure-WindowsCliPathEntries
            if ($CommandNames.Count -gt 0 -and (Test-AnyCommandAvailable -CommandNames $CommandNames)) {
                Write-WarnLog "winget returned exit code $code, but $Label command is available. Continuing with the installed CLI."
                return
            }
            Throw-InstallError "Failed to install/update $Label (exit code $code)."
        }
    }
    if (-not $DryRun) { Ensure-WindowsCliPathEntries }
    Write-Log "Installed/updated $Label."
}

function Install-Antigravity {
    Install-WingetApp -Label 'Antigravity (Google)' -WingetId $AntigravityWingetId -CommandNames @('antigravity')
}

function Install-AntigravityCli {
    Write-Log 'Installing standalone Antigravity CLI (agy) via official PowerShell installer...'
    if ($DryRun) {
        Write-Host "> powershell -NoProfile -ExecutionPolicy Bypass -Command `"Invoke-Expression (Invoke-RestMethod '$AntigravityCliInstallPs1')`""
        return
    }
    Invoke-Expression (Invoke-RestMethod $AntigravityCliInstallPs1)
    $agyBin = Join-Path $env:LOCALAPPDATA 'agy\bin'
    if (-not ($env:PATH -split ';' | Where-Object { $_ -eq $agyBin })) {
        $env:PATH = "$agyBin;$env:PATH"
    }
    Write-Log 'Installed/updated Antigravity CLI (agy).'
}

function Install-AntigravityIde {
    Install-WingetApp -Label 'Antigravity IDE' -WingetId $AntigravityIdeWingetId -CommandNames @('antigravity')
}

function Install-VSCode {
    Install-WingetApp -Label 'Visual Studio Code' -WingetId $VSCodeWingetId -CommandNames @('code')
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
        Configure-RtkIntegrations -RtkExe $rtkExe
        Write-Log "Installed rtk: $(& $rtkExe --version 2>&1)"
    }
}

# Claude Code on Windows runs PreToolUse hooks through Git Bash (/usr/bin/bash),
# whose minimal PATH does NOT include the cargo bin dir, so a bare `rtk` can't
# resolve there. rtk's own hook-detector, however, only recognizes the bare
# `rtk hook claude` string -- an absolute-path hook works but makes rtk print a
# "No hook installed" nag on every proxied command. We drop a tiny `rtk` shim
# into Git's usr\bin (which IS on that minimal PATH) so we can use the bare
# form (no nag); if the shim can't be written we fall back to the absolute
# POSIX path (works, but nags).
function Install-RtkBashShim {
    param([Parameter(Mandatory = $true)][string]$RtkPosix)
    try {
        # git.exe may live in <Git>\cmd, <Git>\bin, or <Git>\mingw64\bin, so
        # walk up until we find the install root whose usr\bin holds bash.exe
        # -- that usr\bin is exactly what Git Bash exposes as /usr/bin.
        $gitCmd = Get-Command git.exe -ErrorAction Stop
        $dir = Split-Path -Parent $gitCmd.Source
        $usrBin = $null
        for ($i = 0; $i -lt 5 -and $dir; $i++) {
            $candidate = Join-Path $dir 'usr\bin'
            if (Test-Path -LiteralPath (Join-Path $candidate 'bash.exe')) { $usrBin = $candidate; break }
            $dir = Split-Path -Parent $dir
        }
        if (-not $usrBin) { return $false }
        $shimPath = Join-Path $usrBin 'rtk'
        $shimBody = "#!/usr/bin/bash`nexec $RtkPosix `"`$@`"`n"
        $existing = if (Test-Path -LiteralPath $shimPath) { [System.IO.File]::ReadAllText($shimPath) } else { $null }
        if ($existing -ne $shimBody) {
            [System.IO.File]::WriteAllText($shimPath, $shimBody, (New-Object System.Text.UTF8Encoding($false)))
        }
        return (Test-Path -LiteralPath $shimPath)
    } catch {
        return $false
    }
}

# Pin the Claude Code PreToolUse Bash hook command to the bare `rtk hook claude`
# form when an rtk shim is resolvable from Git Bash (no detector nag), else the
# absolute POSIX path. Also dedupes any duplicate Bash-matcher blocks repeated
# `rtk init --auto-patch` runs leave behind.
function Update-ClaudeRtkHookCommand {
    if ($DryRun) { return }
    $settingsPath = Join-Path $env:USERPROFILE '.claude\settings.json'
    if (-not (Test-Path -LiteralPath $settingsPath)) { return }
    try {
        $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
        if (-not $settings.hooks -or -not $settings.hooks.PreToolUse) { return }
        $up = $env:USERPROFILE
        $rtkPosix = '/' + $up.Substring(0,1).ToLower() + ($up.Substring(2) -replace '\\','/') + '/.cargo/bin/rtk.exe'
        $want = if (Install-RtkBashShim -RtkPosix $rtkPosix) { 'rtk hook claude' } else { "$rtkPosix hook claude" }
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
            $key = ($entry | ConvertTo-Json -Depth 20 -Compress)
            if ($seen.ContainsKey($key)) {
                $changed = $true
            } else {
                $seen[$key] = $true
                $kept += $entry
            }
        }
        if ($changed) {
            $settings.hooks.PreToolUse = @($kept)
            [System.IO.File]::WriteAllText($settingsPath, ($settings | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding($false)))
            Write-Log "Pinned Claude Code rtk hook command to '$want'"
        }
    } catch {
        Write-WarnLog "Could not normalize Claude rtk hook: $($_.Exception.Message)"
    }
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Ensure-MarkdownImport {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ImportLine
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Utf8NoBom -Path $Path -Content "$ImportLine`n"
        return
    }
    $content = Get-Content -LiteralPath $Path -Raw
    if ($content -notmatch "(?m)^$([regex]::Escape($ImportLine))\s*$") {
        Write-Utf8NoBom -Path $Path -Content "$ImportLine`n`n$content"
    }
}

function Repair-CurrentWindowsPowerShellModulePath {
    if ($PSVersionTable.PSEdition -ne 'Desktop') { return }
    $pwshModuleRoot = Join-Path $env:ProgramFiles 'PowerShell\7\Modules'
    $env:PSModulePath = (($env:PSModulePath -split [IO.Path]::PathSeparator) |
        Where-Object {
            $_ -and
            ($_.TrimEnd('\') -ine $pwshModuleRoot.TrimEnd('\'))
        } |
        Select-Object -Unique) -join [IO.Path]::PathSeparator
}

function Remove-StaleAiCliSessionFunctions {
    foreach ($name in @('codex', 'claude', 'gemini')) {
        try {
            $fn = Get-Item -LiteralPath "Function:\$name" -ErrorAction SilentlyContinue
            if ($fn -and ([string]$fn.Definition) -match '\\AppData\\Local\\AI-CLIs\\') {
                Remove-Item -LiteralPath "Function:\$name" -Force -ErrorAction SilentlyContinue
                Write-Log "Removed stale in-session $name PowerShell shim."
            }
        } catch { }
    }
}

function Remove-StaleAiCliProfileShims {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    try {
        $content = Get-Content -LiteralPath $Path -Raw
        $pattern = '(?ms)^\s*# BEGIN AI-CLIS (?:CODEX|CLAUDE|GEMINI) SHIM\r?\n.*?^# END AI-CLIS (?:CODEX|CLAUDE|GEMINI) SHIM\r?\n?'
        $updated = [regex]::Replace($content, $pattern, '')
        if ($updated -ne $content) {
            Write-Utf8NoBom -Path $Path -Content $updated
            Write-Log "Removed stale AI-CLIS profile shim block(s): $Path"
        }
    } catch {
        Write-WarnLog "Could not clean stale AI-CLIS profile shims in $Path : $($_.Exception.Message)"
    }
}

function Ensure-ProfileBlock {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$BeginMarker,
        [Parameter(Mandatory = $true)][string]$EndMarker,
        [Parameter(Mandatory = $true)][string]$Block
    )
    try {
        $content = if (Test-Path -LiteralPath $Path) { Get-Content -LiteralPath $Path -Raw } else { '' }
        $pattern = "(?ms)^$([regex]::Escape($BeginMarker))\r?\n.*?^$([regex]::Escape($EndMarker))\r?\n?"
        if ($content -match $pattern) {
            $updated = [regex]::Replace($content, $pattern, "$Block`n")
        } else {
            $separator = if ([string]::IsNullOrEmpty($content)) { '' } elseif ($content.StartsWith("`r`n") -or $content.StartsWith("`n")) { "`n" } else { "`n`n" }
            $updated = "$Block$separator$content"
        }
        if ($updated -ne $content) {
            Write-Utf8NoBom -Path $Path -Content $updated
        }
    } catch {
        Write-WarnLog "Could not update PowerShell profile $Path : $($_.Exception.Message)"
    }
}

function Ensure-WindowsPowerShellProfileGuard {
    param([Parameter(Mandatory = $true)][string]$WindowsPowerShellAllHostsProfile)
    $begin = '# BEGIN INSTALLTHECLI WINDOWS POWERSHELL MODULEPATH GUARD'
    $end = '# END INSTALLTHECLI WINDOWS POWERSHELL MODULEPATH GUARD'
    $block = @'
# BEGIN INSTALLTHECLI WINDOWS POWERSHELL MODULEPATH GUARD
# Keep Windows PowerShell 5.1 from importing PowerShell 7 module manifests when
# launched from pwsh or Windows Terminal with an inherited PSModulePath.
if ($PSVersionTable.PSEdition -eq 'Desktop') {
  $pwshModuleRoot = Join-Path $env:ProgramFiles 'PowerShell\7\Modules'
  $env:PSModulePath = (($env:PSModulePath -split [IO.Path]::PathSeparator) |
    Where-Object {
      $_ -and
      ($_.TrimEnd('\') -ine $pwshModuleRoot.TrimEnd('\'))
    } |
    Select-Object -Unique) -join [IO.Path]::PathSeparator
}
# END INSTALLTHECLI WINDOWS POWERSHELL MODULEPATH GUARD
'@
    Ensure-ProfileBlock -Path $WindowsPowerShellAllHostsProfile -BeginMarker $begin -EndMarker $end -Block $block
}

function Ensure-WindowsCliExecutionPolicy {
    try {
        Repair-CurrentWindowsPowerShellModulePath
        $currentUserPolicy = Get-ExecutionPolicy -Scope CurrentUser
        if ($currentUserPolicy -notin @('RemoteSigned', 'Unrestricted', 'Bypass')) {
            Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force
            Write-Log 'Set CurrentUser PowerShell execution policy to RemoteSigned for local CLI shims.'
        }
    } catch {
        Write-WarnLog "Could not verify/set CurrentUser PowerShell execution policy: $($_.Exception.Message)"
    }
}

function Get-NormalizedWindowsPathKey {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    try {
        return [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Path)).TrimEnd('\').ToLowerInvariant()
    } catch {
        return $Path.Trim().TrimEnd('\').ToLowerInvariant()
    }
}

function Add-UniqueWindowsCliPathCandidate {
    param(
        [System.Collections.Generic.List[string]]$Candidates,
        [string]$Path
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return }
    $key = Get-NormalizedWindowsPathKey -Path $Path
    foreach ($existing in $Candidates) {
        if ((Get-NormalizedWindowsPathKey -Path $existing) -eq $key) { return }
    }
    [void]$Candidates.Add($Path)
}

function Get-WindowsCliPathCandidateDirs {
    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($candidate in @(
        (Join-Path $env:ProgramFiles 'nodejs'),
        (Join-Path ${env:ProgramFiles(x86)} 'nodejs'),
        (Join-Path $env:LOCALAPPDATA 'Programs\nodejs'),
        (Join-Path $env:APPDATA 'npm'),
        (Join-Path $env:LOCALAPPDATA 'agy\bin'),
        (Join-Path $env:USERPROFILE '.cargo\bin'),
        (Join-Path $env:USERPROFILE '.local\bin'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Ollama'),
        (Join-Path $env:ProgramFiles 'Ollama'),
        (Join-Path ${env:ProgramFiles(x86)} 'Ollama')
    )) {
        Add-UniqueWindowsCliPathCandidate -Candidates $candidates -Path $candidate
    }

    foreach ($pythonRoot in @(
        (Join-Path $env:APPDATA 'Python'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Python')
    )) {
        if (-not ($pythonRoot -and (Test-Path -LiteralPath $pythonRoot -PathType Container))) { continue }
        Get-ChildItem -LiteralPath $pythonRoot -Directory -Filter 'Python*' -ErrorAction SilentlyContinue |
            ForEach-Object {
                Add-UniqueWindowsCliPathCandidate -Candidates $candidates -Path (Join-Path $_.FullName 'Scripts')
            }
    }

    foreach ($folder in @('Microsoft VS Code', 'Antigravity', 'antigravity', 'Antigravity IDE', 'AntigravityIDE')) {
        foreach ($root in @(
            (Join-Path $env:LOCALAPPDATA 'Programs'),
            $env:ProgramFiles,
            ${env:ProgramFiles(x86)}
        )) {
            if (-not $root) { continue }
            $appRoot = Join-Path $root $folder
            Add-UniqueWindowsCliPathCandidate -Candidates $candidates -Path $appRoot
            Add-UniqueWindowsCliPathCandidate -Candidates $candidates -Path (Join-Path $appRoot 'bin')
        }
    }

    return @($candidates)
}

function Send-WindowsEnvironmentChanged {
    try {
        if (-not ('InstallTheCliNativeMethods' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class InstallTheCliNativeMethods {
  [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Auto)]
  public static extern IntPtr SendMessageTimeout(IntPtr hWnd, int Msg, UIntPtr wParam, string lParam, int fuFlags, int uTimeout, out UIntPtr lpdwResult);
}
'@ -ErrorAction Stop
        }
        $result = [UIntPtr]::Zero
        [void][InstallTheCliNativeMethods]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 0x2, 5000, [ref]$result)
    } catch { }
}

function Ensure-WindowsCliPathEntries {
    $dirs = @(Get-WindowsCliPathCandidateDirs)
    if ($dirs.Count -eq 0) { return }
    try {
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        $parts = @()
        if (-not [string]::IsNullOrWhiteSpace($userPath)) {
            $parts = @($userPath -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        }
        $seen = @{}
        foreach ($part in $parts) {
            $key = Get-NormalizedWindowsPathKey -Path $part
            if ($key) { $seen[$key] = $true }
        }
        $added = New-Object System.Collections.Generic.List[string]
        foreach ($dir in $dirs) {
            $key = Get-NormalizedWindowsPathKey -Path $dir
            if (-not $key -or $seen.ContainsKey($key)) { continue }
            $parts += $dir
            $seen[$key] = $true
            [void]$added.Add($dir)
        }
        if ($added.Count -gt 0) {
            [Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'User')
            Send-WindowsEnvironmentChanged
            Write-Log "Added CLI directories to user PATH for cmd, PowerShell, pwsh, and Windows Terminal: $($added -join ', ')"
        }

        $currentParts = @([string]$env:PATH -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $currentSeen = @{}
        foreach ($part in $currentParts) {
            $key = Get-NormalizedWindowsPathKey -Path $part
            if ($key) { $currentSeen[$key] = $true }
        }
        $prepend = @()
        foreach ($dir in $dirs) {
            $key = Get-NormalizedWindowsPathKey -Path $dir
            if ($key -and -not $currentSeen.ContainsKey($key)) {
                $prepend += $dir
                $currentSeen[$key] = $true
            }
        }
        if ($prepend.Count -gt 0) {
            $env:PATH = (($prepend + $currentParts) -join ';')
        }
    } catch {
        Write-WarnLog "Could not normalize user PATH for CLI consoles: $($_.Exception.Message)"
    }
}

function Test-SafeWindowsCliPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
        $roots = @($env:USERPROFILE, $env:APPDATA, $env:LOCALAPPDATA, $SupportDir) | Where-Object { $_ }
        foreach ($root in $roots) {
            $rootFull = [System.IO.Path]::GetFullPath($root).TrimEnd('\')
            if ($full.Equals($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
            if ($full.StartsWith($rootFull + '\', [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
        }
    } catch { }
    return $false
}

function Remove-ExplicitDenyAces {
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        $acl = Get-Acl -LiteralPath $Path
        $denyRules = @($acl.Access | Where-Object { $_.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Deny -and -not $_.IsInherited })
        if ($denyRules.Count -eq 0) { return }
        foreach ($rule in $denyRules) {
            [void]$acl.RemoveAccessRuleSpecific($rule)
        }
        Set-Acl -LiteralPath $Path -AclObject $acl
        Write-Log "Removed $($denyRules.Count) explicit deny ACE(s): $Path"
    } catch {
        Write-WarnLog "Could not remove deny ACEs from $Path : $($_.Exception.Message)"
    }
}

function Test-WindowsPrincipalExists {
    param([Parameter(Mandatory = $true)][string]$Principal)
    try {
        [void]([System.Security.Principal.NTAccount]$Principal).Translate([System.Security.Principal.SecurityIdentifier])
        return $true
    } catch {
        return $false
    }
}

function Ensure-WindowsCliDirectoryPermissions {
    $targets = New-Object System.Collections.Generic.List[string]
    foreach ($candidate in @(
        (Join-Path $env:APPDATA 'npm'),
        (Join-Path $env:LOCALAPPDATA 'agy'),
        (Join-Path $env:USERPROFILE '.codex'),
        (Join-Path $env:USERPROFILE '.codex-tmp'),
        (Join-Path $env:USERPROFILE '.claude'),
        (Join-Path $env:USERPROFILE '.agents'),
        (Join-Path $env:USERPROFILE '.gemini'),
        (Join-Path $env:USERPROFILE '.cargo'),
        (Join-Path $env:LOCALAPPDATA 'AnthropicClaude'),
        (Join-Path $env:LOCALAPPDATA 'Claude'),
        (Join-Path $env:LOCALAPPDATA 'OpenAI'),
        (Join-Path $env:APPDATA 'Claude'),
        $SupportDir
    )) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Container) -and (Test-SafeWindowsCliPath -Path $candidate)) {
            if (-not ($targets | Where-Object { $_ -ieq $candidate })) { [void]$targets.Add($candidate) }
        }
    }
    if ($targets.Count -eq 0) { return }

    $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $sandboxPrincipal = "$env:COMPUTERNAME\CodexSandboxUsers"
    $hasSandbox = Test-WindowsPrincipalExists -Principal $sandboxPrincipal

    foreach ($target in $targets) {
        try {
            Remove-ExplicitDenyAces -Path $target
            $grantArgs = @(
                $target,
                '/inheritance:e',
                '/grant',
                "${currentUser}:(OI)(CI)(F)",
                'NT AUTHORITY\SYSTEM:(OI)(CI)(F)',
                'BUILTIN\Administrators:(OI)(CI)(F)'
            )
            if ($hasSandbox) {
                $grantArgs += "${sandboxPrincipal}:(OI)(CI)(M)"
            }
            & icacls @grantArgs *> $null
        } catch {
            Write-WarnLog "Could not normalize CLI directory permissions for $target : $($_.Exception.Message)"
        }
    }
}

function Unblock-WindowsCliFiles {
    $dirs = @(
        (Join-Path $env:APPDATA 'npm'),
        (Join-Path $env:LOCALAPPDATA 'agy\bin'),
        (Join-Path $env:USERPROFILE '.cargo\bin')
    )
    foreach ($dir in $dirs) {
        if (-not ($dir -and (Test-Path -LiteralPath $dir -PathType Container))) { continue }
        try {
            Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.Extension -in @('.ps1', '.cmd', '.bat', '.exe') -or
                    $_.Name -match '^(codex|claude|agy|rtk|grok|qwen|copilot|github-copilot|openclaw|ironclaw|mistral-vibe|vibe)(\..*)?$'
                } |
                ForEach-Object {
                    Unblock-File -LiteralPath $_.FullName -ErrorAction SilentlyContinue
                }
        } catch {
            Write-WarnLog "Could not unblock CLI files in $dir : $($_.Exception.Message)"
        }
    }
}

function Ensure-WindowsCliTerminalCompatibility {
    if ($DryRun) {
        Write-Log 'Dry-run: would repair Windows terminal compatibility for CLI shims/profiles/permissions.'
        return
    }
    Write-Log 'Repairing Windows terminal compatibility for AI CLI shims and profiles...'
    Repair-CurrentWindowsPowerShellModulePath
    Ensure-WindowsCliPathEntries
    Remove-StaleAiCliSessionFunctions

    $documents = [Environment]::GetFolderPath('MyDocuments')
    $windowsPowerShellAllHosts = Join-Path $documents 'WindowsPowerShell\profile.ps1'
    $profilePaths = @(
        $windowsPowerShellAllHosts,
        (Join-Path $documents 'WindowsPowerShell\Microsoft.PowerShell_profile.ps1'),
        (Join-Path $documents 'PowerShell\profile.ps1'),
        (Join-Path $documents 'PowerShell\Microsoft.PowerShell_profile.ps1')
    )
    foreach ($profilePath in $profilePaths) {
        Remove-StaleAiCliProfileShims -Path $profilePath
    }
    Ensure-WindowsPowerShellProfileGuard -WindowsPowerShellAllHostsProfile $windowsPowerShellAllHosts
    Ensure-WindowsCliExecutionPolicy
    Ensure-WindowsCliDirectoryPermissions
    Unblock-WindowsCliFiles
}

function Test-AnyCommandAvailable {
    param([Parameter(Mandatory = $true)][string[]]$CommandNames)
    foreach ($name in $CommandNames) {
        if (Get-Command $name -ErrorAction SilentlyContinue) { return $true }
    }
    return $false
}

function Invoke-RtkInitIfCommand {
    param(
        [Parameter(Mandatory = $true)][string]$RtkExe,
        [Parameter(Mandatory = $true)][string[]]$CommandNames,
        [Parameter(Mandatory = $true)][string[]]$InitArgs,
        [Parameter(Mandatory = $true)][string]$Label
    )
    if (-not (Test-AnyCommandAvailable -CommandNames $CommandNames)) { return }
    Write-Log "Registering rtk for $Label"
    $rtkArgs = @($RtkExe, 'init', '-g') + @($InitArgs)
    [void](Invoke-ExternalCommand -Args $rtkArgs)
}

function Configure-RtkIntegrations {
    param([Parameter(Mandatory = $true)][string]$RtkExe)
    if (Get-Command claude -ErrorAction SilentlyContinue) {
        Write-Log 'Registering rtk hook for Claude Code'
        [void](Invoke-ExternalCommand -Args @($RtkExe, 'init', '-g', '--auto-patch'))
        Update-ClaudeRtkHookCommand
    }
    if (Get-Command codex -ErrorAction SilentlyContinue) {
        Write-Log 'Registering rtk for Codex CLI'
        [void](Invoke-ExternalCommand -Args @($RtkExe, 'init', '-g', '--codex'))
    }
    Invoke-RtkInitIfCommand -RtkExe $RtkExe -CommandNames @('copilot','github-copilot-cli','github-copilot') -InitArgs @('--copilot') -Label 'GitHub Copilot CLI'
    Invoke-RtkInitIfCommand -RtkExe $RtkExe -CommandNames @('opencode') -InitArgs @('--opencode') -Label 'OpenCode'
    foreach ($agent in @('cursor','windsurf','cline','kilocode','antigravity','hermes')) {
        Invoke-RtkInitIfCommand -RtkExe $RtkExe -CommandNames @($agent) -InitArgs @('--agent', $agent) -Label $agent
    }
}

function Repair-ClaudeAfterFailedUpdate {
    param([Parameter(Mandatory = $true)][string]$NpmPath)

    if ($DryRun) {
        Write-Log 'Dry-run: would check/repair Claude CLI native executable.'
        return $true
    }
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
    if ($DryRun) {
        Write-Log 'Dry-run: would close Codex CLI before npm update if it is running.'
        return
    }
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

    if ($DryRun) {
        Write-Log 'Dry-run: would clean stale Codex npm temp directories.'
        return
    }
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
        if ($isClaudePackage -and -not $DryRun) {
            [void](Repair-ClaudeAfterFailedUpdate -NpmPath $NpmPath)
        }
        if ($isCodexPackage -and -not $DryRun) {
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
        if ($isCodexPackage -and -not $DryRun) {
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
        if ($isCodexPackage -and -not $DryRun -and (Test-CodexCliRunning)) {
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

function Write-Utf8NoBom([string]$Path, [string]$Content) {
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $encoding = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Repair-CurrentWindowsPowerShellModulePath {
  if ($PSVersionTable.PSEdition -ne 'Desktop') { return }
  $pwshModuleRoot = Join-Path $env:ProgramFiles 'PowerShell\7\Modules'
  $env:PSModulePath = (($env:PSModulePath -split [IO.Path]::PathSeparator) |
    Where-Object { $_ -and ($_.TrimEnd('\') -ine $pwshModuleRoot.TrimEnd('\')) } |
    Select-Object -Unique) -join [IO.Path]::PathSeparator
}

function Remove-StaleAiCliProfileShims([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return }
  try {
    $content = Get-Content -LiteralPath $Path -Raw
    $pattern = '(?ms)^\s*# BEGIN AI-CLIS (?:CODEX|CLAUDE|GEMINI) SHIM\r?\n.*?^# END AI-CLIS (?:CODEX|CLAUDE|GEMINI) SHIM\r?\n?'
    $updated = [regex]::Replace($content, $pattern, '')
    if ($updated -ne $content) { Write-Utf8NoBom $Path $updated }
  } catch { }
}

function Ensure-ProfileBlock([string]$Path, [string]$BeginMarker, [string]$EndMarker, [string]$Block) {
  try {
    $content = if (Test-Path -LiteralPath $Path) { Get-Content -LiteralPath $Path -Raw } else { '' }
    $pattern = "(?ms)^$([regex]::Escape($BeginMarker))\r?\n.*?^$([regex]::Escape($EndMarker))\r?\n?"
    if ($content -match $pattern) {
      $updated = [regex]::Replace($content, $pattern, "$Block`n")
    } else {
      $separator = if ([string]::IsNullOrEmpty($content)) { '' } elseif ($content.StartsWith("`r`n") -or $content.StartsWith("`n")) { "`n" } else { "`n`n" }
      $updated = "$Block$separator$content"
    }
    if ($updated -ne $content) { Write-Utf8NoBom $Path $updated }
  } catch { }
}

function Ensure-WindowsPowerShellProfileGuard([string]$WindowsPowerShellAllHostsProfile) {
  $begin = '# BEGIN INSTALLTHECLI WINDOWS POWERSHELL MODULEPATH GUARD'
  $end = '# END INSTALLTHECLI WINDOWS POWERSHELL MODULEPATH GUARD'
  $lf = [char]0x0A
  $block = '# BEGIN INSTALLTHECLI WINDOWS POWERSHELL MODULEPATH GUARD' + $lf +
    'if ($PSVersionTable.PSEdition -eq ''Desktop'') {' + $lf +
    '  $pwshModuleRoot = Join-Path $env:ProgramFiles ''PowerShell\7\Modules''' + $lf +
    '  $env:PSModulePath = (($env:PSModulePath -split [IO.Path]::PathSeparator) |' + $lf +
    '    Where-Object {' + $lf +
    '      $_ -and' + $lf +
    '      ($_.TrimEnd(''\'') -ine $pwshModuleRoot.TrimEnd(''\''))' + $lf +
    '    } |' + $lf +
    '    Select-Object -Unique) -join [IO.Path]::PathSeparator' + $lf +
    '}' + $lf +
    '# END INSTALLTHECLI WINDOWS POWERSHELL MODULEPATH GUARD'
  Ensure-ProfileBlock $WindowsPowerShellAllHostsProfile $begin $end $block
}

function Ensure-WindowsCliExecutionPolicy {
  try {
    Repair-CurrentWindowsPowerShellModulePath
    $policy = Get-ExecutionPolicy -Scope CurrentUser
    if ($policy -notin @('RemoteSigned','Unrestricted','Bypass')) {
      Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force
    }
  } catch { }
}

function Get-NormalizedWindowsPathKey([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
  try {
    return [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Path)).TrimEnd('\').ToLowerInvariant()
  } catch {
    return $Path.Trim().TrimEnd('\').ToLowerInvariant()
  }
}

function Add-UniqueWindowsCliPathCandidate([System.Collections.Generic.List[string]]$Candidates, [string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) { return }
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return }
  $key = Get-NormalizedWindowsPathKey $Path
  foreach ($existing in $Candidates) {
    if ((Get-NormalizedWindowsPathKey $existing) -eq $key) { return }
  }
  [void]$Candidates.Add($Path)
}

function Get-WindowsCliPathCandidateDirs {
  $candidates = New-Object System.Collections.Generic.List[string]
  foreach ($candidate in @(
    (Join-Path $env:ProgramFiles 'nodejs'),
    (Join-Path ${env:ProgramFiles(x86)} 'nodejs'),
    (Join-Path $env:LOCALAPPDATA 'Programs\nodejs'),
    (Join-Path $env:APPDATA 'npm'),
    (Join-Path $env:LOCALAPPDATA 'agy\bin'),
    (Join-Path $env:USERPROFILE '.cargo\bin'),
    (Join-Path $env:USERPROFILE '.local\bin'),
    (Join-Path $env:LOCALAPPDATA 'Programs\Ollama'),
    (Join-Path $env:ProgramFiles 'Ollama'),
    (Join-Path ${env:ProgramFiles(x86)} 'Ollama')
  )) {
    Add-UniqueWindowsCliPathCandidate $candidates $candidate
  }
  foreach ($pythonRoot in @((Join-Path $env:APPDATA 'Python'), (Join-Path $env:LOCALAPPDATA 'Programs\Python'))) {
    if (-not ($pythonRoot -and (Test-Path -LiteralPath $pythonRoot -PathType Container))) { continue }
    Get-ChildItem -LiteralPath $pythonRoot -Directory -Filter 'Python*' -ErrorAction SilentlyContinue |
      ForEach-Object { Add-UniqueWindowsCliPathCandidate $candidates (Join-Path $_.FullName 'Scripts') }
  }
  foreach ($folder in @('Microsoft VS Code', 'Antigravity', 'antigravity', 'Antigravity IDE', 'AntigravityIDE')) {
    foreach ($root in @((Join-Path $env:LOCALAPPDATA 'Programs'), $env:ProgramFiles, ${env:ProgramFiles(x86)})) {
      if (-not $root) { continue }
      $appRoot = Join-Path $root $folder
      Add-UniqueWindowsCliPathCandidate $candidates $appRoot
      Add-UniqueWindowsCliPathCandidate $candidates (Join-Path $appRoot 'bin')
    }
  }
  return @($candidates)
}

function Send-WindowsEnvironmentChanged {
  try {
    if (-not ('InstallTheCliNativeMethods' -as [type])) {
      $signature = @(
        'using System;',
        'using System.Runtime.InteropServices;',
        'public static class InstallTheCliNativeMethods {',
        '  [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Auto)]',
        '  public static extern IntPtr SendMessageTimeout(IntPtr hWnd, int Msg, UIntPtr wParam, string lParam, int fuFlags, int uTimeout, out UIntPtr lpdwResult);',
        '}'
      ) -join [Environment]::NewLine
      Add-Type -TypeDefinition $signature -ErrorAction Stop
    }
    $result = [UIntPtr]::Zero
    [void][InstallTheCliNativeMethods]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 0x2, 5000, [ref]$result)
  } catch { }
}

function Ensure-WindowsCliPathEntries {
  $dirs = @(Get-WindowsCliPathCandidateDirs)
  if ($dirs.Count -eq 0) { return }
  try {
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $parts = @()
    if (-not [string]::IsNullOrWhiteSpace($userPath)) {
      $parts = @($userPath -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    $seen = @{}
    foreach ($part in $parts) {
      $key = Get-NormalizedWindowsPathKey $part
      if ($key) { $seen[$key] = $true }
    }
    $added = New-Object System.Collections.Generic.List[string]
    foreach ($dir in $dirs) {
      $key = Get-NormalizedWindowsPathKey $dir
      if (-not $key -or $seen.ContainsKey($key)) { continue }
      $parts += $dir
      $seen[$key] = $true
      [void]$added.Add($dir)
    }
    if ($added.Count -gt 0) {
      [Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'User')
      Send-WindowsEnvironmentChanged
    }
    $currentParts = @([string]$env:PATH -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $currentSeen = @{}
    foreach ($part in $currentParts) {
      $key = Get-NormalizedWindowsPathKey $part
      if ($key) { $currentSeen[$key] = $true }
    }
    $prepend = @()
    foreach ($dir in $dirs) {
      $key = Get-NormalizedWindowsPathKey $dir
      if ($key -and -not $currentSeen.ContainsKey($key)) {
        $prepend += $dir
        $currentSeen[$key] = $true
      }
    }
    if ($prepend.Count -gt 0) {
      $env:PATH = (($prepend + $currentParts) -join ';')
    }
  } catch { }
}

function Test-SafeWindowsCliPath([string]$Path) {
  try {
    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    $roots = @($env:USERPROFILE, $env:APPDATA, $env:LOCALAPPDATA, $env:LOCALAPPDATA + '\InstallTheCli') | Where-Object { $_ }
    foreach ($root in $roots) {
      $rootFull = [System.IO.Path]::GetFullPath($root).TrimEnd('\')
      if ($full.Equals($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
      if ($full.StartsWith($rootFull + '\', [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
  } catch { }
  return $false
}

function Remove-ExplicitDenyAces([string]$Path) {
  try {
    $acl = Get-Acl -LiteralPath $Path
    $denyRules = @($acl.Access | Where-Object { $_.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Deny -and -not $_.IsInherited })
    foreach ($rule in $denyRules) { [void]$acl.RemoveAccessRuleSpecific($rule) }
    if ($denyRules.Count -gt 0) { Set-Acl -LiteralPath $Path -AclObject $acl }
  } catch { }
}

function Test-WindowsPrincipalExists([string]$Principal) {
  try {
    [void]([System.Security.Principal.NTAccount]$Principal).Translate([System.Security.Principal.SecurityIdentifier])
    return $true
  } catch { return $false }
}

function Ensure-WindowsCliDirectoryPermissions {
  $targets = @(
    (Join-Path $env:APPDATA 'npm'),
    (Join-Path $env:LOCALAPPDATA 'agy'),
    (Join-Path $env:USERPROFILE '.codex'),
    (Join-Path $env:USERPROFILE '.codex-tmp'),
    (Join-Path $env:USERPROFILE '.claude'),
    (Join-Path $env:USERPROFILE '.agents'),
    (Join-Path $env:USERPROFILE '.gemini'),
    (Join-Path $env:USERPROFILE '.cargo'),
    (Join-Path $env:LOCALAPPDATA 'AnthropicClaude'),
    (Join-Path $env:LOCALAPPDATA 'Claude'),
    (Join-Path $env:LOCALAPPDATA 'OpenAI'),
    (Join-Path $env:APPDATA 'Claude'),
    (Join-Path $env:LOCALAPPDATA 'InstallTheCli')
  ) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) -and (Test-SafeWindowsCliPath $_) } | Select-Object -Unique
  if (-not $targets) { return }
  $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
  $sandboxPrincipal = "$env:COMPUTERNAME\CodexSandboxUsers"
  $hasSandbox = Test-WindowsPrincipalExists $sandboxPrincipal
  foreach ($target in $targets) {
    try {
      Remove-ExplicitDenyAces $target
      $grantArgs = @($target, '/inheritance:e', '/grant', "${currentUser}:(OI)(CI)(F)", 'NT AUTHORITY\SYSTEM:(OI)(CI)(F)', 'BUILTIN\Administrators:(OI)(CI)(F)')
      if ($hasSandbox) { $grantArgs += "${sandboxPrincipal}:(OI)(CI)(M)" }
      & icacls @grantArgs *> $null
    } catch { }
  }
}

function Unblock-WindowsCliFiles {
  foreach ($dir in @((Join-Path $env:APPDATA 'npm'), (Join-Path $env:LOCALAPPDATA 'agy\bin'), (Join-Path $env:USERPROFILE '.cargo\bin'))) {
    if (-not ($dir -and (Test-Path -LiteralPath $dir -PathType Container))) { continue }
    try {
      Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in @('.ps1','.cmd','.bat','.exe') -or $_.Name -match '^(codex|claude|agy|rtk|grok|qwen|copilot|github-copilot|openclaw|ironclaw|mistral-vibe|vibe)(\..*)?$' } |
        ForEach-Object { Unblock-File -LiteralPath $_.FullName -ErrorAction SilentlyContinue }
    } catch { }
  }
}

function Ensure-WindowsCliTerminalCompatibility {
  Repair-CurrentWindowsPowerShellModulePath
  Ensure-WindowsCliPathEntries
  $documents = [Environment]::GetFolderPath('MyDocuments')
  $windowsPowerShellAllHosts = Join-Path $documents 'WindowsPowerShell\profile.ps1'
  foreach ($profilePath in @(
    $windowsPowerShellAllHosts,
    (Join-Path $documents 'WindowsPowerShell\Microsoft.PowerShell_profile.ps1'),
    (Join-Path $documents 'PowerShell\profile.ps1'),
    (Join-Path $documents 'PowerShell\Microsoft.PowerShell_profile.ps1')
  )) {
    Remove-StaleAiCliProfileShims $profilePath
  }
  Ensure-WindowsPowerShellProfileGuard $windowsPowerShellAllHosts
  Ensure-WindowsCliExecutionPolicy
  Ensure-WindowsCliDirectoryPermissions
  Unblock-WindowsCliFiles
}
Ensure-WindowsCliTerminalCompatibility

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
# latest .old when claude.exe is missing; if no orphan is available, or
# claude.exe exists only as a tiny broken placeholder, copy from the
# native-arch package; clean up stale .old files (each ~250MB) once
# claude.exe is healthy.
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
    $needsNativeCopy = -not (Test-Path -LiteralPath $claudeExe)
    if (-not $needsNativeCopy) {
      try {
        $current = Get-Item -LiteralPath $claudeExe -ErrorAction Stop
        if ($current.Length -lt 1048576) { $needsNativeCopy = $true }
      } catch { }
    }
    if ($needsNativeCopy) {
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

if ($npmPath) {
  Update-NpmCli @("@anthropic-ai/claude-code")
  Update-NpmCli @("@openai/codex")
  Update-NpmCli @("@vibe-kit/grok-cli")
  Update-NpmCli @("@qwen-code/qwen-code","qwen-code")
  Update-NpmCli @("@github/copilot","@githubnext/github-copilot-cli")
  Update-NpmCli @("openclaw")
  Update-NpmCli @("ironclaw")
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
  & winget upgrade --id Google.Antigravity -e --accept-package-agreements --accept-source-agreements --silent --disable-interactivity *>&1 | Out-Null
  & winget upgrade --id Google.AntigravityIDE -e --accept-package-agreements --accept-source-agreements --silent --disable-interactivity *>&1 | Out-Null
  & winget upgrade --id Microsoft.VisualStudioCode -e --accept-package-agreements --accept-source-agreements --silent --disable-interactivity *>&1 | Out-Null
}

function Write-Utf8NoBom([string]$Path, [string]$Content) {
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $encoding = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Ensure-MarkdownImport([string]$Path, [string]$ImportLine) {
  if (-not (Test-Path -LiteralPath $Path)) {
    Write-Utf8NoBom $Path "$ImportLine`n"
    return
  }
  $content = Get-Content -LiteralPath $Path -Raw
  if ($content -notmatch "(?m)^$([regex]::Escape($ImportLine))\s*$") {
    Write-Utf8NoBom $Path "$ImportLine`n`n$content"
  }
}

function Test-AnyCmd([string[]]$CommandNames) {
  foreach ($name in $CommandNames) { if (Test-Cmd $name) { return $true } }
  return $false
}

function Invoke-RtkInitIfCommand {
  param([string]$RtkExe, [string[]]$CommandNames, [string[]]$InitArgs)
  if (Test-AnyCmd $CommandNames) { & $RtkExe init -g @InitArgs *>&1 | Out-Null }
}

# Drop a tiny `rtk` shim into Git's usr\bin so the bare `rtk hook claude` form
# resolves from Claude Code's Git-Bash hook shell (minimal PATH, no cargo dir).
# The bare form is also the only one rtk's hook-detector recognizes, so this
# avoids the "No hook installed" nag. Returns $true if the shim is in place.
function Install-RtkBashShim {
  param([string]$RtkPosix)
  try {
    $gitCmd = Get-Command git.exe -ErrorAction Stop
    $dir = Split-Path -Parent $gitCmd.Source
    $usrBin = $null
    for ($i = 0; $i -lt 5 -and $dir; $i++) {
      $candidate = Join-Path $dir 'usr\bin'
      if (Test-Path -LiteralPath (Join-Path $candidate 'bash.exe')) { $usrBin = $candidate; break }
      $dir = Split-Path -Parent $dir
    }
    if (-not $usrBin) { return $false }
    $shimPath = Join-Path $usrBin 'rtk'
    $shimBody = "#!/usr/bin/bash`nexec $RtkPosix `"`$@`"`n"
    $existing = if (Test-Path -LiteralPath $shimPath) { [System.IO.File]::ReadAllText($shimPath) } else { $null }
    if ($existing -ne $shimBody) {
      [System.IO.File]::WriteAllText($shimPath, $shimBody, (New-Object System.Text.UTF8Encoding($false)))
    }
    return (Test-Path -LiteralPath $shimPath)
  } catch { return $false }
}

# Rebuild rtk from latest git master if it's already installed. Mirrors the
# install path: bust the cargo git checkout cache for the rtk repo (without
# this, `cargo install --git --force` silently reuses a stale checkout and
# rebuilds the same old SHA), then rebuild from --branch master. Refresh the
# rtk hook in Claude's settings.json: prefer the bare `rtk hook claude` form
# (no detector nag) backed by the Git-Bash shim above, falling back to the
# absolute POSIX path if the shim can't be installed.
function Update-Rtk {
  $cargoBin = Join-Path $env:USERPROFILE '.cargo\bin'
  $cargo = Join-Path $cargoBin 'cargo.exe'
  $rtk = Join-Path $cargoBin 'rtk.exe'
  if (-not (Test-Path -LiteralPath $cargo) -or -not (Test-Path -LiteralPath $rtk)) { return }
  $activeRtk = @(Get-Process -Name 'rtk' -ErrorAction SilentlyContinue)
  if ($activeRtk.Count -eq 0) {
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
  }
  if (Test-Cmd 'claude') { & $rtk init -g --auto-patch *>&1 | Out-Null }
  if (Test-Cmd 'codex')  { & $rtk init -g --codex *>&1 | Out-Null }
  Invoke-RtkInitIfCommand -RtkExe $rtk -CommandNames @('copilot','github-copilot-cli','github-copilot') -InitArgs @('--copilot')
  Invoke-RtkInitIfCommand -RtkExe $rtk -CommandNames @('opencode') -InitArgs @('--opencode')
  foreach ($agent in @('cursor','windsurf','cline','kilocode','antigravity','hermes')) {
    Invoke-RtkInitIfCommand -RtkExe $rtk -CommandNames @($agent) -InitArgs @('--agent',$agent)
  }

  $settingsPath = Join-Path $env:USERPROFILE '.claude\settings.json'
  if (Test-Path -LiteralPath $settingsPath) {
    try {
      $s = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
      if ($s.hooks -and $s.hooks.PreToolUse) {
        $up = $env:USERPROFILE
        $rtkPosix = '/' + $up.Substring(0,1).ToLower() + ($up.Substring(2) -replace '\\','/') + '/.cargo/bin/rtk.exe'
        $want = if (Install-RtkBashShim -RtkPosix $rtkPosix) { 'rtk hook claude' } else { "$rtkPosix hook claude" }
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
          $key = ($entry | ConvertTo-Json -Depth 20 -Compress)
          if ($seen.ContainsKey($key)) { $changed = $true } else { $seen[$key] = $true; $kept += $entry }
        }
        if ($changed) {
          $s.hooks.PreToolUse = @($kept)
          [System.IO.File]::WriteAllText($settingsPath, ($s | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding($false)))
        }
      }
    } catch { }
  }
}
Update-Rtk
Ensure-WindowsCliTerminalCompatibility
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
        'claude', 'codex', 'antigravity', 'antigravity_cli', 'antigravity_ide', 'vscode', 'grok', 'qwen', 'copilot', 'openclaw', 'ironclaw', 'mistral', 'ollama', 'rtk', 'all'
    ) | ForEach-Object { Write-Host $_ }
}

function Show-Usage {
@"
Usage:
  .\install_all_windows.ps1 [command] [target] [-NoAutoUpdate] [-DryRun] [-AutoUpdateTime "3:00AM"]

Commands:
  install-all              Install all supported CLIs (default)
  install <target>         Install one target (claude/codex/antigravity/antigravity_cli/antigravity_ide/vscode/grok/qwen/copilot/openclaw/ironclaw/mistral/ollama/rtk/all)
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
        'antigravity' { Install-Antigravity }
        'antigravity_cli' { Install-AntigravityCli }
        'antigravity_ide' { Install-AntigravityIde }
        'agy'      { Install-AntigravityCli }
        'antigravity-ide' { Install-AntigravityIde }
        'vscode'   { Install-VSCode }
        'code'     { Install-VSCode }
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
    foreach ($key in @('claude','codex','grok','qwen','copilot','openclaw','ironclaw')) {
        Install-NpmCliTarget -Key $key -NpmPath $npm
    }
    Install-MistralVibe
    Install-OllamaOfficial
    Install-Antigravity
    Install-AntigravityCli
    Install-AntigravityIde
    Install-VSCode
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

    # Repair stale PowerShell profile shims, PowerShell 5.1 module autoloading,
    # user-level execution policy, unblock marks, and scoped CLI directory ACLs
    # before/after install work so Windows Terminal, conhost, cmd, powershell,
    # and pwsh all resolve the same installed commands.
    Ensure-WindowsCliTerminalCompatibility

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

    Ensure-WindowsCliTerminalCompatibility

    Write-Log 'Done.'
}

try {
    Main
}
catch {
    Write-Error $_
    exit 1
}
