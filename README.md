# InstallTheCli

A vibe-coded, set-it-and-forget-it installer for Windows, macOS, and Linux that puts every popular AI CLI and desktop AI app on your machine in one shot and keeps them current in the background — hands-free, no popups, no manual `npm update` ever again.

[![Join SerrebiProjects on Telegram](https://img.shields.io/badge/Telegram-SerrebiProjects-2CA5E0?style=for-the-badge&logo=telegram&logoColor=white)](https://t.me/SerrebiProjects)

**Have a question, hit a bug, or want early word on new releases?** Join the [SerrebiProjects Telegram group](https://t.me/SerrebiProjects) — the community hub for InstallTheCli and my other projects, and the fastest place to get help.

## Features

- Installs fifteen AI CLIs: Claude, Codex, Antigravity 2.0, Antigravity CLI (`agy`), Antigravity IDE, Visual Studio Code, Grok, Qwen, GitHub Copilot, OpenClaw, IronClaw, Freebuff, Mistral Vibe, Ollama, and RTK (Rust Token Killer, built from `rtk-ai/rtk` git master via cargo).
- Installs six desktop AI apps from the GUI: Claude, ChatGPT (the new app with Chat, ChatGPT Work, and Codex), Freebuff, Gemini, Microsoft Copilot, and Perplexity.
- Works three ways so you can pick what fits: a point-and-click GUI, a one-click PowerShell script on Windows, and one-click Bash scripts on macOS and Linux.
- Installs every missing prerequisite without making you chase them: Node.js and npm, Python 3.14 (Windows), pip or uv, and Homebrew on macOS — it asks before touching Homebrew, because that's not my call.
- Adds CLI directories to your PATH and drops desktop shortcuts where you expect them.
- Sets up silent background auto-updates: a hidden Scheduled Task on Windows (startup, logon, and daily — no visible windows, ever), a LaunchAgent on macOS, and cron on Linux. You install once and they just stay current.
- Heals broken installs on its own — a missing or busted Claude CLI gets reinstalled from Anthropic's official installer on the next updater run, and old npm-based Claude installs are quietly migrated to the native one so they don't shadow each other.
- Pulls from official sources only: winget, Homebrew, npm, the Microsoft Store, and vendor installer scripts. Claude comes from Anthropic's own native installer at claude.ai. Freebuff Desktop is a direct download from freebuff.com — it's not on any package manager yet, but the installer fetches it, mounts the DMG, clears the quarantine bit, and drops the .app where it belongs, without winget or Homebrew in the middle.

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

## Quick sanity check

Open a new shell and fire off the commands you installed. If one fails, rerun the installer for just that target and it'll sort itself out.

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
freebuff
vibe
ollama
rtk
```

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
