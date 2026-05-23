#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="$(basename "$0")"
DRY_RUN=0
NO_CRON=0
CRON_TIME="0 3 * * *"
SUBCOMMAND="install-all"
TARGET="all"

OLLAMA_INSTALL_URL="https://ollama.com/install.sh"
ANTIGRAVITY_GCS_LIST_URL="https://storage.googleapis.com/storage/v1/b/antigravity-public/o?prefix=antigravity-hub/&delimiter=/"
ANTIGRAVITY_GCS_BASE="https://storage.googleapis.com/antigravity-public/"
ANTIGRAVITY_INSTALL_DIR="/opt/antigravity"
VSCODE_DEB_URL="https://code.visualstudio.com/sha/download?build=stable&os=linux-deb-x64"
VSCODE_RPM_URL="https://code.visualstudio.com/sha/download?build=stable&os=linux-rpm-x64"
VSCODE_TARBALL_URL="https://code.visualstudio.com/sha/download?build=stable&os=linux-x64"
VSCODE_INSTALL_DIR="/opt/visual-studio-code"
UPDATE_SCRIPT_PATH="/usr/local/bin/installthecli-linux-update.sh"
CRON_FILE_PATH="/etc/cron.d/installthecli-ai-cli-updates"
UPDATE_LOG_PATH="/var/log/installthecli-linux-update.log"

NPM_FLAGS=(--no-fund --no-audit --no-update-notifier --loglevel error)
PIP_FLAGS=(--disable-pip-version-check --no-input --quiet --break-system-packages --root-user-action=ignore)

DISTRO_FAMILY=""
CRON_SERVICE_NAME=""
PYTHON_BIN=""

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
One-click Linux installer for InstallTheCli (Debian/Ubuntu, Fedora, Arch).

Usage:
  ./install_all_linux.sh [command] [target] [options]

Commands:
  install-all              Install all supported CLIs (default).
  install <target>         Install a single target CLI (plus prerequisites).
  setup-cron               Install/update only the cron updater.
  list                     List supported install targets.
  help                     Show help.

Options:
  --dry-run     Print commands but do not modify the system.
  --no-cron     Skip installing the cron-based auto-update job.
  --cron-time   Daily cron schedule (default: 0 3 * * *).
  -h, --help    Show this help.

This script installs:
  - Node.js + npm (distro package manager)
  - Claude CLI, Codex CLI, Grok CLI, Qwen CLI, GitHub Copilot CLI,
    OpenClaw CLI, IronClaw CLI (npm)
  - Mistral Vibe CLI (Python 3.12+ + pip/uv)
  - Ollama (official install script)
  - Antigravity (official tar.gz from antigravity.google) and Visual Studio Code
    (official .deb/.rpm/tar.gz from code.visualstudio.com)
  - RTK (Rust Token Killer) from git master via cargo (opt-in: 'install rtk')
  - Cron updater (@reboot and daily) unless --no-cron is used
EOF
}

print_targets() {
  cat <<'EOF'
Supported targets:
  claude
  codex
  antigravity
  antigravity_cli
  antigravity_ide
  vscode
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
  ./install_all_linux.sh install codex
  ./install_all_linux.sh install openclaw
  ./install_all_linux.sh install mistral --no-cron
  ./install_all_linux.sh install rtk
  ./install_all_linux.sh install-all --cron-time "15 2 * * *"
  ./install_all_linux.sh setup-cron
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
  /bin/sh -lc "$cmd"
}

require_root() {
  if (( DRY_RUN )); then
    return 0
  fi
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "Run this script as root (or with sudo)."
  fi
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

npm_package_installed() {
  npm ls -g --depth=0 "$1" >/dev/null 2>&1
}

detect_distro_family() {
  if [[ ! -r /etc/os-release ]]; then
    die "/etc/os-release not found. Unsupported Linux distribution."
  fi
  # shellcheck disable=SC1091
  source /etc/os-release
  local haystack="${ID:-} ${ID_LIKE:-}"
  case " ${haystack,,} " in
    *" debian "*|*" ubuntu "*) DISTRO_FAMILY="debian" ;;
    *" fedora "*|*" rhel "*|*" centos "*) DISTRO_FAMILY="fedora" ;;
    *" arch "*) DISTRO_FAMILY="arch" ;;
    *)
      die "Unsupported Linux distribution. Supported: Debian/Ubuntu, Fedora, Arch."
      ;;
  esac
  log "Detected Linux distro family: ${DISTRO_FAMILY}"
}

