#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="$(basename "$0")"
DRY_RUN=0
NO_LAUNCH_AGENT=0
SUBCOMMAND="install-all"
TARGET="all"

HOMEBREW_INSTALL_URL="https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"
OPENCLAW_INSTALL_URL="https://openclaw.ai/install.sh"
SUPPORT_DIR="${HOME}/Library/Application Support/InstallTheCli"
UPDATE_SCRIPT_PATH="${SUPPORT_DIR}/auto_update_clis_macos.sh"
LAUNCH_AGENT_ID="com.installthecli.ai-cli-updates"
LAUNCH_AGENT_PATH="${HOME}/Library/LaunchAgents/${LAUNCH_AGENT_ID}.plist"

NPM_FLAGS=(--no-fund --no-audit --no-update-notifier --loglevel error)

BREW_BIN=""

log() {
  printf '[install] %s\n' "$*"
}

warn() {
  printf '[warn] %s\n' "$*" >&2
}

die() {
  printf '[error] %s\n' "$*" >&2
  exit 1
}

print_usage() {
  cat <<'EOF'
One-click macOS installer for InstallTheCli.

Usage:
  ./install_all_macos.sh [command] [target] [options]

Commands:
  install-all              Install all supported CLIs (default).
  install <target>         Install a single target CLI (plus prerequisites).
  setup-launch-agent       Install/update only the hidden launchd updater.
  list                     List supported install targets.
  help                     Show help.

Options:
  --dry-run            Print commands but do not modify the system.
  --no-launch-agent    Skip installing the launchd auto-update job.
  -h, --help           Show this help.

This script installs:
  - Homebrew if missing and you approve it
  - Claude CLI, Codex CLI, Gemini CLI, Qwen CLI, GitHub Copilot CLI,
    Mistral Vibe CLI, Ollama CLI, IronClaw CLI (Homebrew)
  - Grok CLI (npm, with Node.js installed by Homebrew if needed)
  - OpenClaw CLI (official installer, with Node.js 22.14+ installed by Homebrew if needed)
  - RTK (Rust Token Killer) from git master via cargo (opt-in: 'install rtk')
  - launchd updater (RunAtLoad and daily) unless --no-launch-agent is used
EOF
}

print_targets() {
  cat <<'EOF'
Supported targets:
  claude
  codex
  gemini
  grok
  qwen
  copilot
  openclaw
  ironclaw
  mistral
  ollama
  rtk
  all

Examples:
  ./install_all_macos.sh install codex
  ./install_all_macos.sh install openclaw
  ./install_all_macos.sh install mistral --no-launch-agent
  ./install_all_macos.sh install rtk
  ./install_all_macos.sh install-all
  ./install_all_macos.sh setup-launch-agent
EOF
}

print_cmd() {
  printf '[run]'
  printf ' %q' "$@"
  printf '\n'
}

run_cmd() {
  print_cmd "$@"
  if (( DRY_RUN )); then
    return 0
  fi
  "$@"
}

run_shell() {
  local cmd="$1"
  printf '[run] %s\n' "$cmd"
  if (( DRY_RUN )); then
    return 0
  fi
  /bin/bash -lc "$cmd"
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

setup_brew_path() {
  export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:${PATH}"
}

find_brew() {
  setup_brew_path
  if command_exists brew; then
    command -v brew
    return 0
  fi
  for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

ensure_homebrew() {
  if BREW_BIN="$(find_brew)"; then
    log "Homebrew is available: ${BREW_BIN}"
    return 0
  fi

  if (( DRY_RUN )); then
    log "Dry-run: would ask to install Homebrew from https://brew.sh/."
    BREW_BIN="brew"
    return 0
  fi

  printf 'Homebrew is required for macOS installs. Install it now using the official installer? [y/N] ' >&2
  local answer=""
  read -r answer || true
  case "$(lower "$answer")" in
    y|yes)
      log "Installing Homebrew using the official installer."
      NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL "${HOMEBREW_INSTALL_URL}")"
      ;;
    *)
      die "Homebrew is required. Install it from https://brew.sh/ and rerun this script."
      ;;
  esac

  if BREW_BIN="$(find_brew)"; then
    log "Homebrew is available: ${BREW_BIN}"
    return 0
  fi
  die "Homebrew installed, but brew was not found on PATH. Open a new terminal and rerun this script."
}

