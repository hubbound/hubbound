#!/usr/bin/env bash
# Removes a Hubbound installation (daemon, system root, user binaries, shell
# PATH entry, user agent, per-editor integrations and provider artifacts) on
# macOS and Linux.
#
# Usage:
#   ./scripts/uninstall.sh              # interactive: ask about user data
#   ./scripts/uninstall.sh --keep-data  # binaries/services only; keep user state + telemetry
#   ./scripts/uninstall.sh --purge-data # also delete user state, caches, and telemetry
#   ./scripts/uninstall.sh --all        # alias for --purge-data
#   ./scripts/uninstall.sh -h|--help
#
# Environment:
#   HUBBOUND_SYSTEM_ROOT  when set, only that system root is removed
#   HUBBOUND_USER_BIN     directory holding the CLI symlinks (default ~/.local/bin)
set -euo pipefail

# Colors
if [ -t 1 ] && [ -z "${NO_COLOR+x}" ]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[0;33m'
  CYAN='\033[0;36m'
  BOLD='\033[1m'
  NC='\033[0m'
else
  RED='' GREEN='' YELLOW='' CYAN='' BOLD='' NC=''
fi

# Logging helpers
log_info()    { echo -e "${CYAN}==>${NC} ${BOLD}$1${NC}"; }
log_success() { echo -e "    ${GREEN}✓${NC} $1"; }
log_warn()    { echo -e "    ${YELLOW}!${NC} $1"; }
log_error()   { echo -e "    ${RED}✗${NC} $1" >&2; }
log_detail()  { echo -e "      ${CYAN}→${NC} $1"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OS="$(uname -s)"
USER_BIN="${HUBBOUND_USER_BIN:-$HOME/.local/bin}"
INSTALL_URL="https://raw.githubusercontent.com/hubbound/hubbound/main/install.sh"

usage() {
  cat <<'EOF'
Hubbound uninstaller

Usage:
  uninstall.sh              interactive: ask whether to keep user data
  uninstall.sh --keep-data  remove binaries and services; keep user state + telemetry
  uninstall.sh --purge-data remove everything, including user state, caches and telemetry
  uninstall.sh --all        alias for --purge-data
  uninstall.sh -h|--help    show this help

When stdin is not a terminal (for example `curl ... | bash`), one of
--keep-data or --purge-data is required so nothing is deleted by accident.

Environment:
  HUBBOUND_SYSTEM_ROOT  when set, only that system root is removed
  HUBBOUND_USER_BIN     directory holding the CLI symlinks (default ~/.local/bin)
EOF
}

# ─── Privilege helper ────────────────────────────────────────────────────────
# Root mutations go through here so the script also works when it is already
# running as root, and degrades to a warning when sudo is unavailable.
HAVE_PRIV=1
if [ "$(id -u)" -eq 0 ]; then
  PRIV_PREFIX=""
elif command -v sudo >/dev/null 2>&1; then
  PRIV_PREFIX="sudo"
else
  PRIV_PREFIX=""
  HAVE_PRIV=0
fi

run_priv() {
  if [ "$HAVE_PRIV" -eq 0 ]; then
    return 1
  fi
  if [ -n "$PRIV_PREFIX" ]; then
    "$PRIV_PREFIX" "$@"
  else
    "$@"
  fi
}

# Cache sudo credentials once, with a visible password prompt. Callers must not
# redirect stderr around the first privileged call or the prompt is hidden.
ensure_priv() {
  if [ "$(id -u)" -eq 0 ]; then
    return 0
  fi
  if [ "$HAVE_PRIV" -eq 0 ]; then
    log_error "sudo is required to remove the system daemon and protected files."
    exit 1
  fi
  if sudo -n true 2>/dev/null; then
    return 0
  fi
  echo ""
  echo -e "${YELLOW}Administrator permission is needed to remove the system daemon.${NC}"
  if ! sudo -v; then
    log_error "Administrator permission was not granted."
    exit 1
  fi
}

# Removes a path, escalating to root only when the unprivileged attempt fails.
# stderr is kept so a late sudo prompt still reaches the terminal.
remove_path() {
  local path="$1"
  [ -e "$path" ] || [ -L "$path" ] || return 0
  if rm -rf "$path" 2>/dev/null && [ ! -e "$path" ] && [ ! -L "$path" ]; then
    return 0
  fi
  run_priv rm -rf "$path" || return 1
  [ ! -e "$path" ] && [ ! -L "$path" ]
}

# ─── Arguments ───────────────────────────────────────────────────────────────
KEEP_DATA=""
while [ $# -gt 0 ]; do
  case "$1" in
    --keep-data) KEEP_DATA=1; shift ;;
    --purge-data|--all|--purge) KEEP_DATA=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) log_error "Unknown option: $1"; echo ""; usage; exit 1 ;;
  esac
