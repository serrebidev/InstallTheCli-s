# InstallTheCli Architecture & Dev Guide

## Working Agreement (read first)
- Treat this file as the project source of truth. If code and this guide disagree,
  verify the code, fix the guide, and keep the operational rule here.
- Install whatever you need to get the job done.
- Debug and test your changes; add or extend tests in `test_ai_cli_installer_gui.py`
  for any behavior change.
- Fix any warnings or errors you hit along the way.
- Keep this file current when something here goes stale.

## System Overview
- Stack: Python 3.14, wxPython (GUI), PyInstaller (Windows EXE), plus standalone
  one-click installer scripts (PowerShell + Bash) that share behavior with the GUI.
- What it is: a Windows/macOS/Linux installer for AI CLIs and desktop AI apps,
  with hidden background auto-updaters on all three platforms.
- Entry points:
  - `ai_cli_installer_gui.py` — the whole app in one file (specs, install logic,
    updater script generation, GUI). Windows, macOS, and Linux.
  - `install_all_windows.ps1` — one-click PowerShell installer with subcommands.
  - `install_all_macos.sh` — one-click macOS installer + LaunchAgent updater.
  - `install_all_linux.sh` — one-click Linux installer + cron updater.
  - `test_ai_cli_installer_gui.py` — the entire unit test suite (designed for 100% coverage).
  - `build_exe.bat` + `InstallTheCli.spec` — Windows EXE build (PyInstaller).
  - `build.bat` — build/dry-run/release driver. `BUILD.md` has the prose.

## Build & Release
You should not need to open `build.bat` to cut a release — everything operational is here.

### Ship a release (the only path)
- Run ONE command on Windows: `.\build.bat release`. It does the entire release.
  Do not hand-pick the version, tag manually, or run `gh release create` yourself.
- It requires a CLEAN tree (no uncommitted tracked changes, nothing staged). Commit first.
- Release from `master`; `master` is the default branch.
- When it exits 0, the release is published as Latest/non-draft, the Windows assets
  are attached, and the Linux CI asset is confirmed on the release.

### `build.bat` modes
- `release` — full release, in order: compute next version → `build_exe.bat` →
  stage versioned EXE/ZIP + SHA256SUMS + the three one-click scripts under
  `dist\release` → push HEAD → `gh release create` at that exact commit (tag is
  created WITH the release, never pushed bare, so CI always has a release to
  upload to) → force `--draft=false --latest` and re-verify via `gh release view`
  (re-publishes once if the API still shows draft) → wait for the Linux CI build
  on the tag (up to 30 min) and verify the `-linux.tar.gz` asset landed. Any
  failed step exits non-zero; fix it, don't bypass.
- `build` — local build only; delegates to `build_exe.bat`. No git, no GitHub.
- `dry-run` — prints the next version and planned steps; changes nothing.