configure_distro_package_metadata() {
  case "$DISTRO_FAMILY" in
    debian) CRON_SERVICE_NAME="cron" ;;
    fedora) CRON_SERVICE_NAME="crond" ;;
    arch) CRON_SERVICE_NAME="crond" ;;
    *) die "Unsupported distro family: ${DISTRO_FAMILY}" ;;
  esac
}

install_linux_packages() {
  local pkgs=("$@")
  case "$DISTRO_FAMILY" in
    debian)
      run_cmd apt-get update
      run_cmd apt-get install -y "${pkgs[@]}"
      ;;
    fedora)
      run_cmd dnf install -y "${pkgs[@]}"
      ;;
    arch)
      run_cmd pacman -Sy --noconfirm "${pkgs[@]}"
      ;;
    *)
      die "Unsupported distro family: ${DISTRO_FAMILY}"
      ;;
  esac
}

install_base_dependencies() {
  local pkgs=()
  local cron_bin="cron"
  case "$DISTRO_FAMILY" in
    debian)
      cron_bin="cron"
      ;;
    fedora)
      cron_bin="crond"
      ;;
    arch)
      cron_bin="crond"
      ;;
  esac
  pkgs+=(ca-certificates)
  if ! command_exists curl; then
    pkgs+=(curl)
  fi
  if ! command_exists node; then
    pkgs+=(nodejs)
  fi
  if ! command_exists npm; then
    pkgs+=(npm)
  fi

  if ! command_exists python3 && ! command_exists python; then
    if [[ "$DISTRO_FAMILY" == "arch" ]]; then
      pkgs+=(python)
    else
      pkgs+=(python3)
    fi
  fi

  if ! select_python_for_mistral >/dev/null 2>&1; then
    # Ensure pip package is present even if Python exists but is missing pip.
    if [[ "$DISTRO_FAMILY" == "arch" ]]; then
      pkgs+=(python-pip)
    else
      pkgs+=(python3-pip)
    fi
  elif ! "$PYTHON_BIN" -m pip --version >/dev/null 2>&1; then
    if [[ "$DISTRO_FAMILY" == "arch" ]]; then
      pkgs+=(python-pip)
    else
      pkgs+=(python3-pip)
    fi
  fi

  if ! command_exists "$cron_bin"; then
    if [[ "$DISTRO_FAMILY" == "debian" ]]; then
      pkgs+=(cron)
    else
      pkgs+=(cronie)
    fi
  fi

  if [[ ${#pkgs[@]} -eq 0 ]]; then
    log "Base dependencies already available."
    return 0
  fi
  log "Installing base dependencies: ${pkgs[*]}"
  install_linux_packages "${pkgs[@]}"
}

verify_core_binaries() {
  if (( DRY_RUN )); then
    log "Dry-run: skipping post-install binary verification."
    return 0
  fi
  command_exists node || die "node not found after install."
  command_exists npm || die "npm not found after install."
  command_exists curl || die "curl not found after install."
  log "Core tools available: node=$(command -v node), npm=$(command -v npm), curl=$(command -v curl)"
}

python_meets_mistral_requirement() {
  local python_bin="$1"
  "$python_bin" - <<'PY' >/dev/null 2>&1
import sys
raise SystemExit(0 if sys.version_info >= (3, 12) else 1)
PY
}

select_python_for_mistral() {
  local candidate
  for candidate in python3.14 python3 python; do
    if ! command_exists "$candidate"; then
      continue
    fi
    if python_meets_mistral_requirement "$candidate"; then
      PYTHON_BIN="$candidate"
      log "Using Python for Mistral Vibe: $("$candidate" -V 2>&1) (${candidate})"
      return 0
    fi
  done
  return 1
}

ensure_root_local_symlink() {
  local source_path="$1"
  local link_path="$2"
  if [[ ! -x "$source_path" ]]; then
    return 0
  fi
  if [[ -L "$link_path" ]] || [[ -e "$link_path" ]]; then
    return 0
  fi
  run_cmd ln -s "$source_path" "$link_path"
}

install_npm_cli() {
  local label="$1"
  shift
  local candidate
  for candidate in "$@"; do
    log "Trying npm package for ${label}: ${candidate}"
    if run_cmd npm "${NPM_FLAGS[@]}" install -g "$candidate"; then
      log "Installed ${label} using package ${candidate}"
      return 0
    fi
    warn "npm install failed for ${candidate}; trying with --ignore-scripts fallback."
    if run_cmd npm "${NPM_FLAGS[@]}" install -g "$candidate" --ignore-scripts; then
      log "Installed ${label} using package ${candidate} (--ignore-scripts)"
      return 0
    fi
    warn "npm install failed for ${candidate} even with --ignore-scripts; trying next candidate (if any)."
  done
  die "Failed to install ${label} via npm."
}

install_all_npm_clis() {
  install_npm_cli "Claude CLI" "@anthropic-ai/claude-code"
  install_npm_cli "Codex CLI" "@openai/codex"
  install_npm_cli "Grok CLI (Vibe Kit)" "@vibe-kit/grok-cli"
  install_npm_cli "Qwen CLI" "@qwen-code/qwen-code" "qwen-code"
  install_npm_cli "GitHub Copilot CLI" "@github/copilot" "@githubnext/github-copilot-cli"
  install_npm_cli "OpenClaw CLI" "openclaw"
  install_npm_cli "IronClaw CLI" "ironclaw"
}

install_npm_target() {
  local target="$1"
  case "$target" in
    claude) install_npm_cli "Claude CLI" "@anthropic-ai/claude-code" ;;
    codex) install_npm_cli "Codex CLI" "@openai/codex" ;;
    grok) install_npm_cli "Grok CLI (Vibe Kit)" "@vibe-kit/grok-cli" ;;
    qwen) install_npm_cli "Qwen CLI" "@qwen-code/qwen-code" "qwen-code" ;;
    copilot) install_npm_cli "GitHub Copilot CLI" "@github/copilot" "@githubnext/github-copilot-cli" ;;
    openclaw) install_npm_cli "OpenClaw CLI" "openclaw" ;;
    ironclaw) install_npm_cli "IronClaw CLI" "ironclaw" ;;
    *)
      return 1
      ;;
  esac
  return 0
}