node_satisfies() {
  local min_major="$1"
  local min_minor="${2:-0}"
  local min_patch="${3:-0}"
  node -e '
const have = process.versions.node.split(".").map(Number);
const need = process.argv.slice(1).map(Number);
const ok = have[0] > need[0]
  || (have[0] === need[0] && have[1] > need[1])
  || (have[0] === need[0] && have[1] === need[1] && have[2] >= need[2]);
process.exit(ok ? 0 : 1);
' "$min_major" "$min_minor" "$min_patch" >/dev/null 2>&1
}

node_requirement_label() {
  local min_major="$1"
  local min_minor="${2:-0}"
  local min_patch="${3:-0}"
  if [[ "$min_minor" == "0" && "$min_patch" == "0" ]]; then
    printf 'Node %s+' "$min_major"
  elif [[ "$min_patch" == "0" ]]; then
    printf 'Node %s.%s+' "$min_major" "$min_minor"
  else
    printf 'Node %s.%s.%s+' "$min_major" "$min_minor" "$min_patch"
  fi
}

ensure_node() {
  local min_major="$1"
  local min_minor="${2:-0}"
  local min_patch="${3:-0}"
  local requirement
  requirement="$(node_requirement_label "$min_major" "$min_minor" "$min_patch")"
  ensure_homebrew
  if command_exists node && command_exists npm && node_satisfies "$min_major" "$min_minor" "$min_patch"; then
    log "Node.js requirement satisfied: $(node --version), npm $(npm --version)"
    return 0
  fi
  log "Installing/upgrading Node.js via Homebrew for ${requirement} requirement."
  if "${BREW_BIN}" list --formula node >/dev/null 2>&1; then
    run_cmd "${BREW_BIN}" upgrade node || true
  else
    run_cmd "${BREW_BIN}" install node
  fi
  setup_brew_path
  if (( ! DRY_RUN )) && (! command_exists node || ! command_exists npm || ! node_satisfies "$min_major" "$min_minor" "$min_patch"); then
    die "${requirement} and npm were not found after Homebrew node install."
  fi
}

brew_install_formula() {
  local name="$1"
  ensure_homebrew
  if "${BREW_BIN}" list --formula "$name" >/dev/null 2>&1; then
    log "Homebrew formula already installed: ${name}; upgrading."
    run_cmd "${BREW_BIN}" upgrade "$name" || true
  else
    log "Installing Homebrew formula: ${name}"
    run_cmd "${BREW_BIN}" install "$name"
  fi
}

brew_install_cask() {
  local name="$1"
  ensure_homebrew
  if "${BREW_BIN}" list --cask "$name" >/dev/null 2>&1; then
    log "Homebrew cask already installed: ${name}; upgrading."
    run_cmd "${BREW_BIN}" upgrade --cask "$name" || true
  else
    log "Installing Homebrew cask: ${name}"
    run_cmd "${BREW_BIN}" install --cask "$name"
  fi
}

install_npm_cli() {
  local label="$1"
  local min_node="$2"
  shift 2
  ensure_node "$min_node"
  local candidate
  for candidate in "$@"; do
    log "Trying npm package for ${label}: ${candidate}"
    if run_cmd npm "${NPM_FLAGS[@]}" install -g "$candidate"; then
      log "Installed ${label} using package ${candidate}"
      return 0
    fi
    warn "npm install failed for ${candidate}; trying next candidate (if any)."
  done
  die "Failed to install ${label} via npm."
}

install_openclaw_official() {
  ensure_node 22 14
  log "Installing OpenClaw with the official installer."
  run_shell "curl -fsSL ${OPENCLAW_INSTALL_URL} | bash -s -- --no-onboard"
}

install_all_targets() {
  brew_install_cask claude-code
  brew_install_cask codex
  brew_install_formula gemini-cli
  install_npm_cli "Grok CLI (Vibe Kit)" 20 "@vibe-kit/grok-cli"
  brew_install_formula qwen-code
  brew_install_cask copilot-cli
  install_openclaw_official
  brew_install_formula ironclaw
  brew_install_formula mistral-vibe
  brew_install_formula ollama
}

# Install rustup + cargo via Homebrew if missing. Homebrew's rustup formula
# pulls down the stable toolchain on first use of `cargo`.
ensure_rust_toolchain_macos() {
  ensure_homebrew
  if command_exists cargo; then
    log "cargo already available: $(command -v cargo)"
    return 0
  fi
  if "${BREW_BIN}" list --formula rustup >/dev/null 2>&1; then
    log "rustup already installed via Homebrew; ensuring stable toolchain"
  else
    brew_install_formula rustup
  fi
  if (( ! DRY_RUN )); then
    rustup default stable >/dev/null 2>&1 || run_cmd rustup-init -y --default-toolchain stable --profile minimal --no-modify-path
    export PATH="${HOME}/.cargo/bin:${PATH}"
  fi
  command_exists cargo || die "cargo not found after rustup install. Open a new terminal and rerun."
}

