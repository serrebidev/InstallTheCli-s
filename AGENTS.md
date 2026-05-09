# AGENTS.md

This file is for coding agents working in this repo.

## What This Project Is

Windows/macOS/Linux installer for common AI CLIs.

Main entry points:
- `ai_cli_installer_gui.py` (wxPython GUI; supports Windows, macOS, and Linux)
- `install_all_windows.ps1` (one-click PowerShell installer with subcommands/help)
- `install_all_macos.sh` (one-click macOS Bash installer with subcommands/help + LaunchAgent updater)
- `install_all_linux.sh` (one-click Linux installer with subcommands/help + cron updater)
- `test_ai_cli_installer_gui.py` (unit tests; high coverage)
- `build_exe.bat` + `InstallTheCli.spec` (Windows EXE build via PyInstaller)

## Current Behavior (Do Not Break Quietly)

Installed CLIs currently include:
- Claude
- Codex
- Gemini
- Grok (`@vibe-kit/grok-cli`)
- Qwen
- GitHub Copilot CLI
- OpenClaw CLI (`openclaw`)
- IronClaw CLI (`ironclaw`)
- Mistral Vibe CLI (`mistral-vibe`)
- Ollama (official install)

Auto-update behavior:
- Windows GUI / PowerShell script: hidden Scheduled Task (`InstallTheCli - Update AI CLIs`)
  - Triggers: startup, logon, daily (`3:00AM` default)
  - No visible cmd/PowerShell window
  - Launches through `wscript.exe` + `.vbs` so PowerShell stays hidden
  - Codex updates are skipped while Codex is running; stale npm `.codex-*` temp directories are cleaned when possible
  - Claude updates are skipped while `claude.exe` is running; orphaned `bin/claude.exe.old.<ts>` files (left by a half-applied swap, when claude.exe is missing) are renamed back to `claude.exe`, and stale `.old.*` files are deleted once `claude.exe` is healthy. If the orphan is gone but the bundled native-arch package (`@anthropic-ai/claude-code-win32-x64` / `-arm64`) is on disk, `bin/claude.exe` is restored by copying from the native binary instead.
  - Claude bin recovery runs eagerly at the start of the embedded updater script (before consulting the per-machine package list), so it fires on every startup/logon/daily trigger even when the rename was caused by something other than this updater (e.g. the Claude desktop app's winget upgrade).
  - Existing hidden auto-update tasks self-upgrade in place: when the GUI is opened, or when `install_all_windows.ps1` runs `install-all` / `install` / `setup-updater`, we detect a registered `InstallTheCli - Update AI CLIs` task and re-register it with the current embedded updater logic. This propagates fixes (like the bin-recovery improvements above) without making users manually re-run setup.
- Linux script: cron updater
  - `@reboot`
  - daily (`0 3 * * *` default)
- macOS GUI / Bash script: user LaunchAgent (`com.installthecli.ai-cli-updates`)
  - `RunAtLoad`
  - daily (`StartInterval` 86400)
  - updates installed Homebrew formulae/casks, and npm packages only if globally installed

## Hard Requirements / Invariants

1. Keep installs quiet.
- npm commands should keep:
  - `--no-fund`
  - `--no-audit`
  - `--no-update-notifier`
  - `--loglevel error`
- Pip commands should stay quiet/non-interactive where practical.

2. When running `npm.cmd` by absolute path on Windows, ensure child processes can still find `node`.
- Prepend the npm directory (usually `C:\Program Files\nodejs`) to subprocess `PATH`.
- Also set `npm_config_update_notifier=false` for subprocesses and background updater scripts.
- This prevents failures like `'"node"' is not recognized...` during npm installs (seen with Gemini).

3. Keep Ollama official.
- Windows: `winget` package `Ollama.Ollama`
- Linux: official installer script (`https://ollama.com/install.sh`)

4. Keep Mistral Vibe aligned with docs.
- Reference: `https://docs.mistral.ai/mistral-vibe/introduction`
- Windows path uses Python `3.14` (install if needed) + `pip`/`uv`
- Linux path supports Python `3.12+`, plus `pip`/`uv` (and handles PEP 668 via `--break-system-packages`)
- macOS path uses the Homebrew formula `mistral-vibe`

5. Keep macOS installs Homebrew-first unless an official installer is the only confirmed source.
- The app must check for Homebrew. If missing, ask before installing it with the official Homebrew installer.
- Known macOS CLI Homebrew casks: `claude-code`, `codex`, `copilot-cli`
- Known macOS CLI Homebrew formulae: `gemini-cli`, `qwen-code`, `mistral-vibe`, `ollama`, `ironclaw`
- Known macOS desktop casks: `claude`, `chatgpt`, `codex-app`, `google-gemini`
- OpenClaw uses the official installer at `https://openclaw.ai/install.sh` and requires Node `22.14+` (or newer).
- Grok currently uses npm package `@vibe-kit/grok-cli`; install Node through Homebrew when needed.

6. `install_all_linux.sh` and `install_all_macos.sh` must remain LF-only line endings.
- CRLF causes Bash errors (`$'\r': command not found`) when run on Linux.
- If editing on Windows, normalize to LF before testing.

7. Preserve hidden/background updater behavior.
- No visible cmd/PowerShell windows for auto-updates on Windows.
- Cron script should remain non-interactive on Linux.
- LaunchAgent script should remain non-interactive on macOS.

## Python / Build Version

Use Python `3.14` on Windows for tests/builds in this repo.

Preferred commands:
- `py -3.14 -m unittest -q test_ai_cli_installer_gui.py`
- `py -3.14 -m coverage run -m unittest -q test_ai_cli_installer_gui.py`
- `py -3.14 -m coverage report -m ai_cli_installer_gui.py test_ai_cli_installer_gui.py`
- `cmd /c build_exe.bat`

`build_exe.bat` is expected to use `py -3.14 -m PyInstaller`.

## Testing Expectations

Before shipping behavior changes:
- Run the full unit test file: `test_ai_cli_installer_gui.py`
- Keep coverage at/near current level (currently designed for `100%`)
- Add tests for:
  - new CLI specs
  - installer branching/fallbacks
  - updater changes
  - script content changes (PowerShell/Bash one-click scripts)

If you change platform-specific behavior:
- Validate at least one dry-run path locally.
- For Linux script changes, prefer:
  - `bash -n install_all_linux.sh`
  - `./install_all_linux.sh help`
  - `./install_all_linux.sh list`
  - `./install_all_linux.sh install codex --dry-run --no-cron`
- For macOS script changes, prefer:
  - `bash -n install_all_macos.sh`
  - `./install_all_macos.sh help`
  - `./install_all_macos.sh list`
  - `./install_all_macos.sh install codex --dry-run --no-launch-agent`

## Build Quality

Always fix any warnings, bugs, or errors that appear during a build before shipping. If the build produces warnings or errors that you can resolve, fix them immediately and rebuild to confirm they are gone.

## Editing Guidance

- Prefer small, targeted patches.
- Keep logs explicit; users rely on the installer log output to diagnose failures.
- Do not remove fallback behaviors without replacement:
  - Codex locked-file (`EBUSY`) retry and fallback-to-existing-install
  - Claude locked-file skip + `claude.exe.old.<ts>` recovery in the Windows updater
  - Windows Scheduled Task registration warning handling
  - Linux distro detection / package manager branching

## User-Facing Scripts (Command UX)

`install_all_windows.ps1` should continue to support:
- `install-all`
- `install <target>`
- `setup-updater`
- `list`
- `help`
- `Get-Help .\install_all_windows.ps1 -Detailed`

`install_all_linux.sh` should continue to support:
- `install-all`
- `install <target>`
- `setup-cron`
- `list`
- `help`
- convenience alias: `./install_all_linux.sh codex`

`install_all_macos.sh` should continue to support:
- `install-all`
- `install <target>`
- `setup-launch-agent`
- `list`
- `help`
- convenience alias: `./install_all_macos.sh codex`
- Homebrew prompt before installing Homebrew when missing

## Packaging Notes

`InstallTheCli.spec` is intentionally simple:
- `datas=[]`
- `hiddenimports=[]`

Auto-update scripts are generated at runtime under user/system state locations, not bundled.

GitHub release expectations:
- Release from `master`; `master` is the expected default branch.
- Publish real releases, not draft releases. Never leave GitHub releases in draft state unless the user explicitly reverses this project preference.
- Use `build.bat release` for official releases; it publishes the release as Latest/non-draft and removes any remaining draft releases.
- Release assets should include:
  - `InstallTheCli-vX.Y.Z.exe`
  - `InstallTheCli-vX.Y.Z.zip`
  - `InstallTheCli-vX.Y.Z-SHA256SUMS.txt`
  - `install_all_windows.ps1`
  - `install_all_macos.sh`
  - `install_all_linux.sh`

## If You Add A New CLI

Update all of these together:
- `CLI_SPECS` in `ai_cli_installer_gui.py`
- install logic (if not plain npm)
- desktop shortcut resolution rules if needed
- auto-update (Windows + Linux one-click updater scripts, if applicable)
- auto-update (macOS LaunchAgent script, if applicable)
- one-click scripts (`install_all_windows.ps1`, `install_all_macos.sh`, `install_all_linux.sh`)
- tests in `test_ai_cli_installer_gui.py`
- `README.md`
