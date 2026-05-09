import ctypes
import glob
import html
import os
import posixpath
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import threading
import time
import traceback
from dataclasses import dataclass
from typing import Callable, Optional

import wx

try:  # Windows-only
    import winreg
except ImportError:  # pragma: no cover - exercised on non-Windows only
    winreg = None  # type: ignore[assignment]


CREATE_NO_WINDOW = 0x08000000
WM_SETTINGCHANGE = 0x001A
SMTO_ABORTIFHUNG = 0x0002
NODE_WINGET_ID = "OpenJS.NodeJS.LTS"
PYTHON_314_WINGET_ID = "Python.Python.3.14"
OLLAMA_WINGET_ID = "Ollama.Ollama"
LINUX_OLLAMA_INSTALL_URL = "https://ollama.com/install.sh"
OPENCLAW_INSTALL_URL = "https://openclaw.ai/install.sh"
HOMEBREW_INSTALL_URL = "https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"
AUTO_UPDATE_TASK_NAME = "InstallTheCli - Update AI CLIs"
AUTO_UPDATE_DAILY_TIME = "3:00AM"
AUTO_UPDATE_DIR_NAME = "InstallTheCli"
AUTO_UPDATE_PACKAGES_FILE = "auto_update_packages.txt"
AUTO_UPDATE_SCRIPT_FILE = "auto_update_clis.ps1"
AUTO_UPDATE_VBS_FILE = "auto_update_clis.vbs"
MACOS_AUTO_UPDATE_SCRIPT_FILE = "auto_update_clis_macos.sh"
MACOS_AUTO_UPDATE_PLIST_ID = "com.installthecli.ai-cli-updates"
MACOS_AUTO_UPDATE_PLIST_FILE = MACOS_AUTO_UPDATE_PLIST_ID + ".plist"
CODEX_NPM_PACKAGE = "@openai/codex"
CLAUDE_NPM_PACKAGE = "@anthropic-ai/claude-code"
GEMINI_NPM_PACKAGE = "@google/gemini-cli"
GROK_NPM_PACKAGE = "@vibe-kit/grok-cli"
OPENCLAW_NPM_PACKAGE = "openclaw"
GUI_LAST_RUN_LOG_FILE = "gui_last_run.log"
NPM_INSTALL_MAX_ATTEMPTS = 3
NPM_INSTALL_RETRY_DELAY_SECONDS = 2.0
NPM_QUIET_FLAGS = ["--no-fund", "--no-audit", "--no-update-notifier", "--loglevel", "error"]
PIP_QUIET_FLAGS = ["--disable-pip-version-check", "--no-input", "--quiet"]
MACOS_BREW_FORMULA_CLIS = ("gemini-cli", "qwen-code", "mistral-vibe", "ollama", "ironclaw")
MACOS_BREW_CASK_CLIS = ("claude-code", "codex", "copilot-cli")
MACOS_NPM_UPDATE_PACKAGES = (GROK_NPM_PACKAGE, OPENCLAW_NPM_PACKAGE)


@dataclass(frozen=True)
class CliSpec:
    key: str
    label: str
    help_text: str
    package_candidates: tuple[str, ...]
    command_candidates: tuple[str, ...]
    shortcut_name: str
    macos_brew_formula: Optional[str] = None
    macos_brew_cask: Optional[str] = None
    macos_official_install_url: Optional[str] = None
    macos_requires_node_major: Optional[int] = None
    macos_requires_node_version: Optional[tuple[int, int, int]] = None
    optional: bool = False


@dataclass(frozen=True)
class GuiAppSpec:
    key: str
    label: str
    help_text: str
    winget_id: Optional[str] = None
    winget_source: Optional[str] = None
    flatpak_id: Optional[str] = None
    snap_name: Optional[str] = None
    macos_brew_cask: Optional[str] = None
    windows_browser_url: Optional[str] = None
    linux_browser_url: Optional[str] = None
    macos_browser_url: Optional[str] = None
    optional: bool = False


CLI_SPECS: tuple[CliSpec, ...] = (
    CliSpec(
        key="claude",
        label="Claude CLI",
        help_text="Installs Anthropic Claude Code CLI from npm.",
        package_candidates=("@anthropic-ai/claude-code",),
        command_candidates=("claude",),
        shortcut_name="Claude CLI",
        macos_brew_cask="claude-code",
    ),
    CliSpec(
        key="codex",
        label="Codex CLI",
        help_text="Installs OpenAI Codex CLI from npm.",
        package_candidates=("@openai/codex",),
        command_candidates=("codex",),
        shortcut_name="Codex CLI",
        macos_brew_cask="codex",
    ),
    CliSpec(
        key="gemini",
        label="Gemini CLI",
        help_text="Installs Google Gemini CLI from npm.",
        package_candidates=("@google/gemini-cli",),
        command_candidates=("gemini",),
        shortcut_name="Gemini CLI",
        macos_brew_formula="gemini-cli",
    ),
    CliSpec(
        key="grok",
        label="Grok CLI (Vibe Kit)",
        help_text="Optional: installs Grok CLI from npm (@vibe-kit/grok-cli).",
        package_candidates=("@vibe-kit/grok-cli",),
        command_candidates=("grok", "grok-cli"),
        shortcut_name="Grok CLI",
        macos_requires_node_major=20,
        macos_requires_node_version=(20, 0, 0),
        optional=True,
    ),
    CliSpec(
        key="qwen",
        label="Qwen CLI",
        help_text="Installs Qwen coding CLI from npm.",
        package_candidates=("@qwen-code/qwen-code", "qwen-code"),
        command_candidates=("qwen", "qwen-code"),
        shortcut_name="Qwen CLI",
        macos_brew_formula="qwen-code",
    ),
    CliSpec(
        key="mistral",
        label="Mistral Vibe CLI",
        help_text="Installs Mistral Vibe CLI from https://docs.mistral.ai/mistral-vibe/introduction (Windows: Python 3.14 + uv/pip; Linux: Python 3.12+ + uv/pip; macOS: Homebrew formula).",
        package_candidates=("mistral-vibe",),
        command_candidates=("vibe", "mistral-vibe"),
        shortcut_name="Mistral Vibe CLI",
        macos_brew_formula="mistral-vibe",
        optional=True,
    ),
    CliSpec(
        key="ollama",
        label="Ollama CLI (Official)",
        help_text="Installs official Ollama (Windows: winget Ollama.Ollama; Linux: official install script; macOS: Homebrew formula), including the ollama CLI.",
        package_candidates=(OLLAMA_WINGET_ID,),
        command_candidates=("ollama",),
        shortcut_name="Ollama CLI",
        macos_brew_formula="ollama",
    ),
    CliSpec(
        key="copilot",
        label="GitHub Copilot CLI",
        help_text="Installs GitHub Copilot CLI from npm.",
        package_candidates=("@github/copilot", "@githubnext/github-copilot-cli"),
        command_candidates=("copilot", "github-copilot-cli", "github-copilot"),
        shortcut_name="GitHub Copilot CLI",
        macos_brew_cask="copilot-cli",
    ),
    CliSpec(
        key="openclaw",
        label="OpenClaw CLI",
        help_text="Installs OpenClaw AI CLI from npm (Node 22+ required).",
        package_candidates=("openclaw",),
        command_candidates=("openclaw",),
        shortcut_name="OpenClaw CLI",
        macos_official_install_url=OPENCLAW_INSTALL_URL,
        macos_requires_node_major=22,
        macos_requires_node_version=(22, 14, 0),
        optional=True,
    ),
    CliSpec(
        key="ironclaw",
        label="IronClaw CLI",
        help_text="Installs IronClaw CLI (macOS: Homebrew formula; Windows/Linux: npm fallback, Node 22+ required).",
        package_candidates=("ironclaw",),
        command_candidates=("ironclaw",),
        shortcut_name="IronClaw CLI",
        macos_brew_formula="ironclaw",
        optional=True,
    ),
)


GUI_APP_SPECS: tuple[GuiAppSpec, ...] = (
    GuiAppSpec(
        key="claude_app",
        label="Claude App (Desktop)",
        help_text="Installs Anthropic Claude consumer desktop app (Windows: winget; Linux: Flatpak from Flathub).",
        winget_id="Anthropic.Claude",
        flatpak_id="ai.anthropic.Claude",
        macos_brew_cask="claude",
    ),
    GuiAppSpec(
        key="chatgpt_app",
        label="ChatGPT App (Desktop)",
        help_text="Installs OpenAI ChatGPT consumer desktop app (Windows: winget; Linux: browser shortcut to chat.openai.com).",
        winget_id="OpenAI.ChatGPT",
        linux_browser_url="https://chat.openai.com",
        macos_brew_cask="chatgpt",
        macos_browser_url="https://chatgpt.com",
    ),
    GuiAppSpec(
        key="codex_app",
        label="Codex App (Desktop)",
        help_text="Installs Codex desktop app (Windows: Microsoft Store Product ID 9PLM9XGG6VKS; macOS: Homebrew cask).",
        winget_id="9PLM9XGG6VKS",
        winget_source="msstore",
        macos_brew_cask="codex-app",
        macos_browser_url="https://openai.com/codex/",
        optional=True,
    ),
    GuiAppSpec(
        key="gemini_app",
        label="Gemini App (Desktop)",
        help_text="Installs Google Gemini consumer desktop app (Windows: winget; Linux: Flatpak from Flathub).",
        winget_id="Google.Gemini",
        flatpak_id="com.google.Gemini",
        macos_brew_cask="google-gemini",
        macos_browser_url="https://gemini.google.com",
        optional=True,
    ),
    GuiAppSpec(
        key="copilot_app",
        label="Microsoft Copilot App (Desktop)",
        help_text="Installs Microsoft Copilot consumer desktop app (Windows: winget; Linux: browser shortcut to copilot.microsoft.com).",
        winget_id="Microsoft.Copilot",
        linux_browser_url="https://copilot.microsoft.com",
        macos_browser_url="https://copilot.microsoft.com",
        optional=True,
    ),
    GuiAppSpec(
        key="perplexity_app",
        label="Perplexity App (Desktop)",
        help_text="Installs Perplexity AI consumer desktop app (Windows: winget; Linux: Flatpak from Flathub).",
        winget_id="PerplexityAI.Perplexity",
        flatpak_id="ai.perplexity.Perplexity",
        macos_browser_url="https://www.perplexity.ai",
        optional=True,
    ),
)


def is_windows() -> bool:
    return os.name == "nt"


def is_linux() -> bool:
    return sys.platform.startswith("linux")


def is_macos() -> bool:
    return sys.platform == "darwin"


def platform_display_name() -> str:
    if is_windows():
        return "Windows 11"
    if is_macos():
        return "macOS"
    return "Linux"


def is_admin() -> bool:
    if not is_windows():
        geteuid = getattr(os, "geteuid", None)
        if callable(geteuid):
            try:
                return geteuid() == 0
            except OSError:
                return False
        return False
    try:
        return bool(ctypes.windll.shell32.IsUserAnAdmin())
    except Exception:
        return False


def broadcast_environment_change() -> None:
    if not is_windows():
        return
    try:
        result = ctypes.c_ulong()
        ctypes.windll.user32.SendMessageTimeoutW(
            0xFFFF,
            WM_SETTINGCHANGE,
            0,
            "Environment",
            SMTO_ABORTIFHUNG,
            5000,
            ctypes.byref(result),
        )
    except Exception:
        pass


def subprocess_creationflags_kwargs() -> dict[str, int]:
    if is_windows():
        return {"creationflags": CREATE_NO_WINDOW}
    return {}


def read_linux_os_release() -> dict[str, str]:
    data: dict[str, str] = {}
    if not is_linux():
        return data
    try:
        with open("/etc/os-release", "r", encoding="utf-8") as f:
            for raw_line in f:
                line = raw_line.strip()
                if not line or "=" not in line or line.startswith("#"):
                    continue
                key, value = line.split("=", 1)
                data[key] = value.strip().strip('"').strip("'")
    except OSError:
        return {}
    return data


def detect_linux_distro_family() -> Optional[str]:
    if not is_linux():
        return None
    info = read_linux_os_release()
    values = [info.get("ID", ""), info.get("ID_LIKE", "")]
    haystack = " ".join(v.lower() for v in values if v)
    if any(token in haystack for token in ("ubuntu", "debian")):
        return "debian"
    if any(token in haystack for token in ("fedora", "rhel", "centos")):
        return "fedora"
    if "arch" in haystack:
        return "arch"
    return None


def linux_requires_root_for_system_install() -> bool:
    return is_linux()


def ensure_linux_root_for_package_installs(log: Callable[[str], None]) -> bool:
    if not linux_requires_root_for_system_install():
        return True
    if is_admin():
        return True
    log("Linux package installation requires root privileges. Re-run the installer with sudo/root.")
    return False


def pip_install_flags_for_platform() -> list[str]:
    flags = list(PIP_QUIET_FLAGS)
    if is_linux():
        flags.append("--break-system-packages")
    return flags


def split_path(value: str) -> list[str]:
    if not value:
        return []
    return [part for part in value.split(";") if part]


def normalize_path_for_compare(path: str) -> str:
    expanded = os.path.expandvars(path.strip())
    normalized = os.path.normpath(expanded)
    return os.path.normcase(normalized)


def is_path_within(path: str, root: str) -> bool:
    try:
        norm_path = normalize_path_for_compare(path)
        norm_root = normalize_path_for_compare(root)
        return os.path.commonpath([norm_path, norm_root]) == norm_root
    except (ValueError, OSError):
        return False


def add_dirs_to_path(scope: str, dirs: list[str]) -> tuple[list[str], Optional[str]]:
    if not dirs:
        return ([], None)

    dirs = [d for d in dirs if d and os.path.isdir(os.path.expandvars(d))]
    if not dirs:
        return ([], None)

    if not is_windows():
        if scope == "system":
            # Linux installs typically land in standard system paths. We avoid mutating global shell config here.
            return ([], None)
        if scope != "user":
            raise ValueError(f"Unsupported scope: {scope}")
        profile_name = ".zprofile" if is_macos() else ".profile"
        profile_path = os.path.join(os.path.expanduser("~"), profile_name)
        try:
            existing_text = ""
            if os.path.isfile(profile_path):
                with open(profile_path, "r", encoding="utf-8") as f:
                    existing_text = f.read()
            current_env_parts = {normalize_path_for_compare(p) for p in os.environ.get("PATH", "").split(os.pathsep) if p}
            added: list[str] = []
            lines_to_append: list[str] = []
            for directory in dirs:
                norm = normalize_path_for_compare(directory)
                marker = f"InstallTheCli PATH {directory}"
                if norm in current_env_parts:
                    continue
                if marker in existing_text:
                    continue
                lines_to_append.append(f'export PATH="$PATH:{directory}"  # {marker}')
                added.append(directory)
                current_env_parts.add(norm)
            if lines_to_append:
                with open(profile_path, "a", encoding="utf-8", newline="\n") as f:
                    if existing_text and not existing_text.endswith("\n"):
                        f.write("\n")
                    for line in lines_to_append:
                        f.write(line + "\n")
            return (added, None)
        except OSError as exc:
            return ([], str(exc))

    if scope == "user":
        root = winreg.HKEY_CURRENT_USER
        subkey = r"Environment"
    elif scope == "system":
        root = winreg.HKEY_LOCAL_MACHINE
        subkey = r"SYSTEM\CurrentControlSet\Control\Session Manager\Environment"
    else:
        raise ValueError(f"Unsupported scope: {scope}")

    added: list[str] = []
    try:
        with winreg.OpenKey(root, subkey, 0, winreg.KEY_READ | winreg.KEY_WRITE) as key:
            try:
                existing_value, reg_type = winreg.QueryValueEx(key, "Path")
            except FileNotFoundError:
                existing_value, reg_type = "", winreg.REG_EXPAND_SZ

            parts = split_path(existing_value)
            seen = {normalize_path_for_compare(p) for p in parts}
            for directory in dirs:
                norm = normalize_path_for_compare(directory)
                if norm not in seen:
                    parts.append(directory)
                    seen.add(norm)
                    added.append(directory)

            if added:
                new_value = ";".join(parts)
                if reg_type not in (winreg.REG_EXPAND_SZ, winreg.REG_SZ):
                    reg_type = winreg.REG_EXPAND_SZ
                winreg.SetValueEx(key, "Path", 0, reg_type, new_value)
    except PermissionError as exc:
        return ([], str(exc))
    except OSError as exc:
        return ([], str(exc))

    if added:
        broadcast_environment_change()
    return (added, None)


def find_desktop_directory() -> str:
    candidates: list[str] = []

    if not is_windows():
        home = os.path.expanduser("~")
        candidates.append(os.path.join(home, "Desktop"))
        xdg_desktop = os.environ.get("XDG_DESKTOP_DIR")
        if xdg_desktop:
            candidates.append(os.path.expandvars(xdg_desktop))
        for path in candidates:
            if path and os.path.isdir(path):
                return path
        return candidates[0]

    try:
        with winreg.OpenKey(
            winreg.HKEY_CURRENT_USER,
            r"Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders",
        ) as key:
            value, _ = winreg.QueryValueEx(key, "Desktop")
            if value:
                candidates.append(os.path.expandvars(value))
    except OSError:
        pass

    home = os.path.expanduser("~")
    candidates.append(os.path.join(home, "Desktop"))
    candidates.append(os.path.join(home, "OneDrive", "Desktop"))

    for path in candidates:
        if path and os.path.isdir(path):
            return path
    return candidates[0]