install_mistral_vibe() {
  select_python_for_mistral || die "Python 3.12+ is required for Mistral Vibe CLI."

  run_cmd "$PYTHON_BIN" -m pip install --user --upgrade "${PIP_FLAGS[@]}" pip
  run_cmd "$PYTHON_BIN" -m pip install --user --upgrade "${PIP_FLAGS[@]}" uv

  export PATH="/root/.local/bin:${PATH}"
  if command_exists uv; then
    if run_cmd uv tool install --upgrade mistral-vibe; then
      log "Installed Mistral Vibe CLI using uv."
    else
      warn "uv tool install failed; falling back to pip."
      run_cmd "$PYTHON_BIN" -m pip install --user --upgrade "${PIP_FLAGS[@]}" mistral-vibe
      log "Installed Mistral Vibe CLI using pip."
    fi
  else
    warn "uv not found after install; falling back to pip."
    run_cmd "$PYTHON_BIN" -m pip install --user --upgrade "${PIP_FLAGS[@]}" mistral-vibe
    log "Installed Mistral Vibe CLI using pip."
  fi

  ensure_root_local_symlink "/root/.local/bin/uv" "/usr/local/bin/uv"
  ensure_root_local_symlink "/root/.local/bin/vibe" "/usr/local/bin/vibe"
  ensure_root_local_symlink "/root/.local/bin/mistral-vibe" "/usr/local/bin/mistral-vibe"
}

install_ollama_official() {
  if command_exists ollama; then
    log "Ollama already available: $(command -v ollama)"
  fi
  run_shell "curl -fsSL ${OLLAMA_INSTALL_URL} | sh"
  if command_exists ollama; then
    log "Ollama CLI available: $(command -v ollama)"
  fi
}

