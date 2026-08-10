#Requires -Version 5.1
<#
Fix-AiClis.ps1  (v2)

v2 changes:
  - FIXED: Get-Command returned multiple matches; v1 crashed trying to run the
    whole array as one path. Now takes the first PATH match.
  - Codex is now sourced from npm (@openai/codex) and the conflicting winget
    package (OpenAI.Codex) is removed, per your choice.
  - Reports MSIX service state (AppXSvc / InstallService / ClipSVC / wuauserv)
    WITHOUT changing anything - that 0x80070422 is why winget MSIX upgrades die.
  - Actually launches claude and codex to prove they run, not just resolve.

Run non-elevated:
    powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\admin\git\InstallTheCli-s\Fix-AiClis.ps1"

Add -ReportOnly to diagnose without changing anything.
Log: %USERPROFILE%\Fix-AiClis-log.txt
#>

[CmdletBinding()]
param(
    [switch]$ReportOnly
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

$LogPath = Join-Path $env:USERPROFILE 'Fix-AiClis-log.txt'
if (Test-Path -LiteralPath $LogPath) { Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue }

function Say {
    param([string]$Text = '')
    Write-Host $Text
    Add-Content -LiteralPath $script:LogPath -Value $Text -Encoding UTF8
}

function Section {
    param([string]$Title)
    Say ''
    Say ('=' * 60)
    Say $Title
    Say ('=' * 60)
}

# v1 BUG WAS HERE: Get-Command can return several matches; .Source on the array
# produced one space-joined mega-string that was then executed as a command.
function Get-CmdPath {
    param([string]$Name)
    $all = @(Get-Command $Name -All -ErrorAction SilentlyContinue |
             Where-Object { $_.CommandType -in @('Application','ExternalScript') })
    if ($all.Count -eq 0) { return $null }
    return $all[0].Source
}

function Get-AllCmdPaths {
    param([string]$Name)
    return @(Get-Command $Name -All -ErrorAction SilentlyContinue |
             Where-Object { $_.CommandType -in @('Application','ExternalScript') } |
             ForEach-Object { $_.Source })
}

function Invoke-Probe {
    param([string]$ExePath, [string[]]$Arguments = @('--version'), [int]$TimeoutSec = 45)
    if (-not $ExePath) { return '(not found)' }
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = $ExePath
        $psi.Arguments              = ($Arguments -join ' ')
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.UseShellExecute        = $false
        $psi.CreateNoWindow         = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        if (-not $p.WaitForExit($TimeoutSec * 1000)) {
            try { $p.Kill() } catch { }
            return "(HUNG - no exit after $TimeoutSec s)"
        }
        $out = ($p.StandardOutput.ReadToEnd() + ' ' + $p.StandardError.ReadToEnd())
        return ("exit={0} :: {1}" -f $p.ExitCode, (($out -replace '\s+', ' ').Trim()))
    } catch {
        return "(failed to launch: $($_.Exception.Message))"
    }
}

Say "Fix-AiClis.ps1 v2"
Say "Run at     : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Say "User       : $env:USERDOMAIN\$env:USERNAME"
Say "PS version : $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
Say "ReportOnly : $ReportOnly"

# ---------------------------------------------------------------------------
Section '1. COMMAND RESOLUTION (all PATH matches, in search order)'
# ---------------------------------------------------------------------------

foreach ($n in @('claude','codex','node','npm','winget')) {
    $paths = Get-AllCmdPaths $n
    if ($paths.Count -eq 0) {
        Say ("{0,-8} : NOT FOUND" -f $n)
    } else {
        Say ("{0,-8} : {1}" -f $n, $paths[0])
        for ($i = 1; $i -lt $paths.Count; $i++) {
            Say ("{0,-8}   shadowed: {1}" -f '', $paths[$i])
        }
    }
}

Say ''
$pyNpm = Join-Path $env:LOCALAPPDATA 'Programs\Python\Python314\Scripts\npm.exe'
if (Test-Path -LiteralPath $pyNpm) {
    Say "NOTE: an npm.exe exists inside Python's Scripts folder and wins on PATH:"
    Say "  $pyNpm"
    $fi = Get-Item -LiteralPath $pyNpm
    Say "  size=$($fi.Length) modified=$($fi.LastWriteTime)"
    Say "  This is almost certainly from a pip package (nodejs-bin / nodeenv)."
    Say "  It shadows the real Node npm and can break npm-based updates."
    Say "  probe: $(Invoke-Probe -ExePath $pyNpm -Arguments @('--version') -TimeoutSec 30)"
}

