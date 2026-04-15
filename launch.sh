#!/usr/bin/env bash
set -euo pipefail

# WARNING:
# OpenClaw agents can execute shell commands, read files, and install software.
# Production deployments should isolate agent runtimes, restrict permissions,
# and add approval layers for destructive actions.

SOURCE_PATH="${BASH_SOURCE[0]-}"
if [[ -z "$SOURCE_PATH" || "$SOURCE_PATH" == "bash" || "$SOURCE_PATH" == "-bash" ]]; then
  SCRIPT_DIR="$PWD"
else
  SCRIPT_DIR="$(cd "$(dirname "$SOURCE_PATH")" && pwd)"
fi

CODE_SERVER_VERSION="${CODE_SERVER_VERSION:-4.89.1}"
CODE_SERVER_PORT="${CODE_SERVER_PORT:-13337}"
OPENCLAW_ENV_FILE="${OPENCLAW_ENV_FILE:-$HOME/.openclaw/.env}"
LAUNCH_REPO_URL="${LAUNCH_REPO_URL:-https://github.com/liveaverage/launch-openclaw.git}"
LAUNCH_REPO_REF="${LAUNCH_REPO_REF:-main}"
LAUNCH_REPO_DIR="${LAUNCH_REPO_DIR:-$HOME/launch-openclaw}"
OSMO_REPO_URL="${OSMO_REPO_URL:-https://github.com/maufrancom/OSMO.git}"
OSMO_REPO_REF="${OSMO_REPO_REF:-main}"
OSMO_REPO_DIR="${OSMO_REPO_DIR:-$HOME/OSMO}"
NUREC_REPO_URL="${NUREC_REPO_URL:-https://gitlab-master.nvidia.com/tse/nurec-workflows.git}"
NUREC_REPO_REF="${NUREC_REPO_REF:-main}"
NUREC_REPO_DIR="${NUREC_REPO_DIR:-$HOME/nurec-workflows}"
TARGET_USER="${SUDO_USER:-$(id -un)}"
TARGET_HOME="${HOME}"

log() {
  printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

fail() {
  printf '\nERROR: %s\n' "$*" >&2
  exit 1
}

require_non_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    fail "Run this script as the target user, not root. The script will use sudo only when required."
  fi
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

run_as_root() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    fail "This step requires root privileges and sudo is not available: $*"
  fi
}

append_path_if_dir() {
  local dir="$1"
  if [[ -d "$dir" && ":$PATH:" != *":$dir:"* ]]; then
    export PATH="$dir:$PATH"
  fi
}

ensure_path_line_in_shell_rc() {
  local dir="$1"
  local rc_file="$2"
  local line

  mkdir -p "$(dirname "$rc_file")"
  touch "$rc_file"
  line="export PATH=\"$dir:\$PATH\""

  if ! grep -Fqx "$line" "$rc_file"; then
    printf '\n%s\n' "$line" >>"$rc_file"
  fi
}

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '%s' "$value"
}

wait_for_tcp_port() {
  local port="$1"
  local timeout_secs="${2:-30}"
  local start_ts
  start_ts="$(date +%s)"

  while true; do
    if (echo >"/dev/tcp/127.0.0.1/$port") >/dev/null 2>&1; then
      return 0
    fi

    if (( "$(date +%s)" - start_ts >= timeout_secs )); then
      return 1
    fi

    sleep 1
  done
}

detect_deb_arch() {
  case "$(uname -m)" in
    x86_64|amd64) printf 'amd64\n' ;;
    aarch64|arm64) printf 'arm64\n' ;;
    *) fail "Unsupported architecture: $(uname -m)" ;;
  esac
}

clone_or_refresh_launch_repo() {
  clone_or_refresh_repo "$LAUNCH_REPO_URL" "$LAUNCH_REPO_REF" "$LAUNCH_REPO_DIR" "launch-openclaw"
  [[ -f "$LAUNCH_REPO_DIR/configure.sh" ]] || fail "configure.sh not found in cloned repo: $LAUNCH_REPO_DIR"
}