# Resolve the newest Antigravity Linux tarball URL by listing the public Google
# Cloud Storage bucket (there is no stable "latest" alias). Skips non-numeric
# (e.g. dogfood) prefixes and the 100.0.0 canary sentinel. Prints the URL.
resolve_antigravity_tarball_url() {
  command_exists curl || install_linux_packages curl
  command_exists python3 || install_linux_packages python3
  local listing
  listing="$(curl -fsSL "$ANTIGRAVITY_GCS_LIST_URL" 2>/dev/null)" || return 1
  local prefix
  prefix="$(printf '%s' "$listing" | python3 - <<'PY'
import json, sys
try:
    data = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
best = None
best_key = None
for p in data.get("prefixes", []):
    rel = p[len("antigravity-hub/"):] if p.startswith("antigravity-hub/") else p
    rel = rel.strip("/")
    if "-" not in rel:
        continue
    ver, _, build = rel.partition("-")
    parts = ver.split(".")
    if len(parts) != 3 or not all(x.isdigit() for x in parts) or not build.isdigit():
        continue
    v = tuple(int(x) for x in parts)
    if v[0] >= 100:
        continue
    key = (v, int(build))
    if best_key is None or key > best_key:
        best_key = key
        best = p if p.endswith("/") else p + "/"
print(best or "")
PY
)" || return 1
  [[ -n "$prefix" ]] || return 1
  printf '%s%slinux-x64/Antigravity.tar.gz\n' "$ANTIGRAVITY_GCS_BASE" "$prefix"
}

install_antigravity_linux() {
  if (( DRY_RUN )); then
    log "[dry-run] resolve latest Antigravity tarball from ${ANTIGRAVITY_GCS_LIST_URL}"
    log "[dry-run] download + extract to ${ANTIGRAVITY_INSTALL_DIR} and symlink antigravity into /usr/local/bin"
    return 0
  fi
  command_exists curl || install_linux_packages curl
  command_exists tar || install_linux_packages tar
  local url
  url="$(resolve_antigravity_tarball_url)" || die "Could not resolve the latest Antigravity Linux download URL."
  log "Downloading Antigravity from ${url}"
  local tmp
  tmp="$(mktemp -d)"
  curl -fsSL -o "${tmp}/antigravity.tar.gz" "$url" || { rm -rf "$tmp"; die "Antigravity download failed."; }
  mkdir -p "${tmp}/x"
  tar -xzf "${tmp}/antigravity.tar.gz" -C "${tmp}/x" || { rm -rf "$tmp"; die "Antigravity extraction failed."; }
  local launcher
  launcher="$(find "${tmp}/x" -type f -name antigravity -path '*/bin/antigravity' 2>/dev/null | head -n1)"
  [[ -n "$launcher" ]] || launcher="$(find "${tmp}/x" -type f -name antigravity 2>/dev/null | head -n1)"
  [[ -n "$launcher" ]] || { rm -rf "$tmp"; die "Antigravity archive did not contain an 'antigravity' launcher."; }
  local app_root
  app_root="$(find "${tmp}/x" -mindepth 1 -maxdepth 1 -type d | head -n1)"
  [[ -n "$app_root" ]] || app_root="${tmp}/x"
  local rel="${launcher#"${app_root}"/}"
  rm -rf "$ANTIGRAVITY_INSTALL_DIR"
  cp -a "$app_root" "$ANTIGRAVITY_INSTALL_DIR"
  chmod +x "${ANTIGRAVITY_INSTALL_DIR}/${rel}" 2>/dev/null || true
  ln -sf "${ANTIGRAVITY_INSTALL_DIR}/${rel}" /usr/local/bin/antigravity
  rm -rf "$tmp"
  log "Installed Antigravity to ${ANTIGRAVITY_INSTALL_DIR} and linked antigravity into /usr/local/bin."
}

install_antigravity_cli_linux() {
  if (( DRY_RUN )); then
    log "[dry-run] install Antigravity CLI via official install.sh"
    return 0
  fi
  log "Installing standalone Antigravity CLI (agy) via official installer..."
  curl -fsSL https://antigravity.google/cli/install.sh | bash
}