def powershell_single_quote(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def xml_escape(value: str) -> str:
    return html.escape(value, quote=True)


def dedupe_preserve_order(values: list[str]) -> list[str]:
    unique: list[str] = []
    seen: set[str] = set()
    for value in values:
        if value not in seen:
            unique.append(value)
            seen.add(value)
    return unique


def get_app_support_directory() -> str:
    if is_macos():
        return os.path.join(os.path.expanduser("~"), "Library", "Application Support", AUTO_UPDATE_DIR_NAME)
    if is_linux():
        xdg_state = os.environ.get("XDG_STATE_HOME")
        if xdg_state:
            return os.path.join(xdg_state, AUTO_UPDATE_DIR_NAME)
        return os.path.join(os.path.expanduser("~"), ".local", "state", AUTO_UPDATE_DIR_NAME)
    local_app = os.environ.get("LocalAppData")
    if local_app:
        return os.path.join(local_app, AUTO_UPDATE_DIR_NAME)
    return os.path.join(os.path.expanduser("~"), "AppData", "Local", AUTO_UPDATE_DIR_NAME)


def get_gui_last_run_log_path() -> str:
    return os.path.join(get_app_support_directory(), GUI_LAST_RUN_LOG_FILE)


def reset_gui_last_run_log() -> Optional[str]:
    path = get_gui_last_run_log_path()
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            started = time.strftime("%Y-%m-%d %H:%M:%S")
            f.write(f"InstallTheCli GUI log started: {started}\n")
        return path
    except OSError:
        return None


def append_persistent_log_line(path: Optional[str], message: str) -> Optional[str]:
    if not path:
        return None
    try:
        with open(path, "a", encoding="utf-8", newline="\n") as f:
            f.write(message + "\n")
        return None
    except OSError as exc:
        return str(exc)


def read_nonempty_lines(path: str) -> list[str]:
    try:
        with open(path, "r", encoding="utf-8") as f:
            return [line.strip() for line in f if line.strip()]
    except FileNotFoundError:
        return []


def write_nonempty_lines(path: str, values: list[str]) -> None:
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        for value in values:
            value = value.strip()
            if value:
                f.write(value + "\n")


def write_text_file(path: str, content: str) -> None:
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(content)


def build_cli_auto_update_script(npm_exe: str, packages_file: str) -> str:
    npm_quiet_args = " ".join(
        powershell_single_quote(flag) for flag in NPM_QUIET_FLAGS
    )
    codex_pkg_literal = powershell_single_quote(CODEX_NPM_PACKAGE)
    claude_pkg_literal = powershell_single_quote(CLAUDE_NPM_PACKAGE)
    gemini_pkg_literal = powershell_single_quote(GEMINI_NPM_PACKAGE)
    lines = [
        "$ErrorActionPreference = 'Stop'",
        "$ProgressPreference = 'SilentlyContinue'",
        "function Get-NpmPath([string]$ConfiguredNpm) {",
        "  if ($ConfiguredNpm -and (Test-Path -LiteralPath $ConfiguredNpm)) { return $ConfiguredNpm }",
        "  $cmd = Get-Command npm -ErrorAction SilentlyContinue",
        "  if ($cmd) { return $cmd.Source }",
        "  $candidates = @()",
        "  if ($env:ProgramFiles) { $candidates += (Join-Path $env:ProgramFiles 'nodejs\\npm.cmd') }",
        "  $pf86 = ${env:ProgramFiles(x86)}",
        "  if ($pf86) { $candidates += (Join-Path $pf86 'nodejs\\npm.cmd') }",
        "  foreach ($candidate in $candidates) {",
        "    if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }",
        "  }",
        "  return $null",
        "}",
        f"$configuredNpm = {powershell_single_quote(npm_exe)}",
        "$npm = Get-NpmPath $configuredNpm",
        "if (-not $npm) { exit 0 }",
        "$npmDir = Split-Path -Parent $npm",
        "if ($npmDir) { $env:PATH = $npmDir + ';' + [string]$env:PATH }",
        "$env:npm_config_update_notifier = 'false'",
        "function Get-NpmPrefix {",
        "  try {",
        "    $prefix = & $npm prefix -g 2>$null",
        "    if ($prefix) { return $prefix.Trim() }",
        "  } catch { }",
        "  return $null",
        "}",
        "function Remove-CodexNpmTempDirs {",
        "  try {",
        "    $prefix = Get-NpmPrefix",
        "    if (-not $prefix) { return }",
        "    $openAiRoot = Join-Path (Join-Path $prefix 'node_modules') '@openai'",
        "    if (-not (Test-Path -LiteralPath $openAiRoot)) { return }",
        "    $rootFull = [System.IO.Path]::GetFullPath($openAiRoot).TrimEnd('\\') + '\\'",
        "    Get-ChildItem -LiteralPath $openAiRoot -Force -Directory -Filter '.codex-*' -ErrorAction SilentlyContinue | ForEach-Object {",
        "      $targetFull = [System.IO.Path]::GetFullPath($_.FullName)",
        "      $isSafeTarget = $targetFull.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase) -and $_.Name.StartsWith('.codex-', [System.StringComparison]::OrdinalIgnoreCase)",
        "      if ($isSafeTarget) { Remove-Item -LiteralPath $targetFull -Recurse -Force -ErrorAction SilentlyContinue }",
        "    }",
        "  } catch { }",
        "}",
        "function Test-CodexCliRunning {",
        "  try {",
        "    $matches = Get-CimInstance Win32_Process -Filter \"name = 'codex.exe' or name = 'node.exe'\" -ErrorAction SilentlyContinue | Where-Object {",
        "      $_.Name -ieq 'codex.exe' -or ([string]$_.CommandLine) -match '\\\\@openai\\\\codex\\\\bin\\\\codex\\.js'",
        "    } | Select-Object -First 1",
        "    return $null -ne $matches",
        "  } catch {",
        "    return $false",
        "  }",
        "}",
        # Claude self-updater (and the @anthropic-ai/claude-code postinstall)
        # rename bin/claude.exe -> bin/claude.exe.old.<ts> before swapping in
        # a new binary. If the swap fails (claude running -> EBUSY, missing
        # platform package, interrupted download), the install is left with
        # no claude.exe and an orphan .old file. Restore the latest .old when
        # claude.exe is missing; clean up stale .old files (each ~250MB) when
        # claude.exe is healthy.
        "function Test-ClaudeCliRunning {",
        "  try {",
        "    $matches = Get-CimInstance Win32_Process -Filter \"name = 'claude.exe'\" -ErrorAction SilentlyContinue | Select-Object -First 1",
        "    return $null -ne $matches",
        "  } catch {",
        "    return $false",
        "  }",
        "}",
        "function Repair-ClaudeAfterFailedUpdate {",
        "  try {",
        "    $prefix = Get-NpmPrefix",
        "    if (-not $prefix) { return }",
        "    $pkgDir = Join-Path $prefix 'node_modules\\@anthropic-ai\\claude-code'",
        "    $binDir = Join-Path $pkgDir 'bin'",
        "    if (-not (Test-Path -LiteralPath $binDir)) { return }",
        "    $claudeExe = Join-Path $binDir 'claude.exe'",
        "    $orphans = @(Get-ChildItem -LiteralPath $binDir -Filter 'claude.exe.old.*' -File -ErrorAction SilentlyContinue)",
        "    if ($orphans.Count -gt 0) {",
        "      $orphans = $orphans | Sort-Object Name -Descending",
        "      if (-not (Test-Path -LiteralPath $claudeExe)) {",
        "        $latest = $orphans | Select-Object -First 1",
        "        try {",
        "          Move-Item -LiteralPath $latest.FullName -Destination $claudeExe -Force -ErrorAction Stop",
        "          $orphans = $orphans | Where-Object { $_.FullName -ne $latest.FullName }",
        "        } catch { }",
        "      }",
        "    }",
        # Fallback: if claude.exe is still missing, copy from the optional
        # native-arch package bundled under node_modules/. The .old file may
        # already be gone (cleaned up earlier), or the rename half completed.
        "    if (-not (Test-Path -LiteralPath $claudeExe)) {",
        "      $nativeCandidates = @(",
        "        (Join-Path $pkgDir 'node_modules\\@anthropic-ai\\claude-code-win32-x64\\claude.exe'),",
        "        (Join-Path $pkgDir 'node_modules\\@anthropic-ai\\claude-code-win32-arm64\\claude.exe')",
        "      )",
        "      foreach ($native in $nativeCandidates) {",
        "        if (Test-Path -LiteralPath $native) {",
        "          try {",
        "            Copy-Item -LiteralPath $native -Destination $claudeExe -Force -ErrorAction Stop",
        "            break",
        "          } catch { }",
        "        }",
        "      }",
        "    }",
        "    foreach ($o in $orphans) {",
        "      Remove-Item -LiteralPath $o.FullName -Force -ErrorAction SilentlyContinue",
        "    }",
        "  } catch { }",
        "}",
        # Run a Claude bin recovery upfront, before reading $packages or doing
        # any npm work. The orphan claude.exe.old.<ts> can be left behind by
        # ANY update path that touches @anthropic-ai/claude-code (the Claude
        # desktop app's winget update, a self-update from inside `claude`, a
        # half-applied npm install). By repairing eagerly we ensure this
        # scheduled task self-heals at every startup/logon/daily run, even
        # when the user's $packages list does not include Claude.
        "Repair-ClaudeAfterFailedUpdate",
        f"$packagesFile = {powershell_single_quote(packages_file)}",
        "if (-not (Test-Path -LiteralPath $packagesFile)) { exit 0 }",
        "$packages = Get-Content -LiteralPath $packagesFile -ErrorAction SilentlyContinue | ForEach-Object { $_.Trim() } | Where-Object { $_ }",
        "if (-not $packages -or $packages.Count -eq 0) { exit 0 }",
        # Per-package install of @latest: more reliable than `npm update -g`,
        # which can leave packages stale if their dist-tag pinning is odd
        # (codex / claude both exhibited this; the user's hand-rolled task
        # runs `npm i -g <pkg>@latest` per package and behaves correctly).
        "foreach ($pkg in $packages) {",
        f"  if ($pkg -eq {codex_pkg_literal}) {{",
        "    Remove-CodexNpmTempDirs",
        "    if (Test-CodexCliRunning) { continue }",
        "  }",
        f"  if ($pkg -eq {claude_pkg_literal}) {{",
        "    Repair-ClaudeAfterFailedUpdate",
        "    if (Test-ClaudeCliRunning) { continue }",
        "  }",
        f"  $null = & $npm {npm_quiet_args} 'i' '-g' (\"$pkg@latest\") *>&1",
        f"  if ($pkg -eq {codex_pkg_literal}) {{ Remove-CodexNpmTempDirs }}",
        f"  if ($pkg -eq {claude_pkg_literal}) {{ Repair-ClaudeAfterFailedUpdate }}",
        "}",
        # Re-emit the gemini shim if @google/gemini-cli is in the package set.
        # Gemini's npm shim can break across versions when the package layout
        # under node_modules/@google changes; rewriting the shim each run keeps
        # the `gemini` command working regardless.
        f"if ($packages -contains {gemini_pkg_literal}) {{",
        "  try {",
        "    $npmBin = & $npm prefix -g 2>$null",
        "    if ($npmBin) { $npmBin = $npmBin.Trim() }",
        "    if ($npmBin -and (Test-Path -LiteralPath $npmBin)) {",
        "      $geminiCmd = \"@ECHO off`r`nGOTO start`r`n:find_dp0`r`nSET dp0=%~dp0`r`nEXIT /b`r`n:start`r`nSETLOCAL`r`nCALL :find_dp0`r`n`r`nSET `\"GEMINI_ENTRY=`\"`r`nIF EXIST `\"%dp0%node_modules\\@google\\gemini-cli\\bundle\\gemini.js`\" (`r`n  SET `\"GEMINI_ENTRY=%dp0%node_modules\\@google\\gemini-cli\\bundle\\gemini.js`\"`r`n) ELSE IF EXIST `\"%dp0%node_modules\\@google\\gemini-cli\\dist\\index.js`\" (`r`n  SET `\"GEMINI_ENTRY=%dp0%node_modules\\@google\\gemini-cli\\dist\\index.js`\"`r`n) ELSE (`r`n  for /d %%D in (`\"%dp0%node_modules\\@google\\.gemini-cli-*`\") do (`r`n    IF EXIST `\"%%~fD\\bundle\\gemini.js`\" (`r`n      SET `\"GEMINI_ENTRY=%%~fD\\bundle\\gemini.js`\"`r`n      GOTO found`r`n    )`r`n    IF EXIST `\"%%~fD\\dist\\index.js`\" (`r`n      SET `\"GEMINI_ENTRY=%%~fD\\dist\\index.js`\"`r`n      GOTO found`r`n    )`r`n  )`r`n)`r`n`r`n:found`r`nIF NOT DEFINED GEMINI_ENTRY (`r`n  ECHO Gemini CLI package not found under `\"%dp0%node_modules\\@google`\" 1>&2`r`n  EXIT /b 1`r`n)`r`n`r`nIF EXIST `\"%dp0%node.exe`\" (`r`n  SET `\"_prog=%dp0%node.exe`\"`r`n) ELSE (`r`n  SET `\"_prog=node`\"`r`n  SET PATHEXT=%PATHEXT:;.JS;=;%`r`n)`r`n`r`nendLocal & goto #_undefined_# 2>NUL || title %COMSPEC% & `\"%_prog%`\"  `\"%GEMINI_ENTRY%`\" %*`r`n\"",
        "      Set-Content -LiteralPath (Join-Path $npmBin 'gemini.cmd') -Value $geminiCmd -Encoding ASCII",
        "      $ps1Shim = Join-Path $npmBin 'gemini.ps1'",
        "      if (Test-Path -LiteralPath $ps1Shim) { Remove-Item -LiteralPath $ps1Shim -Force -ErrorAction SilentlyContinue }",
        "    }",
        "  } catch { }",
        "}",
        "exit 0",
    ]
    return "\n".join(lines) + "\n"


def build_cli_auto_update_vbs(script_path: str) -> str:
    """Tiny VBScript wrapper that launches the PowerShell updater fully hidden.

    `powershell.exe -WindowStyle Hidden` still flashes a console briefly on
    some Windows builds; wscript.exe + WshShell.Run(..., 0, False) does not.
    Mirrors the user's hand-rolled `update-codex-gemini.vbs` setup.
    """
    escaped = script_path.replace('"', '""')
    return (
        "Set WshShell = CreateObject(\"WScript.Shell\")\r\n"
        "WshShell.Run \"powershell.exe -NoProfile -ExecutionPolicy Bypass "
        "-WindowStyle Hidden -File \"\"" + escaped + "\"\"\", 0, False\r\n"
    )


def ensure_cli_auto_update_task(
    npm_exe: str,
    package_names: list[str],
    log: Callable[[str], None],
) -> list[str]:
    if is_macos():
        ensure_macos_cli_auto_update_task(log)
        return []
    if not is_windows():
        log("Hidden auto-update scheduler is currently Windows-only; skipping on Linux.")
        return []
    clean_packages = dedupe_preserve_order([p.strip() for p in package_names if p and p.strip()])
    if not clean_packages:
        log("Auto-update task unchanged: no newly installed npm CLI packages in this run.")
        return []

    support_dir = get_app_support_directory()
    os.makedirs(support_dir, exist_ok=True)

    packages_file = os.path.join(support_dir, AUTO_UPDATE_PACKAGES_FILE)
    script_file = os.path.join(support_dir, AUTO_UPDATE_SCRIPT_FILE)
    vbs_file = os.path.join(support_dir, AUTO_UPDATE_VBS_FILE)

    existing_packages = read_nonempty_lines(packages_file)
    merged_packages = dedupe_preserve_order(existing_packages + clean_packages)

    write_nonempty_lines(packages_file, merged_packages)
    write_text_file(script_file, build_cli_auto_update_script(npm_exe, packages_file))
    write_text_file(vbs_file, build_cli_auto_update_vbs(script_file))

    # Run the .vbs via wscript.exe so the PowerShell updater never flashes a
    # console window. `powershell -WindowStyle Hidden` directly is not
    # actually hidden on logon.
    action_args = f'"{vbs_file}" //nologo'
    register_lines = [
        "$currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name",
        f"$action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument {powershell_single_quote(action_args)}",
        "$triggerStartup = New-ScheduledTaskTrigger -AtStartup",
        "$triggerLogon = New-ScheduledTaskTrigger -AtLogOn",
        f"$triggerDaily = New-ScheduledTaskTrigger -Daily -At {powershell_single_quote(AUTO_UPDATE_DAILY_TIME)}",
        "$settings = New-ScheduledTaskSettingsSet -Hidden -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries",
        "$principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Limited",
        "Register-ScheduledTask "
        + f"-TaskName {powershell_single_quote(AUTO_UPDATE_TASK_NAME)} "
        + "-Action $action "
        + "-Trigger @($triggerStartup, $triggerLogon, $triggerDaily) "
        + "-Settings $settings "
        + "-Principal $principal "
        + f"-Description {powershell_single_quote('Hidden npm AI CLI auto-update (user logon + daily) created by InstallTheCli.')} "
        + "-Force | Out-Null",
    ]

    try:
        subprocess.run(
            [
                "powershell",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-Command",
                "; ".join(register_lines),
            ],
            check=True,
            capture_output=True,
            text=True,
            **subprocess_creationflags_kwargs(),
        )
    except subprocess.CalledProcessError as exc:
        detail = (exc.stderr or exc.stdout or str(exc)).strip()
        raise RuntimeError(
            "Unable to configure hidden CLI auto-update task. "
            + (detail if detail else "Task Scheduler registration failed.")
        ) from exc
    except OSError as exc:
        raise RuntimeError(f"Unable to configure hidden CLI auto-update task: {exc}") from exc

    log(
        "Configured hidden CLI auto-update task (startup, user logon, and daily "
        + AUTO_UPDATE_DAILY_TIME
        + ")."
    )
    return merged_packages


def refresh_existing_cli_auto_update_task(log: Callable[[str], None]) -> bool:
    """Re-deploy the hidden CLI auto-update task in place using the current
    embedded updater logic, but only if the task is already configured.

    This lets us roll out improvements to the updater script (e.g. better
    Claude bin recovery) automatically the next time the GUI is opened or
    `install-all` is run, without forcing the user to re-add packages or run
    `setup-updater` manually. We treat the existing packages file as the
    source of truth for which CLIs to update.

    Returns True if a refresh actually ran (existing task was found and
    re-registered). Returns False on platforms without scheduling support,
    when no existing configuration is detected, or on transient failures.
    The function is intentionally non-fatal -- a failure here should never
    block the GUI from opening or stop a one-click install.
    """
    if is_macos():
        return _refresh_existing_macos_cli_auto_update_task(log)
    if not is_windows():
        return False

    support_dir = get_app_support_directory()
    packages_file = os.path.join(support_dir, AUTO_UPDATE_PACKAGES_FILE)
    script_file = os.path.join(support_dir, AUTO_UPDATE_SCRIPT_FILE)
    vbs_file = os.path.join(support_dir, AUTO_UPDATE_VBS_FILE)

    task_present = _windows_scheduled_task_exists(AUTO_UPDATE_TASK_NAME)
    has_packages_state = os.path.isfile(packages_file)
    if not task_present and not has_packages_state:
        return False

    existing_packages = read_nonempty_lines(packages_file) if has_packages_state else []
    if not existing_packages:
        # The task exists but we have no record of which packages it should
        # update. Refresh the script/VBS anyway so future installs land on
        # the new logic, but skip task re-registration since there is no
        # behavior to enforce.
        return False

    npm_exe = find_npm() or "npm.cmd"
    try:
        os.makedirs(support_dir, exist_ok=True)
        write_text_file(script_file, build_cli_auto_update_script(npm_exe, packages_file))
        write_text_file(vbs_file, build_cli_auto_update_vbs(script_file))
    except OSError as exc:
        log(f"Auto-update task refresh skipped: could not rewrite updater files: {exc}")
        return False

    if not task_present:
        # Files refreshed, but no task to update. Leave registration to the
        # next install run rather than silently creating a task.
        return False

    action_args = f'"{vbs_file}" //nologo'
    register_lines = [
        "$currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name",
        f"$action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument {powershell_single_quote(action_args)}",
        "$triggerStartup = New-ScheduledTaskTrigger -AtStartup",
        "$triggerLogon = New-ScheduledTaskTrigger -AtLogOn",
        f"$triggerDaily = New-ScheduledTaskTrigger -Daily -At {powershell_single_quote(AUTO_UPDATE_DAILY_TIME)}",
        "$settings = New-ScheduledTaskSettingsSet -Hidden -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries",
        "$principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Limited",
        "Register-ScheduledTask "
        + f"-TaskName {powershell_single_quote(AUTO_UPDATE_TASK_NAME)} "
        + "-Action $action "
        + "-Trigger @($triggerStartup, $triggerLogon, $triggerDaily) "
        + "-Settings $settings "
        + "-Principal $principal "
        + f"-Description {powershell_single_quote('Hidden npm AI CLI auto-update (refreshed by InstallTheCli on app open / install-all).')} "
        + "-Force | Out-Null",
    ]

    try:
        subprocess.run(
            [
                "powershell",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-Command",
                "; ".join(register_lines),
            ],
            check=True,
            capture_output=True,
            text=True,
            **subprocess_creationflags_kwargs(),
        )
    except (subprocess.CalledProcessError, OSError) as exc:
        detail = ""
        if isinstance(exc, subprocess.CalledProcessError):
            detail = (exc.stderr or exc.stdout or "").strip()
        log(
            "Auto-update task refresh skipped: re-registration failed."
            + (f" {detail}" if detail else f" {exc}")
        )
        return False

    log(
        "Refreshed hidden CLI auto-update task in place "
        f"({len(existing_packages)} package(s); startup, logon, daily "
        + AUTO_UPDATE_DAILY_TIME
        + ")."
    )
    return True


def _windows_scheduled_task_exists(task_name: str) -> bool:
    if not is_windows():
        return False
    try:
        completed = subprocess.run(
            ["schtasks.exe", "/Query", "/TN", task_name],
            capture_output=True,
            text=True,
            **subprocess_creationflags_kwargs(),
        )
    except OSError:
        return False
    return completed.returncode == 0


def _refresh_existing_macos_cli_auto_update_task(log: Callable[[str], None]) -> bool:
    if not is_macos():
        return False
    plist_path = os.path.join(
        os.path.expanduser("~/Library/LaunchAgents"), MACOS_AUTO_UPDATE_PLIST_FILE
    )
    if not os.path.isfile(plist_path):
        return False
    try:
        ensure_macos_cli_auto_update_task(log)
    except Exception as exc:  # noqa: BLE001 -- never block GUI startup
        log(f"Auto-update LaunchAgent refresh skipped: {exc}")
        return False
    return True


def build_macos_cli_auto_update_script() -> str:
    formula_lines = "\n".join(
        f"  update_brew_package formula {shlex.quote(name)}" for name in MACOS_BREW_FORMULA_CLIS
    )
    cask_lines = "\n".join(
        f"  update_brew_package cask {shlex.quote(name)}" for name in MACOS_BREW_CASK_CLIS
    )
    npm_lines = "\n".join(
        f"  update_npm_package {shlex.quote(name)}" for name in MACOS_NPM_UPDATE_PACKAGES
    )
    return f"""#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\\n\\t'
PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
export HOMEBREW_NO_AUTO_UPDATE=1
export npm_config_update_notifier=false

log() {{
  printf '[installthecli-update] %s\\n' "$*"
}}

command_exists() {{
  command -v "$1" >/dev/null 2>&1
}}

find_brew() {{
  if command_exists brew; then
    command -v brew
    return 0
  fi
  for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [[ -x "$candidate" ]]; then
      printf '%s\\n' "$candidate"
      return 0
    fi
  done
  return 1
}}

brew_bin="$(find_brew || true)"

update_brew_package() {{
  local kind="$1"
  local name="$2"
  [[ -n "$brew_bin" ]] || return 0
  if [[ "$kind" == "cask" ]]; then
    "$brew_bin" list --cask "$name" >/dev/null 2>&1 || return 0
    "$brew_bin" upgrade --cask "$name" || true
  else
    "$brew_bin" list --formula "$name" >/dev/null 2>&1 || return 0
    "$brew_bin" upgrade "$name" || true
  fi
}}

update_npm_package() {{
  local package="$1"
  command_exists npm || return 0
  npm ls -g --depth=0 "$package" >/dev/null 2>&1 || return 0
  npm --no-fund --no-audit --no-update-notifier --loglevel error install -g "${{package}}@latest" || true
}}

if [[ -n "$brew_bin" ]]; then
  "$brew_bin" update >/dev/null 2>&1 || true
{formula_lines}
{cask_lines}
fi

{npm_lines}
"""


def build_macos_launch_agent_plist(script_path: str) -> str:
    support_dir = get_app_support_directory()
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>{MACOS_AUTO_UPDATE_PLIST_ID}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>{xml_escape(script_path)}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>StartInterval</key>
  <integer>86400</integer>
  <key>StandardOutPath</key>
  <string>{xml_escape(posixpath.join(support_dir, "macos_auto_update.log"))}</string>
  <key>StandardErrorPath</key>
  <string>{xml_escape(posixpath.join(support_dir, "macos_auto_update.err.log"))}</string>
</dict>
</plist>
"""


def ensure_macos_cli_auto_update_task(log: Callable[[str], None]) -> None:
    if not is_macos():
        return
    support_dir = get_app_support_directory()
    os.makedirs(support_dir, exist_ok=True)
    script_path = os.path.join(support_dir, MACOS_AUTO_UPDATE_SCRIPT_FILE)
    write_text_file(script_path, build_macos_cli_auto_update_script())
    os.chmod(script_path, 0o755)

    launch_agents_dir = os.path.join(os.path.expanduser("~"), "Library", "LaunchAgents")
    os.makedirs(launch_agents_dir, exist_ok=True)
    plist_path = os.path.join(launch_agents_dir, MACOS_AUTO_UPDATE_PLIST_FILE)
    write_text_file(plist_path, build_macos_launch_agent_plist(script_path))

    uid = str(os.getuid()) if hasattr(os, "getuid") else ""
    domain = f"gui/{uid}" if uid else "gui"
    subprocess.run(["launchctl", "bootout", domain, plist_path], capture_output=True, **subprocess_creationflags_kwargs())
    code = run_command(["launchctl", "bootstrap", domain, plist_path], log)
    if code != 0:
        log(f"launchctl bootstrap failed with exit code {format_exit_code(code)}; trying legacy load.")
        code = run_command(["launchctl", "load", "-w", plist_path], log)
        if code != 0:
            raise RuntimeError(f"Unable to configure macOS LaunchAgent updater: launchctl exit code {format_exit_code(code)}")
    log("Configured macOS LaunchAgent auto-update task (RunAtLoad + daily).")


def remove_cli_auto_update_packages(
    package_names: list[str],
    log: Callable[[str], None],
) -> list[str]:
    if not is_windows():
        return []
    to_remove = {p.strip() for p in package_names if p and p.strip()}
    if not to_remove:
        return []
    packages_file = os.path.join(get_app_support_directory(), AUTO_UPDATE_PACKAGES_FILE)
    existing = read_nonempty_lines(packages_file)
    if not existing:
        return []
    kept = [pkg for pkg in existing if pkg not in to_remove]
    if kept == existing:
        return existing
    try:
        write_nonempty_lines(packages_file, kept)
    except OSError as exc:
        log(f"Warning: unable to update auto-update package list after uninstall: {exc}")
    return kept


def create_windows_shortcut(
    shortcut_path: str,
    target_path: str,
    arguments: str = "",
    working_directory: str = "",
    icon_location: str = "",
) -> None:
    script_lines = [
        "$ws = New-Object -ComObject WScript.Shell",
        f"$sc = $ws.CreateShortcut({powershell_single_quote(shortcut_path)})",
        f"$sc.TargetPath = {powershell_single_quote(target_path)}",
    ]
    if arguments:
        script_lines.append(f"$sc.Arguments = {powershell_single_quote(arguments)}")
    if working_directory:
        script_lines.append(
            f"$sc.WorkingDirectory = {powershell_single_quote(working_directory)}"
        )
    if icon_location:
        script_lines.append(f"$sc.IconLocation = {powershell_single_quote(icon_location)}")
    script_lines.append("$sc.Save()")

    subprocess.run(
        ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", "; ".join(script_lines)],
        check=True,
        capture_output=True,
        text=True,
        **subprocess_creationflags_kwargs(),
    )


def run_command(
    args: list[str],
    log: Callable[[str], None],
    env: Optional[dict[str, str]] = None,
    cwd: Optional[str] = None,
) -> int:
    log("> " + " ".join(args))
    process = subprocess.Popen(
        args,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        stdin=subprocess.DEVNULL,
        text=True,
        encoding="utf-8",
        errors="replace",
        env=env,
        cwd=cwd,
        **subprocess_creationflags_kwargs(),
    )
    assert process.stdout is not None
    for line in process.stdout:
        text = line.rstrip()
        if text:
            log(text)
    return process.wait()


def command_exists(name: str, env: Optional[dict[str, str]] = None) -> bool:
    probe = ["where", name] if is_windows() else ["which", name]
    try:
        completed = subprocess.run(
            probe,
            capture_output=True,
            text=True,
            env=env,
            **subprocess_creationflags_kwargs(),
        )
        return completed.returncode == 0
    except OSError:
        return False


def where_all(name: str, env: Optional[dict[str, str]] = None) -> list[str]:
    probe = ["where", name] if is_windows() else ["which", "-a", name]
    try:
        completed = subprocess.run(
            probe,
            capture_output=True,
            text=True,
            env=env,
            **subprocess_creationflags_kwargs(),
        )
    except OSError:
        return []
    if completed.returncode != 0:
        return []
    return [line.strip() for line in completed.stdout.splitlines() if line.strip()]


def find_winget() -> Optional[str]:
    return shutil.which("winget")


def find_brew() -> Optional[str]:
    for name in ("brew", "/opt/homebrew/bin/brew", "/usr/local/bin/brew"):
        path = shutil.which(name) if not os.path.isabs(name) else name
        if path and os.path.isfile(path):
            return path
    return None


def _apply_homebrew_path_hints() -> None:
    candidates = [
        "/opt/homebrew/bin",
        "/opt/homebrew/sbin",
        "/usr/local/bin",
        "/usr/local/sbin",
    ]
    existing = os.environ.get("PATH", "")
    parts = existing.split(os.pathsep) if existing else []
    prepend = [p for p in candidates if os.path.isdir(p) and p not in parts]
    if prepend:
        os.environ["PATH"] = os.pathsep.join(prepend + parts)


def _prompt_user_yes_no(title: str, message: str) -> bool:
    if not wx.GetApp():
        return False
    result: list[bool] = []
    done = threading.Event()

    def ask() -> None:
        answer = wx.MessageBox(message, title, wx.YES_NO | wx.NO_DEFAULT | wx.ICON_QUESTION)
        result.append(answer == wx.YES)
        done.set()

    wx.CallAfter(ask)
    done.wait()
    return bool(result and result[0])


def ensure_homebrew(log: Callable[[str], None]) -> str:
    _apply_homebrew_path_hints()
    brew = find_brew()
    if brew:
        log(f"Homebrew is available: {brew}")
        return brew

    message = (
        "Homebrew is required for macOS installs in InstallTheCli.\n\n"
        "Install Homebrew now using the official installer?"
    )
    if not _prompt_user_yes_no("Install Homebrew?", message):
        raise RuntimeError(
            "Homebrew is required on macOS. Install it from https://brew.sh/ or rerun and choose to install it."
        )

    log("Installing Homebrew using the official installer from brew.sh...")
    env = os.environ.copy()
    env["NONINTERACTIVE"] = "1"
    code = run_command(
        ["/bin/bash", "-c", f"curl -fsSL {HOMEBREW_INSTALL_URL} | /bin/bash"],
        log,
        env=env,
    )
    if code != 0:
        raise RuntimeError(f"Homebrew install failed with exit code {format_exit_code(code)}.")

    _apply_homebrew_path_hints()
    brew = find_brew()
    if not brew:
        raise RuntimeError(
            "Homebrew installed, but brew was not found on PATH. Open a new terminal or add Homebrew shellenv to your shell profile."
        )
    log(f"Homebrew is available: {brew}")
    return brew


def find_uv() -> Optional[str]:
    for name in ("uv.exe", "uv"):
        path = shutil.which(name)
        if path:
            return path
    return None


def find_python_launcher() -> Optional[str]:
    for name in ("py.exe", "py", "python.exe", "python"):
        path = shutil.which(name)
        if path:
            return path
    return None


def find_pip3() -> Optional[str]:
    for name in ("pip3.exe", "pip3", "pip.exe", "pip"):
        path = shutil.which(name)
        if path:
            return path
    return None


def find_ollama() -> Optional[str]:
    for name in ("ollama.exe", "ollama"):
        path = shutil.which(name)
        if path:
            return path

    if is_linux():
        for candidate in ("/usr/local/bin/ollama", "/usr/bin/ollama"):
            if os.path.isfile(candidate):
                return candidate
        return None

    if is_macos():
        for candidate in (
            "/opt/homebrew/bin/ollama",
            "/usr/local/bin/ollama",
            "/Applications/Ollama.app/Contents/Resources/ollama",
        ):
            if os.path.isfile(candidate):
                return candidate
        return None

    local_app = os.environ.get("LocalAppData", "")
    program_files = os.environ.get("ProgramFiles", r"C:\Program Files")
    program_files_x86 = os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)")
    candidates = [
        os.path.join(local_app, "Programs", "Ollama", "ollama.exe") if local_app else "",
        os.path.join(program_files, "Ollama", "ollama.exe"),
        os.path.join(program_files_x86, "Ollama", "ollama.exe"),
    ]
    for candidate in candidates:
        if candidate and os.path.isfile(candidate):
            return candidate
    return None


def get_python_version(prefix_args: list[str]) -> Optional[tuple[int, int, int]]:
    try:
        completed = subprocess.run(
            [
                *prefix_args,
                "-c",
                "import sys; print(f'{sys.version_info[0]}.{sys.version_info[1]}.{sys.version_info[2]}')",
            ],
            capture_output=True,
            text=True,
            **subprocess_creationflags_kwargs(),
        )
    except OSError:
        return None
    if completed.returncode != 0:
        return None
    text = (completed.stdout or "").strip()
    try:
        major_s, minor_s, patch_s = text.split(".", 2)
        return (int(major_s), int(minor_s), int(patch_s))
    except (TypeError, ValueError):
        return None


def get_node_version(node_exe: str) -> Optional[tuple[int, int, int]]:
    try:
        completed = subprocess.run(
            [node_exe, "--version"],
            capture_output=True,
            text=True,
            **subprocess_creationflags_kwargs(),
        )
    except OSError:
        return None
    if completed.returncode != 0:
        return None
    text = (completed.stdout or "").strip().lstrip("v")
    try:
        major_s, minor_s, patch_s = text.split(".", 2)
        return (int(major_s), int(minor_s), int(patch_s.split("-", 1)[0]))
    except (TypeError, ValueError):
        return None


def node_requirement_label(min_version: tuple[int, int, int]) -> str:
    major, minor, patch = min_version
    if minor == 0 and patch == 0:
        return f"v{major}+"
    if patch == 0:
        return f"v{major}.{minor}+"
    return f"v{major}.{minor}.{patch}+"


def node_version_satisfies(version: Optional[tuple[int, int, int]], min_version: tuple[int, int, int]) -> bool:
    return bool(version and version >= min_version)


def find_python_314_command() -> Optional[list[str]]:
    for py_name in ("py.exe", "py"):
        py_path = shutil.which(py_name)
        if not py_path:
            continue
        prefix = [py_path, "-3.14"]
        version = get_python_version(prefix)
        if version and version[:2] == (3, 14):
            return prefix

    for name in ("python3.14.exe", "python3.14"):
        path = shutil.which(name)
        if not path:
            continue
        version = get_python_version([path])
        if version and version[:2] == (3, 14):
            return [path]

    local_app = os.environ.get("LocalAppData", "")
    program_files = os.environ.get("ProgramFiles", r"C:\Program Files")
    program_files_x86 = os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)")
    known_python_314_paths = [
        os.path.join(local_app, "Programs", "Python", "Python314", "python.exe") if local_app else "",
        os.path.join(program_files, "Python314", "python.exe"),
        os.path.join(program_files, "Python", "Python314", "python.exe"),
        os.path.join(program_files_x86, "Python314", "python.exe"),
        os.path.join(program_files_x86, "Python", "Python314", "python.exe"),
    ]
    for path in known_python_314_paths:
        if not path or not os.path.isfile(path):
            continue
        version = get_python_version([path])
        if version and version[:2] == (3, 14):
            return [path]

    for name in ("python.exe", "python"):
        path = shutil.which(name)
        if not path:
            continue
        version = get_python_version([path])
        if version and version[:2] == (3, 14):
            return [path]
    return None


def find_node() -> Optional[str]:
    for name in ("node.exe", "node"):
        path = shutil.which(name)
        if path:
            return path

    program_files = os.environ.get("ProgramFiles", r"C:\Program Files")
    local_app = os.environ.get("LocalAppData", "")
    program_files_x86 = os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)")

    candidates = [
        os.path.join(program_files, "nodejs", "node.exe"),
        os.path.join(program_files_x86, "nodejs", "node.exe"),
    ]
    if local_app:
        candidates.append(os.path.join(local_app, "Programs", "nodejs", "node.exe"))

    for candidate in candidates:
        if os.path.isfile(candidate):
            return candidate
    return None


def find_npm() -> Optional[str]:
    for name in ("npm.cmd", "npm"):
        path = shutil.which(name)
        if path:
            return path

    program_files = os.environ.get("ProgramFiles", r"C:\Program Files")
    local_app = os.environ.get("LocalAppData", "")
    program_files_x86 = os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)")

    candidates = [
        os.path.join(program_files, "nodejs", "npm.cmd"),
        os.path.join(program_files_x86, "nodejs", "npm.cmd"),
    ]
    if local_app:
        candidates.append(os.path.join(local_app, "Programs", "nodejs", "npm.cmd"))

    for candidate in candidates:
        if os.path.isfile(candidate):
            return candidate
    return None


def get_npm_global_prefix(npm_exe: str, log: Callable[[str], None]) -> Optional[str]:
    env = os.environ.copy()
    npm_dir = os.path.dirname(npm_exe)
    if npm_dir:
        env["PATH"] = npm_dir + os.pathsep + env.get("PATH", "")
    env["npm_config_update_notifier"] = "false"
    for args in ([npm_exe, "prefix", "-g"], [npm_exe, "config", "get", "prefix"]):
        try:
            completed = subprocess.run(
                args,
                capture_output=True,
                text=True,
                env=env,
                **subprocess_creationflags_kwargs(),
            )
        except OSError as exc:
            log(f"Unable to query npm prefix: {exc}")
            return None
        if completed.returncode == 0:
            prefix = completed.stdout.strip()
            if prefix and os.path.isdir(prefix):
                return prefix
    return None


def repair_claude_after_failed_update(npm_exe: str, log: Callable[[str], None]) -> bool:
    if not is_windows():
        return False

    prefix = get_npm_global_prefix(npm_exe, log)
    if not prefix:
        return False

    pkg_dir = os.path.join(prefix, "node_modules", "@anthropic-ai", "claude-code")
    bin_dir = os.path.join(pkg_dir, "bin")
    claude_exe = os.path.join(bin_dir, "claude.exe")
    if not os.path.isdir(bin_dir):
        return os.path.isfile(claude_exe)

    orphans = sorted(
        (
            path
            for path in glob.glob(os.path.join(bin_dir, "claude.exe.old.*"))
            if os.path.isfile(path)
        ),
        key=lambda path: os.path.basename(path),
        reverse=True,
    )

    if not os.path.isfile(claude_exe) and orphans:
        latest = orphans[0]
        try:
            os.replace(latest, claude_exe)
            log(f"Restored Claude CLI executable from {os.path.basename(latest)}.")
            orphans = orphans[1:]
        except OSError as exc:
            log(f"Warning: could not restore Claude CLI executable: {exc}")

    # Fall back to copying from the optional native-arch package when the
    # bin/claude.exe is still missing (e.g. the .old file is gone, or the
    # rename succeeded but the new download never landed). The native
    # package ships the same Win32 binary that the postinstall normally
    # hard-links into bin/claude.exe.
    if not os.path.isfile(claude_exe):
        native_candidates = (
            os.path.join(
                pkg_dir, "node_modules", "@anthropic-ai", "claude-code-win32-x64", "claude.exe"
            ),
            os.path.join(
                pkg_dir, "node_modules", "@anthropic-ai", "claude-code-win32-arm64", "claude.exe"
            ),
        )
        for native in native_candidates:
            if not os.path.isfile(native):
                continue
            try:
                shutil.copyfile(native, claude_exe)
                log(f"Restored Claude CLI executable by copying from native package: {native}")
                break
            except OSError as exc:
                log(f"Warning: could not copy native Claude binary {native}: {exc}")

    for orphan in orphans:
        try:
            os.remove(orphan)
        except OSError as exc:
            log(f"Warning: could not remove stale Claude CLI backup {os.path.basename(orphan)}: {exc}")

    return os.path.isfile(claude_exe)


def get_cli_bin_dirs(npm_exe: Optional[str], log: Callable[[str], None]) -> list[str]:
    dirs: list[str] = []

    if is_macos():
        node_dir_candidates = ["/opt/homebrew/bin", "/usr/local/bin"]
        brew = find_brew()
        if brew:
            try:
                completed = subprocess.run(
                    [brew, "--prefix"],
                    capture_output=True,
                    text=True,
                    **subprocess_creationflags_kwargs(),
                )
                if completed.returncode == 0 and completed.stdout.strip():
                    node_dir_candidates.insert(0, os.path.join(completed.stdout.strip(), "bin"))
            except OSError:
                pass
    elif is_linux():
        node_dir_candidates = ["/usr/local/bin", "/usr/bin"]
    else:
        node_dir_candidates = [
            os.path.join(os.environ.get("ProgramFiles", r"C:\Program Files"), "nodejs"),
            os.path.join(os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)"), "nodejs"),
        ]
    for d in node_dir_candidates:
        if os.path.isdir(d):
            dirs.append(d)

    if is_macos():
        for default in ("/opt/homebrew/bin", "/usr/local/bin", os.path.join(os.path.expanduser("~"), ".local", "bin")):
            if os.path.isdir(default):
                dirs.append(default)
    else:
        appdata = os.environ.get("AppData")
        if appdata:
            npm_global_default = os.path.join(appdata, "npm")
            if os.path.isdir(npm_global_default):
                dirs.append(npm_global_default)

    if npm_exe:
        prefix = get_npm_global_prefix(npm_exe, log)
        if prefix:
            prefix_bin = prefix if is_windows() else os.path.join(prefix, "bin")
            if os.path.isdir(prefix_bin):
                dirs.append(prefix_bin)
            elif os.path.isdir(prefix):
                dirs.append(prefix)

    unique: list[str] = []
    seen: set[str] = set()
    for d in dirs:
        norm = normalize_path_for_compare(d)
        if norm not in seen:
            unique.append(d)
            seen.add(norm)
    return unique


def get_python_cli_bin_dirs(log: Callable[[str], None]) -> list[str]:
    del log  # reserved for future diagnostics to keep call shape consistent with other helpers
    dirs: list[str] = []

    home = os.path.expanduser("~")
    if home:
        dirs.append(os.path.join(home, ".local", "bin"))

    appdata = os.environ.get("AppData")
    if appdata:
        dirs.extend(glob.glob(os.path.join(appdata, "Python", "Python*", "Scripts")))

    local_app = os.environ.get("LocalAppData")
    if local_app:
        dirs.extend(glob.glob(os.path.join(local_app, "Programs", "Python", "Python*", "Scripts")))

    existing_dirs = [d for d in dirs if d and os.path.isdir(d)]
    unique: list[str] = []
    seen: set[str] = set()
    for d in existing_dirs:
        norm = normalize_path_for_compare(d)
        if norm not in seen:
            unique.append(d)
            seen.add(norm)
    return unique


def get_ollama_cli_bin_dirs(log: Callable[[str], None]) -> list[str]:
    del log  # reserved for future diagnostics to keep call shape consistent with other helpers
    dirs: list[str] = []

    if is_macos():
        dirs.extend(["/opt/homebrew/bin", "/usr/local/bin", os.path.join(os.path.expanduser("~"), ".ollama", "bin")])
        existing_dirs = [d for d in dirs if d and os.path.isdir(d)]
        unique: list[str] = []
        seen: set[str] = set()
        for d in existing_dirs:
            norm = normalize_path_for_compare(d)
            if norm not in seen:
                unique.append(d)
                seen.add(norm)
        return unique

    if is_linux():
        dirs.extend(["/usr/local/bin", "/usr/bin"])
        existing_dirs = [d for d in dirs if d and os.path.isdir(d)]
        unique: list[str] = []
        seen: set[str] = set()
        for d in existing_dirs:
            norm = normalize_path_for_compare(d)
            if norm not in seen:
                unique.append(d)
                seen.add(norm)
        return unique

    local_app = os.environ.get("LocalAppData")
    program_files = os.environ.get("ProgramFiles", r"C:\Program Files")
    program_files_x86 = os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)")
    if local_app:
        dirs.append(os.path.join(local_app, "Programs", "Ollama"))
    dirs.append(os.path.join(program_files, "Ollama"))
    dirs.append(os.path.join(program_files_x86, "Ollama"))

    existing_dirs = [d for d in dirs if d and os.path.isdir(d)]
    unique: list[str] = []
    seen: set[str] = set()
    for d in existing_dirs:
        norm = normalize_path_for_compare(d)
        if norm not in seen:
            unique.append(d)
            seen.add(norm)
    return unique


def filter_system_path_dirs(dirs: list[str]) -> list[str]:
    user_roots: list[str] = []
    home = os.path.expanduser("~")
    if home:
        user_roots.append(home)
    for env_name in ("AppData", "LocalAppData", "UserProfile"):
        value = os.environ.get(env_name)
        if value:
            user_roots.append(value)

    filtered: list[str] = []
    for directory in dirs:
        if any(is_path_within(directory, root) for root in user_roots):
            continue
        filtered.append(directory)
    return filtered


def linux_package_manager_name() -> Optional[str]:
    return detect_linux_distro_family()


def linux_package_manager_install_commands(packages: list[str]) -> list[list[str]]:
    family = linux_package_manager_name()
    if family == "debian":
        return [
            ["apt-get", "update"],
            ["apt-get", "install", "-y", *packages],
        ]
    if family == "fedora":
        return [["dnf", "install", "-y", *packages]]
    if family == "arch":
        return [["pacman", "-Sy", "--noconfirm", *packages]]
    raise RuntimeError(
        "Unsupported Linux distribution. Supported families: Debian/Ubuntu, Fedora, Arch."
    )


def ensure_linux_packages_installed(packages: list[str], log: Callable[[str], None]) -> None:
    if not is_linux():
        return
    if not ensure_linux_root_for_package_installs(log):
        raise RuntimeError("Linux package installation requires root privileges.")
    commands = linux_package_manager_install_commands(packages)
    log("Installing Linux packages: " + ", ".join(packages))
    for args in commands:
        code = run_command(args, log)
        if code != 0:
            raise RuntimeError(
                "Linux package install failed with exit code "
                + format_exit_code(code)
                + f" while running: {' '.join(args)}"
            )


def brew_package_installed(brew: str, name: str, cask: bool = False) -> bool:
    args = [brew, "list", "--cask" if cask else "--formula", name]
    completed = _probe_command(args)
    return bool(completed and completed.returncode == 0)


def brew_install_or_upgrade(
    name: str,
    log: Callable[[str], None],
    cask: bool = False,
) -> tuple[bool, str]:
    brew = ensure_homebrew(log)
    kind = "cask" if cask else "formula"
    install_args = [brew, "install"]
    upgrade_args = [brew, "upgrade"]
    uninstall_hint = f"--{kind}" if cask else "--formula"
    if cask:
        install_args.append("--cask")
        upgrade_args.append("--cask")
    install_args.append(name)
    upgrade_args.append(name)

    if brew_package_installed(brew, name, cask=cask):
        log(f"Homebrew {kind} already installed: {name}. Upgrading...")
        code = run_command(upgrade_args, log)
        if code == 0:
            return (True, name)
        log(f"brew upgrade {uninstall_hint} {name} failed with exit code {format_exit_code(code)}; continuing with installed copy.")
        return (True, name)

    log(f"Installing Homebrew {kind}: {name}")
    code = run_command(install_args, log)
    if code == 0:
        return (True, name)

    log(f"brew install {uninstall_hint} {name} failed with exit code {format_exit_code(code)}; trying upgrade...")
    code = run_command(upgrade_args, log)
    if code == 0:
        return (True, name)
    return (False, f"brew {kind} {name} failed with exit code {format_exit_code(code)}")


def brew_uninstall(
    name: str,
    log: Callable[[str], None],
    cask: bool = False,
) -> tuple[bool, str]:
    brew = ensure_homebrew(log)
    args = [brew, "uninstall"]
    if cask:
        args.append("--cask")
    args.append(name)
    code = run_command(args, log)
    if code == 0:
        return (True, name)
    return (False, f"brew uninstall {name} failed with exit code {format_exit_code(code)}")


def ensure_node_via_brew(
    log: Callable[[str], None],
    min_major: int = 20,
    min_version: Optional[tuple[int, int, int]] = None,
) -> None:
    required = min_version or (min_major, 0, 0)
    requirement = node_requirement_label(required)
    node_path = find_node()
    npm_path = find_npm()
    version = get_node_version(node_path) if node_path else None
    if node_path and npm_path and node_version_satisfies(version, required):
        log(f"Node.js is already available: {node_path} (v{'.'.join(str(v) for v in version)})")
        log(f"npm is already available: {npm_path}")
        return

    if node_path and version:
        log(
            f"Node.js v{'.'.join(str(v) for v in version)} is below the required {requirement}; installing/upgrading node via Homebrew."
        )
    else:
        log(f"Node.js {requirement} and npm are required; installing node via Homebrew.")

    ok, detail = brew_install_or_upgrade("node", log)
    if not ok:
        raise RuntimeError(detail)

    _apply_homebrew_path_hints()
    node_path = find_node()
    npm_path = find_npm()
    version = get_node_version(node_path) if node_path else None
    if not node_path or not npm_path or not node_version_satisfies(version, required):
        raise RuntimeError(
            f"Homebrew node install completed, but Node.js {requirement} and npm were not both found. "
            "Open a new terminal or run `brew doctor` and ensure Homebrew is on PATH."
        )
    log(f"Node.js is available: {node_path} (v{'.'.join(str(v) for v in version)})")
    log(f"npm is available: {npm_path}")


def ensure_node_via_winget(log: Callable[[str], None]) -> None:
    if is_macos():
        ensure_homebrew(log)
        ensure_node_via_brew(log, 20)
        return

    if is_linux():
        node_path = find_node()
        npm_path = find_npm()
        if node_path and npm_path:
            log(f"Node.js is already available: {node_path}")
            log(f"npm is already available: {npm_path}")
            return
        missing = []
        if not node_path:
            missing.append("Node.js")
        if not npm_path:
            missing.append("npm")
        log("Installing Node.js + npm via Linux package manager...")
        log("Missing prerequisites: " + ", ".join(missing))
        ensure_linux_packages_installed(["nodejs", "npm"], log)
        node_path = find_node()
        npm_path = find_npm()
        if not node_path or not npm_path:
            raise RuntimeError(
                "Node.js installation completed, but node and/or npm could not be found. "
                "Try reopening the app or install Node.js manually."
            )
        log(f"Node.js is available: {node_path}")
        log(f"npm is available: {npm_path}")
        return

    winget = find_winget()
    if not winget:
        raise RuntimeError("winget was not found. Install Microsoft App Installer / winget first.")

    node_path = find_node()
    npm_path = find_npm()
    if node_path and npm_path:
        log(f"Node.js is already available: {node_path}")
        log(f"npm is already available: {npm_path}")
        return

    missing = []
    if not node_path:
        missing.append("Node.js")
    if not npm_path:
        missing.append("npm")
    log("Installing Node.js LTS via winget (includes npm)...")
    log("Missing prerequisites: " + ", ".join(missing))
    code = run_command(
        [
            winget,
            "install",
            "--id",
            NODE_WINGET_ID,
            "-e",
            "--accept-package-agreements",
            "--accept-source-agreements",
            "--silent",
            "--disable-interactivity",
        ],
        log,
    )
    if code != 0:
        raise RuntimeError(f"winget Node.js install failed with exit code {code}.")

    node_path = find_node()
    npm_path = find_npm()
    if not node_path or not npm_path:
        raise RuntimeError(
            "Node.js installation completed, but node and/or npm could not be found. "
            "Try reopening the app or install Node.js manually from nodejs.org."
        )
    log(f"Node.js is available: {node_path}")
    log(f"npm is available: {npm_path}")


def ensure_ollama_via_winget(log: Callable[[str], None]) -> tuple[bool, Optional[str]]:
    package_name = OLLAMA_WINGET_ID

    if is_macos():
        existing = find_ollama()
        if existing:
            log(f"Ollama CLI is already available: {existing}")
        ok, detail = brew_install_or_upgrade("ollama", log)
        return (ok, detail)

    if is_linux():
        existing = find_ollama()
        if existing:
            log(f"Ollama CLI is already available: {existing}")
        try:
            if not command_exists("curl"):
                ensure_linux_packages_installed(["curl"], log)
            if not command_exists("sh"):
                return (False, "sh was not found. Unable to run official Ollama Linux installer.")
        except RuntimeError as exc:
            err = str(exc)
            log(err)
            return (False, err)

        log("Installing official Ollama for Linux via install script (includes ollama CLI)...")
        code = run_command(["sh", "-c", f"curl -fsSL {LINUX_OLLAMA_INSTALL_URL} | sh"], log)
        if code != 0:
            existing = find_ollama()
            if existing:
                log(
                    "Warning: Ollama install/update command failed, but an existing Ollama CLI was found. "
                    "Using existing installation and continuing."
                )
                return (True, package_name)
            err = f"{package_name} failed with exit code {format_exit_code(code)}"
            log(err)
            return (False, err)
        return (True, package_name)

    winget = find_winget()
    if not winget:
        err = "winget was not found. Install Microsoft App Installer / winget first to install Ollama."
        log(err)
        return (False, err)

    existing = find_ollama()
    if existing:
        log(f"Ollama CLI is already available: {existing}")

    install_args = [
        winget,
        "install",
        "--id",
        package_name,
        "-e",
        "--accept-package-agreements",
        "--accept-source-agreements",
        "--silent",
        "--disable-interactivity",
    ]
    upgrade_args = [
        winget,
        "upgrade",
        "--id",
        package_name,
        "-e",
        "--accept-package-agreements",
        "--accept-source-agreements",
        "--silent",
        "--disable-interactivity",
    ]

    log("Installing official Ollama for Windows via winget (includes ollama CLI)...")
    code = run_command(install_args, log)
    if code != 0:
        log(
            "winget install for Ollama failed with exit code "
            + format_exit_code(code)
            + "; trying winget upgrade..."
        )
        code = run_command(upgrade_args, log)
        if code != 0:
            existing = find_ollama()
            if existing:
                log(
                    "Warning: Ollama install/update command failed, but an existing Ollama CLI was found. "
                    "Using existing installation and continuing."
                )
                return (True, package_name)
            err = f"{package_name} failed with exit code {format_exit_code(code)}"
            log(err)
            return (False, err)

    return (True, package_name)


def ensure_python_314_via_winget(log: Callable[[str], None]) -> list[str]:
    python_cmd = find_python_314_command()
    if python_cmd:
        log("Python 3.14 is already available for Mistral Vibe: " + " ".join(python_cmd))
        return python_cmd

    winget = find_winget()
    if not winget:
        raise RuntimeError(
            "Python 3.14 is required for Mistral Vibe CLI, but winget was not found. "
            "Install Microsoft App Installer / winget first or install Python 3.14 manually."
        )

    log("Installing Python 3.14 via winget for Mistral Vibe CLI...")
    code = run_command(
        [
            winget,
            "install",
            "--id",
            PYTHON_314_WINGET_ID,
            "-e",
            "--accept-package-agreements",
            "--accept-source-agreements",
            "--silent",
            "--disable-interactivity",
        ],
        log,
    )
    if code != 0:
        raise RuntimeError(f"winget Python 3.14 install failed with exit code {format_exit_code(code)}.")

    python_cmd = find_python_314_command()
    if not python_cmd:
        raise RuntimeError(
            "Python 3.14 installation completed, but Python 3.14 could not be found. "
            "Try reopening the app or install Python 3.14 manually."
        )
    log("Python 3.14 is available for Mistral Vibe: " + " ".join(python_cmd))
    return python_cmd


def find_linux_python_for_mistral() -> Optional[list[str]]:
    for candidate in (["python3.14"], ["python3"], ["python"]):
        exe = shutil.which(candidate[0])
        if not exe:
            continue
        version = get_python_version([exe])
        if version and version >= (3, 12, 0):
            return [exe]
    return None


def ensure_python_for_mistral_on_linux(log: Callable[[str], None]) -> list[str]:
    python_cmd = find_linux_python_for_mistral()
    if python_cmd:
        version = get_python_version(python_cmd)
        label = ".".join(str(v) for v in version) if version else "unknown"
        log("Python is already available for Mistral Vibe on Linux: " + " ".join(python_cmd) + f" (v{label})")
        return python_cmd

    family = linux_package_manager_name()
    if family == "arch":
        packages = ["python", "python-pip"]
    else:
        packages = ["python3", "python3-pip"]
    log("Installing Python + pip for Mistral Vibe via Linux package manager...")
    ensure_linux_packages_installed(packages, log)

    python_cmd = find_linux_python_for_mistral()
    if not python_cmd:
        raise RuntimeError(
            "Python 3.12+ is required for Mistral Vibe CLI, but no compatible Python was found after install."
        )
    version = get_python_version(python_cmd)
    if not version or version < (3, 12, 0):
        raise RuntimeError(
            "Mistral Vibe CLI requires Python 3.12+, but the installed Linux Python is too old."
        )
    log("Python is available for Mistral Vibe on Linux: " + " ".join(python_cmd))
    return python_cmd


def ensure_pip3_for_python(
    python_cmd: list[str],
    log: Callable[[str], None],
    python_label: str = "Python 3.14",
) -> None:
    pip_check = run_command([*python_cmd, "-m", "pip", "--version"], log)
    if pip_check != 0:
        log(f"pip3 was not found for {python_label}; bootstrapping pip with ensurepip...")
        code = run_command([*python_cmd, "-m", "ensurepip", "--upgrade"], log)
        if code != 0:
            raise RuntimeError(f"{python_label} ensurepip failed with exit code {format_exit_code(code)}.")
        pip_check = run_command([*python_cmd, "-m", "pip", "--version"], log)
        if pip_check != 0:
            raise RuntimeError(f"pip3 is still unavailable after ensurepip for {python_label}.")
    else:
        log(f"pip3 is already available for {python_label}.")

    log(f"Updating pip3 for {python_label}...")
    code = run_command(
        [*python_cmd, "-m", "pip", "install", "--user", "--upgrade", *pip_install_flags_for_platform(), "pip"],
        log,
    )
    if code != 0:
        raise RuntimeError(f"pip3 update failed with exit code {format_exit_code(code)}.")

    pip3_path = find_pip3()
    if pip3_path:
        log(f"pip3 is available: {pip3_path}")


def ensure_uv_for_mistral(python_cmd: list[str], log: Callable[[str], None]) -> Optional[str]:
    existing_uv = find_uv()
    if existing_uv:
        log(f"uv is already available: {existing_uv}")
    else:
        log("uv was not found; installing uv via pip3 for Mistral Vibe CLI...")

    log("Updating uv for Mistral Vibe CLI...")
    code = run_command(
        [*python_cmd, "-m", "pip", "install", "--user", "--upgrade", *pip_install_flags_for_platform(), "uv"],
        log,
    )
    if code != 0:
        log(f"uv install/update failed with exit code {format_exit_code(code)}; pip fallback will be used for Mistral Vibe.")
        return find_uv()

    uv_exe = find_uv()
    if uv_exe:
        log(f"uv is available: {uv_exe}")
        return uv_exe

    log("uv install/update completed, but uv was not found on PATH yet; pip fallback will be used for Mistral Vibe.")
    return None


def ensure_mistral_vibe_dependencies(log: Callable[[str], None]) -> tuple[list[str], Optional[str]]:
    if is_macos():
        ok, detail = brew_install_or_upgrade("mistral-vibe", log)
        if ok:
            return (["mistral-vibe"], None)
        raise RuntimeError(detail)
    if is_linux():
        python_cmd = ensure_python_for_mistral_on_linux(log)
        ensure_pip3_for_python(python_cmd, log, "Python 3.12+ (Linux)")
    else:
        python_cmd = ensure_python_314_via_winget(log)
        ensure_pip3_for_python(python_cmd, log)
    uv_exe = ensure_uv_for_mistral(python_cmd, log)
    return (python_cmd, uv_exe)


def try_install_mistral_vibe(
    spec: CliSpec,
    log: Callable[[str], None],
) -> tuple[bool, Optional[str]]:
    package_name = spec.package_candidates[0] if spec.package_candidates else "mistral-vibe"

    if is_macos():
        ok, detail = brew_install_or_upgrade(spec.macos_brew_formula or "mistral-vibe", log)
        return (ok, detail)

    try:
        python_cmd, uv_exe = ensure_mistral_vibe_dependencies(log)
    except RuntimeError as exc:
        err = str(exc)
        log(err)
        return (False, err)

    if uv_exe:
        log(f"Trying official Mistral Vibe install via uv: {package_name}")
        code = run_command([uv_exe, "tool", "install", "--upgrade", package_name], log)
        if code == 0:
            return (True, package_name)
        log(f"uv tool install failed with exit code {format_exit_code(code)}")
    else:
        log("uv was not found; falling back to pip for Mistral Vibe CLI.")

    log(f"Trying official Mistral Vibe install via pip: {package_name}")
    code = run_command(
        [*python_cmd, "-m", "pip", "install", "--user", "--upgrade", *pip_install_flags_for_platform(), package_name],
        log,
    )
    if code == 0:
        return (True, package_name)

    err = f"Mistral Vibe install failed with exit code {format_exit_code(code)}"
    log(err)
    return (False, err)


def _find_python_for_mistral_uninstall() -> Optional[list[str]]:
    if is_linux():
        found = find_linux_python_for_mistral()
        if found:
            return found
        for candidate in ("python3", "python"):
            exe = shutil.which(candidate)
            if exe:
                return [exe]
        return None

    found = find_python_314_command()
    if found:
        return found
    for candidate in ("python.exe", "python"):
        exe = shutil.which(candidate)
        if exe:
            return [exe]
    return None


def try_uninstall_mistral_vibe(
    spec: CliSpec,
    log: Callable[[str], None],
) -> tuple[bool, Optional[str]]:
    package_name = spec.package_candidates[0] if spec.package_candidates else "mistral-vibe"

    if is_macos():
        return brew_uninstall(spec.macos_brew_formula or "mistral-vibe", log)

    uv_ok = False
    pip_ok = False

    uv_exe = find_uv()
    if uv_exe:
        log(f"Trying Mistral Vibe uninstall via uv: {package_name}")
        code = run_command([uv_exe, "tool", "uninstall", package_name], log)
        if code == 0:
            uv_ok = True
        else:
            log(f"uv tool uninstall failed with exit code {format_exit_code(code)}")
    else:
        log("uv was not found for Mistral Vibe uninstall; trying pip fallback.")

    python_cmd = _find_python_for_mistral_uninstall()
    if python_cmd:
        python_label = " ".join(python_cmd)
        log(f"Trying Mistral Vibe uninstall via pip using: {python_label}")
        code = run_command(
            [
                *python_cmd,
                "-m",
                "pip",
                "uninstall",
                "--yes",
                *pip_install_flags_for_platform(),
                package_name,
            ],
            log,
        )
        if code == 0:
            pip_ok = True
        else:
            log(f"pip uninstall failed with exit code {format_exit_code(code)}")
    else:
        log("Python interpreter not found for Mistral Vibe pip uninstall fallback.")

    if uv_ok or pip_ok:
        return (True, package_name)

    command_path = resolve_command_path(
        spec.command_candidates,
        dedupe_preserve_order(get_python_cli_bin_dirs(log) + get_cli_bin_dirs(find_npm(), log)),
    )
    if not command_path:
        log("Mistral Vibe command was not found; treating as already uninstalled.")
        return (True, package_name)

    err = "Mistral Vibe uninstall failed and command is still present."
    log(err)
    return (False, err)


def try_uninstall_ollama(log: Callable[[str], None]) -> tuple[bool, Optional[str]]:
    package_name = OLLAMA_WINGET_ID

    existing_before = find_ollama()
    if not existing_before:
        log("Ollama CLI was not detected; nothing to uninstall.")
        return (True, package_name)

    if is_macos():
        ok, detail = brew_uninstall("ollama", log)
        if ok or not find_ollama():
            return (True, detail)
        return (False, detail)

    if is_linux():
        linux_steps: list[list[str]] = []
        if shutil.which("systemctl"):
            linux_steps.extend(
                [
                    [*_linux_sudo(), "systemctl", "stop", "ollama"],
                    [*_linux_sudo(), "systemctl", "disable", "ollama"],
                    [*_linux_sudo(), "rm", "-f", "/etc/systemd/system/ollama.service"],
                    [*_linux_sudo(), "systemctl", "daemon-reload"],
                ]
            )
        linux_steps.extend(
            [
                [*_linux_sudo(), "rm", "-f", "/usr/local/bin/ollama", "/usr/bin/ollama"],
                [*_linux_sudo(), "rm", "-rf", "/usr/local/lib/ollama", "/usr/share/ollama"],
            ]
        )
        for args in linux_steps:
            code = run_command(args, log)
            if code != 0:
                log(
                    "Warning: Ollama uninstall step failed with exit code "
                    + format_exit_code(code)
                    + f": {' '.join(args)}"
                )
        if find_ollama():
            err = "Ollama uninstall could not fully remove the ollama command on Linux."
            log(err)
            return (False, err)
        return (True, package_name)

    winget = find_winget()
    if not winget:
        err = "winget was not found. Cannot uninstall Ollama automatically."
        log(err)
        return (False, err)

    code = run_command(
        [
            winget,
            "uninstall",
            "--id",
            package_name,
            "-e",
            "--accept-source-agreements",
            "--silent",
            "--disable-interactivity",
        ],
        log,
    )
    if code != 0 and find_ollama():
        err = f"{package_name} uninstall failed with exit code {format_exit_code(code)}"
        log(err)
        return (False, err)

    return (True, package_name)


def _linux_sudo() -> list[str]:
    return [] if is_admin() else ["sudo", "-A"]


def _sudo_needs_password() -> bool:
    """Return True if sudo requires a password (no cached credential)."""
    try:
        result = subprocess.run(
            ["sudo", "-n", "true"],
            capture_output=True,
            **subprocess_creationflags_kwargs(),
        )
        return result.returncode != 0
    except OSError:
        return True


def _create_sudo_askpass_script(password: str) -> str:
    """Write a temporary askpass helper script and return its path."""
    fd, path = tempfile.mkstemp(prefix="itc_askpass_", suffix=".sh")
    try:
        with os.fdopen(fd, "w") as f:
            f.write("#!/bin/sh\n")
            f.write(f"printf '%s\\n' {shlex.quote(password)}\n")
        os.chmod(path, stat.S_IRWXU)
    except Exception:
        try:
            os.unlink(path)
        except OSError:
            pass
        raise
    return path


def npm_install_global(
    npm_exe: str,
    package_name: str,
    log: Callable[[str], None],
) -> int:
    env = os.environ.copy()
    npm_dir = os.path.dirname(npm_exe)
    if npm_dir:
        env["PATH"] = npm_dir + os.pathsep + env.get("PATH", "")
    env["npm_config_update_notifier"] = "false"
    sudo = _linux_sudo() if is_linux() else []
    return run_command([*sudo, npm_exe, *NPM_QUIET_FLAGS, "install", "-g", package_name], log, env=env)


def npm_uninstall_global(
    npm_exe: str,
    package_name: str,
    log: Callable[[str], None],
) -> int:
    env = os.environ.copy()
    npm_dir = os.path.dirname(npm_exe)
    if npm_dir:
        env["PATH"] = npm_dir + os.pathsep + env.get("PATH", "")
    env["npm_config_update_notifier"] = "false"
    sudo = _linux_sudo() if is_linux() else []
    return run_command([*sudo, npm_exe, *NPM_QUIET_FLAGS, "uninstall", "-g", package_name], log, env=env)


def is_probably_windows_errno_exit_code(code: int) -> bool:
    # npm on Windows sometimes returns negative errno values reinterpreted as unsigned exit codes.
    return code >= 0xFFFF0000


def format_exit_code(code: int) -> str:
    if not is_probably_windows_errno_exit_code(code):
        return str(code)
    signed = code - (1 << 32)
    return f"{code} (Windows errno {signed})"


def is_probably_windows_file_lock_error(detail: Optional[str]) -> bool:
    if not detail:
        return False
    lowered = detail.lower()
    return (
        "ebusy" in lowered
        or "windows errno -4082" in lowered
        or "4294963214" in lowered
    )


def _ensure_flatpak_flathub(log: Callable[[str], None]) -> bool:
    if not shutil.which("flatpak"):
        return False
    try:
        result = subprocess.run(
            ["flatpak", "remotes"],
            capture_output=True,
            text=True,
            **subprocess_creationflags_kwargs(),
        )
        if "flathub" in (result.stdout or "").lower():
            return True
    except OSError:
        pass
    log("Adding Flathub remote (system-wide)...")
    code = run_command(
        [
            *_linux_sudo(), "flatpak", "remote-add", "--if-not-exists",
            "flathub", "https://dl.flathub.org/repo/flathub.flatpakrepo",
        ],
        log,
    )
    return code == 0


def _install_gui_app_flatpak(spec: GuiAppSpec, log: Callable[[str], None]) -> bool:
    if not spec.flatpak_id:
        return False
    if not _ensure_flatpak_flathub(log):
        log(f"{spec.label}: flatpak/Flathub not available.")
        return False
    log(f"Installing {spec.label} via Flatpak ({spec.flatpak_id})...")
    code = run_command(
        [*_linux_sudo(), "flatpak", "install", "flathub", spec.flatpak_id, "-y", "--noninteractive"],
        log,
    )
    if code == 0:
        log(f"Successfully installed {spec.label} via Flatpak.")
        return True
    log(f"Flatpak install returned exit code {format_exit_code(code)}; trying update...")
    code = run_command(
        [*_linux_sudo(), "flatpak", "update", spec.flatpak_id, "-y", "--noninteractive"],
        log,
    )
    if code == 0:
        log(f"Successfully updated {spec.label} via Flatpak.")
        return True
    log(f"Flatpak install/update failed with exit code {format_exit_code(code)}.")
    return False


def _install_gui_app_snap(spec: GuiAppSpec, log: Callable[[str], None]) -> bool:
    if not spec.snap_name:
        return False
    if not shutil.which("snap"):
        log(f"{spec.label}: snap is not available.")
        return False
    log(f"Installing {spec.label} via Snap ({spec.snap_name})...")
    code = run_command([*_linux_sudo(), "snap", "install", spec.snap_name], log)
    if code == 0:
        log(f"Successfully installed {spec.label} via Snap.")
        return True
    log(f"Snap install failed with exit code {format_exit_code(code)}.")
    return False


def _install_gui_app_winget(spec: GuiAppSpec, log: Callable[[str], None]) -> bool:
    if not spec.winget_id:
        log(f"{spec.label}: No winget ID configured for Windows. Skipping.")
        return False
    winget = find_winget()
    if not winget:
        log(f"{spec.label}: winget was not found. Cannot install.")
        return False
    source_suffix = f", source={spec.winget_source}" if spec.winget_source else ""
    log(f"Installing {spec.label} via winget ({spec.winget_id}{source_suffix})...")
    install_args = [
        winget,
        "install",
        "--id",
        spec.winget_id,
        "-e",
        "--accept-package-agreements",
        "--accept-source-agreements",
        "--silent",
        "--disable-interactivity",
    ]
    upgrade_args = [
        winget,
        "upgrade",
        "--id",
        spec.winget_id,
        "-e",
        "--accept-package-agreements",
        "--accept-source-agreements",
        "--silent",
        "--disable-interactivity",
    ]
    if spec.winget_source:
        install_args.extend(["--source", spec.winget_source])
        upgrade_args.extend(["--source", spec.winget_source])
    code = run_command(install_args, log)
    if code != 0:
        log(f"winget install returned exit code {format_exit_code(code)}; trying upgrade...")
        code = run_command(upgrade_args, log)
        if code != 0:
            log(f"{spec.label} install/upgrade failed with exit code {format_exit_code(code)}.")
            return False
    log(f"Successfully installed/updated {spec.label}.")
    return True


def _install_gui_app_brew_cask(spec: GuiAppSpec, log: Callable[[str], None]) -> bool:
    if not spec.macos_brew_cask:
        return False
    ok, detail = brew_install_or_upgrade(spec.macos_brew_cask, log, cask=True)
    if ok:
        log(f"Successfully installed/updated {spec.label} via Homebrew cask.")
        return True
    log(f"{spec.label} Homebrew cask install/update failed: {detail}")
    return False


def _gui_app_browser_url_for_platform(spec: GuiAppSpec) -> Optional[str]:
    if is_windows():
        return spec.windows_browser_url or spec.linux_browser_url
    if is_macos():
        return spec.macos_browser_url or spec.linux_browser_url or spec.windows_browser_url
    if is_linux():
        return spec.linux_browser_url or spec.windows_browser_url
    return None


def _gui_app_browser_shortcut_paths(spec: GuiAppSpec) -> list[str]:
    desktop_dir = find_desktop_directory()
    if is_windows():
        return [os.path.join(desktop_dir, f"{spec.label}.url")]
    if is_macos():
        return [os.path.join(desktop_dir, f"{spec.label}.webloc")]
    return [
        os.path.join(os.path.expanduser("~"), ".local", "share", "applications", f"installcli-{spec.key}.desktop"),
        os.path.join(desktop_dir, f"{spec.label}.desktop"),
    ]


def _probe_command(args: list[str]) -> Optional[subprocess.CompletedProcess[str]]:
    try:
        return subprocess.run(
            args,
            capture_output=True,
            text=True,
            **subprocess_creationflags_kwargs(),
        )
    except OSError:
        return None


def _winget_app_installed(winget_id: str, winget_source: Optional[str] = None) -> bool:
    winget = find_winget()
    if not winget:
        return False
    args = [winget, "list", "--id", winget_id, "-e", "--accept-source-agreements"]
    if winget_source:
        args.extend(["--source", winget_source])
    completed = _probe_command(args)
    if not completed or completed.returncode != 0:
        return False
    combined = ((completed.stdout or "") + "\n" + (completed.stderr or "")).lower()
    return winget_id.lower() in combined


def _flatpak_app_installed(flatpak_id: str) -> bool:
    if not shutil.which("flatpak"):
        return False
    completed = _probe_command(["flatpak", "list", "--app", "--columns=application"])
    if not completed or completed.returncode != 0:
        return False
    rows = [line.strip() for line in (completed.stdout or "").splitlines() if line.strip()]
    return flatpak_id in rows


def _snap_app_installed(snap_name: str) -> bool:
    if not shutil.which("snap"):
        return False
    completed = _probe_command(["snap", "list", snap_name])
    return bool(completed and completed.returncode == 0)


def _brew_cask_app_installed(cask_name: str) -> bool:
    brew = find_brew()
    if not brew:
        return False
    return brew_package_installed(brew, cask_name, cask=True)


def is_gui_app_installed(spec: GuiAppSpec) -> bool:
    if is_windows():
        if spec.winget_id and _winget_app_installed(spec.winget_id, spec.winget_source):
            return True
    elif is_macos():
        if spec.macos_brew_cask and _brew_cask_app_installed(spec.macos_brew_cask):
            return True
    elif is_linux():
        if spec.flatpak_id and _flatpak_app_installed(spec.flatpak_id):
            return True
        if spec.snap_name and _snap_app_installed(spec.snap_name):
            return True
    for path in _gui_app_browser_shortcut_paths(spec):
        if os.path.isfile(path):
            return True
    return False


def _install_gui_app_browser_shortcut(spec: GuiAppSpec, log: Callable[[str], None]) -> bool:
    url = _gui_app_browser_url_for_platform(spec)
    if not url:
        return False
    if is_windows():
        desktop_shortcut = _gui_app_browser_shortcut_paths(spec)[0]
        os.makedirs(os.path.dirname(desktop_shortcut), exist_ok=True)
        lines = [
            "[InternetShortcut]",
            f"URL={url}",
        ]
        write_text_file(desktop_shortcut, "\n".join(lines) + "\n")
        log(f"Created browser shortcut for {spec.label} → {url}")
        log(f"Created desktop shortcut: {desktop_shortcut}")
        return True

    if is_macos():
        desktop_shortcut = _gui_app_browser_shortcut_paths(spec)[0]
        os.makedirs(os.path.dirname(desktop_shortcut), exist_ok=True)
        lines = [
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
            "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">",
            "<plist version=\"1.0\">",
            "<dict>",
            "  <key>URL</key>",
            f"  <string>{xml_escape(url)}</string>",
            "</dict>",
            "</plist>",
        ]
        write_text_file(desktop_shortcut, "\n".join(lines) + "\n")
        log(f"Created browser shortcut for {spec.label} -> {url}")
        log(f"Created desktop shortcut: {desktop_shortcut}")
        return True

    apps_dir = os.path.join(os.path.expanduser("~"), ".local", "share", "applications")
    os.makedirs(apps_dir, exist_ok=True)
    desktop_path = os.path.join(apps_dir, f"installcli-{spec.key}.desktop")
    lines = [
        "[Desktop Entry]",
        "Type=Application",
        f"Name={spec.label}",
        f"Comment={spec.help_text}",
        f"Exec=xdg-open {url}",
        "Icon=applications-internet",
        "Categories=Network;",
        "StartupNotify=false",
    ]
    write_text_file(desktop_path, "\n".join(lines) + "\n")
    os.chmod(desktop_path, 0o755)
    log(f"Created browser shortcut for {spec.label} → {url}")
    desktop_dir = find_desktop_directory()
    if desktop_dir:
        desktop_shortcut = os.path.join(desktop_dir, f"{spec.label}.desktop")
        write_text_file(desktop_shortcut, "\n".join(lines) + "\n")
        os.chmod(desktop_shortcut, 0o755)
        log(f"Created desktop shortcut: {desktop_shortcut}")
    return True


def _uninstall_gui_app_winget(spec: GuiAppSpec, log: Callable[[str], None]) -> bool:
    if not spec.winget_id:
        return False
    winget = find_winget()
    if not winget:
        log(f"{spec.label}: winget was not found. Cannot uninstall.")
        return False
    source_suffix = f", source={spec.winget_source}" if spec.winget_source else ""
    log(f"Uninstalling {spec.label} via winget ({spec.winget_id}{source_suffix})...")
    args = [
        winget,
        "uninstall",
        "--id",
        spec.winget_id,
        "-e",
        "--accept-source-agreements",
        "--silent",
        "--disable-interactivity",
    ]
    if spec.winget_source:
        args.extend(["--source", spec.winget_source])
    code = run_command(args, log)
    if code != 0:
        log(f"{spec.label} winget uninstall returned exit code {format_exit_code(code)}.")
    return code == 0


def _uninstall_gui_app_flatpak(spec: GuiAppSpec, log: Callable[[str], None]) -> bool:
    if not spec.flatpak_id:
        return False
    if not shutil.which("flatpak"):
        return False
    log(f"Uninstalling {spec.label} via Flatpak ({spec.flatpak_id})...")
    code = run_command(
        [*_linux_sudo(), "flatpak", "uninstall", spec.flatpak_id, "-y", "--noninteractive", "--delete-data"],
        log,
    )
    if code != 0:
        log(f"{spec.label} Flatpak uninstall returned exit code {format_exit_code(code)}.")
    return code == 0


def _uninstall_gui_app_snap(spec: GuiAppSpec, log: Callable[[str], None]) -> bool:
    if not spec.snap_name:
        return False
    if not shutil.which("snap"):
        return False
    log(f"Uninstalling {spec.label} via Snap ({spec.snap_name})...")
    code = run_command([*_linux_sudo(), "snap", "remove", spec.snap_name], log)
    if code != 0:
        log(f"{spec.label} Snap uninstall returned exit code {format_exit_code(code)}.")
    return code == 0


def _uninstall_gui_app_brew_cask(spec: GuiAppSpec, log: Callable[[str], None]) -> bool:
    if not spec.macos_brew_cask:
        return False
    ok, detail = brew_uninstall(spec.macos_brew_cask, log, cask=True)
    if not ok:
        log(f"{spec.label} Homebrew cask uninstall failed: {detail}")
    return ok


def _uninstall_gui_app_browser_shortcut(spec: GuiAppSpec, log: Callable[[str], None]) -> bool:
    url = _gui_app_browser_url_for_platform(spec)
    if not url:
        return False
    removed_any = False
    for path in _gui_app_browser_shortcut_paths(spec):
        if not os.path.isfile(path):
            continue
        try:
            os.remove(path)
            removed_any = True
            log(f"Removed browser shortcut: {path}")
        except OSError as exc:
            log(f"Warning: failed to remove browser shortcut {path}: {exc}")
            return False
    if is_linux() and removed_any:
        update_desktop_database_for_user(log)
    return True


def install_gui_app(spec: GuiAppSpec, log: Callable[[str], None]) -> bool:
    if is_windows():
        if spec.winget_id and _install_gui_app_winget(spec, log):
            return True
        if _install_gui_app_browser_shortcut(spec, log):
            return True
        log(f"{spec.label}: No Windows install method available. Please install it manually from the app's website.")
        return False
    if is_macos():
        if spec.macos_brew_cask and _install_gui_app_brew_cask(spec, log):
            return True
        if _install_gui_app_browser_shortcut(spec, log):
            return True
        log(f"{spec.label}: No macOS install method available. Please install it manually from the app's website.")
        return False
    if is_linux():
        if spec.flatpak_id and _install_gui_app_flatpak(spec, log):
            return True
        if spec.snap_name and _install_gui_app_snap(spec, log):
            return True
        if _install_gui_app_browser_shortcut(spec, log):
            return True
        log(f"{spec.label}: No Linux install method available. Please install it manually from the app's website.")
        return False
    log(f"{spec.label}: Unsupported platform.")
    return False


def uninstall_gui_app(spec: GuiAppSpec, log: Callable[[str], None]) -> bool:
    attempted = False
    if is_windows():
        if spec.winget_id:
            attempted = True
            _uninstall_gui_app_winget(spec, log)
        if _gui_app_browser_url_for_platform(spec):
            attempted = True
            _uninstall_gui_app_browser_shortcut(spec, log)
    elif is_macos():
        if spec.macos_brew_cask:
            attempted = True
            _uninstall_gui_app_brew_cask(spec, log)
        if _gui_app_browser_url_for_platform(spec):
            attempted = True
            _uninstall_gui_app_browser_shortcut(spec, log)
    elif is_linux():
        if spec.flatpak_id:
            attempted = True
            _uninstall_gui_app_flatpak(spec, log)
        if spec.snap_name:
            attempted = True
            _uninstall_gui_app_snap(spec, log)
        if _gui_app_browser_url_for_platform(spec):
            attempted = True
            _uninstall_gui_app_browser_shortcut(spec, log)
    else:
        log(f"{spec.label}: Unsupported platform.")
        return False

    if not attempted:
        log(f"{spec.label}: No uninstall method available.")
        return False
    if is_gui_app_installed(spec):
        log(f"{spec.label} still appears installed after uninstall attempt.")
        return False
    log(f"Uninstall completed for {spec.label}.")
    return True


def try_install_package_candidates(
    npm_exe: str,
    spec: CliSpec,
    log: Callable[[str], None],
) -> tuple[bool, Optional[str]]:
    last_error: Optional[str] = None
    for package_name in spec.package_candidates:
        is_claude_package = package_name == CLAUDE_NPM_PACKAGE
        if is_claude_package:
            repair_claude_after_failed_update(npm_exe, log)
        for attempt in range(1, NPM_INSTALL_MAX_ATTEMPTS + 1):
            suffix = "" if attempt == 1 else f" (attempt {attempt}/{NPM_INSTALL_MAX_ATTEMPTS})"
            log(f"Trying npm package for {spec.label}: {package_name}{suffix}")
            code = npm_install_global(npm_exe, package_name, log)
            claude_repaired = False
            if is_claude_package:
                claude_repaired = repair_claude_after_failed_update(npm_exe, log)
            if code == 0:
                if is_claude_package and is_windows() and not claude_repaired:
                    last_error = f"{package_name} installed, but claude.exe was not found"
                    log(last_error)
                    break
                return (True, package_name)
            if claude_repaired:
                log(
                    "Warning: Claude CLI install/update failed, but an existing "
                    "claude.exe was restored. Continuing with the recovered installation."
                )
                return (True, package_name)

            if attempt < NPM_INSTALL_MAX_ATTEMPTS and is_probably_windows_errno_exit_code(code):
                log(
                    "Transient npm install failure detected (possible Windows file lock). "
                    + f"Retrying in {NPM_INSTALL_RETRY_DELAY_SECONDS:.0f}s..."
                )
                time.sleep(NPM_INSTALL_RETRY_DELAY_SECONDS)
                continue

            last_error = f"{package_name} failed with exit code {format_exit_code(code)}"
            log(last_error)
            break
    return (False, last_error)


def try_install_openclaw_official_macos(
    spec: CliSpec,
    log: Callable[[str], None],
) -> tuple[bool, Optional[str]]:
    ensure_homebrew(log)
    required = spec.macos_requires_node_version or (spec.macos_requires_node_major or 22, 0, 0)
    ensure_node_via_brew(log, required[0], min_version=required)
    url = spec.macos_official_install_url or OPENCLAW_INSTALL_URL
    log("Installing OpenClaw using the official macOS/Linux installer...")
    code = run_command(["/bin/bash", "-c", f"curl -fsSL {url} | /bin/bash -s -- --no-onboard"], log)
    if code == 0:
        return (True, OPENCLAW_NPM_PACKAGE)
    return (False, f"OpenClaw official installer failed with exit code {format_exit_code(code)}")


def try_install_macos_cli(
    spec: CliSpec,
    log: Callable[[str], None],
) -> tuple[bool, Optional[str]]:
    try:
        if spec.macos_brew_cask:
            return brew_install_or_upgrade(spec.macos_brew_cask, log, cask=True)
        if spec.macos_brew_formula:
            return brew_install_or_upgrade(spec.macos_brew_formula, log, cask=False)
        if spec.macos_official_install_url:
            return try_install_openclaw_official_macos(spec, log)
        if spec.macos_requires_node_major:
            required = spec.macos_requires_node_version or (spec.macos_requires_node_major, 0, 0)
            ensure_node_via_brew(log, required[0], min_version=required)
    except RuntimeError as exc:
        err = str(exc)
        log(err)
        return (False, err)

    npm_exe = find_npm()
    if not npm_exe:
        err = "npm was not found. Install Node.js/npm with Homebrew before installing this CLI."
        log(err)
        return (False, err)
    return try_install_package_candidates(npm_exe, spec, log)


def try_uninstall_package_candidates(
    npm_exe: str,
    spec: CliSpec,
    log: Callable[[str], None],
) -> tuple[bool, Optional[str]]:
    last_error: Optional[str] = None
    saw_success = False
    for package_name in spec.package_candidates:
        for attempt in range(1, NPM_INSTALL_MAX_ATTEMPTS + 1):
            suffix = "" if attempt == 1 else f" (attempt {attempt}/{NPM_INSTALL_MAX_ATTEMPTS})"
            log(f"Trying npm package uninstall for {spec.label}: {package_name}{suffix}")
            code = npm_uninstall_global(npm_exe, package_name, log)
            if code == 0:
                saw_success = True
                break

            if attempt < NPM_INSTALL_MAX_ATTEMPTS and is_probably_windows_errno_exit_code(code):
                log(
                    "Transient npm uninstall failure detected (possible Windows file lock). "
                    + f"Retrying in {NPM_INSTALL_RETRY_DELAY_SECONDS:.0f}s..."
                )
                time.sleep(NPM_INSTALL_RETRY_DELAY_SECONDS)
                continue

            last_error = f"{package_name} uninstall failed with exit code {format_exit_code(code)}"
            log(last_error)
            break

    if saw_success:
        return (True, None)
    return (False, last_error)


def try_uninstall_macos_cli(
    spec: CliSpec,
    log: Callable[[str], None],
) -> tuple[bool, Optional[str]]:
    if spec.macos_brew_cask:
        return brew_uninstall(spec.macos_brew_cask, log, cask=True)
    if spec.macos_brew_formula:
        return brew_uninstall(spec.macos_brew_formula, log, cask=False)

    npm_exe = find_npm()
    if npm_exe:
        return try_uninstall_package_candidates(npm_exe, spec, log)

    command_path = resolve_command_path(spec.command_candidates, get_cli_bin_dirs(None, log))
    if not command_path:
        log(f"{spec.label} command was not found; treating as already uninstalled.")
        return (True, spec.package_candidates[0] if spec.package_candidates else None)
    err = "npm was not found. Cannot uninstall this macOS CLI automatically."
    log(err)
    return (False, err)


def resolve_command_path(
    command_candidates: tuple[str, ...],
    extra_dirs: list[str],
) -> Optional[str]:
    env = os.environ.copy()
    if extra_dirs:
        joined = os.pathsep.join(extra_dirs)
        env["PATH"] = joined + os.pathsep + env.get("PATH", "")

    for cmd in command_candidates:
        found = where_all(cmd, env=env)
        if found:
            priority_order = (".cmd", ".exe", ".bat", ".ps1") if is_windows() else (".sh", ".bin", "")
            for ext in priority_order:
                for candidate in found:
                    if ext:
                        if candidate.lower().endswith(ext):
                            return candidate
                    else:
                        return candidate
            return found[0]

    for d in extra_dirs:
        for cmd in command_candidates:
            ext_candidates = (".cmd", ".exe", ".bat", ".ps1") if is_windows() else (".sh", ".bin")
            for ext in ext_candidates:
                candidate = os.path.join(d, cmd + ext)
                if os.path.isfile(candidate):
                    return candidate
            direct = os.path.join(d, cmd)
            if os.path.isfile(direct):
                return direct
    return None


def find_linux_terminal_emulator() -> Optional[str]:
    """Return an Exec-ready prefix for launching a command in a terminal window."""
    candidates = [
        ("ptyxis", "ptyxis -- {cmd}"),
        ("kgx", "kgx -- {cmd}"),
        ("gnome-terminal", "gnome-terminal -- {cmd}"),
        ("xfce4-terminal", "xfce4-terminal -x {cmd}"),
        ("konsole", "konsole -e {cmd}"),
        ("xterm", "xterm -e {cmd}"),
    ]
    for binary, template in candidates:
        if shutil.which(binary):
            return template
    return None


def create_linux_desktop_shortcut(
    shortcut_path: str,
    command_path: str,
    terminal_title: str,
    comment: str = "",
    icon: str = "utilities-terminal",
) -> None:
    os.makedirs(os.path.dirname(shortcut_path), exist_ok=True)
    terminal_template = find_linux_terminal_emulator()
    if terminal_template:
        exec_value = terminal_template.format(cmd=command_path)
        use_terminal_flag = False
    else:
        exec_value = command_path
        use_terminal_flag = True
    lines = [
        "[Desktop Entry]",
        "Type=Application",
        f"Name={terminal_title}",
    ]
    if comment:
        lines.append(f"Comment={comment}")
    lines += [
        f"Exec={exec_value}",
        f"Icon={icon}",
    ]
    if use_terminal_flag:
        lines.append("Terminal=true")
    lines += [
        "Categories=Development;",
        "StartupNotify=false",
    ]
    write_text_file(shortcut_path, "\n".join(lines) + "\n")
    os.chmod(shortcut_path, 0o755)


def create_macos_command_shortcut(
    shortcut_path: str,
    command_path: str,
    terminal_title: str,
) -> None:
    os.makedirs(os.path.dirname(shortcut_path), exist_ok=True)
    lines = [
        "#!/bin/zsh",
        f"# {terminal_title}",
        "cd ~",
        f"exec {shlex.quote(command_path)}",
    ]
    write_text_file(shortcut_path, "\n".join(lines) + "\n")
    os.chmod(shortcut_path, 0o755)


def update_desktop_database_for_user(log: Callable[[str], None]) -> None:
    apps_dir = os.path.join(os.path.expanduser("~"), ".local", "share", "applications")
    if shutil.which("update-desktop-database"):
        try:
            subprocess.run(
                ["update-desktop-database", apps_dir],
                capture_output=True,
                **subprocess_creationflags_kwargs(),
            )
            log("Updated desktop application database.")
        except OSError:
            pass
    # Reset GNOME Shell's cached app-picker layout so new apps appear in the grid.
    # GNOME Shell keeps a hardcoded layout in dconf; new .desktop files are invisible
    # until this is cleared and the shell regenerates it (happens at next login or
    # when the app grid is first opened after the reset).
    if shutil.which("gsettings"):
        try:
            subprocess.run(
                ["gsettings", "set", "org.gnome.shell", "app-picker-layout", "[]"],
                capture_output=True,
                **subprocess_creationflags_kwargs(),
            )
            log("Cleared GNOME app grid cache — new shortcuts will appear after re-opening the app grid or logging out and back in.")
        except OSError:
            pass


def create_cli_desktop_shortcut(
    spec: CliSpec,
    command_path: str,
    log: Callable[[str], None],
) -> str:
    desktop = find_desktop_directory()
    if is_macos():
        shortcut_path = os.path.join(desktop, f"{spec.shortcut_name}.command")
        create_macos_command_shortcut(shortcut_path, command_path, spec.shortcut_name)
        log(f"Created desktop command shortcut: {shortcut_path}")
        return shortcut_path

    if not is_windows():
        shortcut_path = os.path.join(desktop, f"{spec.shortcut_name}.desktop")
        create_linux_desktop_shortcut(shortcut_path, command_path, spec.shortcut_name, comment=spec.help_text)
        log(f"Created desktop shortcut: {shortcut_path}")
        # Also install to XDG applications dir so the app appears in the system menu.
        apps_dir = os.path.join(os.path.expanduser("~"), ".local", "share", "applications")
        menu_path = os.path.join(apps_dir, f"installcli-{spec.key}.desktop")
        create_linux_desktop_shortcut(menu_path, command_path, spec.shortcut_name, comment=spec.help_text)
        log(f"Created menu entry: {menu_path}")
        return shortcut_path

    shortcut_path = os.path.join(desktop, f"{spec.shortcut_name}.lnk")
    cmd_exe = os.environ.get("ComSpec", r"C:\Windows\System32\cmd.exe")
    arguments = f'/k "{command_path}"'
    working_dir = os.path.expanduser("~")
    icon = f"{cmd_exe},0"
    create_windows_shortcut(
        shortcut_path=shortcut_path,
        target_path=cmd_exe,
        arguments=arguments,
        working_directory=working_dir,
        icon_location=icon,
    )
    log(f"Created desktop shortcut: {shortcut_path}")
    return shortcut_path


def remove_cli_desktop_shortcuts(spec: CliSpec, log: Callable[[str], None]) -> None:
    desktop = find_desktop_directory()
    paths: list[str] = []
    if is_windows():
        paths.append(os.path.join(desktop, f"{spec.shortcut_name}.lnk"))
    elif is_macos():
        paths.append(os.path.join(desktop, f"{spec.shortcut_name}.command"))
    else:
        paths.append(os.path.join(desktop, f"{spec.shortcut_name}.desktop"))
        paths.append(
            os.path.join(
                os.path.expanduser("~"),
                ".local",
                "share",
                "applications",
                f"installcli-{spec.key}.desktop",
            )
        )

    removed_any = False
    for path in paths:
        try:
            if os.path.isfile(path):
                os.remove(path)
                log(f"Removed shortcut: {path}")
                removed_any = True
        except OSError as exc:
            log(f"Warning: Could not remove shortcut {path}: {exc}")

    if is_linux() and removed_any:
        update_desktop_database_for_user(log)


class InstallerFrame(wx.Frame):
    def __init__(self) -> None:  # pragma: no cover
        platform_label = platform_display_name()
        super().__init__(None, title=f"AI CLI Installer ({platform_label})", size=(920, 820))
        self.worker_thread: Optional[threading.Thread] = None
        self._persistent_log_path: Optional[str] = None
        self._persistent_log_write_warning_shown = False
        self._reset_persistent_log_for_new_run()
        self._build_ui()
        self.Centre()
        # Auto-upgrade an existing hidden auto-update task to the current
        # updater logic. This is fully automatic on app open: if the user
        # already has the task from an older InstallTheCli release, we
        # rewrite the embedded updater script and re-register the task in
        # place. Failures are non-fatal and only logged.
        try:
            refresh_existing_cli_auto_update_task(self.log)
        except Exception as exc:  # noqa: BLE001 -- never block GUI startup
            self.log(f"Auto-update task refresh skipped on startup: {exc}")

    def _build_ui(self) -> None:  # pragma: no cover
        panel = wx.Panel(self)
        root = wx.BoxSizer(wx.VERTICAL)

        title_platform = platform_display_name()
        title = wx.StaticText(panel, label=f"Install AI CLI tools on {title_platform}")
        title_font = title.GetFont()
        title_font.MakeBold()
        title_font.PointSize += 2
        title.SetFont(title_font)
        title.SetName("Installer Title")
        root.Add(title, 0, wx.ALL, 12)

        note_lines = [
            (
                "This installer uses winget for Node.js/Ollama, npm for most CLI tools, and uv/pip for Mistral Vibe."
                if is_windows()
                else (
                    "This installer uses Homebrew for macOS formulas/casks, npm only where no brew package exists, and official installers where required."
                    if is_macos()
                    else "This installer uses your Linux package manager for Node.js/npm, the official Ollama install script, npm for most CLI tools, and uv/pip for Mistral Vibe."
                )
            ),
            "Use Tab and Enter/Space to run install/uninstall actions for each CLI, or use Install All.",
            "Run as Administrator/root if you want system-level installs and PATH updates to succeed.",
        ]
        note = wx.StaticText(panel, label="\n".join(note_lines))
        note.Wrap(860)
        note.SetName("Instructions")
        root.Add(note, 0, wx.LEFT | wx.RIGHT | wx.BOTTOM, 12)

        admin_label_name = "Administrator" if is_windows() else ("User install" if is_macos() else "Root")
        admin_text = (
            "macOS Homebrew/user install"
            if is_macos()
            else (f"{admin_label_name}: Yes" if is_admin() else f"{admin_label_name}: No (system PATH may fail)")
        )
        self.admin_label = wx.StaticText(panel, label=admin_text)
        self.admin_label.SetName("Admin Status")
        root.Add(self.admin_label, 0, wx.LEFT | wx.RIGHT | wx.BOTTOM, 12)

        box = wx.StaticBox(panel, label="Install or uninstall CLI tools")
        box_sizer = wx.StaticBoxSizer(box, wx.VERTICAL)

        self.cli_action_buttons: dict[str, wx.Button] = {}
        self.cli_installed_state: dict[str, bool] = {spec.key: False for spec in CLI_SPECS}
        for spec in CLI_SPECS:
            row = wx.BoxSizer(wx.HORIZONTAL)
            label = wx.StaticText(box, label=spec.label)
            label.SetToolTip(spec.help_text)
            action_btn = wx.Button(box, label=f"Install {spec.label}")
            action_btn.SetName(f"{spec.label} Action")
            action_btn.SetToolTip(spec.help_text)
            action_btn.Bind(wx.EVT_BUTTON, lambda _evt, cli_key=spec.key: self.on_cli_action(cli_key))
            row.Add(label, 1, wx.ALIGN_CENTER_VERTICAL | wx.RIGHT, 8)
            row.Add(action_btn, 0)
            box_sizer.Add(row, 0, wx.ALL | wx.EXPAND, 6)
            self.cli_action_buttons[spec.key] = action_btn

        root.Add(box_sizer, 0, wx.LEFT | wx.RIGHT | wx.EXPAND | wx.BOTTOM, 12)

        app_box = wx.StaticBox(panel, label="Install or uninstall AI desktop apps (Windows: winget/browser; macOS: Homebrew/browser; Linux: Flatpak/Snap/browser)")
        app_box_sizer = wx.StaticBoxSizer(app_box, wx.VERTICAL)

        self.gui_app_action_buttons: dict[str, wx.Button] = {}
        self.gui_app_installed_state: dict[str, bool] = {spec.key: False for spec in GUI_APP_SPECS}
        for app_spec in GUI_APP_SPECS:
            row = wx.BoxSizer(wx.HORIZONTAL)
            label = wx.StaticText(app_box, label=app_spec.label)
            label.SetToolTip(app_spec.help_text)
            action_btn = wx.Button(app_box, label=f"Install {app_spec.label}")
            action_btn.SetName(f"{app_spec.label} Action")
            action_btn.SetToolTip(app_spec.help_text)
            action_btn.Bind(wx.EVT_BUTTON, lambda _evt, app_key=app_spec.key: self.on_gui_app_action(app_key))
            row.Add(label, 1, wx.ALIGN_CENTER_VERTICAL | wx.RIGHT, 8)
            row.Add(action_btn, 0)
            app_box_sizer.Add(row, 0, wx.ALL | wx.EXPAND, 6)
            self.gui_app_action_buttons[app_spec.key] = action_btn

        root.Add(app_box_sizer, 0, wx.LEFT | wx.RIGHT | wx.EXPAND | wx.BOTTOM, 12)

        self.auto_update_checkbox = wx.CheckBox(
            panel,
            label="Enable hidden auto-update task (startup/logon/daily where supported)",
        )
        self.auto_update_checkbox.SetName("Auto Update Toggle")
        self.auto_update_checkbox.SetValue(True)
        self.auto_update_checkbox.SetToolTip(
            "When enabled, a hidden scheduled task updates installed AI CLIs through Task Scheduler or launchd."
        )
        root.Add(self.auto_update_checkbox, 0, wx.LEFT | wx.RIGHT | wx.BOTTOM, 12)

        btn_row = wx.BoxSizer(wx.HORIZONTAL)
        self.install_all_btn = wx.Button(panel, label="Install &All")
        self.install_btn = wx.Button(panel, label="Install Apps &All")
        self.close_btn = wx.Button(panel, label="&Close")

        self.install_all_btn.Bind(wx.EVT_BUTTON, self.on_install_all_toggle)
        self.install_btn.Bind(wx.EVT_BUTTON, self.on_install_all_apps_toggle)
        self.close_btn.Bind(wx.EVT_BUTTON, self.on_close)

        btn_row.Add(self.install_all_btn, 0, wx.RIGHT, 8)
        btn_row.Add(self.install_btn, 0, wx.RIGHT, 8)
        btn_row.AddStretchSpacer(1)
        btn_row.Add(self.close_btn, 0)
        root.Add(btn_row, 0, wx.LEFT | wx.RIGHT | wx.EXPAND | wx.BOTTOM, 12)

        self.status_label = wx.StaticText(panel, label="Status: Ready")
        self.status_label.SetName("Current Status")
        root.Add(self.status_label, 0, wx.LEFT | wx.RIGHT | wx.BOTTOM, 8)

        self.gauge = wx.Gauge(panel, range=100, style=wx.GA_HORIZONTAL)
        self.gauge.SetValue(0)
        root.Add(self.gauge, 0, wx.LEFT | wx.RIGHT | wx.EXPAND | wx.BOTTOM, 12)

        log_label = wx.StaticText(panel, label="Installation Log")
        log_label.SetName("Log Label")
        root.Add(log_label, 0, wx.LEFT | wx.RIGHT | wx.BOTTOM, 4)

        self.log_ctrl = wx.TextCtrl(
            panel,
            style=wx.TE_MULTILINE | wx.TE_READONLY | wx.TE_DONTWRAP | wx.HSCROLL | wx.TE_RICH2,
        )
        self.log_ctrl.SetName("Installation Log")
        self.log_ctrl.SetMinSize((-1, 260))
        root.Add(self.log_ctrl, 1, wx.LEFT | wx.RIGHT | wx.BOTTOM | wx.EXPAND, 12)

        panel.SetSizer(root)
        self.install_all_btn.SetDefault()
        self.refresh_cli_action_buttons()
        self.refresh_gui_app_action_buttons()

    def log(self, message: str) -> None:
        wx.CallAfter(self._append_log, message)

    def _reset_persistent_log_for_new_run(self) -> None:
        self._persistent_log_path = reset_gui_last_run_log()
        self._persistent_log_write_warning_shown = False

    def _append_log(self, message: str) -> None:
        self.log_ctrl.AppendText(message + "\n")
        self.log_ctrl.ShowPosition(self.log_ctrl.GetLastPosition())
        err = append_persistent_log_line(getattr(self, "_persistent_log_path", None), message)
        if err and not getattr(self, "_persistent_log_write_warning_shown", False):
            self._persistent_log_write_warning_shown = True
            warning = f"Persistent log write warning: {err}"
            self.log_ctrl.AppendText(warning + "\n")
            self.log_ctrl.ShowPosition(self.log_ctrl.GetLastPosition())

    def set_status(self, text: str) -> None:
        wx.CallAfter(self.status_label.SetLabel, f"Status: {text}")

    def set_gauge(self, value: int) -> None:
        value = max(0, min(100, value))
        wx.CallAfter(self.gauge.SetValue, value)

    def set_busy(self, busy: bool) -> None:
        def _apply() -> None:
            self.install_btn.Enable(not busy)
            install_all_btn = getattr(self, "install_all_btn", None)
            if install_all_btn is not None:
                install_all_btn.Enable(not busy)
            for btn in getattr(self, "cli_action_buttons", {}).values():
                btn.Enable(not busy)
            for btn in getattr(self, "gui_app_action_buttons", {}).values():
                btn.Enable(not busy)
            if busy:
                self.gauge.Pulse()
        wx.CallAfter(_apply)

    def _detection_log(self, _message: str) -> None:
        return None

    def _get_cli_detection_dirs(self) -> list[str]:
        npm_exe = find_npm()
        dirs = get_cli_bin_dirs(npm_exe, self._detection_log)
        dirs = dedupe_preserve_order(dirs + get_python_cli_bin_dirs(self._detection_log))
        dirs = dedupe_preserve_order(dirs + get_ollama_cli_bin_dirs(self._detection_log))
        return dirs

    def _is_cli_installed(self, spec: CliSpec, cli_dirs: Optional[list[str]] = None) -> bool:
        if spec.key == "ollama":
            return bool(find_ollama())
        dirs = cli_dirs if cli_dirs is not None else self._get_cli_detection_dirs()
        return bool(resolve_command_path(spec.command_candidates, dirs))

    def _all_clis_installed(self) -> bool:
        return bool(CLI_SPECS) and all(self.cli_installed_state.get(spec.key, False) for spec in CLI_SPECS)

    def _all_gui_apps_installed(self) -> bool:
        return bool(GUI_APP_SPECS) and all(self.gui_app_installed_state.get(spec.key, False) for spec in GUI_APP_SPECS)

    def refresh_cli_action_buttons(self) -> None:
        cli_dirs = self._get_cli_detection_dirs()
        for spec in CLI_SPECS:
            installed = self._is_cli_installed(spec, cli_dirs)
            self.cli_installed_state[spec.key] = installed
            button = self.cli_action_buttons.get(spec.key)
            if button is not None:
                action = "Uninstall" if installed else "Install"
                button.SetLabel(f"{action} {spec.label}")

        install_all_btn = getattr(self, "install_all_btn", None)
        if install_all_btn is not None:
            install_all_btn.SetLabel("&Uninstall All" if self._all_clis_installed() else "Install &All")

    def refresh_gui_app_action_buttons(self) -> None:
        for spec in GUI_APP_SPECS:
            installed = is_gui_app_installed(spec)
            self.gui_app_installed_state[spec.key] = installed
            button = self.gui_app_action_buttons.get(spec.key)
            if button is not None:
                action = "Uninstall" if installed else "Install"
                button.SetLabel(f"{action} {spec.label}")

        install_apps_btn = getattr(self, "install_btn", None)
        if install_apps_btn is not None:
            install_apps_btn.SetLabel("&Uninstall All Apps" if self._all_gui_apps_installed() else "Install Apps &All")

    def on_close(self, _event: wx.CommandEvent) -> None:
        if self.worker_thread and self.worker_thread.is_alive():
            wx.MessageBox(
                "An install/uninstall workflow is still running. Wait for it to finish before closing.",
                "Workflow In Progress",
                wx.OK | wx.ICON_INFORMATION,
                self,
            )
            return
        self.Close()

    def _prepare_for_worker_run(self) -> bool:
        if self.worker_thread and self.worker_thread.is_alive():
            return False

        self._askpass_script: Optional[str] = None
        if is_linux() and not is_admin() and _sudo_needs_password():
            password = self._prompt_sudo_password()
            if not password:
                return False
            try:
                self._askpass_script = _create_sudo_askpass_script(password)
                os.environ["SUDO_ASKPASS"] = self._askpass_script
            except Exception as exc:
                wx.MessageBox(
                    f"Failed to set up sudo authentication: {exc}",
                    "Error",
                    wx.OK | wx.ICON_ERROR,
                    self,
                )
                return False

        self.log_ctrl.Clear()
        reset_log = getattr(self, "_reset_persistent_log_for_new_run", None)
        if callable(reset_log):
            reset_log()
        self.set_status("Starting...")
        self.set_gauge(0)
        self.set_busy(True)
        return True

    def _auto_update_enabled(self) -> bool:
        auto_update_enabled = True
        auto_update_cb = getattr(self, "auto_update_checkbox", None)
        if auto_update_cb is not None and hasattr(auto_update_cb, "GetValue"):
            auto_update_enabled = bool(auto_update_cb.GetValue())
        return auto_update_enabled

    def _start_worker(self, target: Callable[..., None], args: tuple[object, ...]) -> None:
        self.worker_thread = threading.Thread(
            target=target,
            args=args,
            daemon=True,
        )
        self.worker_thread.start()

    def on_cli_action(self, cli_key: str) -> None:
        if self.worker_thread and self.worker_thread.is_alive():
            return

        spec = next((item for item in CLI_SPECS if item.key == cli_key), None)
        if spec is None:
            return
        installed = self.cli_installed_state.get(spec.key, self._is_cli_installed(spec))
        action = "uninstall" if installed else "install"
        enable_auto_update = self._auto_update_enabled()

        if not self._prepare_for_worker_run():
            return
        self._start_worker(
            self._cli_action_worker,
            (action, [spec], enable_auto_update),
        )

    def on_install_all_toggle(self, _event: wx.CommandEvent) -> None:
        if self.worker_thread and self.worker_thread.is_alive():
            return

        self.refresh_cli_action_buttons()
        install_all = not self._all_clis_installed()
        action = "install" if install_all else "uninstall"
        if install_all:
            selected = [spec for spec in CLI_SPECS if not self.cli_installed_state.get(spec.key, False)]
        else:
            selected = [spec for spec in CLI_SPECS if self.cli_installed_state.get(spec.key, False)]

        if not selected:
            wx.MessageBox(
                ("All supported CLI tools are already installed." if install_all else "No installed CLI tools were detected."),
                "Nothing To Do",
                wx.OK | wx.ICON_INFORMATION,
                self,
            )
            return

        if not self._prepare_for_worker_run():
            return
        self._start_worker(
            self._cli_action_worker,
            (action, selected, self._auto_update_enabled()),
        )

    def on_gui_app_action(self, app_key: str) -> None:
        if self.worker_thread and self.worker_thread.is_alive():
            return

        spec = next((item for item in GUI_APP_SPECS if item.key == app_key), None)
        if spec is None:
            return
        installed = self.gui_app_installed_state.get(spec.key, is_gui_app_installed(spec))
        action = "uninstall" if installed else "install"

        if not self._prepare_for_worker_run():
            return

        self._start_worker(
            self._gui_app_action_worker,
            (action, [spec]),
        )

    def on_install_all_apps_toggle(self, _event: wx.CommandEvent) -> None:
        if self.worker_thread and self.worker_thread.is_alive():
            return

        self.refresh_gui_app_action_buttons()
        install_all = not self._all_gui_apps_installed()
        action = "install" if install_all else "uninstall"
        if install_all:
            selected_apps = [spec for spec in GUI_APP_SPECS if not self.gui_app_installed_state.get(spec.key, False)]
        else:
            selected_apps = [spec for spec in GUI_APP_SPECS if self.gui_app_installed_state.get(spec.key, False)]

        if not selected_apps:
            wx.MessageBox(
                ("All supported desktop apps are already installed." if install_all else "No installed desktop apps were detected."),
                "Nothing To Do",
                wx.OK | wx.ICON_INFORMATION,
                self,
            )
            return

        if not self._prepare_for_worker_run():
            return

        self._start_worker(
            self._gui_app_action_worker,
            (action, selected_apps),
        )

    def on_install(self, event: wx.CommandEvent) -> None:
        InstallerFrame.on_install_all_apps_toggle(self, event)

    def on_install_apps(self, event: wx.CommandEvent) -> None:
        InstallerFrame.on_install_all_apps_toggle(self, event)

    def _prompt_sudo_password(self) -> Optional[str]:  # pragma: no cover
        dlg = wx.PasswordEntryDialog(
            self,
            "Enter your sudo password to install packages as root:",
            "Sudo Password Required",
        )
        result = dlg.ShowModal()
        value = dlg.GetValue() if result == wx.ID_OK else None
        dlg.Destroy()
        return value

    def _cleanup_askpass(self) -> None:
        script = getattr(self, "_askpass_script", None)
        if script:
            try:
                os.unlink(script)
            except OSError:
                pass
            self._askpass_script = None
        os.environ.pop("SUDO_ASKPASS", None)

    def _install_worker(
        self,
        selected: list[CliSpec],
        selected_apps: Optional[list[GuiAppSpec]] = None,
        enable_auto_update: bool = True,
    ) -> None:
        chosen_apps = selected_apps or []
        try:
            if selected:
                self._run_install(selected, enable_auto_update)
            if chosen_apps:
                self._run_gui_apps_install(chosen_apps)
            self.log("Installation workflow complete.")
            self.set_status("Complete")
            self.set_gauge(100)
        except Exception as exc:
            self.log(f"ERROR: {exc}")
            self.log(traceback.format_exc().rstrip())
            self.set_status("Failed")
        finally:
            self.set_busy(False)
            cleanup = getattr(self, "_cleanup_askpass", None)
            if callable(cleanup):
                cleanup()
            refresh_cli = getattr(self, "refresh_cli_action_buttons", None)
            if callable(refresh_cli):
                wx.CallAfter(refresh_cli)
            refresh_apps = getattr(self, "refresh_gui_app_action_buttons", None)
            if callable(refresh_apps):
                wx.CallAfter(refresh_apps)

    def _cli_action_worker(
        self,
        action: str,
        selected: list[CliSpec],
        enable_auto_update: bool = True,
    ) -> None:
        try:
            if action == "install":
                self._run_install(selected, enable_auto_update)
                self.log("CLI installation workflow complete.")
            elif action == "uninstall":
                self._run_uninstall(selected)
                self.log("CLI uninstall workflow complete.")
            else:
                raise RuntimeError(f"Unsupported CLI action: {action}")
            self.set_status("Complete")
            self.set_gauge(100)
        except Exception as exc:
            self.log(f"ERROR: {exc}")
            self.log(traceback.format_exc().rstrip())
            self.set_status("Failed")
        finally:
            self.set_busy(False)
            cleanup = getattr(self, "_cleanup_askpass", None)
            if callable(cleanup):
                cleanup()
            refresh_cli = getattr(self, "refresh_cli_action_buttons", None)
            if callable(refresh_cli):
                wx.CallAfter(refresh_cli)
            refresh_apps = getattr(self, "refresh_gui_app_action_buttons", None)
            if callable(refresh_apps):
                wx.CallAfter(refresh_apps)

    def _gui_app_action_worker(
        self,
        action: str,
        selected_apps: list[GuiAppSpec],
    ) -> None:
        try:
            if action == "install":
                self._run_gui_apps_install(selected_apps)
                self.log("Desktop app installation workflow complete.")
            elif action == "uninstall":
                self._run_gui_apps_uninstall(selected_apps)
                self.log("Desktop app uninstall workflow complete.")
            else:
                raise RuntimeError(f"Unsupported desktop-app action: {action}")
            self.set_status("Complete")
            self.set_gauge(100)
        except Exception as exc:
            self.log(f"ERROR: {exc}")
            self.log(traceback.format_exc().rstrip())
            self.set_status("Failed")
        finally:
            self.set_busy(False)
            cleanup = getattr(self, "_cleanup_askpass", None)
            if callable(cleanup):
                cleanup()
            refresh_cli = getattr(self, "refresh_cli_action_buttons", None)
            if callable(refresh_cli):
                wx.CallAfter(refresh_cli)
            refresh_apps = getattr(self, "refresh_gui_app_action_buttons", None)
            if callable(refresh_apps):
                wx.CallAfter(refresh_apps)

    def _run_gui_apps_install(self, selected_apps: list[GuiAppSpec]) -> None:
        total = len(selected_apps)
        any_installed = False
        for index, app_spec in enumerate(selected_apps, start=1):
            pct = int((index - 1) / max(total, 1) * 80) + 10
            self.set_gauge(pct)
            self.set_status(f"Installing {app_spec.label} ({index}/{total})")
            success = install_gui_app(app_spec, self.log)
            if success:
                any_installed = True
            else:
                self.log(f"Warning: Could not install {app_spec.label}.")
        if is_linux() and any_installed:
            update_desktop_database_for_user(self.log)

    def _run_gui_apps_uninstall(self, selected_apps: list[GuiAppSpec]) -> None:
        total = len(selected_apps)
        any_uninstalled = False
        for index, app_spec in enumerate(selected_apps, start=1):
            pct = int((index - 1) / max(total, 1) * 80) + 10
            self.set_gauge(pct)
            self.set_status(f"Uninstalling {app_spec.label} ({index}/{total})")
            success = uninstall_gui_app(app_spec, self.log)
            if success:
                any_uninstalled = True
            else:
                if app_spec.optional:
                    self.log(f"Warning: Could not uninstall optional {app_spec.label}.")
                    continue
                raise RuntimeError(f"Failed to uninstall {app_spec.label}.")
        if is_linux() and any_uninstalled:
            update_desktop_database_for_user(self.log)

    def _run_uninstall(self, selected: list[CliSpec]) -> None:
        self.log(f"{platform_display_name()} AI CLI Uninstaller started.")
        persistent_log_path = getattr(self, "_persistent_log_path", None)
        if persistent_log_path:
            self.log(f"Persistent log file: {persistent_log_path}")
        self.log(f"Administrator mode: {'Yes' if is_admin() else 'No'}")

        if not selected:
            self.log("No CLI tools selected for uninstall.")
            return

        needs_npm = any(spec.key not in ("mistral", "ollama") for spec in selected) and not is_macos()
        npm_exe: Optional[str] = None
        if needs_npm:
            self.set_status("Locating npm")
            self.set_gauge(10)
            npm_exe = find_npm()
            if not npm_exe:
                raise RuntimeError("npm was not found. Install Node.js/npm before uninstalling npm-based CLIs.")
            self.log(f"Using npm executable: {npm_exe}")

        removed_npm_packages: list[str] = []
        total = len(selected)
        for index, spec in enumerate(selected, start=1):
            pct = 15 + int((index - 1) / max(total, 1) * 70)
            self.set_gauge(pct)
            self.set_status(f"Uninstalling {spec.label} ({index}/{total})")

            if is_macos():
                if spec.key == "mistral":
                    success, detail = try_uninstall_mistral_vibe(spec, self.log)
                elif spec.key == "ollama":
                    success, detail = try_uninstall_ollama(self.log)
                else:
                    success, detail = try_uninstall_macos_cli(spec, self.log)
            elif spec.key == "mistral":
                success, detail = try_uninstall_mistral_vibe(spec, self.log)
            elif spec.key == "ollama":
                success, detail = try_uninstall_ollama(self.log)
            else:
                assert npm_exe is not None
                success, detail = try_uninstall_package_candidates(npm_exe, spec, self.log)

            if not success:
                if spec.optional:
                    self.log(f"Warning: Could not uninstall optional {spec.label}: {detail}")
                    continue
                raise RuntimeError(f"Failed to uninstall {spec.label}.")

            self.log(f"Uninstall completed for {spec.label}.")
            remove_cli_desktop_shortcuts(spec, self.log)
            if spec.key not in ("mistral", "ollama"):
                removed_npm_packages.extend(spec.package_candidates)

        if removed_npm_packages and is_windows():
            self.set_status("Updating auto-update package list")
            self.set_gauge(90)
            remaining = remove_cli_auto_update_packages(removed_npm_packages, self.log)
            if remaining:
                self.log("Remaining npm packages in auto-update list: " + ", ".join(remaining))
            else:
                self.log("No npm packages remain in auto-update list.")

        self.set_status("Finalizing")
        self.set_gauge(98)
        self.log("")
        self.log("CLI uninstall run complete.")

    def _run_install(self, selected: list[CliSpec], enable_auto_update: bool = True) -> None:
        self.log(f"{platform_display_name()} AI CLI Installer started.")
        persistent_log_path = getattr(self, "_persistent_log_path", None)
        if persistent_log_path:
            self.log(f"Persistent log file: {persistent_log_path}")
        self.log(f"Administrator mode: {'Yes' if is_admin() else 'No'}")
        if not is_admin() and not is_macos():
            self.log(
                "System PATH update may fail without Administrator/root privileges."
            )
        needs_python_cli_dirs = any(spec.key == "mistral" for spec in selected)
        needs_ollama_cli_dirs = any(spec.key == "ollama" for spec in selected)

        self.set_status("Checking/installing requirements")
        self.set_gauge(5)
        npm_exe: Optional[str] = None
        if is_macos():
            ensure_homebrew(self.log)
            required_node_versions = [
                spec.macos_requires_node_version or (spec.macos_requires_node_major or 20, 0, 0)
                for spec in selected
                if spec.macos_requires_node_major
                or (not spec.macos_brew_formula and not spec.macos_brew_cask and spec.key not in ("mistral", "ollama"))
            ]
            if required_node_versions:
                required = max(required_node_versions)
                ensure_node_via_brew(self.log, required[0], min_version=required)
            npm_exe = find_npm()
        else:
            ensure_node_via_winget(self.log)

        self.set_status("Locating npm")
        self.set_gauge(15)
        if npm_exe is None:
            npm_exe = find_npm()
        if not npm_exe and not is_macos():
            raise RuntimeError(
                "npm was not found after Node.js setup. Try closing and reopening the app, or install Node.js manually."
            )
        if npm_exe:
            self.log(f"Using npm executable: {npm_exe}")
        else:
            self.log("npm is not required for the selected macOS installs.")

        cli_bin_dirs = get_cli_bin_dirs(npm_exe, self.log)
        if needs_python_cli_dirs:
            cli_bin_dirs = dedupe_preserve_order(cli_bin_dirs + get_python_cli_bin_dirs(self.log))
        if needs_ollama_cli_dirs:
            cli_bin_dirs = dedupe_preserve_order(cli_bin_dirs + get_ollama_cli_bin_dirs(self.log))
        self.log("PATH directories to ensure: " + (", ".join(cli_bin_dirs) if cli_bin_dirs else "(none found yet)"))

        self.set_status("Updating user/system PATH")
        self.set_gauge(20)
        added_user, user_err = add_dirs_to_path("user", cli_bin_dirs)
        if user_err:
            self.log(f"User PATH update warning: {user_err}")
        elif added_user:
            self.log("Added to user PATH: " + ", ".join(added_user))
        else:
            self.log("User PATH already contains required directories.")

        system_path_dirs = filter_system_path_dirs(cli_bin_dirs)
        added_system, system_err = add_dirs_to_path("system", system_path_dirs)
        if system_err:
            self.log(f"System PATH update warning: {system_err}")
        elif added_system:
            self.log("Added to system PATH: " + ", ".join(added_system))
        else:
            self.log("System PATH already contains required directories.")

        total = len(selected)
        installed_commands: list[tuple[CliSpec, str]] = []
        installed_packages: list[str] = []

        for index, spec in enumerate(selected, start=1):
            pct = 20 + int((index - 1) / max(total, 1) * 60)
            self.set_gauge(pct)
            self.set_status(f"Installing {spec.label} ({index}/{total})")

            if is_macos():
                if spec.key == "mistral":
                    success, pkg = try_install_mistral_vibe(spec, self.log)
                elif spec.key == "ollama":
                    success, pkg = ensure_ollama_via_winget(self.log)
                else:
                    success, pkg = try_install_macos_cli(spec, self.log)
            elif spec.key == "mistral":
                success, pkg = try_install_mistral_vibe(spec, self.log)
            elif spec.key == "ollama":
                success, pkg = ensure_ollama_via_winget(self.log)
            else:
                success, pkg = try_install_package_candidates(npm_exe, spec, self.log)
            if not success:
                if spec.optional:
                    self.log(f"Skipping optional {spec.label}: no working install candidate.")
                    continue
                if is_probably_windows_file_lock_error(pkg):
                    cli_bin_dirs = get_cli_bin_dirs(npm_exe, self.log)
                    command_path = resolve_command_path(spec.command_candidates, cli_bin_dirs)
                    if command_path:
                        self.log(
                            f"Warning: {spec.label} install/update is blocked by a locked file "
                            "(likely a running CLI process). Using existing installation and continuing."
                        )
                        self.log(f"Resolved existing command path for {spec.label}: {command_path}")
                        installed_commands.append((spec, command_path))
                        if spec.package_candidates:
                            installed_packages.append(spec.package_candidates[0])
                        continue
                raise RuntimeError(f"Failed to install {spec.label}.")

            assert pkg is not None
            self.log(f"Installed {spec.label} using package {pkg}")
            if not is_macos() and spec.key not in ("mistral", "ollama"):
                installed_packages.append(pkg)

            cli_bin_dirs = get_cli_bin_dirs(npm_exe, self.log)
            if spec.key == "mistral":
                cli_bin_dirs = dedupe_preserve_order(cli_bin_dirs + get_python_cli_bin_dirs(self.log))
            if spec.key == "ollama":
                cli_bin_dirs = dedupe_preserve_order(cli_bin_dirs + get_ollama_cli_bin_dirs(self.log))
            command_path = resolve_command_path(spec.command_candidates, cli_bin_dirs)
            if command_path:
                self.log(f"Resolved command path for {spec.label}: {command_path}")
                installed_commands.append((spec, command_path))
            else:
                self.log(f"Warning: Could not resolve executable path for {spec.label}. Shortcut will be skipped.")

        self.set_status("Refreshing PATH entries")
        self.set_gauge(85)
        cli_bin_dirs = get_cli_bin_dirs(npm_exe, self.log)
        if needs_python_cli_dirs:
            cli_bin_dirs = dedupe_preserve_order(cli_bin_dirs + get_python_cli_bin_dirs(self.log))
        if needs_ollama_cli_dirs:
            cli_bin_dirs = dedupe_preserve_order(cli_bin_dirs + get_ollama_cli_bin_dirs(self.log))
        added_user, user_err = add_dirs_to_path("user", cli_bin_dirs)
        if user_err:
            self.log(f"User PATH refresh warning: {user_err}")
        elif added_user:
            self.log("Added to user PATH (post-install): " + ", ".join(added_user))

        system_path_dirs = filter_system_path_dirs(cli_bin_dirs)
        added_system, system_err = add_dirs_to_path("system", system_path_dirs)
        if system_err:
            self.log(f"System PATH refresh warning: {system_err}")
        elif added_system:
            self.log("Added to system PATH (post-install): " + ", ".join(added_system))

        self.set_status("Configuring auto-updates")
        self.set_gauge(90)
        if enable_auto_update:
            try:
                ensure_cli_auto_update_task(npm_exe or "", installed_packages, self.log)
            except Exception as exc:
                self.log(f"Auto-update task warning: {exc}")
        else:
            self.log("Hidden auto-update task disabled for this run.")

        self.set_status("Creating desktop shortcuts")
        self.set_gauge(92)
        for spec, cmd_path in installed_commands:
            try:
                create_cli_desktop_shortcut(spec, cmd_path, self.log)
            except Exception as exc:
                self.log(f"Shortcut creation failed for {spec.label}: {exc}")
        if is_linux() and installed_commands:
            update_desktop_database_for_user(self.log)

        self.set_status("Finalizing")
        self.set_gauge(98)
        self.log("")
        self.log("Next step: launch a shortcut on the Desktop, or open a new terminal and run the installed CLI command.")


class InstallerApp(wx.App):
    def OnInit(self) -> bool:
        if not (is_windows() or is_macos() or is_linux()):
            wx.MessageBox(
                "This installer currently supports Windows, macOS, and Linux (Debian/Ubuntu, Fedora, Arch).",
                "Unsupported OS",
                wx.OK | wx.ICON_ERROR,
            )
            return False
        frame = InstallerFrame()
        frame.Show()
        return True


def main() -> int:
    app = InstallerApp(False)
    app.MainLoop()
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
