#!/usr/bin/env sh
# Official bootstrap. It verifies the public GitHub Release checksum, then
# performs one privileged suite installation through hubbound-helper.
set -eu

REPO="${HUBBOUND_REPO:-hubbound/hubbound}"
VERSION="${HUBBOUND_VERSION:-}"
SYSTEM_ROOT="${HUBBOUND_SYSTEM_ROOT:-}"
USER_BIN="${HUBBOUND_USER_BIN:-$HOME/.local/bin}"

if [ -t 1 ] && [ -z "${NO_COLOR+x}" ]; then
	escape=$(printf '\033')
	cyan="${escape}[36m"
	green="${escape}[32m"
	yellow="${escape}[33m"
	red="${escape}[31m"
	bold="${escape}[1m"
	reset="${escape}[0m"
else
	cyan=''
	green=''
	yellow=''
	red=''
	bold=''
	reset=''
fi

line() { printf '%s\n' "────────────────────────────────────────────────────"; }
title() {
	printf '\n%s%s%s\n' "$bold" "$1" "$reset"
	line
}
step() { printf '  %s→%s %s\n' "$cyan" "$reset" "$1"; }
ok() { printf '  %s✓%s %s\n' "$green" "$reset" "$1"; }
warn() { printf '  %s!%s %s\n' "$yellow" "$reset" "$1" >&2; }
fail() {
	printf '  %s✗%s %s\n' "$red" "$reset" "$1" >&2
	exit 1
}
need() { command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"; }

need curl
need tar
need sudo

os=$(uname -s | tr '[:upper:]' '[:lower:]')
case "$os" in darwin | linux) ;; *) fail "Unsupported operating system: $os" ;; esac
case "$(uname -m)" in x86_64 | amd64) arch=amd64 ;; arm64 | aarch64) arch=arm64 ;; *) fail "Unsupported architecture: $(uname -m)" ;; esac

title "Hubbound Installer"
if [ -z "$VERSION" ]; then
	step "Finding the latest Hubbound release"
	VERSION=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1) || fail "Could not find the latest release"
fi
[ -n "$VERSION" ] || fail "Could not determine the release version"
printf '\nInstalling %s%s%s  %s(%s-%s)%s\n\n' "$bold" "$VERSION" "$reset" "$yellow" "$os" "$arch" "$reset"

archive="hubbound_${os}_${arch}.tar.gz"
base="https://github.com/$REPO/releases/download/$VERSION"
tmp=$(mktemp -d)
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT INT TERM

step "Downloading the Hubbound suite"
curl -fsSL "$base/$archive" -o "$tmp/$archive" || fail "Could not download $archive"
ok "Downloaded $archive"
curl -fsSL "$base/checksums.txt" -o "$tmp/checksums.txt" || fail "Could not download release checksums"

step "Verifying the SHA-256 checksum"
expected=$(grep "  $archive$" "$tmp/checksums.txt" | awk '{print $1}')
[ -n "${expected:-}" ] || fail "Checksum not found for $archive"
if command -v sha256sum >/dev/null 2>&1; then
	actual=$(sha256sum "$tmp/$archive" | awk '{print $1}')
else
	actual=$(shasum -a 256 "$tmp/$archive" | awk '{print $1}')
fi
[ "$expected" = "$actual" ] || fail "Checksum verification failed — installation stopped"
ok "Checksum verified"

step "Preparing the protected system installation"
tar -xzf "$tmp/$archive" -C "$tmp" || fail "Could not extract the release archive"
helper=$(find "$tmp" -type f -name hubbound-helper -print | head -n1)
[ -n "$helper" ] || fail "Archive is missing hubbound-helper"
printf '  %s%s%s Administrator permission is needed once to install the system daemon.\n' "$yellow" '!' "$reset"

# Exactly one sudo boundary: the helper owns every root mutation and service
# registration. The agent below remains intentionally user-owned.
if [ -n "$SYSTEM_ROOT" ]; then
	sudo "$helper" system install --archive "$tmp/$archive" --version "$VERSION" --system-root "$SYSTEM_ROOT" >/dev/null || fail "System installation or daemon health check failed"
else
	sudo "$helper" system install --archive "$tmp/$archive" --version "$VERSION" >/dev/null || fail "System installation or daemon health check failed"
fi
ok "Installed protected binaries and started hubboundd"