install_vscode_linux() {
  case "$DISTRO_FAMILY" in
    debian)
      if (( DRY_RUN )); then
        log "[dry-run] download ${VSCODE_DEB_URL} and apt-get install -y the .deb"
        return 0
      fi
      command_exists curl || install_linux_packages curl
      local tmp
      tmp="$(mktemp -d)"
      curl -fsSL -L -o "${tmp}/code.deb" "$VSCODE_DEB_URL" || { rm -rf "$tmp"; die "Visual Studio Code download failed."; }
      run_cmd apt-get install -y "${tmp}/code.deb"
      rm -rf "$tmp"
      ;;
    fedora)
      if (( DRY_RUN )); then
        log "[dry-run] download ${VSCODE_RPM_URL} and dnf install -y the .rpm"
        return 0
      fi
      command_exists curl || install_linux_packages curl
      local tmp
      tmp="$(mktemp -d)"
      curl -fsSL -L -o "${tmp}/code.rpm" "$VSCODE_RPM_URL" || { rm -rf "$tmp"; die "Visual Studio Code download failed."; }
      run_cmd dnf install -y "${tmp}/code.rpm"
      rm -rf "$tmp"
      ;;
    *)
      # Arch and other families: install the official stable tarball under /opt.
      if (( DRY_RUN )); then
        log "[dry-run] download ${VSCODE_TARBALL_URL}, extract to ${VSCODE_INSTALL_DIR}, symlink code"
        return 0
      fi
      command_exists curl || install_linux_packages curl
      command_exists tar || install_linux_packages tar
      local tmp
      tmp="$(mktemp -d)"
      curl -fsSL -L -o "${tmp}/code.tgz" "$VSCODE_TARBALL_URL" || { rm -rf "$tmp"; die "Visual Studio Code download failed."; }
      mkdir -p "${tmp}/x"
      tar -xzf "${tmp}/code.tgz" -C "${tmp}/x" || { rm -rf "$tmp"; die "Visual Studio Code extraction failed."; }
      local app_root
      app_root="$(find "${tmp}/x" -mindepth 1 -maxdepth 1 -type d | head -n1)"
      [[ -n "$app_root" ]] || { rm -rf "$tmp"; die "Visual Studio Code archive layout was unexpected."; }
      rm -rf "$VSCODE_INSTALL_DIR"
      cp -a "$app_root" "$VSCODE_INSTALL_DIR"
      ln -sf "${VSCODE_INSTALL_DIR}/bin/code" /usr/local/bin/code
      rm -rf "$tmp"
      ;;
  esac
  if command_exists code; then
    log "Visual Studio Code CLI available: $(command -v code)"
  fi
}

# Install rustup + cargo if missing. Uses the official rustup-init script with
# --default-toolchain stable --profile minimal so we get just enough Rust to
# `cargo install` rtk.
ensure_rust_toolchain() {
  local cargo_bin="/root/.cargo/bin"
  if [[ -x "$cargo_bin/cargo" ]]; then
    log "cargo already available: $cargo_bin/cargo"
    export PATH="$cargo_bin:$PATH"
    return 0
  fi
  if ! command_exists curl; then
    install_linux_packages curl
  fi
  log "Installing Rust toolchain via rustup (minimal profile, stable)"
  if (( DRY_RUN )); then
    log "[dry-run] curl -fsSL https://sh.rustup.rs | sh -s -- -y --default-toolchain stable --profile minimal --no-modify-path"
  else
    /bin/sh -lc "curl -fsSL https://sh.rustup.rs | sh -s -- -y --default-toolchain stable --profile minimal --no-modify-path"
  fi
  export PATH="$cargo_bin:$PATH"
  if (( ! DRY_RUN )) && ! command_exists cargo; then
    die "cargo not found after rustup install. Open a new shell and rerun."
  fi
}

rtk_has_any_command() {
  local name
  for name in "$@"; do
    command_exists "$name" && return 0
  done
  return 1
}

configure_rtk_supported_agents() {
  local rtk_bin="$1"
  if rtk_has_any_command copilot github-copilot-cli github-copilot; then
    log "Registering rtk for GitHub Copilot CLI"
    "$rtk_bin" init -g --copilot || warn "rtk init (Copilot) failed"
  fi
  if command_exists opencode; then
    log "Registering rtk for OpenCode"
    "$rtk_bin" init -g --opencode || warn "rtk init (OpenCode) failed"
  fi
  local agent
  for agent in cursor windsurf cline kilocode antigravity hermes; do
    if command_exists "$agent"; then
      log "Registering rtk for ${agent}"
      "$rtk_bin" init -g --agent "$agent" || warn "rtk init (${agent}) failed"
    fi
  done
}

configure_rtk_integrations() {
  local rtk_bin="$1"
  if command_exists claude; then
    log "Registering rtk hook for Claude Code"
    "$rtk_bin" init -g --auto-patch || warn "rtk init (Claude) failed"
  fi
  if command_exists codex; then
    log "Registering rtk for Codex CLI"
    "$rtk_bin" init -g --codex || warn "rtk init (Codex) failed"
  fi
  configure_rtk_supported_agents "$rtk_bin"
}