get_node_major() {
  if ! command -v node >/dev/null 2>&1; then
    printf '0\n'
    return
  fi

  node -p "process.versions.node.split('.')[0]" 2>/dev/null || printf '0\n'
}

is_openclaw_configured() {
  [[ -f "$OPENCLAW_ENV_FILE" && -f "$HOME/.openclaw/openclaw.json" ]]
}

derive_openclaw_origin() {
  local host_name env_id
  host_name="$(hostname 2>/dev/null || true)"
  env_id="$(printf '%s\n' "$host_name" | sed -E 's/^brev-([[:alnum:]]+)$/\1/')"

  if [[ -n "$env_id" && "$env_id" != "$host_name" ]]; then
    printf 'https://openclaw0-%s.brevlab.com\n' "$env_id"
  else
    printf 'http://localhost:3000\n'
  fi
}

derive_code_server_origin() {
  local host_name env_id
  host_name="$(hostname 2>/dev/null || true)"
  env_id="$(printf '%s\n' "$host_name" | sed -E 's/^brev-([[:alnum:]]+)$/\1/')"

  if [[ -n "$env_id" && "$env_id" != "$host_name" ]]; then
    printf 'https://code-server0-%s.brevlab.com\n' "$env_id"
  else
    printf 'http://localhost:%s\n' "$CODE_SERVER_PORT"
  fi
}

ensure_node() {
  local node_major
  node_major="$(get_node_major)"

  if [[ "$node_major" -ge 22 ]]; then
    log "Node.js $(node --version) already satisfies the >=22 requirement"
    return
  fi

  log "Installing Node.js 22 from NodeSource"
  require_cmd curl
  command -v apt-get >/dev/null 2>&1 || fail "This script currently supports Ubuntu/Debian environments with apt-get"

  run_as_root apt-get update
  run_as_root apt-get install -y ca-certificates curl gnupg
  curl -fsSL https://deb.nodesource.com/setup_22.x | run_as_root bash -
  run_as_root apt-get install -y nodejs

  log "Installed Node.js $(node --version)"
}

ensure_openclaw_installed() {
  local npm_prefix npm_global_bin

  append_path_if_dir "$HOME/.npm-global/bin"
  append_path_if_dir "$HOME/.local/bin"
  append_path_if_dir "$HOME/bin"

  if command -v openclaw >/dev/null 2>&1; then
    log "OpenClaw CLI already present at $(command -v openclaw)"
  else
    log "Installing OpenClaw with the official installer (onboarding disabled)"
    require_cmd curl
    curl -fsSL https://openclaw.ai/install.sh | OPENCLAW_NO_ONBOARD=1 bash
  fi

  npm_prefix="$(npm config get prefix 2>/dev/null || true)"
  if [[ -n "$npm_prefix" && "$npm_prefix" != "undefined" && "$npm_prefix" != "null" ]]; then
    npm_global_bin="${npm_prefix%/}/bin"
    append_path_if_dir "$npm_global_bin"
    ensure_path_line_in_shell_rc "$npm_global_bin" "$HOME/.bashrc"
    ensure_path_line_in_shell_rc "$npm_global_bin" "$HOME/.profile"
  fi

  append_path_if_dir "$HOME/.npm-global/bin"
  append_path_if_dir "$HOME/.local/bin"
  append_path_if_dir "$HOME/bin"
  command -v openclaw >/dev/null 2>&1 || fail "OpenClaw installation completed, but the CLI is not on PATH"
  log "OpenClaw CLI available at $(command -v openclaw)"
}

verify_openclaw_cli() {
  log "Verifying OpenClaw CLI"
  if ! openclaw --help >/dev/null 2>&1; then
    fail "The OpenClaw CLI failed to run. Check PATH, reinstall with the official installer, and retry."
  fi
}

detect_bazelisk_arch() {
  case "$(uname -m)" in
    x86_64|amd64) printf 'amd64\n' ;;
    aarch64|arm64) printf 'arm64\n' ;;
    *) fail "Unsupported architecture for Bazelisk: $(uname -m)" ;;
  esac
}

