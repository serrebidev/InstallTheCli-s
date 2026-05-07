# InstallTheCli

I know the name is boring. This project installs a bunch of AI CLIs so you do not have to do it manually.

It supports:
- Windows (GUI app + one-click PowerShell script)
- macOS (GUI app + one-click Bash script using Homebrew/official installers)
- Linux: Debian, Ubuntu, Fedora, Arch (one-click Bash script, plus Linux support in the GUI app)

## What It Installs

By default it can install:
- Claude CLI
- Codex CLI
- Gemini CLI
- Grok CLI (`@vibe-kit/grok-cli`)
- Qwen CLI
- GitHub Copilot CLI
- OpenClaw CLI (`openclaw`)
- IronClaw CLI (`ironclaw`)
- Mistral Vibe CLI (`mistral-vibe`)
- Ollama (official version + `ollama` CLI)

From the GUI, it can also install desktop AI apps (or shortcuts), including:
- Claude App
- ChatGPT App
- Codex App (Microsoft Store app via `9PLM9XGG6VKS`)
- Gemini App
- Microsoft Copilot App
- Perplexity App

## What It Changes On Your System

It does real system changes. Here they are.

It may:
- install Node.js / npm (if missing)
- install Python 3.14 on Windows (for Mistral Vibe, if needed)
- install `pip` / `uv` for Mistral Vibe (if needed)
- install Ollama (official source)
- add CLI directories to your PATH
- create Desktop shortcuts
- create background auto-update jobs

Auto-update jobs:
- Windows: hidden Scheduled Task (startup + logon + daily)
- macOS: LaunchAgent (RunAtLoad + daily)
- Linux: cron (`@reboot` + daily)

## Windows (GUI)

Run the built EXE:
- `dist\InstallTheCli.exe`

Run the Python GUI directly from terminal:
- `.\run_gui.ps1` (PowerShell)
- `run_gui.cmd` (cmd/PowerShell)
- or `py -3.14 .\ai_cli_installer_gui.py`

What it does:
- installs selected CLIs
- updates PATH
- creates shortcuts
- can create a hidden auto-update task (toggle in the UI)

Notes:
- Run as Administrator for best results (system PATH writes and installers).
- Non-admin runs still work for many cases, but you may get warnings.

## Windows (One-Click PowerShell)

Use this if you want CLI/scriptable install instead of the GUI.

Help:
```powershell
.\install_all_windows.ps1 help
Get-Help .\install_all_windows.ps1 -Detailed
```

List targets:
```powershell
.\install_all_windows.ps1 list
```

Install everything:
```powershell
.\install_all_windows.ps1
```

Install one thing:
```powershell
.\install_all_windows.ps1 install codex
.\install_all_windows.ps1 install mistral
.\install_all_windows.ps1 install ollama
```

Only configure the hidden updater task:
```powershell
.\install_all_windows.ps1 setup-updater
```

Useful flags:
- `-DryRun` (prints commands only)
- `-NoAutoUpdate` (skip hidden updater task)
- `-AutoUpdateTime "3:00AM"` (change daily run time)

## macOS (GUI + One-Click Bash)

macOS installs use Homebrew wherever a formula or cask exists. If Homebrew is missing, the GUI and script ask before installing it with the official Homebrew installer.

Run the Python GUI directly:
```bash
python3 ai_cli_installer_gui.py
```

Run the one-click script:
```bash
./install_all_macos.sh
```

Help:
```bash
./install_all_macos.sh help
```

List targets:
```bash
./install_all_macos.sh list
```

Install one thing:
```bash
./install_all_macos.sh install codex
./install_all_macos.sh install openclaw
./install_all_macos.sh install mistral --no-launch-agent
```

Only configure the LaunchAgent updater:
```bash
./install_all_macos.sh setup-launch-agent
```

Useful flags:
- `--dry-run`
- `--no-launch-agent`

macOS install sources:
- Homebrew casks: Claude Code, Codex CLI, GitHub Copilot CLI
- Homebrew formulae: Gemini CLI, Qwen CLI, Mistral Vibe CLI, Ollama, IronClaw
- npm via Homebrew Node.js where needed: Grok CLI
- official installer: OpenClaw (checks Node.js 22.14+)

## Linux (One-Click Bash)

This is the easiest Linux path. Use this instead of clicking around.

Supported distros:
- Debian
- Ubuntu
- Fedora
- Arch

Run:
```bash
sudo bash install_all_linux.sh
```

Help:
```bash
./install_all_linux.sh help
```

List targets:
```bash
./install_all_linux.sh list
```

Install one thing:
```bash
sudo bash install_all_linux.sh install codex
sudo bash install_all_linux.sh install mistral --no-cron
sudo bash install_all_linux.sh install ollama
```

Convenience alias:
```bash
sudo bash install_all_linux.sh codex
```

Only configure the cron updater:
```bash
sudo bash install_all_linux.sh setup-cron
```

Useful flags:
- `--dry-run`
- `--no-cron`
- `--cron-time "0 3 * * *"`

## Auto-Updates (Background)

This project can keep installed CLIs updated in the background.

### Windows

Task name:
- `InstallTheCli - Update AI CLIs`

Behavior:
- hidden task
- runs at startup, logon, and daily
- no popup console window
- invokes a small `.vbs` wrapper through `wscript.exe`, which launches the PowerShell updater hidden
- npm CLIs are refreshed with `npm install -g <package>@latest`
- Codex CLI updates are skipped while Codex is running, then retried on the next task run to avoid locked `codex.exe` cleanup warnings
- Claude CLI updates are skipped while `claude.exe` is running. If a prior update was interrupted and left `bin/claude.exe.old.<timestamp>` without a current `claude.exe`, the latest `.old` is restored automatically; once `claude.exe` is healthy, leftover `.old.*` files are deleted

Files written under:
- `%LocalAppData%\InstallTheCli\`

### Linux

Files:
- `/usr/local/bin/installthecli-linux-update.sh`
- `/etc/cron.d/installthecli-ai-cli-updates`
- `/var/log/installthecli-linux-update.log`

Behavior:
- runs on reboot and daily
- non-interactive cron job
- npm CLIs are refreshed with `npm install -g <package>@latest`

### macOS

Files:
- `~/Library/Application Support/InstallTheCli/auto_update_clis_macos.sh`
- `~/Library/LaunchAgents/com.installthecli.ai-cli-updates.plist`
- `~/Library/Application Support/InstallTheCli/macos_auto_update.log`

Behavior:
- runs at login/load and daily
- updates installed Homebrew formulae/casks
- refreshes npm CLIs only when those npm packages are globally installed

## Build From Source (Windows)

Requirements:
- Python 3.14
- `wxPython` (`pip install -r requirements.txt`)
- PyInstaller installed in that Python environment

Install deps:
```powershell
py -3.14 -m pip install -r requirements.txt
py -3.14 -m pip install pyinstaller coverage
```

Run tests:
```powershell
py -3.14 -m unittest -q test_ai_cli_installer_gui.py
```

Build EXE:
```powershell
cmd /c build_exe.bat
```



## Quick Sanity Check After Install

Open a new shell and run:

```text
claude
codex
gemini
grok
qwen
copilot
openclaw
ironclaw
vibe
ollama
```

If one fails, rerun the installer for that target only.

##Submit bugs in issues, or join my Telegram group!
(https://t.me/SerrebiProjects)