done

if [ -z "$KEEP_DATA" ]; then
  if [ -t 0 ]; then
    echo ""
    echo -e "${BOLD}What should be removed?${NC}"
    echo -e "  ${CYAN}1)${NC} Binaries and services only — keep config, DB and telemetry"
    echo -e "  ${CYAN}2)${NC} Full purge — also delete config, database, caches and telemetry"
    echo ""
    printf "Choice [1/2] (default 1): "
    read -r choice || choice=1
    case "${choice:-1}" in
      2|full|purge|all) KEEP_DATA=0 ;;
      *) KEEP_DATA=1 ;;
    esac
  else
    log_error "Running non-interactively: pass --keep-data or --purge-data explicitly."
    log_detail "Refusing to guess whether your Hubbound data should be deleted."
    exit 1
  fi
fi

# ─── Paths ───────────────────────────────────────────────────────────────────
SYSTEM_ROOTS=()
if [ -n "${HUBBOUND_SYSTEM_ROOT:-}" ]; then
  SYSTEM_ROOTS+=("$HUBBOUND_SYSTEM_ROOT")
elif [ "$OS" = "Darwin" ]; then
  SYSTEM_ROOTS+=("/Library/Application Support/hubbound" "/Library/Application Support/hubbound-lab")
else
  SYSTEM_ROOTS+=("/var/lib/hubbound" "/var/lib/hubbound-lab")
fi

USER_STATE_DIRS=()
USER_CACHE_DIRS=()
if [ "$OS" = "Darwin" ]; then
  USER_STATE_DIRS+=("$HOME/Library/Application Support/hubbound" "$HOME/Library/Application Support/hubbound-lab")
  USER_CACHE_DIRS+=("$HOME/Library/Caches/hubbound" "$HOME/Library/Caches/hubbound-lab")
else
  USER_STATE_DIRS+=("$HOME/.config/hubbound" "$HOME/.config/hubbound-lab")
  USER_CACHE_DIRS+=("$HOME/.cache/hubbound" "$HOME/.cache/hubbound-lab")
fi

EDITOR_DIRS=(
  "$HOME/.claude/hubbound"
  "$HOME/.claude/hubbound-hooks"
  "$HOME/.cursor/hubbound"
  "$HOME/.cursor/hubbound-hooks"
  "$HOME/.codex/hubbound"
  "$HOME/.codex/hubbound-hooks"
  "$HOME/.copilot/hubbound"
  "$HOME/.gemini/hubbound"
  "$HOME/.gemini/hubbound-hooks"
)

echo ""
if [ "$KEEP_DATA" -eq 1 ]; then
  echo -e "${BOLD}${YELLOW}╔═══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${YELLOW}║  Hubbound: uninstall (your data is kept)                  ║${NC}"
  echo -e "${BOLD}${YELLOW}╚═══════════════════════════════════════════════════════════╝${NC}"
else
  echo -e "${BOLD}${RED}╔═══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${RED}║  Hubbound: full uninstall (data will be deleted)          ║${NC}"
  echo -e "${BOLD}${RED}╚═══════════════════════════════════════════════════════════╝${NC}"
fi
echo ""

# Maps a system-root basename (hubbound | hubbound-lab | custom) to the
# matching per-user state directory for this OS.
user_state_dir_for() {
  local name="$1"
  if [ "$OS" = "Darwin" ]; then
    printf '%s\n' "$HOME/Library/Application Support/$name"
  else
    printf '%s\n' "$HOME/.config/$name"
  fi
}

# Telemetry spool lives at {system_root}/analytics (root-owned). --keep-data
# must relocate it into the matching user state dir BEFORE helper uninstall
# (which RemoveAll's the whole system root).
preserve_system_telemetry() {
  [ "$KEEP_DATA" -eq 1 ] || return 0
  log_info "Preserving system telemetry (analytics)"
  local preserved=0
  local root name src dest dest_parent
  for root in "${SYSTEM_ROOTS[@]}"; do
    src="$root/analytics"
    [ -d "$src" ] || continue
    name="$(basename "$root")"
    dest="$(user_state_dir_for "$name")/analytics"
    dest_parent="$(dirname "$dest")"
    log_detail "From: $src"
    log_detail "To:   $dest"
    mkdir -p "$dest_parent"
	if [ -d "$dest" ] && [ "$(find "$dest" -mindepth 1 -maxdepth 1 2>/dev/null | head -n1)" ]; then
		# Keep both: stash the previous user copy, then take the system spool
		# as the canonical preserved analytics.
		local stash
		stash="${dest}.user-prior.$(date +%Y%m%d%H%M%S)"
		mv "$dest" "$stash"
      log_detail "Existing user analytics moved aside: $stash"
    fi
    rm -rf "$dest"
    # Copy as root (source is root-owned), then hand ownership to the user.
    if ! run_priv cp -a "$src" "$dest"; then
      log_warn "Could not preserve analytics from $root"
      PRIV_FAILURES=$((PRIV_FAILURES + 1))
      continue
    fi
    if [ "$(id -u)" -ne 0 ]; then
      run_priv chown -R "$(id -u):$(id -g)" "$dest" || true
    fi
    log_success "Preserved telemetry for $name"
    preserved=$((preserved + 1))
  done
  if [ "$preserved" -eq 0 ]; then
    log_warn "No system analytics spool found to preserve"
  fi
}