# Prefer the real Node npm, never the Python shim.
$npmExe = $null
foreach ($cand in @(
    (Join-Path $env:ProgramFiles 'nodejs\npm.cmd'),
    (Join-Path $env:APPDATA 'npm\npm.cmd')
)) {
    if (Test-Path -LiteralPath $cand -PathType Leaf) { $npmExe = $cand; break }
}
if (-not $npmExe) { $npmExe = Get-CmdPath 'npm' }
Say ''
Say "npm chosen for this script: $(if ($npmExe) { $npmExe } else { 'NONE - Node.js missing' })"

# ---------------------------------------------------------------------------
Section '2. DOES CLAUDE ACTUALLY RUN?'
# ---------------------------------------------------------------------------

$claudeNative = Join-Path $env:USERPROFILE '.local\bin\claude.exe'
Say "claude.exe on disk : $(Test-Path -LiteralPath $claudeNative -PathType Leaf)"
if (Test-Path -LiteralPath $claudeNative -PathType Leaf) {
    $fi = Get-Item -LiteralPath $claudeNative
    Say "  size=$($fi.Length) bytes  modified=$($fi.LastWriteTime)"
}
Say "claude --version   : $(Invoke-Probe -ExePath (Get-CmdPath 'claude'))"
Say "codex  --version   : $(Invoke-Probe -ExePath (Get-CmdPath 'codex'))"