### Version numbers are automatic — never pick them
- Next version = highest existing `v*.*.*` tag with the patch bumped
  (`v1.5.16` → `v1.5.17`). No conventional-commit parsing; every release is a
  patch bump unless you retag the major/minor by hand first (don't).
- If the tag already exists on origin, `release` refuses. That means someone
  already released that version — rerun to get the next patch, don't fight the tag.

### CI (`.github/workflows/`)
- `linux-build.yml` and `macos-build.yml` trigger on the `v*` tag and
  `gh release upload --clobber` their platform binaries onto the release.
  `build.bat release` gates on Linux only; macOS attaches in parallel, ungated.
- `windows-build.yml` is validation only (push/PR/dispatch) and NEVER touches
  releases — build.bat uploads the authoritative Windows assets. Do not add a
  tag-triggered Windows upload; it would clobber the signed local build.
- If the Linux gate fails, the release and tag stay in place; rerun the workflow
  from the Actions tab instead of re-releasing.

### Release assets
- `InstallTheCli-vX.Y.Z.exe`, `InstallTheCli-vX.Y.Z.zip`,
  `InstallTheCli-vX.Y.Z-SHA256SUMS.txt` (from build.bat)
- `install_all_windows.ps1`, `install_all_macos.sh`, `install_all_linux.sh` (from build.bat)
- `InstallTheCli-vX.Y.Z-linux.tar.gz` (Linux CI), `InstallTheCli-vX.Y.Z-macos.zip` (macOS CI)

### Release rules
- Publish real releases, never drafts. `build.bat release` enforces and
  self-verifies this — do not remove the guards.
- It does NOT delete other draft releases; clean up prior drafts manually by exact tag.
- Do not ship if the build shows unresolved warnings or errors. Fix, rebuild, confirm gone.

## What It Installs (Do Not Break Quietly)

CLI specs (`CLI_SPECS` in `ai_cli_installer_gui.py`):
- Claude CLI (Anthropic's official NATIVE installer — Windows
  `https://claude.ai/install.ps1`, Linux `https://claude.ai/install.sh`,
  binary at `~/.local/bin/claude(.exe)`; macOS cask `claude-code`. NOT npm:
  the legacy `@anthropic-ai/claude-code` npm install is migrated out of the
  way by installers and updaters because its shims shadow the native exe)
- Codex CLI (`@openai/codex`, npm; macOS cask `codex`)
- Antigravity 2.0 (Google's agentic IDE + `antigravity` CLI; winget / brew cask / Linux tarball)
- Antigravity CLI (standalone `agy`; Google's official self-updating installer, all platforms)
- Antigravity IDE (winget `Google.AntigravityIDE` / cask `antigravity-ide`; no Linux; optional)
- Visual Studio Code (`code` CLI; winget / cask / official .deb/.rpm/tarball)
- Grok CLI (`@vibe-kit/grok-cli`, npm; optional)
- Qwen CLI (`@qwen-code/qwen-code`, npm; macOS formula `qwen-code`)
- Mistral Vibe CLI (pip/uv; macOS formula `mistral-vibe`; optional)
- Ollama (official only: winget `Ollama.Ollama` / `https://ollama.com/install.sh` / formula)
- GitHub Copilot CLI (`@github/copilot`, npm; macOS cask `copilot-cli`)
- OpenClaw CLI (npm; macOS official installer, Node 22.14+; optional)
- IronClaw CLI (macOS formula; npm fallback elsewhere; optional)
- RTK (Rust Token Killer; cargo install from `rtk-ai/rtk` git master; optional)

Desktop app specs (`GUI_APP_SPECS`, GUI only):
- Claude App (winget `Anthropic.Claude` / Flatpak / cask `claude`)
- ChatGPT App (the NEW desktop app with Chat, ChatGPT Work, and Codex —
  Microsoft Store Product ID `9PLM9XGG6VKS` via winget `msstore` source; cask
  `chatgpt`; Linux browser shortcut). This REPLACED the separate Codex App spec;
  do not resurrect `codex_app` or the old `OpenAI.ChatGPT` winget id.
- Gemini App, Microsoft Copilot App, Perplexity App (winget/Flatpak/shortcut; optional)

IDE-style CLIs (Antigravity, VS Code) are not npm packages. They are `CliSpec`s
where `cli_is_app_installer(spec)` is true (`winget_id` or `linux_install_kind`
set) and go through `ensure_app_cli` / `uninstall_app_cli`:
- Windows: winget (`Google.Antigravity`, `Microsoft.VisualStudioCode`).
- macOS: Homebrew casks via the normal `macos_brew_cask` path; both are in
  `MACOS_BREW_CASK_CLIS` so the LaunchAgent updater upgrades them.
- Linux: Antigravity (`linux_install_kind="antigravity_tarball"`) lists the
  public `antigravity-public` GCS bucket, picks the newest version dir (skipping
  `dogfood`/`100.0.0`), extracts to `/opt/antigravity` (or `~/.local/opt`) and
  symlinks `antigravity` onto PATH. VS Code (`linux_install_kind="vscode_pkg"`)
  installs the official `.deb`/`.rpm`, or the stable tarball on other distros.
- They are NOT in the npm auto-update package list (their `pkg` is a winget id);
  the Windows/macOS updaters upgrade them via winget/brew, like Ollama.
- rtk integration: Antigravity is wired via `rtk init -g --agent antigravity`
  (in `RTK_OPTIONAL_INTEGRATIONS` and every updater's agent loop). There is no
  per-app `.gemini`-style hook config anymore.

## Auto-Update Behavior
- Windows (GUI and PowerShell script): hidden Scheduled Task
  `InstallTheCli - Update AI CLIs`.
  - Triggers: startup, logon, daily (3:00AM default). No visible window — it
    launches through `wscript.exe` + a `.vbs` wrapper so PowerShell stays hidden.
  - Codex updates close running Codex processes before npm touches `codex.exe`;
    stale npm `.codex-*` temp directories are cleaned when possible.
  - Claude updates are skipped while `claude.exe` is running. `Update-ClaudeNative`
    runs `%USERPROFILE%\.local\bin\claude.exe update`; if the exe is missing or
    the update fails, it reinstalls via `https://claude.ai/install.ps1`. Any
    legacy `@anthropic-ai/claude-code` npm install is uninstalled first
    (migration), and legacy packages-file entries for it are skipped/filtered.
  - Claude's native update runs EAGERLY at the start of the embedded updater
    script (before consulting the npm package list), because Claude is no
    longer an npm package and never appears in new packages files.
  - After each Codex npm update, the updater verifies both PowerShell shims
    and the native executable. It forces optional native dependencies,
    retries one forced reinstall on failure, and exits non-zero if the CLI is
    still unusable so Task Scheduler cannot report a false success.
  - Registered tasks self-upgrade: opening the GUI, or running
    `install-all` / `install` / `setup-updater` in `install_all_windows.ps1`,
    re-registers an existing task with the current embedded updater logic, so
    fixes propagate without users re-running setup.
- Linux: cron (`@reboot` + daily `0 3 * * *` default), non-interactive.
- macOS: user LaunchAgent `com.installthecli.ai-cli-updates` (`RunAtLoad` +
  daily `StartInterval` 86400); updates installed brew formulae/casks, and npm
  packages only if globally installed.

## Hard Invariants
1. Keep installs quiet. npm keeps `--no-fund --no-audit --no-update-notifier
   --loglevel error`; pip stays quiet/non-interactive where practical.
2. When running `npm.cmd` by absolute path on Windows, prepend the npm directory
   (usually `C:\Program Files\nodejs`) to subprocess `PATH` and set
   `npm_config_update_notifier=false` — otherwise child processes fail with
   `'"node"' is not recognized...`.
3. Keep Ollama official (winget `Ollama.Ollama`, `https://ollama.com/install.sh`).
4. Keep Mistral Vibe aligned with `https://docs.mistral.ai/mistral-vibe/introduction`:
   Windows = Python 3.14 (installed if needed) + pip/uv; Linux = Python 3.12+ and
   PEP 668 handled via `--break-system-packages`; macOS = formula `mistral-vibe`.
5. macOS is Homebrew-first unless an official installer is the only confirmed
   source. If Homebrew is missing, ASK before installing it. CLI casks:
   `claude-code`, `codex`, `copilot-cli`, `antigravity`, `antigravity-ide`,
   `visual-studio-code`. CLI formulae: `qwen-code`, `mistral-vibe`, `ollama`,
   `ironclaw`. Desktop casks: `claude`, `chatgpt`, `google-gemini`. OpenClaw uses
   `https://openclaw.ai/install.sh` (Node 22.14+). Grok installs Node via brew when needed.
6. `install_all_linux.sh` and `install_all_macos.sh` must stay LF-only. CRLF
   breaks Bash (`$'\r': command not found`). Normalize before testing if you edited on Windows.
7. Preserve hidden/background updater behavior: no visible windows on Windows,
   non-interactive cron/LaunchAgent on Linux/macOS.
8. Do not remove fallback behaviors without replacement:
   - Codex locked-file (`EBUSY`) retry and fallback-to-existing-install.
   - The Claude native self-heal above (skip-while-running, `claude update`,
     reinstall via install.ps1/install.sh on breakage, legacy npm migration).
   - Windows Scheduled Task registration warning handling.
   - Linux distro detection / package manager branching.
   - Windows rtk Claude hook: `Install-RtkBashShim` drops an `rtk` shim into
     Git's `usr\bin` so the bare `rtk hook claude` command resolves from Claude
     Code's Git-Bash hook shell (minimal PATH, no cargo dir) AND is recognized by
     rtk's hook-detector (avoids the "No hook installed" nag). If the shim can't
     be written, fall back to the absolute POSIX path
     `/c/Users/<leaf>/.cargo/bin/rtk.exe hook claude` (works, but nags). Mirrored
     in `install_all_windows.ps1` (installer + embedded updater) and
     `ai_cli_installer_gui.py` (`_install_rtk_bash_shim` /
     `_normalize_claude_rtk_hook` + the embedded updater string) — keep them in
     sync. Not needed on Linux/macOS.
9. Keep logs explicit; users diagnose failures from the installer log output.
10. Prefer small, targeted patches.

## Testing (before shipping anything)
- `py -3.14 -m unittest -q test_ai_cli_installer_gui.py` — the full suite must pass.
- Coverage is designed for 100%:
  `py -3.14 -m coverage run -m unittest -q test_ai_cli_installer_gui.py` then
  `py -3.14 -m coverage report -m ai_cli_installer_gui.py test_ai_cli_installer_gui.py`.
- Add tests for: new CLI specs, installer branching/fallbacks, updater changes,
  and any change to the generated PowerShell/Bash script content.
- Shell script changes: validate at least one dry-run path locally.
  - Linux: `bash -n install_all_linux.sh`, `./install_all_linux.sh help`, `list`,
    `install codex --dry-run --no-cron`.
  - macOS: `bash -n install_all_macos.sh`, `./install_all_macos.sh help`, `list`,
    `install codex --dry-run --no-launch-agent`.

## User-Facing Script Commands (do not drop any)
- `install_all_windows.ps1`: `install-all`, `install <target>`, `setup-updater`,
  `list`, `help`, and `Get-Help .\install_all_windows.ps1 -Detailed`.
- `install_all_linux.sh`: `install-all`, `install <target>`, `setup-cron`,
  `list`, `help`, and the convenience alias `./install_all_linux.sh codex`.
- `install_all_macos.sh`: `install-all`, `install <target>`, `setup-launch-agent`,
  `list`, `help`, the `codex` alias, and the Homebrew prompt before installing Homebrew.

## Packaging Notes
- `InstallTheCli.spec` is intentionally simple: `datas=[]`, `hiddenimports=[]`.
- Auto-update scripts are generated at runtime under user/system state
  locations, never bundled.

## If You Add A New CLI
Update all of these together:
- `CLI_SPECS` in `ai_cli_installer_gui.py`
- install logic (if not plain npm)
- desktop shortcut resolution rules if needed
- auto-update: Windows embedded updater, Linux cron script, macOS LaunchAgent
  script (whichever apply)
- one-click scripts (`install_all_windows.ps1`, `install_all_macos.sh`, `install_all_linux.sh`)
- tests in `test_ai_cli_installer_gui.py`
- `README.md`
