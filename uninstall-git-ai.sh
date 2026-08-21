#!/usr/bin/env bash
# uninstall-git-ai.sh — remove git-ai and IDE hooks it installed.
#
# Usage:
#   ./scripts/uninstall-git-ai.sh              # interactive
#   ./scripts/uninstall-git-ai.sh --dry-run    # show actions only
#   ./scripts/uninstall-git-ai.sh --yes        # skip confirmation
#   ./scripts/uninstall-git-ai.sh --repos      # also scrub .git/ai in repos under $HOME
#   ./scripts/dev/uninstall-git-ai.sh ...      # historical alias (same script)
#
# Close Cursor, Claude Code, Codex, and OpenCode before running.

set -euo pipefail

DRY_RUN=0
ASSUME_YES=0
CLEAN_REPOS=0

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    --repos) CLEAN_REPOS=1 ;;
    -h|--help)
      sed -n '2,10p' "$0"
      exit 0
      ;;
    *)
      echo "unknown argument: $arg" >&2
      exit 1
      ;;
  esac
done

HOME_DIR="${HOME:?}"
BACKUP_DIR="${HOME_DIR}/.git-ai-uninstall-backup-$(date +%Y%m%d-%H%M%S)"
# Legacy + current install layouts (prod hubbound, dev hubbound-lab).
HUBBOUND_GIT_AI_CANDIDATES=(
  "/Library/Application Support/hubbound/current/git-ai"
  "/Library/Application Support/hubbound-lab/current/git-ai"
  "/Library/Application Support/hubbound/bin/git-ai"
  "/Library/Application Support/hubbound-lab/bin/git-ai"
  "/var/lib/hubbound/current/git-ai"
  "/var/lib/hubbound-lab/current/git-ai"
)

log() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }

run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[dry-run] %s\n' "$*"
    return 0
  fi
  "$@"
}

run_sudo() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[dry-run] sudo %s\n' "$*"
    return 0
  fi
  sudo "$@"
}

backup_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[dry-run] backup %s -> %s/\n' "$file" "$BACKUP_DIR"
    return 0
  fi
  mkdir -p "$BACKUP_DIR"
  local rel
  rel="${file#${HOME_DIR}/}"
  mkdir -p "$BACKUP_DIR/$(dirname "$rel")"
  if [[ -r "$file" ]]; then
    cp -p "$file" "$BACKUP_DIR/$rel"
  else
    sudo cp -p "$file" "$BACKUP_DIR/$rel"
  fi
}

find_git_ai_bin() {
  local candidate
  for candidate in \
    "${HOME_DIR}/.git-ai/bin/git-ai" \
    "${HOME_DIR}/.hubbound/bins/git-ai" \
    "${HOME_DIR}/.local/bin/git-ai" \
    "/usr/local/bin/git-ai" \
    "${HUBBOUND_GIT_AI_CANDIDATES[@]}" \
    "$(command -v git-ai 2>/dev/null || true)"; do
    [[ -n "$candidate" && -x "$candidate" ]] || continue
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
}

reclaim_root_owned_user_configs() {
  log "reclaiming root-owned IDE config files"
  local base item
  local -a roots=(
    "${HOME_DIR}/.claude"
    "${HOME_DIR}/.cursor"
    "${HOME_DIR}/.codex"
    "${HOME_DIR}/.config/opencode"
  )
  for base in "${roots[@]}"; do
    [[ -d "$base" ]] || continue
    while IFS= read -r item; do
      [[ -n "$item" ]] || continue
      warn "chown $(id -un):$(id -gn) $item"
      run_sudo chown -R "$(id -un):$(id -gn)" "$item"
    done < <(find "$base" -user root 2>/dev/null || true)
  done
}

if [[ "$ASSUME_YES" -ne 1 ]]; then
  cat <<EOF
This will remove git-ai from your system:

  - stop git-ai background daemon
  - run git-ai uninstall-hooks (official cleanup)
  - reclaim root-owned IDE configs (doctor/install-hooks side effect)
  - delete ~/.git-ai
  - remove git-ai binaries/symlinks (incl. hubbound + /usr/local/bin)
  - unset git trace2 hooks in ~/.gitconfig
  - strip git-ai hooks from Cursor, Claude, Codex, OpenCode configs
  - remove Cursor git-ai VS Code extension