# Install rtk-ai/rtk from git master via `cargo install`. The cargo git
# checkout cache is cleared first so we always pick up new commits on master;
# without this, cargo silently rebuilds the same old SHA when only the
# branch ref has moved (the rtk repo was bitten by this at 0.34.3 -> 0.40.0).
install_rtk() {
  ensure_rust_toolchain
  local cargo_bin="/root/.cargo/bin"
  local rtk_bin="$cargo_bin/rtk"
  local cargo_exe="$cargo_bin/cargo"

  for d in /root/.cargo/git/checkouts/rtk-* /root/.cargo/git/db/rtk-*; do
    if [[ -d "$d" ]]; then
      log "Clearing cargo git cache: $d"
      run_cmd rm -rf "$d"
    fi
  done

  log "Installing rtk from https://github.com/rtk-ai/rtk (branch master) via cargo"
  run_cmd "$cargo_exe" install --git https://github.com/rtk-ai/rtk --branch master --force

  # Surface rtk on PATH for any login shell. /root/.local/bin is already
  # added to PATH by /root/.profile on Debian-family root accounts, but the
  # cargo bin dir is not, so a symlink there is the simplest fix.
  if (( ! DRY_RUN )); then
    mkdir -p /root/.local/bin
    ln -sfn "$rtk_bin" /root/.local/bin/rtk
    log "Linked /root/.local/bin/rtk -> $rtk_bin"
  fi

  # Wire rtk into compatible AI CLIs if those CLIs are installed.
  if (( ! DRY_RUN )) && [[ -x "$rtk_bin" ]]; then
    configure_rtk_integrations "$rtk_bin"
    log "Installed rtk: $("$rtk_bin" --version 2>&1)"
  fi
}

install_all_targets() {
  install_all_npm_clis
  install_mistral_vibe
  install_ollama_official
  install_antigravity_linux
  install_antigravity_cli_linux
  install_vscode_linux
}

install_single_target() {
  local target_key="${1,,}"
  case "$target_key" in
    all)
      install_all_targets
      ;;
    mistral|mistral-vibe|vibe)
      install_mistral_vibe
      ;;
    ollama)
      install_ollama_official
      ;;
    antigravity)
      install_antigravity_linux
      ;;
    antigravity_cli|agy)
      install_antigravity_cli_linux
      ;;
    antigravity_ide)
      die "Antigravity IDE is not available on Linux."
      ;;
    vscode|code)
      install_vscode_linux
      ;;
    rtk)
      install_rtk
      ;;
    claude|codex|grok|qwen|copilot|openclaw|ironclaw)
      install_npm_target "$target_key"
      ;;
    *)
      die "Unknown target: ${target_key}. Use '$SCRIPT_NAME list' to see supported targets."
      ;;
  esac
}