# Install rtk-ai/rtk from git master via cargo. Mirror the Linux/Windows
# logic: clear cargo's git checkout cache for the rtk repo first, otherwise
# `cargo install --git --force` may reuse a stale checkout and silently
# rebuild the same old SHA when only the master ref has moved.
install_rtk() {
  ensure_rust_toolchain_macos
  local cargo_bin
  cargo_bin="$(dirname "$(command -v cargo)")"
  for d in "${HOME}/.cargo/git/checkouts/"rtk-* "${HOME}/.cargo/git/db/"rtk-*; do
    if [[ -d "$d" ]]; then
      log "Clearing cargo git cache: $d"
      run_cmd rm -rf "$d"
    fi
  done
  log "Installing rtk from https://github.com/rtk-ai/rtk (branch master) via cargo"
  run_cmd cargo install --git https://github.com/rtk-ai/rtk --branch master --force

  local rtk_bin="${cargo_bin}/rtk"
  if (( ! DRY_RUN )) && [[ -x "$rtk_bin" ]]; then
    if command_exists claude; then
      log "Registering rtk hook for Claude Code"
      "$rtk_bin" init -g --auto-patch || warn "rtk init (Claude) failed"
    fi
    if command_exists codex; then
      log "Registering rtk for Codex CLI"
      "$rtk_bin" init -g --codex || warn "rtk init (Codex) failed"
    fi
    log "Installed rtk: $("$rtk_bin" --version 2>&1)"
  fi
}

install_single_target() {
  local target_key
  target_key="$(lower "$1")"
  case "$target_key" in
    all) install_all_targets ;;
    claude) brew_install_cask claude-code ;;
    codex) brew_install_cask codex ;;
    gemini) brew_install_formula gemini-cli ;;
    grok) install_npm_cli "Grok CLI (Vibe Kit)" 20 "@vibe-kit/grok-cli" ;;
    qwen) brew_install_formula qwen-code ;;
    copilot) brew_install_cask copilot-cli ;;
    openclaw) install_openclaw_official ;;
    ironclaw) brew_install_formula ironclaw ;;
    mistral|mistral-vibe|vibe) brew_install_formula mistral-vibe ;;
    ollama) brew_install_formula ollama ;;
    rtk) install_rtk ;;
    *) die "Unknown target: ${target_key}. Use '$SCRIPT_NAME list' to see supported targets." ;;
  esac
}

update_script_content() {
  cat <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH}"
export HOMEBREW_NO_AUTO_UPDATE=1
export npm_config_update_notifier=false

log() {
  printf '[installthecli-update] %s\n' "$*"
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

find_brew() {
  if command_exists brew; then
    command -v brew
    return 0
  fi
  for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

brew_bin="$(find_brew || true)"

update_brew_package() {
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
}

update_npm_package() {
  local package="$1"
  command_exists npm || return 0
  npm ls -g --depth=0 "$package" >/dev/null 2>&1 || return 0
  npm --no-fund --no-audit --no-update-notifier --loglevel error install -g "${package}@latest" || true
}

if [[ -n "$brew_bin" ]]; then
  "$brew_bin" update >/dev/null 2>&1 || true
  update_brew_package formula gemini-cli
  update_brew_package formula qwen-code
  update_brew_package formula mistral-vibe
  update_brew_package formula ollama
  update_brew_package formula ironclaw
  update_brew_package cask claude-code
  update_brew_package cask codex
  update_brew_package cask copilot-cli
fi

update_npm_package "@vibe-kit/grok-cli"
update_npm_package "openclaw"

# Rebuild rtk from latest git master if it's already installed. Bust the
# cargo git checkout cache for the rtk repo first; without this, cargo's
# --force flag reuses a stale checkout and rebuilds the same old SHA when
# only the master ref has moved.
update_rtk() {
  local cargo_exe="${HOME}/.cargo/bin/cargo"
  local rtk_exe="${HOME}/.cargo/bin/rtk"
  [[ -x "$cargo_exe" && -x "$rtk_exe" ]] || return 0
  for d in "${HOME}/.cargo/git/checkouts/"rtk-* "${HOME}/.cargo/git/db/"rtk-*; do
    [[ -d "$d" ]] && rm -rf "$d"
  done
  "$cargo_exe" install --git https://github.com/rtk-ai/rtk --branch master --force >/dev/null 2>&1 || return 0
  command_exists claude && "$rtk_exe" init -g --auto-patch >/dev/null 2>&1 || true
  command_exists codex && "$rtk_exe" init -g --codex >/dev/null 2>&1 || true
}
update_rtk
EOF
}

plist_content() {
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LAUNCH_AGENT_ID}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${UPDATE_SCRIPT_PATH}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>StartInterval</key>
  <integer>86400</integer>
  <key>StandardOutPath</key>
  <string>${SUPPORT_DIR}/macos_auto_update.log</string>
  <key>StandardErrorPath</key>
  <string>${SUPPORT_DIR}/macos_auto_update.err.log</string>
</dict>
</plist>
EOF
}