Say ''
Say "Cross-shell check (each spawns a fresh environment):"
foreach ($shell in @(
    @{ n = 'cmd.exe';        c = { cmd.exe /d /c "claude --version 2>&1 & echo ERRORLEVEL=%errorlevel%" } },
    @{ n = 'powershell 5.1'; c = { powershell.exe -NoProfile -Command "claude --version; 'exit=' + `$LASTEXITCODE" } },
    @{ n = 'pwsh 7';         c = { pwsh.exe -NoProfile -Command "claude --version; 'exit=' + `$LASTEXITCODE" } }
)) {
    Say "  --- $($shell.n) ---"
    try {
        $r = & $shell.c 2>&1 | Out-String
        Say ("    " + ($r.Trim() -replace "`r?`n", "`n    "))
    } catch {
        Say "    FAILED: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
Section '3. MSIX SERVICE STATE  (read-only - the 0x80070422 cause)'
# ---------------------------------------------------------------------------

Say "winget MSIX installs (Anthropic.Claude desktop, Firefox Nightly MSIX) fail"
Say "with 0x80070422 = ERROR_SERVICE_DISABLED. These are the services involved."
Say ''
foreach ($svc in @('AppXSvc','ClipSVC','InstallService','wuauserv','StateRepository','TokenBroker')) {
    $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if (-not $s) { Say ("  {0,-16} : NOT PRESENT" -f $svc); continue }
    $start = (Get-CimInstance Win32_Service -Filter "Name='$svc'" -ErrorAction SilentlyContinue).StartMode
    $flag = if ($start -eq 'Disabled') { '   <-- DISABLED' } else { '' }
    Say ("  {0,-16} : Status={1,-8} StartMode={2}{3}" -f $svc, $s.Status, $start, $flag)
}
Say ''
Say "NOT changing these, per your instruction. To re-enable one yourself, from an"
Say "ELEVATED prompt:    sc.exe config AppXSvc start= demand"
Say "                    sc.exe config InstallService start= demand"
Say "(AppXSvc is protected on some builds; if sc.exe is denied, set StartMode via"
Say " HKLM\SYSTEM\CurrentControlSet\Services\AppXSvc\Start = 3, then reboot.)"

if ($ReportOnly) {
    Section 'REPORT-ONLY - NO CHANGES MADE'
    Say "Log: $LogPath"
    return
}

# ---------------------------------------------------------------------------
Section '4. CLAUDE CODE CLI - NATIVE INSTALL / UPDATE'
# ---------------------------------------------------------------------------

if ($npmExe) {
    $prefix = (& $npmExe prefix -g 2>$null | Out-String).Trim()
    if ($prefix) {
        $legacy = Join-Path $prefix 'node_modules\@anthropic-ai\claude-code'
        if (Test-Path -LiteralPath $legacy) {
            Say "Removing legacy npm @anthropic-ai/claude-code (it shadows the native exe)..."
            & $npmExe uninstall -g '@anthropic-ai/claude-code' 2>&1 | ForEach-Object { Say "  $_" }
        } else {
            Say "No legacy npm Claude package. Good."
        }
    } else {
        Say "Could not read npm global prefix; skipping legacy check."
    }
}

Say "Running Anthropic's native installer..."
try {
    $script = Invoke-RestMethod -Uri 'https://claude.ai/install.ps1' -UseBasicParsing
    Invoke-Expression $script 2>&1 | ForEach-Object { Say "  $_" }
} catch {
    Say "Native Claude installer FAILED: $($_.Exception.Message)"
}

# ---------------------------------------------------------------------------
Section '5. CODEX CLI - REMOVE WINGET COPY, INSTALL VIA npm'
# ---------------------------------------------------------------------------

Say "Stopping running codex processes..."
Get-Process -Name 'codex' -ErrorAction SilentlyContinue | ForEach-Object {
    Say "  stopping PID $($_.Id)"
    Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Seconds 2

$wingetExe = Get-CmdPath 'winget'
if ($wingetExe) {
    $listed = & $wingetExe list --id OpenAI.Codex --exact 2>&1 | Out-String
    if ($listed -match 'OpenAI\.Codex') {
        Say "Uninstalling winget package OpenAI.Codex (conflicts with the npm codex)..."
        & $wingetExe uninstall --id OpenAI.Codex --exact --silent --disable-interactivity 2>&1 |
            ForEach-Object { Say "  $_" }
        Say "Pinning OpenAI.Codex so 'winget upgrade --all' cannot bring it back..."
        & $wingetExe pin add --id OpenAI.Codex --exact --blocking 2>&1 |
            ForEach-Object { Say "  $_" }
    } else {
        Say "winget package OpenAI.Codex is not installed. Nothing to remove."
    }
    foreach ($alias in @('codex.exe','codex-command-runner.exe','codex-windows-sandbox-setup.exe')) {
        $link = Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Links\$alias"
        if (Test-Path -LiteralPath $link) {
            Say "Removing leftover WinGet alias: $link"
            Remove-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue
        }
    }
} else {
    Say "winget not found; skipping winget codex removal."
}

if ($npmExe) {
    Say "Installing @openai/codex via npm..."
    & $npmExe install -g '@openai/codex' --no-fund --no-audit 2>&1 | ForEach-Object { Say "  $_" }
} else {
    Say "npm unavailable - install Node.js 22 LTS from https://nodejs.org, then re-run."
}

# ---------------------------------------------------------------------------
Section '6. USER PATH (registry-safe write, no truncation)'
# ---------------------------------------------------------------------------

function Test-PathHas {
    param([string]$PathBlob, [string]$Dir)
    if (-not $PathBlob) { return $false }
    $target = ($Dir.TrimEnd('\')).ToLowerInvariant()
    foreach ($p in ($PathBlob -split ';')) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        if ([Environment]::ExpandEnvironmentVariables($p).TrimEnd('\').ToLowerInvariant() -eq $target) { return $true }
    }
    return $false
}

$localBin = Join-Path $env:USERPROFILE '.local\bin'
$npmDir   = Join-Path $env:APPDATA 'npm'
$wanted   = @($localBin, $npmDir) | Where-Object { Test-Path -LiteralPath $_ -PathType Container }

try {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
    $cur = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    Say "Current user PATH length: $($cur.Length) characters"
    if ($cur.Length -gt 2000) {
        Say "WARNING: over 2000 chars. Anything past ~2048 can be silently dropped by"
        Say "older tools and by the classic Environment Variables GUI. Worth pruning."
    }
    $parts = @($cur -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $added = @()
    foreach ($d in $wanted) {
        if (-not (Test-PathHas -PathBlob ($parts -join ';') -Dir $d)) { $parts += $d; $added += $d }
    }
    if ($added.Count -gt 0) {
        $key.SetValue('Path', ($parts -join ';'), [Microsoft.Win32.RegistryValueKind]::ExpandString)
        Say "Added: $($added -join ', ')"
    } else {
        Say "Already present: $($wanted -join ', ')"
    }
    $key.Close()
} catch {
    Say "PATH repair FAILED: $($_.Exception.Message)"
}

try {
    if (-not ('Win32SettingChange' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class Win32SettingChange {
  [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Auto)]
  public static extern IntPtr SendMessageTimeout(IntPtr hWnd, int Msg, UIntPtr wParam, string lParam, int fuFlags, int uTimeout, out UIntPtr lpdwResult);
}
'@ -ErrorAction Stop
    }
    $r = [UIntPtr]::Zero
    [void][Win32SettingChange]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 0x2, 5000, [ref]$r)
    Say "Broadcast environment-change to running apps."
} catch { }

$env:PATH = "$env:PATH;$($wanted -join ';')"

# ---------------------------------------------------------------------------
Section '7. FINAL VERIFICATION'
# ---------------------------------------------------------------------------

foreach ($n in @('claude','codex')) {
    $p = Get-CmdPath $n
    Say ("{0,-8} path    : {1}" -f $n, $(if ($p) { $p } else { 'NOT FOUND' }))
    Say ("{0,-8} probe   : {1}" -f $n, (Invoke-Probe -ExePath $p))
}

Say ''
Say "Fresh cmd.exe resolution:"
Say (cmd.exe /d /c "where claude & where codex" 2>&1 | Out-String).Trim()

Section 'DONE'
Say "Close ALL terminals and open a new one before testing."
Say "Log: $LogPath  -- paste it back into the chat."