ensure_bazel() {
  if command -v bazel >/dev/null 2>&1; then
    log "Bazel already installed: $(bazel --version 2>/dev/null | head -n 1)"
    return
  fi

  local arch
  arch="$(detect_bazelisk_arch)"

  log "Installing Bazelisk (Bazel launcher)"
  require_cmd curl
  curl -fsSL "https://github.com/bazelbuild/bazelisk/releases/latest/download/bazelisk-linux-${arch}" -o /tmp/bazelisk
  chmod +x /tmp/bazelisk
  run_as_root install -m 755 /tmp/bazelisk /usr/local/bin/bazel
  rm -f /tmp/bazelisk

  append_path_if_dir "/usr/local/bin"
  command -v bazel >/dev/null 2>&1 || fail "Bazelisk installation completed, but bazel is not on PATH"
  log "Bazel available at $(command -v bazel)"
}

ensure_ngc_cli() {
  if command -v ngc >/dev/null 2>&1; then
    log "NGC CLI already installed: $(ngc --version 2>/dev/null | head -n 1)"
    return
  fi

  log "Installing NGC CLI"
  require_cmd curl

  local tmp_zip tmp_dir
  tmp_zip="$(mktemp /tmp/ngccli_linux.XXXXXX.zip)"
  tmp_dir="$(mktemp -d /tmp/ngc-install.XXXXXX)"

  curl -fSL "https://ngc.nvidia.com/downloads/ngccli_linux.zip" -o "$tmp_zip"

  run_as_root apt-get install -y unzip >/dev/null 2>&1 || true
  unzip -o "$tmp_zip" -d "$tmp_dir"
  run_as_root install -m 755 "$tmp_dir/ngc-cli/ngc" /usr/local/bin/ngc
  rm -rf "$tmp_zip" "$tmp_dir"

  append_path_if_dir "/usr/local/bin"
  command -v ngc >/dev/null 2>&1 || fail "NGC CLI installation completed, but ngc is not on PATH"
  log "NGC CLI available at $(command -v ngc)"
}

clone_or_refresh_repo() {
  local repo_url="$1"
  local repo_ref="$2"
  local repo_dir="$3"
  local label="$4"

  log "Ensuring ${label} repo is available at ${repo_dir}"
  mkdir -p "$(dirname "$repo_dir")"

  if [[ -d "$repo_dir/.git" ]]; then
    git -C "$repo_dir" fetch --tags --prune origin
    git -C "$repo_dir" checkout "$repo_ref"
    git -C "$repo_dir" pull --ff-only origin "$repo_ref"
  elif [[ -e "$repo_dir" ]]; then
    fail "${label} repo target exists but is not a git checkout: $repo_dir"
  else
    git clone --branch "$repo_ref" "$repo_url" "$repo_dir"
  fi
}