$( [[ "$CLEAN_REPOS" -eq 1 ]] && echo "  - remove .git/ai + refs/notes/ai in repos under \$HOME" )

Config backups -> ${BACKUP_DIR}

EOF
  read -r -p "Continue? [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]] || { echo "aborted"; exit 1; }
fi

# --- 1. Stop daemon + official uninstall-hooks --------------------------------

GIT_AI_BIN="$(find_git_ai_bin || true)"

log "stopping git-ai background service"
if [[ -n "$GIT_AI_BIN" ]]; then
  run "$GIT_AI_BIN" bg shutdown --hard 2>/dev/null || true
else
  for bin in \
    "${HOME_DIR}/.local/bin/git-ai" \
    "/usr/local/bin/git-ai" \
    "${HUBBOUND_GIT_AI_CANDIDATES[@]}"; do
    [[ -n "$bin" && -x "$bin" ]] || continue
    run "$bin" bg shutdown --hard 2>/dev/null || true
  done
fi

if [[ -n "$GIT_AI_BIN" ]]; then
  log "running git-ai uninstall-hooks"
  run "$GIT_AI_BIN" uninstall-hooks || warn "git-ai uninstall-hooks failed; continuing with manual cleanup"
else
  warn "git-ai binary not found; skipping uninstall-hooks"
fi

reclaim_root_owned_user_configs

# --- 2. Manual hook cleanup (fallback; preserves non-git-ai hooks) ------------

log "cleaning IDE hook configs (manual fallback)"

export UNINSTALL_GIT_AI_DRY_RUN="$DRY_RUN"
export UNINSTALL_GIT_AI_BACKUP_DIR="$BACKUP_DIR"
export UNINSTALL_GIT_AI_HOME="$HOME_DIR"

python3 <<'PY'
from __future__ import annotations

import json
import os
import re
import shutil
import sys
from pathlib import Path

HOME = Path(os.environ["UNINSTALL_GIT_AI_HOME"])
DRY = os.environ.get("UNINSTALL_GIT_AI_DRY_RUN") == "1"
BACKUP = Path(os.environ["UNINSTALL_GIT_AI_BACKUP_DIR"])

GIT_AI_RE = re.compile(r"git-ai|git ai", re.I)


def is_git_ai_command(value: str | None) -> bool:
    return bool(value and GIT_AI_RE.search(value))


def backup(path: Path) -> None:
    if not path.is_file():
        return
    if DRY:
        print(f"[dry-run] backup {path} -> {BACKUP}/")
        return
    rel = path.relative_to(HOME)
    dest = BACKUP / rel
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(path, dest)


def write_json(path: Path, data: dict) -> None:
    if DRY:
        print(f"[dry-run] write {path}")
        return
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")


def write_text(path: Path, text: str) -> None:
    if DRY:
        print(f"[dry-run] write {path}")
        return
    path.write_text(text, encoding="utf-8")


def clean_cursor_hooks(path: Path) -> bool:
    if not path.is_file():
        return False
    backup(path)
    data = json.loads(path.read_text(encoding="utf-8"))
    hooks = data.get("hooks", {})
    changed = False
    for key in ("postToolUse", "preToolUse", "postToolUseFailure"):
        items = hooks.get(key, [])
        if not isinstance(items, list):
            continue
        filtered = [
            item for item in items
            if not is_git_ai_command((item or {}).get("command", ""))
        ]
        if filtered != items:
            changed = True
            if filtered:
                hooks[key] = filtered
            else:
                hooks.pop(key, None)
    if not hooks:
        data.pop("hooks", None)
        if len(data) <= 1 and "version" in data:
            if DRY:
                print(f"[dry-run] remove {path} (only git-ai hooks)")
            else:
                path.unlink()
            return True
    elif changed:
        data["hooks"] = hooks
    if changed:
        write_json(path, data)
    return changed