root=${SYSTEM_ROOT:-}
if [ -z "$root" ]; then
	case "$VERSION" in
	*-dev.*) data_dir_name=hubbound-lab ;;
	*) data_dir_name=hubbound ;;
	esac
	[ "$os" = darwin ] && root="/Library/Application Support/$data_dir_name" || root="/var/lib/$data_dir_name"
fi
step "Configuring your user session"
mkdir -p "$USER_BIN"
for bin in hubbound hubbound-agent hubbound-helper; do
	ln -sf "$root/current/$bin" "$USER_BIN/$bin"
done
ok "Linked Hubbound commands at $USER_BIN"

path_added=0
case ":$PATH:" in
*":$USER_BIN:"*) ;;
*)
	case "${SHELL:-}" in
	*/zsh) shell_rc="$HOME/.zshrc" ;;
	*/bash) shell_rc="$HOME/.bashrc" ;;
	*) shell_rc="$HOME/.profile" ;;
	esac
	marker='# Hubbound CLI'
	if ! grep -F "$marker" "$shell_rc" >/dev/null 2>&1; then
		{
			printf '\n%s\n' "$marker"
			printf 'export PATH="%s:$PATH"\n' "$USER_BIN"
		} >>"$shell_rc"
	fi
	path_added=1
	;;
esac

if [ "$os" = darwin ]; then
	d="$HOME/Library/LaunchAgents"
	p="$d/com.hubbound.agent.plist"
	mkdir -p "$d"
	cat >"$p" <<EOF
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>Label</key><string>com.hubbound.agent</string><key>ProgramArguments</key><array><string>$root/current/hubbound-agent</string><string>run</string></array><key>RunAtLoad</key><true/><key>KeepAlive</key><true/></dict></plist>
EOF
	launchctl bootout "gui/$(id -u)" "$p" >/dev/null 2>&1 || true
	launchctl bootstrap "gui/$(id -u)" "$p" >/dev/null 2>&1 || launchctl load "$p" >/dev/null 2>&1 || warn "Could not start the LaunchAgent automatically"
	ok "Installed your Hubbound LaunchAgent"
else
	d="$HOME/.config/systemd/user"
	mkdir -p "$d"
	cat >"$d/hubbound-agent.service" <<EOF
[Unit]
Description=Hubbound user agent
[Service]
ExecStart=$root/current/hubbound-agent run
Restart=on-failure
[Install]
WantedBy=default.target
EOF
	systemctl --user daemon-reload >/dev/null 2>&1 || true
	systemctl --user enable --now hubbound-agent.service >/dev/null 2>&1 || warn "Could not start the systemd user service automatically"
	ok "Installed your Hubbound user agent"
fi
ok "Daemon health check passed"

# If a previous --keep-data uninstall parked telemetry under the user state
# dir, move it back into the new system root so hubboundd resumes the spool.
# User-state folder matches the system-root basename (hubbound vs hubbound-lab).
data_dir_name=$(basename "$root")
case "$os" in
darwin) user_state="$HOME/Library/Application Support/$data_dir_name" ;;
*) user_state="$HOME/.config/$data_dir_name" ;;
esac
preserved_analytics="$user_state/analytics"
system_analytics="$root/analytics"
if [ -d "$preserved_analytics" ]; then
	step "Restoring preserved telemetry into the system analytics spool"
	if [ -d "$system_analytics" ] && [ -n "$(ls -A "$system_analytics" 2>/dev/null)" ]; then
		warn "System analytics already present; leaving $preserved_analytics in place"
	else
		sudo mkdir -p "$root"
		sudo rm -rf "$system_analytics"
		sudo cp -a "$preserved_analytics" "$system_analytics"
		# Spool must stay root-owned like a fresh install (daemon runs as root).
		sudo chown -R root:wheel "$system_analytics" 2>/dev/null || sudo chown -R root:root "$system_analytics" 2>/dev/null || true
		rm -rf "$preserved_analytics"
		ok "Restored telemetry to $system_analytics"
	fi
fi

printf '\n%sHubbound %s is ready!%s\n\n' "$green" "$VERSION" "$reset"
printf '%sGet started:%s\n' "$bold" "$reset"
printf '  %shubbound auth login%s       connect your Hubbound account\n' "$cyan" "$reset"
printf '  %shubbound daemon status%s    check the system daemon\n' "$cyan" "$reset"
printf '  %shubbound update status%s    view update state\n' "$cyan" "$reset"
if [ "$path_added" = 1 ]; then
	printf '\n%sReload your shell to activate Hubbound:%s\n' "$bold" "$reset"
	printf '  source "%s"\n' "$shell_rc"
fi