install_osmo() {
  log "Installing OSMO from source"
  require_cmd git

  clone_or_refresh_repo "$OSMO_REPO_URL" "$OSMO_REPO_REF" "$OSMO_REPO_DIR" "OSMO"

  log "Ensuring C++ toolchain is available for Bazel"
  if ! command -v g++ >/dev/null 2>&1; then
    run_as_root apt-get update
    run_as_root apt-get install -y g++
  fi

  log "Building OSMO with Bazel"
  require_cmd bazel
  (cd "$OSMO_REPO_DIR" && bazel build //...)

  log "OSMO build complete"
}

clone_nurec_workflows() {
  require_cmd git
  clone_or_refresh_repo "$NUREC_REPO_URL" "$NUREC_REPO_REF" "$NUREC_REPO_DIR" "nurec-workflows"
}

install_code_server() {
  local deb_arch tmp_deb url

  if command -v code-server >/dev/null 2>&1; then
    log "code-server already installed: $(code-server --version | head -n 1)"
    return
  fi

  require_cmd curl
  command -v apt-get >/dev/null 2>&1 || fail "code-server installation requires apt-get"

  deb_arch="$(detect_deb_arch)"
  tmp_deb="$(mktemp /tmp/code-server.XXXXXX.deb)"
  url="https://github.com/coder/code-server/releases/download/v${CODE_SERVER_VERSION}/code-server_${CODE_SERVER_VERSION}_${deb_arch}.deb"

  log "Installing code-server ${CODE_SERVER_VERSION}"
  curl -fsSL "$url" -o "$tmp_deb"
  run_as_root apt-get install -y "$tmp_deb"
  rm -f "$tmp_deb"
}

install_code_server_extensions() {
  local config_dir theme_vsix source_theme_vsix

  config_dir="$TARGET_HOME/.config/code-server"
  theme_vsix="$config_dir/nv-theme-0.0.1.vsix"
  source_theme_vsix="$LAUNCH_REPO_DIR/nv-theme-0.0.1.vsix"

  log "Installing code-server extensions"
  [[ -f "$source_theme_vsix" ]] || fail "Theme VSIX not found in cloned repo: $source_theme_vsix"
  run_as_root -u "$TARGET_USER" mkdir -p "$config_dir"
  run_as_root -u "$TARGET_USER" install -m 644 "$source_theme_vsix" "$theme_vsix"
  run_as_root -H -u "$TARGET_USER" env HOME="$TARGET_HOME" code-server --install-extension "$theme_vsix" --force >/dev/null
  run_as_root -H -u "$TARGET_USER" env HOME="$TARGET_HOME" code-server --install-extension fabiospampinato.vscode-terminals --force >/dev/null
}

configure_code_server() {
  local config_dir settings_dir settings_user_dir workspaces_dir workspace_path home_workspace_path
  local terminals_target code_server_origin terminal_cmd run_once_marker wrapper_cmd
  local home_readme

  config_dir="$TARGET_HOME/.config/code-server"
  settings_dir="$TARGET_HOME/.local/share/code-server"
  settings_user_dir="$settings_dir/User"
  workspaces_dir="$settings_user_dir/Workspaces"
  workspace_path="$workspaces_dir/openclaw-launchable.code-workspace"
  home_workspace_path="$TARGET_HOME/openclaw-launchable.code-workspace"
  home_readme="$TARGET_HOME/README.md"
  terminals_target="$TARGET_HOME/.vscode/terminals.json"
  code_server_origin="$(derive_code_server_origin)"
  run_once_marker="$TARGET_HOME/.cache/openclaw-launchable/configure-ran"

  log "Configuring code-server"
  run_as_root -u "$TARGET_USER" mkdir -p "$config_dir" "$settings_user_dir" "$workspaces_dir" "$TARGET_HOME/.vscode" "$TARGET_HOME/.cache/openclaw-launchable"
  run_as_root -u "$TARGET_USER" install -m 644 "$LAUNCH_REPO_DIR/README.md" "$home_readme"

  wrapper_cmd="mkdir -p \"${TARGET_HOME}/.cache/openclaw-launchable\" && if [[ -f \"${run_once_marker}\" ]]; then printf 'OpenClaw configure autorun already ran. Opening a fresh login shell.\\n\\n'; source ~/.profile >/dev/null 2>&1 || true; source ~/.bashrc >/dev/null 2>&1 || true; exec bash -l; fi; cd $(printf '%q' "$LAUNCH_REPO_DIR") && bash $(printf '%q' "$LAUNCH_REPO_DIR/configure.sh") && touch \"${run_once_marker}\"; source ~/.profile >/dev/null 2>&1 || true; source ~/.bashrc >/dev/null 2>&1 || true; exec bash -l"
  terminal_cmd="$wrapper_cmd"

  run_as_root -u "$TARGET_USER" tee "$terminals_target" >/dev/null <<EOF
{
  "autorun": true,
  "terminals": [
    {
      "name": "openclaw-configure",
      "description": "OpenClaw first-run configuration",
      "open": true,
      "focus": true,
      "commands": [
        "$(json_escape "$terminal_cmd")"
      ]
    }
  ]
}
EOF

  run_as_root -u "$TARGET_USER" tee "$settings_user_dir/settings.json" >/dev/null <<EOF
{
  "workbench.colorTheme": "NV Theme",
  "workbench.startupEditor": "readme",
  "window.menuBarVisibility": "classic",
  "security.workspace.trust.enabled": false,
  "telemetry.telemetryLevel": "off",
  "update.mode": "none",
  "donations.disablePrompt": true,
  "extensions.ignoreRecommendations": true,
  "workbench.tips.enabled": false
}
EOF

  run_as_root -u "$TARGET_USER" tee "$config_dir/config.yaml" >/dev/null <<EOF
bind-addr: 0.0.0.0:${CODE_SERVER_PORT}
auth: none
disable-workspace-trust: true
disable-telemetry: true
disable-update-check: true
app-name: "OpenClaw Brev Launchable"
welcome-text: "OpenClaw first-run configuration"
EOF

  run_as_root -u "$TARGET_USER" tee "$settings_dir/coder.json" >/dev/null <<EOF
{
  "query": {
    "folder": "${TARGET_HOME}"
  },
  "lastVisited": {
    "url": "${workspace_path}",
    "workspace": true
  }
}
EOF

  run_as_root -u "$TARGET_USER" tee "$workspace_path" >/dev/null <<EOF
{
  "folders": [
    {
      "name": "Home",
      "path": "${TARGET_HOME}"
    },
    {
      "name": "Launchable",
      "path": "${LAUNCH_REPO_DIR}"
    }
  ]
}
EOF

  run_as_root -u "$TARGET_USER" install -m 644 "$workspace_path" "$home_workspace_path"

  log "code-server configured for ${code_server_origin}"
}

enable_code_server_service() {
  log "Starting code-server service"
  run_as_root systemctl daemon-reload
  run_as_root systemctl enable "code-server@${TARGET_USER}" >/dev/null
  run_as_root systemctl restart "code-server@${TARGET_USER}"

  if ! wait_for_tcp_port "$CODE_SERVER_PORT" 30; then
    run_as_root systemctl status "code-server@${TARGET_USER}" --no-pager || true
    fail "code-server did not open port ${CODE_SERVER_PORT} within 30 seconds"
  fi
}

print_configuration_pending() {
  local host_name origin code_server_origin

  host_name="$(hostname 2>/dev/null || true)"
  origin="$(derive_openclaw_origin)"
  code_server_origin="$(derive_code_server_origin)"

  printf '\nOpenClaw Configuration Pending\n'
  printf '==============================\n\n'
  printf 'Hostname:\n%s\n\n' "${host_name:-unknown}"
  printf 'OpenClaw Origin:\n%s\n\n' "$origin"
  printf 'code-server:\n%s\n\n' "$code_server_origin"
  printf 'Next Step:\nOpen code-server and complete the auto-opened configure.sh terminal.\n'
}

main() {
  require_non_root
  require_cmd id
  require_cmd sudo

  if command -v getent >/dev/null 2>&1; then
    TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
  fi

  log "Step 1/10: Ensuring Node.js >= 22"
  ensure_node
  log "Confirmed Node version: $(node --version)"

  log "Step 2/10: Ensuring OpenClaw is installed"
  ensure_openclaw_installed

  log "Step 3/10: Verifying OpenClaw CLI availability"
  verify_openclaw_cli

  log "Step 4/10: Installing Bazel"
  ensure_bazel

  log "Step 5/10: Installing NGC CLI"
  ensure_ngc_cli

  log "Step 6/10: Cloning and building OSMO"
  install_osmo

  #log "Step 7/10: Cloning nurec-workflows"
  #clone_nurec_workflows

  log "Step 8/10: Cloning the launch-openclaw repo and configuring code-server"
  clone_or_refresh_launch_repo
  install_code_server
  install_code_server_extensions
  configure_code_server
  enable_code_server_service

  if is_openclaw_configured; then
    log "Step 9/10: OpenClaw is already configured"
  else
    log "Step 9/10: OpenClaw onboarding is deferred to configure.sh"
  fi
  log "Step 10/10: Printing code-server access information"
  print_configuration_pending
}

main "$@"