setup_launch_agent() {
  local updater plist
  updater="$(update_script_content)"
  plist="$(plist_content)"

  if (( DRY_RUN )); then
    log "Would write ${UPDATE_SCRIPT_PATH}"
    log "Would write ${LAUNCH_AGENT_PATH}"
    log "Would load launchd agent ${LAUNCH_AGENT_ID}"
    return 0
  fi

  mkdir -p "$SUPPORT_DIR" "$(dirname "$LAUNCH_AGENT_PATH")"
  printf '%s' "$updater" > "$UPDATE_SCRIPT_PATH"
  chmod 0755 "$UPDATE_SCRIPT_PATH"
  printf '%s' "$plist" > "$LAUNCH_AGENT_PATH"
  launchctl bootout "gui/$(id -u)" "$LAUNCH_AGENT_PATH" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$LAUNCH_AGENT_PATH" || launchctl load -w "$LAUNCH_AGENT_PATH"
  log "Configured launchd updater: RunAtLoad and daily."
}

parse_args() {
  local positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        DRY_RUN=1
        ;;
      --no-launch-agent)
        NO_LAUNCH_AGENT=1
        ;;
      -h|--help)
        SUBCOMMAND="help"
        ;;
      install-all|install|setup-launch-agent|launch-agent|list|help)
        positional+=("$1")
        ;;
      *)
        if [[ "$1" == -* ]]; then
          die "Unknown argument: $1 (use --help)"
        fi
        positional+=("$1")
        ;;
    esac
    shift
  done

  if [[ "${SUBCOMMAND}" == "help" || ${#positional[@]} -eq 0 ]]; then
    return 0
  fi

  local command_name
  command_name="$(lower "${positional[0]}")"

  case "$command_name" in
    install-all)
      SUBCOMMAND="install-all"
      ;;
    install)
      SUBCOMMAND="install"
      [[ ${#positional[@]} -ge 2 ]] || die "install requires a target. Use '$SCRIPT_NAME list'."
      TARGET="$(lower "${positional[1]}")"
      ;;
    setup-launch-agent|launch-agent)
      SUBCOMMAND="setup-launch-agent"
      ;;
    list)
      SUBCOMMAND="list"
      ;;
    help)
      SUBCOMMAND="help"
      ;;
    claude|codex|gemini|grok|qwen|copilot|openclaw|ironclaw|mistral|mistral-vibe|vibe|ollama|rtk|all)
      SUBCOMMAND="install"
      TARGET="$command_name"
      ;;
    *)
      die "Unknown command: ${positional[0]} (use --help)"
      ;;
  esac
}

main() {
  parse_args "$@"

  case "$SUBCOMMAND" in
    help)
      print_usage
      print_targets
      exit 0
      ;;
    list)
      print_targets
      exit 0
      ;;
  esac

  case "$SUBCOMMAND" in
    install-all)
      log "Installing all supported AI CLIs for macOS..."
      install_all_targets
      if (( NO_LAUNCH_AGENT )); then
        log "Skipping launchd updater (--no-launch-agent)"
      else
        setup_launch_agent
      fi
      ;;
    install)
      log "Installing macOS CLI target: ${TARGET}"
      install_single_target "$TARGET"
      if (( NO_LAUNCH_AGENT )); then
        log "Skipping launchd updater (--no-launch-agent)"
      else
        setup_launch_agent
      fi
      ;;
    setup-launch-agent)
      if (( NO_LAUNCH_AGENT )); then
        log "Skipping launchd updater (--no-launch-agent)"
      else
        setup_launch_agent
      fi
      ;;
    *)
      die "Unsupported command state: ${SUBCOMMAND}"
      ;;
  esac

  log "Done."
  if [[ "$SUBCOMMAND" == "setup-launch-agent" ]]; then
    log "launchd updater is configured."
  else
    log "Open a new shell and run: claude, codex, gemini, grok, qwen, copilot, openclaw, ironclaw, vibe, ollama"
  fi
}

main "$@"