update_script_content() {
  cat <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
PATH="/root/.local/bin:/root/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
LOG_PREFIX="[installthecli-update]"
OLLAMA_INSTALL_URL="https://ollama.com/install.sh"
NPM_FLAGS=(--no-fund --no-audit --no-update-notifier --loglevel error)
PIP_FLAGS=(--disable-pip-version-check --no-input --quiet --break-system-packages --root-user-action=ignore)

log() {
  printf '%s %s\n' "${LOG_PREFIX}" "$*"
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

run_cmd() {
  log "+ $*"
  "$@"
}

run_shell() {
  log "+ $1"
  /bin/sh -lc "$1"
}

npm_package_installed() {
  npm ls -g --depth=0 "$1" >/dev/null 2>&1
}

update_npm_cli() {
  local label="$1"
  shift
  local candidate
  for candidate in "$@"; do
    if ! npm_package_installed "$candidate"; then
      continue
    fi
    if run_cmd npm "${NPM_FLAGS[@]}" install -g "${candidate}@latest"; then
      log "Updated ${label} via ${candidate}"
      return 0
    fi
  done
  log "Skipped or failed to update ${label}"
  return 0
}

update_npm_all() {
  if ! command_exists npm; then
    log "npm not found; skipping npm CLI updates"
    return 0
  fi
  update_npm_cli "Claude CLI" "@anthropic-ai/claude-code"
  update_npm_cli "Codex CLI" "@openai/codex"
  update_npm_cli "Grok CLI (Vibe Kit)" "@vibe-kit/grok-cli"
  update_npm_cli "Qwen CLI" "@qwen-code/qwen-code" "qwen-code"
  update_npm_cli "GitHub Copilot CLI" "@github/copilot" "@githubnext/github-copilot-cli"
  update_npm_cli "OpenClaw CLI" "openclaw"
  update_npm_cli "IronClaw CLI" "ironclaw"
}

select_python() {
  local candidate
  for candidate in python3.14 python3 python; do
    if ! command_exists "$candidate"; then
      continue
    fi
    if "$candidate" - <<'PY' >/dev/null 2>&1
import sys
raise SystemExit(0 if sys.version_info >= (3, 12) else 1)
PY
    then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

ensure_root_symlink_if_missing() {
  local source_path="$1"
  local link_path="$2"
  if [[ -x "$source_path" && ! -e "$link_path" ]]; then
    ln -s "$source_path" "$link_path" || true
  fi
}

update_mistral_vibe() {
  local py
  py="$(select_python || true)"
  if [[ -z "${py}" ]]; then
    log "Python 3.12+ not found; skipping Mistral Vibe update"
    return 0
  fi
  run_cmd "$py" -m pip install --user --upgrade "${PIP_FLAGS[@]}" pip || true
  run_cmd "$py" -m pip install --user --upgrade "${PIP_FLAGS[@]}" uv || true
  if command_exists uv; then
    run_cmd uv tool install --upgrade mistral-vibe || true
  else
    run_cmd "$py" -m pip install --user --upgrade "${PIP_FLAGS[@]}" mistral-vibe || true
  fi
  ensure_root_symlink_if_missing "/root/.local/bin/uv" "/usr/local/bin/uv"
  ensure_root_symlink_if_missing "/root/.local/bin/vibe" "/usr/local/bin/vibe"
  ensure_root_symlink_if_missing "/root/.local/bin/mistral-vibe" "/usr/local/bin/mistral-vibe"
}

update_ollama() {
  if ! command_exists curl; then
    log "curl not found; skipping Ollama update"
    return 0
  fi
  run_shell "curl -fsSL ${OLLAMA_INSTALL_URL} | sh" || true
}

rtk_has_any_command() {
  local name
  for name in "$@"; do
    command_exists "$name" && return 0
  done
  return 1
}

configure_rtk_supported_agents() {
  local rtk_bin="$1"
  rtk_has_any_command copilot github-copilot-cli github-copilot && "$rtk_bin" init -g --copilot >/dev/null 2>&1 || true
  command_exists opencode && "$rtk_bin" init -g --opencode >/dev/null 2>&1 || true
  local agent
  for agent in cursor windsurf cline kilocode antigravity hermes; do
    command_exists "$agent" && "$rtk_bin" init -g --agent "$agent" >/dev/null 2>&1 || true
  done
}

configure_rtk_integrations() {
  local rtk_bin="$1"
  command_exists claude && "$rtk_bin" init -g --auto-patch >/dev/null 2>&1 || true
  command_exists codex && "$rtk_bin" init -g --codex >/dev/null 2>&1 || true
  configure_rtk_supported_agents "$rtk_bin"
}

# Rebuild rtk from latest git master if it's already installed. Mirrors the
# install path: bust the cargo git checkout cache for the rtk repo so cargo
# actually picks up new commits (the --force flag alone doesn't refetch a
# cached checkout if only the ref moved), then rebuild from --branch master.
# Refresh the /root/.local/bin/rtk symlink so it points at the new binary,
# and re-run rtk init so any new hook capabilities or RTK.md content land.
update_rtk() {
  local cargo_bin="/root/.cargo/bin"
  local rtk_bin="$cargo_bin/rtk"
  if [[ ! -x "$cargo_bin/cargo" ]] || [[ ! -x "$rtk_bin" ]]; then
    log "rtk not installed; skipping rtk update"
    return 0
  fi
  for d in /root/.cargo/git/checkouts/rtk-* /root/.cargo/git/db/rtk-*; do
    [[ -d "$d" ]] && rm -rf "$d"
  done
  if ! run_cmd "$cargo_bin/cargo" install --git https://github.com/rtk-ai/rtk --branch master --force; then
    log "rtk cargo install failed; keeping previous binary"
    return 0
  fi
  ln -sfn "$rtk_bin" /root/.local/bin/rtk 2>/dev/null || true
  configure_rtk_integrations "$rtk_bin"
  log "Updated rtk to $("$rtk_bin" --version 2>&1)"
}

main() {
  update_npm_all
  update_mistral_vibe
  update_ollama
  update_rtk
}

main "$@"
EOF
}

cron_file_content() {
  cat <<EOF
SHELL=/bin/bash
PATH=/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
@reboot root ${UPDATE_SCRIPT_PATH} >> ${UPDATE_LOG_PATH} 2>&1
${CRON_TIME} root ${UPDATE_SCRIPT_PATH} >> ${UPDATE_LOG_PATH} 2>&1
EOF
}

write_root_file() {
  local path="$1"
  local mode="$2"
  local content="$3"
  if (( DRY_RUN )); then
    log "Would write ${path} (mode ${mode})"
    return 0
  fi
  mkdir -p "$(dirname "$path")"
  printf '%s' "$content" > "$path"
  chmod "$mode" "$path"
}

enable_cron_service() {
  if command_exists systemctl; then
    if run_cmd systemctl enable --now "$CRON_SERVICE_NAME"; then
      return 0
    fi
    warn "systemctl could not enable/start ${CRON_SERVICE_NAME}; trying service command."
  fi
  if command_exists service; then
    run_cmd service "$CRON_SERVICE_NAME" start || warn "Failed to start ${CRON_SERVICE_NAME} via service."
    return 0
  fi
  warn "No supported service manager found. Cron may already be running."
}

setup_cron_updater() {
  local updater cron_file
  updater="$(update_script_content)"
  cron_file="$(cron_file_content)"

  write_root_file "$UPDATE_SCRIPT_PATH" "0755" "$updater"
  write_root_file "$CRON_FILE_PATH" "0644" "$cron_file"
  if (( DRY_RUN )); then
    log "Would ensure update log file exists: ${UPDATE_LOG_PATH}"
  else
    touch "$UPDATE_LOG_PATH"
    chmod 0644 "$UPDATE_LOG_PATH" || true
  fi
  enable_cron_service
  log "Configured cron updater: @reboot and daily (${CRON_TIME})"
}

parse_args() {
  local positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        DRY_RUN=1
        ;;
      --no-cron)
        NO_CRON=1
        ;;
      --cron-time)
        shift
        [[ $# -gt 0 ]] || die "--cron-time requires a value"
        CRON_TIME="$1"
        ;;
      -h|--help)
        SUBCOMMAND="help"
        ;;
      install-all|install|setup-cron|cron|list|help)
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

  if [[ "${SUBCOMMAND}" == "help" ]]; then
    return 0
  fi

  if [[ ${#positional[@]} -eq 0 ]]; then
    return 0
  fi

  case "${positional[0],,}" in
    install-all)
      SUBCOMMAND="install-all"
      ;;
    install)
      SUBCOMMAND="install"
      [[ ${#positional[@]} -ge 2 ]] || die "install requires a target. Use '$SCRIPT_NAME list'."
      TARGET="${positional[1],,}"
      ;;
    setup-cron|cron)
      SUBCOMMAND="setup-cron"
      ;;
    list)
      SUBCOMMAND="list"
      ;;
    help)
      SUBCOMMAND="help"
      ;;
    claude|codex|antigravity|antigravity_cli|antigravity_ide|agy|vscode|code|grok|qwen|copilot|openclaw|ironclaw|mistral|mistral-vibe|vibe|ollama|rtk|all)
      # Convenience alias: treat first positional target as "install <target>"
      SUBCOMMAND="install"
      TARGET="${positional[0],,}"
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

  require_root
  detect_distro_family
  configure_distro_package_metadata

  case "$SUBCOMMAND" in
    install-all)
      log "Installing all supported AI CLIs for Linux..."
      install_base_dependencies
      verify_core_binaries
      install_all_targets
      if (( NO_CRON )); then
        log "Skipping cron updater (--no-cron)"
      else
        setup_cron_updater
      fi
      ;;
    install)
      log "Installing Linux CLI target: ${TARGET}"
      install_base_dependencies
      verify_core_binaries
      install_single_target "$TARGET"
      if (( NO_CRON )); then
        log "Skipping cron updater (--no-cron)"
      else
        setup_cron_updater
      fi
      ;;
    setup-cron)
      if (( NO_CRON )); then
        log "Skipping cron updater (--no-cron)"
      else
        setup_cron_updater
      fi
      ;;
    *)
      die "Unsupported command state: ${SUBCOMMAND}"
      ;;
  esac

  log "Done."
  if [[ "$SUBCOMMAND" == "setup-cron" ]]; then
    log "Cron updater is configured."
  else
    log "Open a new shell and run: claude, codex, antigravity, code, grok, qwen, copilot, openclaw, ironclaw, vibe, ollama"
  fi
}

main "$@"