# After a later reinstall, move preserved user-state analytics back into the
# new system root (see scripts/install.sh).

ensure_priv

PRIV_FAILURES=0

# Stop the daemon before copying analytics so spool files are not locked, then
# preserve telemetry under --keep-data before helper RemoveAll's the system root.
log_info "Stopping hubboundd before teardown"
stopped=0
if command -v hubbound >/dev/null 2>&1; then
  if run_priv hubbound daemon stop >/dev/null 2>&1; then
    log_success "Daemon stopped via 'hubbound daemon stop'"
    stopped=1
  fi
fi
if [ "$stopped" -eq 0 ]; then
  for root in "${SYSTEM_ROOTS[@]}"; do
    daemon_bin="$root/current/hubboundd"
    if [ -x "$daemon_bin" ] && run_priv "$daemon_bin" stop >/dev/null 2>&1; then
      log_success "Daemon stopped via $daemon_bin"
      stopped=1
    fi
  done
fi
if [ "$stopped" -eq 0 ]; then
  log_warn "Daemon stop skipped or already stopped"
fi

preserve_system_telemetry

# ─── Daemon ──────────────────────────────────────────────────────────────────
log_info "Stopping and removing the hubboundd system daemon"
if command -v hubbound >/dev/null 2>&1; then
  log_detail "hubbound found on PATH: $(command -v hubbound)"
  if run_priv hubbound daemon uninstall; then
    log_success "Daemon uninstalled via 'hubbound daemon uninstall'"
  else
    log_warn "'hubbound daemon uninstall' failed or the daemon was not installed"
  fi
else
  log_warn "hubbound not on PATH, falling back to the helper"
fi

for root in "${SYSTEM_ROOTS[@]}"; do
  helper="$root/current/hubbound-helper"
  if [ -x "$helper" ]; then
    log_detail "Helper uninstall: $helper"
    if run_priv "$helper" system uninstall --system-root "$root"; then
      log_success "Helper uninstall completed for $root"
    else
      log_warn "Helper uninstall failed for $root (continuing)"
    fi
  fi
done