def clean_claude_hooks(path: Path) -> bool:
    if not path.is_file():
        return False
    backup(path)
    data = json.loads(path.read_text(encoding="utf-8"))
    hooks = data.get("hooks")
    if not isinstance(hooks, dict):
        return False
    changed = False
    for event, groups in list(hooks.items()):
        if not isinstance(groups, list):
            continue
        new_groups = []
        for group in groups:
            if not isinstance(group, dict):
                new_groups.append(group)
                continue
            inner = group.get("hooks", [])
            if not isinstance(inner, list):
                new_groups.append(group)
                continue
            filtered = [
                h for h in inner
                if not is_git_ai_command((h or {}).get("command", ""))
            ]
            if filtered != inner:
                changed = True
            if filtered:
                group = dict(group)
                group["hooks"] = filtered
                new_groups.append(group)
        if new_groups:
            hooks[event] = new_groups
        else:
            del hooks[event]
            changed = True
    if changed:
        if hooks:
            data["hooks"] = hooks
        else:
            data.pop("hooks", None)
        write_json(path, data)
    return changed


def clean_codex_toml(path: Path) -> bool:
    if not path.is_file():
        return False
    backup(path)
    text = path.read_text(encoding="utf-8")
    lines = text.splitlines(keepends=True)
    out: list[str] = []
    i = 0
    changed = False
    while i < len(lines):
        line = lines[i]
        if line.startswith("[[hooks.") or line.startswith("[hooks.state."):
            block = [line]
            i += 1
            while i < len(lines) and not (
                lines[i].startswith("[[hooks.") or
                lines[i].startswith("[hooks.") and not lines[i].startswith("[hooks.state.")
            ):
                if lines[i].startswith("[") and not lines[i].startswith("[hooks."):
                    break
                block.append(lines[i])
                i += 1
            block_text = "".join(block)
            if GIT_AI_RE.search(block_text):
                changed = True
                continue
            out.extend(block)
            continue
        if line.startswith("command = ") and GIT_AI_RE.search(line):
            changed = True
            i += 1
            continue
        out.append(line)
        i += 1
    if changed:
        write_text(path, "".join(out))
    return changed


def clean_codex_hooks_json(path: Path) -> bool:
    return clean_claude_hooks(path)


