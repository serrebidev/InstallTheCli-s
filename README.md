# InstallTheCli

A vibe-coded installer for Windows, macOS, and Linux that sets up all the popular AI CLIs and desktop AI apps in one go, then keeps them updated in the background — so you never have to do it manually.

[![Join SerrebiProjects on Telegram](https://img.shields.io/badge/Telegram-SerrebiProjects-2CA5E0?style=for-the-badge&logo=telegram&logoColor=white)](https://t.me/SerrebiProjects)

**Have a question, hit a bug, or want early word on new releases?** Join the [SerrebiProjects Telegram group](https://t.me/SerrebiProjects) — the community hub for InstallTheCli and my other projects, and the fastest place to get help.

## Features

- Installs the popular AI CLIs: Claude, Codex, Antigravity 2.0, Antigravity CLI (`agy`), Antigravity IDE, Visual Studio Code, Grok, Qwen, GitHub Copilot, OpenClaw, IronClaw, Mistral Vibe, Ollama, and RTK (Rust Token Killer, built from `rtk-ai/rtk` git master via cargo).
- Installs desktop AI apps from the GUI: Claude, ChatGPT (the new app with Chat, ChatGPT Work, and Codex), Gemini, Microsoft Copilot, and Perplexity.
- Works three ways: a GUI app, a one-click PowerShell script on Windows, and one-click Bash scripts on macOS and Linux (Debian, Ubuntu, Fedora, Arch).
- Installs prerequisites for you when missing: Node.js/npm, Python 3.14 (Windows), pip/uv, and Homebrew on macOS (it asks first).
- Adds CLI directories to PATH and creates desktop shortcuts.
- Sets up silent background auto-updates: a hidden Scheduled Task on Windows (startup, logon, and daily — no popup windows), a LaunchAgent on macOS, and cron on Linux.
- Repairs broken installs automatically — for example a Claude CLI left half-updated by an interrupted upgrade is restored on the next updater run.
- Uses official sources: winget, Homebrew, npm, Microsoft Store, and vendor installer scripts.

## Download and install

Grab the latest build from the [Releases page](https://github.com/serrebidev/InstallTheCli-s/releases).

**Windows GUI (recommended)**

1. Download `InstallTheCli-vX.Y.Z.exe` (or the `.zip` and extract it).
2. Run it — as Administrator for best results (system PATH writes and installers). Tick what you want, click install.

**Windows one-click script**

Download `install_all_windows.ps1` from the same release, then:

```powershell
.\install_all_windows.ps1              # install everything
.\install_all_windows.ps1 list         # list targets
.\install_all_windows.ps1 install codex
.\install_all_windows.ps1 setup-updater
.\install_all_windows.ps1 help
```

Useful flags: `-DryRun`, `-NoAutoUpdate`, `-AutoUpdateTime "3:00AM"`.

**macOS**

Download `install_all_macos.sh` (or the `…-macos.zip` GUI build). Installs are Homebrew-first; if Homebrew is missing you are asked before it gets installed.

```bash
./install_all_macos.sh                 # install everything
./install_all_macos.sh list
./install_all_macos.sh install codex
./install_all_macos.sh setup-launch-agent
```

Useful flags: `--dry-run`, `--no-launch-agent`.

**Linux (Debian, Ubuntu, Fedora, Arch)**

Download `install_all_linux.sh` (or the `…-linux.tar.gz` GUI build).

```bash
sudo bash install_all_linux.sh         # install everything
./install_all_linux.sh list
sudo bash install_all_linux.sh install codex
sudo bash install_all_linux.sh setup-cron
```

Useful flags: `--dry-run`, `--no-cron`, `--cron-time "0 3 * * *"`.

## Auto-updates

Once set up, updates run silently in the background:

- Windows: hidden Scheduled Task `InstallTheCli - Update AI CLIs` (startup, logon, daily at 3:00AM by default). Files live under `%LocalAppData%\InstallTheCli\`.
- macOS: LaunchAgent `com.installthecli.ai-cli-updates` (login and daily). Updates Homebrew formulae/casks and globally installed npm CLIs.
- Linux: cron (`@reboot` and daily). Log at `/var/log/installthecli-linux-update.log`.

## Quick sanity check after install

Open a new shell and try the commands you installed:

```text
claude
codex
antigravity
agy
code
grok
qwen
copilot
openclaw
ironclaw
vibe
ollama
rtk
```

If one fails, rerun the installer for that target only.

## Run from source (any OS)

1. Install Python 3.14.
2. Install dependencies: `pip install -r requirements.txt`
3. Launch it: `python ai_cli_installer_gui.py` (on Windows: `.\run_gui.ps1` or `py -3.14 .\ai_cli_installer_gui.py`)

Run the tests with `py -3.14 -m unittest -q test_ai_cli_installer_gui.py`.

## Building

See [`BUILD.md`](BUILD.md) for the full release pipeline — PyInstaller packaging, release staging, and the Linux/macOS CI builds.

## Contributing

Pull requests are welcome. If InstallTheCli has been useful to you, open a PR with a fix or feature and I'll review it.

## Community and support

Report bugs and request features in [Issues](https://github.com/serrebidev/InstallTheCli-s/issues). For questions, feedback, and release news, join the [SerrebiProjects Telegram group](https://t.me/SerrebiProjects).