# Belt and suspenders: the uninstall paths above need a runnable binary on a
# healthy install. After a partial or broken install neither holds, which
# leaves the service definition orphaned and blocks the next install.
log_info "Force-removing the system service definition"
if [ "$OS" = "Darwin" ]; then
  plists_seen=0
  plists_removed=0
  seen_plists=" "
  for plist in /Library/LaunchDaemons/hubboundd.plist /Library/LaunchDaemons/*hubbound*.plist; do
    [ -f "$plist" ] || continue
    case "$seen_plists" in
      *" $plist "*) continue ;;
    esac
    seen_plists="$seen_plists$plist "
    plists_seen=$((plists_seen + 1))
    log_detail "Path: $plist"
    run_priv launchctl bootout system "$plist" >/dev/null 2>&1 || true
    run_priv launchctl unload "$plist" >/dev/null 2>&1 || true
    if remove_path "$plist"; then
      log_success "Removed $plist"
      plists_removed=$((plists_removed + 1))
    else
      log_warn "Could not remove $plist"
      PRIV_FAILURES=$((PRIV_FAILURES + 1))
    fi
  done
  if [ "$plists_seen" -eq 0 ]; then
    log_warn "No hubboundd LaunchDaemon plist found"
  fi
else
  if command -v systemctl >/dev/null 2>&1; then
    run_priv systemctl stop hubboundd.service >/dev/null 2>&1 || true
    run_priv systemctl disable hubboundd.service >/dev/null 2>&1 || true
  fi
  unit_seen=0
  unit_removed=0
  for unit in /etc/systemd/system/hubboundd.service \
    /etc/systemd/system/hubboundd*.service \
    /etc/systemd/system/multi-user.target.wants/hubboundd*.service \
    /lib/systemd/system/hubboundd*.service \
    /usr/lib/systemd/system/hubboundd*.service; do
    [ -e "$unit" ] || [ -L "$unit" ] || continue
    unit_seen=$((unit_seen + 1))
    log_detail "Path: $unit"
    if remove_path "$unit"; then
      log_success "Removed $unit"
      unit_removed=$((unit_removed + 1))
    else
      log_warn "Could not remove $unit"
      PRIV_FAILURES=$((PRIV_FAILURES + 1))
    fi
  done
  if [ "$unit_seen" -eq 0 ]; then
    log_warn "No hubboundd systemd unit found"
  elif command -v systemctl >/dev/null 2>&1; then
    run_priv systemctl daemon-reload >/dev/null 2>&1 || true
    run_priv systemctl reset-failed >/dev/null 2>&1 || true
  fi
fi

# ─── User agent ──────────────────────────────────────────────────────────────
log_info "Removing the user agent service"
if [ "$OS" = "Darwin" ]; then
  agent_seen=0
  for AGENT_PLIST in \
    "$HOME/Library/LaunchAgents/net.hubbound.agent.plist" \
    "$HOME/Library/LaunchAgents/com.hubbound.agent.plist" \
    "/Library/LaunchAgents/net.hubbound.agent.plist"; do
    [ -e "$AGENT_PLIST" ] || [ -L "$AGENT_PLIST" ] || continue
    agent_seen=1
    log_detail "Path: $AGENT_PLIST"
    launchctl bootout "gui/$(id -u)" "$AGENT_PLIST" >/dev/null 2>&1 || true
    launchctl unload "$AGENT_PLIST" >/dev/null 2>&1 || true
    if remove_path "$AGENT_PLIST"; then
      log_success "LaunchAgent removed"
    else
      log_warn "Could not remove LaunchAgent plist"
      PRIV_FAILURES=$((PRIV_FAILURES + 1))
    fi
  done
  if [ "$agent_seen" -eq 0 ]; then
    log_warn "LaunchAgent plist not found"
  fi
else
  AGENT_SERVICE="$HOME/.config/systemd/user/hubbound-agent.service"
  log_detail "Path: $AGENT_SERVICE"
  if [ -f "$AGENT_SERVICE" ]; then
    systemctl --user disable --now hubbound-agent.service >/dev/null 2>&1 || true
    rm -f "$AGENT_SERVICE"
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    log_success "systemd user service removed"
  else
    log_warn "systemd user service not found"
  fi
fi

# ─── System roots ────────────────────────────────────────────────────────────
log_info "Removing system roots"
roots_seen=0
roots_removed=0
for root in "${SYSTEM_ROOTS[@]}"; do
  if [ -d "$root" ]; then
    roots_seen=$((roots_seen + 1))
    log_detail "Path: $root"
    if remove_path "$root"; then
      log_success "Removed $root"
      roots_removed=$((roots_removed + 1))
    else
      log_warn "Could not remove $root"
      PRIV_FAILURES=$((PRIV_FAILURES + 1))
    fi
  fi
done
if [ "$roots_seen" -eq 0 ]; then
  log_warn "No system root found"
fi

# ─── User binaries ───────────────────────────────────────────────────────────
log_info "Removing command symlinks"
log_detail "Directory: $USER_BIN"
bins_removed=0
for bin in hubbound hubbound-agent hubbound-helper; do
  link="$USER_BIN/$bin"
  if [ -L "$link" ] || [ -f "$link" ]; then
    rm -f "$link"
    log_success "Removed $link"
    bins_removed=$((bins_removed + 1))
  fi
done
if [ "$bins_removed" -eq 0 ]; then
  log_warn "No Hubbound commands found in $USER_BIN"
fi

# ─── Shell PATH block ────────────────────────────────────────────────────────
log_info "Removing the shell PATH entry"
rc_cleaned=0
for shell_rc in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.profile"; do
  [ -f "$shell_rc" ] || continue
  grep -qF '# Hubbound CLI' "$shell_rc" 2>/dev/null || continue
  tmp_rc="$(mktemp "${TMPDIR:-/tmp}/hubbound-rc.XXXXXX")"
  # Drops the marker line plus the export line that follows it.
  awk '
    skip == 1 { skip = 0; next }
    index($0, "# Hubbound CLI") { skip = 1; next }
    { print }
  ' "$shell_rc" >"$tmp_rc"
  # Copy through the original file so its inode and permissions survive.
  cat "$tmp_rc" >"$shell_rc"
  rm -f "$tmp_rc"
  log_success "Removed the Hubbound block from $shell_rc"
  rc_cleaned=$((rc_cleaned + 1))
done
if [ "$rc_cleaned" -eq 0 ]; then
  log_warn "No Hubbound block found in your shell startup files"
fi

# ─── Editor integration dirs ─────────────────────────────────────────────────
log_info "Removing per-editor integration directories"
editors_removed=0
for d in "${EDITOR_DIRS[@]}"; do
  if [ -e "$d" ] || [ -L "$d" ]; then
    log_detail "Removing: $d"
    rm -rf "$d"
    editors_removed=$((editors_removed + 1))
  fi
done
if [ "$editors_removed" -eq 0 ]; then
  log_warn "No editor integration directories found"
else
  log_success "Removed $editors_removed editor integration director$([ "$editors_removed" -eq 1 ] && echo y || echo ies)"
fi

# ─── Provider integrations ───────────────────────────────────────────────────
log_info "Cleaning provider integrations (hooks, MCP servers, artifacts)"
PURGE_PROVIDERS_GO=""
for candidate in "$SCRIPT_DIR/dev/purge-providers.go" "$SCRIPT_DIR/purge-providers.go"; do
  if [ -f "$candidate" ]; then
    PURGE_PROVIDERS_GO="$candidate"
    break
  fi
done

provider_cleanup_python() {
  if ! command -v python3 >/dev/null 2>&1; then
    log_warn "python3 not found — provider integrations were left untouched"
    log_detail "Remove leftover hubbound entries manually from your editor configs."
    return 0
  fi
  if python3 - <<'PYCLEAN'; then
import json
import os
import platform
import re
import shutil
import sys

HOME = os.path.expanduser("~")
DARWIN = platform.system() == "Darwin"

if sys.stdout.isatty() and os.environ.get("NO_COLOR") is None:
    CYAN, GREEN, YELLOW, BOLD, NC = "\033[0;36m", "\033[0;32m", "\033[0;33m", "\033[1m", "\033[0m"
else:
    CYAN = GREEN = YELLOW = BOLD = NC = ""


def info(msg):
    print(f"{CYAN}==>{NC} {BOLD}{msg}{NC}")


def ok(msg):
    print(f"    {GREEN}\u2713{NC} {msg}")


def warn(msg):
    print(f"    {YELLOW}!{NC} {msg}")


def detail(msg):
    print(f"      {CYAN}\u2192{NC} {msg}")


def read_json(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            raw = handle.read()
    except FileNotFoundError:
        return None
    except OSError as err:
        warn(f"read {path}: {err}")
        return None
    if not raw.strip():
        return None
    try:
        doc = json.loads(raw)
    except ValueError as err:
        warn(f"parse {path}: {err}")
        return None
    return doc if isinstance(doc, dict) else None


def write_json(path, doc):
    try:
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(doc, handle, indent=2)
            handle.write("\n")
    except OSError as err:
        warn(f"write {path}: {err}")
        return
    ok(f"cleaned {path}")


def is_hubbound(value):
    if not isinstance(value, dict):
        return False
    marker = value.get("hubbound")
    return isinstance(marker, dict) and marker.get("source") == "hubbound"


def clean_mcp_servers(*paths):
    for path in paths:
        doc = read_json(path)
        if not doc:
            continue
        servers = doc.get("mcpServers")
        if not isinstance(servers, dict):
            continue
        removed = [name for name, entry in servers.items() if is_hubbound(entry)]
        if not removed:
            continue
        for name in removed:
            del servers[name]
            detail(f"removed MCP server: {name}")
        write_json(path, doc)


def clean_claude_settings(path):
    doc = read_json(path)
    if not doc:
        return
    changed = False
    hooks_root = doc.get("hooks")
    if isinstance(hooks_root, dict):
        for event in list(hooks_root):
            groups = hooks_root[event]
            if not isinstance(groups, list):
                continue
            kept_groups = []
            for group in groups:
                if not isinstance(group, dict):
                    kept_groups.append(group)
                    continue
                handlers = group.get("hooks")
                if not isinstance(handlers, list):
                    kept_groups.append(group)
                    continue
                kept = [h for h in handlers if not is_hubbound(h)]
                if len(kept) != len(handlers):
                    changed = True
                if not kept:
                    continue
                group["hooks"] = kept
                kept_groups.append(group)
            if not kept_groups:
                del hooks_root[event]
                changed = True
            elif kept_groups != groups:
                hooks_root[event] = kept_groups
                changed = True
        if not hooks_root:
            doc.pop("hooks", None)

    # Legacy cleanup: retired statusLine integration pointing at a removed script.
    status_line = doc.get("statusLine")
    if isinstance(status_line, dict) and "hubbound-statusline-entry" in str(status_line.get("command", "")):
        del doc["statusLine"]
        changed = True
        detail("removed legacy Claude display config")

    if changed:
        write_json(path, doc)


def clean_cursor_hooks(path):
    doc = read_json(path)
    if not doc:
        return
    hooks_root = doc.get("hooks")
    if not isinstance(hooks_root, dict):
        return
    changed = False
    for event in list(hooks_root):
        handlers = hooks_root[event]
        if not isinstance(handlers, list):
            continue
        kept = [h for h in handlers if not is_hubbound(h)]
        if len(kept) == len(handlers):
            continue
        changed = True
        if kept:
            hooks_root[event] = kept
        else:
            del hooks_root[event]
    if changed:
        write_json(path, doc)


def clean_gemini_hooks(path):
    doc = read_json(path)
    if not doc:
        return
    removed = [key for key in doc if isinstance(key, str) and key.startswith("hubbound-artifact-")]
    if not removed:
        return
    for key in removed:
        del doc[key]
        detail(f"removed hook block: {key}")
    write_json(path, doc)


def clean_owned_dirs(directory):
    try:
        entries = sorted(os.listdir(directory))
    except OSError:
        return
    for name in entries:
        target = os.path.join(directory, name)
        if not os.path.isdir(target):
            continue
        marker = read_json(os.path.join(target, ".hubbound.json"))
        if marker and marker.get("source") == "hubbound":
            shutil.rmtree(target, ignore_errors=True)
            detail(f"removed: {target}")


def clean_owned_files(directory, suffix):
    try:
        entries = sorted(os.listdir(directory))
    except OSError:
        return
    for name in entries:
        if not name.endswith(suffix):
            continue
        target = os.path.join(directory, name)
        if not os.path.isfile(target):
            continue
        try:
            with open(target, "r", encoding="utf-8", errors="replace") as handle:
                body = handle.read()
        except OSError:
            continue
        if "<!-- hubbound:artifact" in body:
            try:
                os.remove(target)
            except OSError as err:
                warn(f"remove {target}: {err}")
                continue
            detail(f"removed: {target}")


MANAGED_BLOCK = re.compile(
    r"<!-- hubbound:artifact [^>]+ BEGIN -->.*?<!-- hubbound:artifact [^>]+ END -->\n?",
    re.DOTALL,
)


def clean_markdown_blocks(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            original = handle.read()
    except OSError:
        return
    cleaned = MANAGED_BLOCK.sub("", original)
    if cleaned == original:
        return
    try:
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(cleaned.strip() + "\n")
    except OSError as err:
        warn(f"write {path}: {err}")
        return
    ok(f"removed hubbound blocks from {path}")


def remove_paths(*paths):
    for path in paths:
        if os.path.islink(path) or os.path.isfile(path):
            try:
                os.remove(path)
            except OSError:
                continue
            detail(f"removed: {path}")
        elif os.path.isdir(path):
            shutil.rmtree(path, ignore_errors=True)
            detail(f"removed: {path}")


try:
    import tomllib
except ImportError:
    tomllib = None

TOML_HEADER = re.compile(r"^\s*(\[\[?)([^\]]+)\]\]?\s*$")
TOML_SOURCE = re.compile(r'^\s*source\s*=\s*"hubbound"\s*$')
TOML_INLINE = re.compile(r'hubbound\s*=\s*\{[^}]*source\s*=\s*"hubbound"')


def _toml_blocks(lines):
    """Splits a TOML document into (header_path, is_array, lines) blocks."""
    blocks = []
    current = {"path": None, "array": False, "lines": []}
    for line in lines:
        match = TOML_HEADER.match(line)
        if match:
            blocks.append(current)
            path = [part.strip().strip('"').strip("'") for part in match.group(2).split(".")]
            current = {"path": path, "array": match.group(1) == "[[", "lines": [line]}
        else:
            current["lines"].append(line)
    blocks.append(current)
    return blocks


def clean_codex_config(path):
    """Best-effort removal of hubbound-owned tables from Codex's config.toml.

    Text based so unrelated comments and formatting survive; the result is
    re-parsed with tomllib and discarded if it no longer parses.
    """
    if tomllib is None:
        try:
            has_marker = 'source = "hubbound"' in open(path, "r", encoding="utf-8").read()
        except OSError:
            return
        if has_marker:
            warn(f"python3 lacks tomllib (needs 3.11+) — clean {path} manually")
        return
    try:
        with open(path, "r", encoding="utf-8") as handle:
            original = handle.read()
    except OSError:
        return

    lines = original.splitlines(keepends=True)
    blocks = _toml_blocks(lines)

    # Group each table with its strict descendants; array entries start their
    # own group so sibling non-hubbound entries are never swept up.
    groups = []
    for block in blocks:
        path_parts = block["path"]
        if groups and path_parts is not None and not block["array"] and len(path_parts) >= 2:
            head = groups[-1]
            head_path = head[0]["path"]
            if (
                head_path is not None
                and len(head_path) >= 2
                and len(path_parts) > len(head_path)
                and path_parts[: len(head_path)] == head_path
            ):
                head.append(block)
                continue
        groups.append([block])

    drop = set()
    for index, group in enumerate(groups):
        if group[0]["path"] is None:
            continue
        marked = False
        for block in group:
            body = "".join(block["lines"])
            if TOML_INLINE.search(body):
                marked = True
                break
            if block["path"][-1] == "hubbound" and any(TOML_SOURCE.match(l) for l in block["lines"]):
                marked = True
                break
        if marked:
            drop.add(index)

    if not drop:
        return

    kept = []
    for index, group in enumerate(groups):
        if index in drop:
            detail("removed table: [{}]".format(".".join(groups[index][0]["path"])))
            continue
        for block in group:
            kept.extend(block["lines"])
    cleaned = "".join(kept)

    try:
        tomllib.loads(cleaned)
    except Exception as err:
        warn(f"skipped {path}: cleaned file would be invalid TOML ({err})")
        return
    try:
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(cleaned)
    except OSError as err:
        warn(f"write {path}: {err}")
        return
    ok(f"cleaned {path}")


def clean_codex_agents(directory):
    try:
        entries = sorted(os.listdir(directory))
    except OSError:
        return
    for name in entries:
        if not name.endswith(".toml"):
            continue
        target = os.path.join(directory, name)
        try:
            with open(target, "rb") as handle:
                raw = handle.read()
        except OSError:
            continue
        owned = False
        if tomllib is not None:
            try:
                owned = is_hubbound(tomllib.loads(raw.decode("utf-8", "replace")))
            except Exception:
                owned = False
        else:
            text = raw.decode("utf-8", "replace")
            owned = "[hubbound]" in text and 'source = "hubbound"' in text
        if owned:
            try:
                os.remove(target)
            except OSError:
                continue
            detail(f"removed subagent: {name}")


def clean_claude():
    info("Claude Code")
    clean_claude_settings(os.path.join(HOME, ".claude", "settings.json"))
    clean_mcp_servers(os.path.join(HOME, ".mcp.json"))
    if DARWIN:
        clean_claude_settings("/Library/Application Support/ClaudeCode/managed-settings.json")
        clean_mcp_servers("/Library/Application Support/ClaudeCode/managed-mcp.json")
    remove_paths(
        os.path.join(HOME, ".claude", "hubbound-hooks"),
        os.path.join(HOME, ".claude", "hubbound"),
    )
    clean_owned_dirs(os.path.join(HOME, ".claude", "skills"))
    clean_owned_files(os.path.join(HOME, ".claude", "rules"), ".md")
    clean_owned_files(os.path.join(HOME, ".claude", "agents"), ".md")


def clean_cursor():
    info("Cursor")
    clean_cursor_hooks(os.path.join(HOME, ".cursor", "hooks.json"))
    clean_mcp_servers(os.path.join(HOME, ".cursor", "mcp.json"))
    remove_paths(os.path.join(HOME, ".cursor", "hubbound-hooks"))
    clean_owned_dirs(os.path.join(HOME, ".cursor", "skills"))
    clean_owned_files(os.path.join(HOME, ".cursor", "rules"), ".mdc")
    clean_owned_files(os.path.join(HOME, ".cursor", "agents"), ".md")


def clean_codex():
    info("Codex CLI")
    clean_codex_config(os.path.join(HOME, ".codex", "config.toml"))
    remove_paths(os.path.join(HOME, ".codex", "hubbound-hooks"))
    clean_owned_dirs(os.path.join(HOME, ".agents", "skills"))
    clean_markdown_blocks(os.path.join(HOME, ".codex", "AGENTS.md"))
    clean_codex_agents(os.path.join(HOME, ".codex", "agents"))


def clean_copilot():
    info("Copilot")
    clean_owned_dirs(os.path.join(HOME, ".copilot", "skills"))
    clean_owned_files(os.path.join(HOME, ".copilot", "agents"), ".agent.md")


def clean_antigravity():
    info("Antigravity / Gemini")
    clean_mcp_servers(os.path.join(HOME, ".gemini", "config", "mcp_config.json"))
    clean_gemini_hooks(os.path.join(HOME, ".gemini", "config", "hooks.json"))
    remove_paths(os.path.join(HOME, ".gemini", "hubbound-hooks"))
    clean_owned_dirs(os.path.join(HOME, ".gemini", "skills"))
    clean_markdown_blocks(os.path.join(HOME, ".gemini", "GEMINI.md"))


clean_claude()
clean_cursor()
clean_codex()
clean_copilot()
clean_antigravity()
PYCLEAN
    log_success "Provider integrations cleaned"
  else
    log_warn "Provider cleanup had issues (non-fatal)"
  fi
}

if [ -n "$PURGE_PROVIDERS_GO" ] && command -v go >/dev/null 2>&1; then
  log_detail "Using $PURGE_PROVIDERS_GO"
  if go run "$PURGE_PROVIDERS_GO"; then
    log_success "Provider integrations cleaned"
  else
    log_warn "Go provider cleanup failed, falling back to the built-in cleaner"
    provider_cleanup_python
  fi
else
  provider_cleanup_python
fi

# ─── User data ───────────────────────────────────────────────────────────────
if [ "$KEEP_DATA" -eq 1 ]; then
  log_info "Keeping user data"
  for d in "${USER_STATE_DIRS[@]}"; do
    [ -d "$d" ] && log_detail "Kept: $d"
    [ -d "$d/analytics" ] && log_detail "Kept telemetry: $d/analytics"
  done
  log_success "Config, database, installs and telemetry preserved"
else
  log_info "Removing user state and caches"
  data_removed=0
  for d in "${USER_STATE_DIRS[@]}" "${USER_CACHE_DIRS[@]}"; do
    if [ -d "$d" ]; then
      log_detail "Removing: $d"
      # A daemon bug can leave root-owned files here, so escalate when needed.
      if remove_path "$d"; then
        data_removed=$((data_removed + 1))
      else
        log_warn "Could not remove $d"
      fi
    fi
  done
  if [ "$data_removed" -eq 0 ]; then
    log_warn "No user state or cache directories found"
  else
    log_success "Removed $data_removed director$([ "$data_removed" -eq 1 ] && echo y || echo ies)"
  fi
fi

# ─── Leftover privileged paths ───────────────────────────────────────────────
for root in "${SYSTEM_ROOTS[@]}"; do
  if [ -d "$root" ]; then
    log_error "System root still present: $root"
    PRIV_FAILURES=$((PRIV_FAILURES + 1))
  fi
done
if [ "$OS" = "Darwin" ] && [ -f /Library/LaunchDaemons/hubboundd.plist ]; then
  log_error "LaunchDaemon still present: /Library/LaunchDaemons/hubboundd.plist"
  PRIV_FAILURES=$((PRIV_FAILURES + 1))
fi

# ─── Summary ─────────────────────────────────────────────────────────────────
echo ""
if [ "$PRIV_FAILURES" -gt 0 ]; then
  echo -e "${BOLD}${RED}╔═══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${RED}║  ✗ Uninstall incomplete — protected paths remain.         ║${NC}"
  echo -e "${BOLD}${RED}╚═══════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "    ${CYAN}→${NC} Re-run in a terminal that can prompt for sudo:"
  echo -e "        ${BOLD}bash scripts/uninstall.sh --keep-data${NC}"
  echo ""
  exit 1
fi

if [ "$KEEP_DATA" -eq 1 ]; then
  echo -e "${BOLD}${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${GREEN}║  ✓ Hubbound removed. Your data was kept.                  ║${NC}"
  echo -e "${BOLD}${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}"
  echo ""
  for d in "${USER_STATE_DIRS[@]}"; do
    [ -d "$d" ] && echo -e "    ${CYAN}→${NC} Kept: ${BOLD}$d${NC}"
    [ -d "$d/analytics" ] && echo -e "    ${CYAN}→${NC} Telemetry: ${BOLD}$d/analytics${NC}"
  done
  echo -e "    ${CYAN}→${NC} Reinstall restores telemetry into the system analytics spool."
else
  echo -e "${BOLD}${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${GREEN}║  ✓ Hubbound is fully removed.                             ║${NC}"
  echo -e "${BOLD}${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}"
  echo ""
fi
echo -e "    ${CYAN}→${NC} Open a new shell so the PATH change takes effect."
echo -e "    ${CYAN}→${NC} Reinstall any time with:"
echo ""
echo -e "        ${BOLD}curl -fsSLo ./hubbound-install.sh $INSTALL_URL${NC}"
echo -e "        ${BOLD}less ./hubbound-install.sh${NC}"
echo -e "        ${BOLD}sh ./hubbound-install.sh${NC}"
echo -e "        ${BOLD}rm -f ./hubbound-install.sh${NC}"
echo ""