def main() -> int:
    touched = []

    cursor_hooks = HOME / ".cursor" / "hooks.json"
    if clean_cursor_hooks(cursor_hooks):
        touched.append(str(cursor_hooks))

    claude_settings = HOME / ".claude" / "settings.json"
    if clean_claude_hooks(claude_settings):
        touched.append(str(claude_settings))

    codex_toml = HOME / ".codex" / "config.toml"
    if clean_codex_toml(codex_toml):
        touched.append(str(codex_toml))

    codex_hooks = HOME / ".codex" / "hooks.json"
    if clean_codex_hooks_json(codex_hooks):
        touched.append(str(codex_hooks))

    opencode_plugin = HOME / ".config" / "opencode" / "plugins" / "git-ai.ts"
    if opencode_plugin.is_file():
        backup(opencode_plugin)
        if DRY:
            print(f"[dry-run] remove {opencode_plugin}")
        else:
            opencode_plugin.unlink()
        touched.append(str(opencode_plugin))

    if touched:
        print("updated:")
        for item in touched:
            print(f"  - {item}")
    else:
        print("no IDE hook configs needed changes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
PY

# --- 3. Binaries & symlinks --------------------------------------------------

log "removing git-ai binaries and symlinks"
for path in \
  "${HOME_DIR}/.local/bin/git-ai" \
  "${HOME_DIR}/.hubbound/bins/git-ai" \
  "/usr/local/bin/git-ai" \
  "${HUBBOUND_GIT_AI_CANDIDATES[@]}"; do
  [[ -e "$path" || -L "$path" ]] || continue
  if [[ "$path" == /usr/local/* || "$path" == /Library/* || "$path" == /var/lib/* ]]; then
    run_sudo rm -f "$path"
  else
    run rm -f "$path"
  fi
done

# --- 4. User data dir --------------------------------------------------------

log "removing ~/.git-ai"
if [[ -d "${HOME_DIR}/.git-ai" ]]; then
  if [[ "$(stat -f '%u' "${HOME_DIR}/.git-ai" 2>/dev/null || echo "")" == "0" ]]; then
    run_sudo rm -rf "${HOME_DIR}/.git-ai"
  else
    run rm -rf "${HOME_DIR}/.git-ai"
  fi
fi

# --- 5. Git global trace2 ----------------------------------------------------

log "cleaning git global trace2 config"
if git config --global --get trace2.eventtarget 2>/dev/null | rg -q '\.git-ai/'; then
  run git config --global --unset trace2.eventtarget || true
fi
if git config --global --get trace2.eventnesting >/dev/null 2>&1; then
  if ! git config --global --get trace2.eventtarget >/dev/null 2>&1; then
    run git config --global --unset trace2.eventnesting || true
  fi
fi

# --- 6. Cursor extension -----------------------------------------------------

log "removing Cursor git-ai extension"
shopt -s nullglob
for ext in "${HOME_DIR}/.cursor/extensions"/git-ai.git-ai-vscode-*; do
  if [[ -d "$ext" ]] && [[ "$(stat -f '%u' "$ext" 2>/dev/null || echo "")" == "0" ]]; then
    run_sudo rm -rf "$ext"
  else
    run rm -rf "$ext"
  fi
done

reclaim_root_owned_user_configs

EXT_JSON="${HOME_DIR}/.cursor/extensions/extensions.json"
if [[ -f "$EXT_JSON" ]]; then
  backup_file "$EXT_JSON"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[dry-run] prune git-ai from %s\n' "$EXT_JSON"
  else
    python3 - "$EXT_JSON" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    data = json.load(f)
if not isinstance(data, list):
    sys.exit(0)
filtered = [e for e in data if "git-ai" not in json.dumps(e).lower()]
if filtered != data:
    with open(path, "w", encoding="utf-8") as f:
        json.dump(filtered, f, indent=2)
        f.write("\n")
PY
  fi
fi

# --- 7. Optional repo scrub --------------------------------------------------

if [[ "$CLEAN_REPOS" -eq 1 ]]; then
  log "scrubbing .git/ai and refs/notes/ai in repos under ${HOME_DIR}"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    fd --type d --hidden --exclude .npm --exclude node_modules --exclude Library \
      --max-depth 6 '^ai$' "${HOME_DIR}" 2>/dev/null | rg '/\.git/ai$' || true
  else
    while IFS= read -r ai_dir; do
      [[ -n "$ai_dir" ]] || continue
      repo_git="$(dirname "$ai_dir")"
      log "  repo: $(dirname "$repo_git")"
      rm -rf "$ai_dir"
      git -C "$(dirname "$repo_git")" notes --ref=ai list 2>/dev/null | while read -r _ sha; do
        git -C "$(dirname "$repo_git")" notes --ref=ai remove "$sha" 2>/dev/null || true
      done
      git -C "$(dirname "$repo_git")" update-ref -d refs/notes/ai 2>/dev/null || true
    done < <(fd --type d --hidden --exclude .npm --exclude node_modules --exclude Library \
      --max-depth 6 '^ai$' "${HOME_DIR}" 2>/dev/null | rg '/\.git/ai$' || true)
  fi
fi

# --- 8. Project-local OpenCode plugins ---------------------------------------

log "removing project-local .opencode/plugins/git-ai.ts (if any)"
if [[ "$DRY_RUN" -eq 1 ]]; then
  fd -H 'git-ai.ts' "${HOME_DIR}/dev" "${HOME_DIR}/Documents" 2>/dev/null \
    | rg '/\.opencode/plugins/git-ai\.ts$' || true
else
  while IFS= read -r plugin; do
    [[ -n "$plugin" ]] || continue
    backup_file "$plugin"
    rm -f "$plugin"
    log "  removed $plugin"
  done < <(fd -H 'git-ai.ts' "${HOME_DIR}/dev" "${HOME_DIR}/Documents" 2>/dev/null \
    | rg '/\.opencode/plugins/git-ai\.ts$' || true)
fi

log "done"
if [[ "$DRY_RUN" -ne 1 && -d "$BACKUP_DIR" ]]; then
  log "backups saved to ${BACKUP_DIR}"
fi
log "restart Cursor / Claude / Codex / OpenCode before using them again"
