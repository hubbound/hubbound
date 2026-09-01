#!/usr/bin/env sh
# Official bootstrap. It verifies the public GitHub Release checksum, then
# installs the selected component. Set HUBBOUND_COMPONENT to cli, runtime or
# suite; suite remains the backwards-compatible default.
set -eu

REPO="${HUBBOUND_REPO:-hubbound/hubbound}"
VERSION="${HUBBOUND_VERSION:-}"
SYSTEM_ROOT="${HUBBOUND_SYSTEM_ROOT:-}"
# HUBBOUND_INSTALL_DIR is kept as a compatibility alias for the original
# bootstrap contract; HUBBOUND_USER_BIN is the component-oriented name.
USER_BIN="${HUBBOUND_USER_BIN:-${HUBBOUND_INSTALL_DIR:-$HOME/.local/bin}}"

# Component bootstraps are published as standalone copies of this file. Infer
# the component from the filename so a downloaded `hubbound-install-cli.sh`
# remains self-contained and does not need to fetch/execute another script.
# A shell interpreter name means the file arrived through stdin (`curl | sh`);
# reject that mode because there is no local source the user can inspect.
script_name=${0##*/}
case "$script_name" in
*install-cli.sh) inferred_component=cli ;;
*install-runtime.sh) inferred_component=runtime ;;
*install.sh) inferred_component=suite ;;
*)
	printf '%s\n' 'Hubbound installer: download the installer, inspect it, then run the local file; piped execution is disabled.' >&2
	exit 2
	;;
esac
COMPONENT="${HUBBOUND_COMPONENT:-$inferred_component}"

case "$COMPONENT" in
cli | runtime | suite) ;;
*)
	printf 'Hubbound installer: unknown component %s (want cli, runtime or suite)\n' "$COMPONENT" >&2
	exit 2
	;;
esac

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
[ "$COMPONENT" = cli ] || need sudo

os=$(uname -s | tr '[:upper:]' '[:lower:]')
case "$os" in darwin | linux) ;; *) fail "Unsupported operating system: $os" ;; esac
case "$(uname -m)" in x86_64 | amd64) arch=amd64 ;; arm64 | aarch64) arch=arm64 ;; *) fail "Unsupported architecture: $(uname -m)" ;; esac

title "Hubbound Installer"
if [ -z "$VERSION" ]; then
	step "Finding the latest Hubbound release"
	VERSION=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1) || fail "Could not find the latest release"
fi
[ -n "$VERSION" ] || fail "Could not determine the release version"
printf '\nInstalling %s%s%s  %s(%s-%s, %s)%s\n\n' "$bold" "$VERSION" "$reset" "$yellow" "$os" "$arch" "$COMPONENT" "$reset"

case "$COMPONENT" in
cli) archive="hubbound-cli_${os}_${arch}.tar.gz" ;;
runtime) archive="hubbound-runtime_${os}_${arch}.tar.gz" ;;
suite) archive="hubbound_${os}_${arch}.tar.gz" ;;
esac
base="${HUBBOUND_RELEASE_BASE_URL:-https://github.com/$REPO/releases/download/$VERSION}"
base=${base%/}
case "$base" in
https://*) ;;
http://*)
	[ "${HUBBOUND_ALLOW_INSECURE_HTTP:-}" = 1 ] || fail "Insecure HTTP release mirrors require HUBBOUND_ALLOW_INSECURE_HTTP=1"
	;;
*) fail "Release mirror must use HTTPS" ;;
esac
tmp=$(mktemp -d)
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT INT TERM

step "Downloading the Hubbound $COMPONENT"
curl -fsSL "$base/$archive" -o "$tmp/$archive" || fail "Could not download $archive"
ok "Downloaded $archive"
curl -fsSL "$base/checksums.txt" -o "$tmp/checksums.txt" || fail "Could not download release checksums"

step "Verifying the SHA-256 checksum"
expected=$(awk -v file="$archive" '{ name=$2; sub(/^\*/, "", name); if (name == file) print $1 }' "$tmp/checksums.txt")
match_count=$(printf '%s\n' "$expected" | awk 'NF { count++ } END { print count + 0 }')
[ "$match_count" = 1 ] || fail "Expected exactly one checksum entry for $archive"
if ! printf '%s\n' "$expected" | awk 'length($0) == 64 && $0 !~ /[^0-9A-Fa-f]/ { valid=1 } END { exit valid ? 0 : 1 }'; then
	fail "Checksum entry is not a valid SHA-256 for $archive"
fi
expected=$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]')
if command -v sha256sum >/dev/null 2>&1; then
	actual=$(sha256sum "$tmp/$archive" | awk '{print $1}')
else
	actual=$(shasum -a 256 "$tmp/$archive" | awk '{print $1}')
fi
[ "$expected" = "$actual" ] || fail "Checksum verification failed — installation stopped"
ok "Checksum verified"

if [ "$COMPONENT" = cli ]; then
	# Extract only the expected top-level member. Release archives are
	# checksum-verified, but keeping extraction member-scoped also prevents a
	# compromised mirror/archive from writing unrelated paths in this user's
	# temporary directory.
	tar -xzf "$tmp/$archive" -C "$tmp" -- hubbound || fail "Could not extract hubbound from the release archive"
	cli_bin=$(find "$tmp" -maxdepth 1 -type f -name hubbound -print -quit)
	[ -n "$cli_bin" ] || fail "Archive is missing hubbound"
	step "Installing the CLI in your user account"
	mkdir -p "$USER_BIN"
	install -m 755 "$cli_bin" "$USER_BIN/hubbound" || fail "Could not install hubbound in $USER_BIN"
	ok "Installed the standalone CLI at $USER_BIN/hubbound"
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
		printf '\n%sReload your shell to activate Hubbound:%s\n  source "%s"\n' "$bold" "$reset" "$shell_rc"
		;;
	esac
	printf '\n%sHubbound CLI %s is ready!%s\n' "$green" "$VERSION" "$reset"
	exit 0
fi

step "Preparing the protected system installation"
printf '  %s%s%s Administrator permission is needed once to install the system daemon.\n' "$yellow" '!' "$reset"

# Exactly one sudo boundary: copy the already checksum-verified archive into a
# root-owned temporary directory, verify that protected copy, extract the
# helper from it, and only then execute the helper. This prevents a same-user
# process from replacing either the archive or the helper between the
# unprivileged checksum check and the privileged operation.
if [ -n "$SYSTEM_ROOT" ]; then
	sudo sh -c '
		set -eu
		umask 077
		source_archive=$1
		expected_sha256=$2
		component=$3
		version=$4
		system_root=$5
		archive_name=${source_archive##*/}
		# Do not execute the privileged helper from /tmp: hardened enterprise
		# images commonly mount it noexec. Keep the temporary copy root-owned and
		# under the protected filesystem that contains the requested root. The
		# helper validates the root ownership and writability before mutating it.
	bootstrap_parent=${system_root%/*}
	[ "$bootstrap_parent" = "$system_root" ] && bootstrap_parent="/"
	[ -n "$bootstrap_parent" ] || bootstrap_parent="/"
	mkdir -p "$bootstrap_parent"
	bootstrap_dir=$(mktemp -d "$bootstrap_parent/.hubbound-bootstrap.XXXXXX")
	trap '\''rm -rf "$bootstrap_dir"'\'' EXIT INT TERM
		install -m 600 "$source_archive" "$bootstrap_dir/$archive_name"
		if command -v sha256sum >/dev/null 2>&1; then
			actual_sha256=$(sha256sum "$bootstrap_dir/$archive_name" | awk "{print \$1}")
		else
			actual_sha256=$(shasum -a 256 "$bootstrap_dir/$archive_name" | awk "{print \$1}")
		fi
		[ "$actual_sha256" = "$expected_sha256" ] || {
			printf "protected archive checksum mismatch: got %s want %s\n" "$actual_sha256" "$expected_sha256" >&2
			exit 1
		}
		mkdir "$bootstrap_dir/payload"
		tar -xzf "$bootstrap_dir/$archive_name" -C "$bootstrap_dir/payload" -- hubbound-helper
		helper=$(find "$bootstrap_dir/payload" -maxdepth 1 -type f -name hubbound-helper -print -quit)
		[ -n "$helper" ] || {
			printf "%s\n" "protected archive is missing hubbound-helper" >&2
			exit 1
		}
		chmod 700 "$helper"
		"$helper" system install --component "$component" --archive "$bootstrap_dir/$archive_name" --sha256 "$expected_sha256" --version "$version" --system-root "$system_root"
	' sh "$tmp/$archive" "$expected" "$COMPONENT" "$VERSION" "$SYSTEM_ROOT" || fail "System installation or daemon health check failed"
else
	sudo sh -c '
		set -eu
		umask 077
		source_archive=$1
		expected_sha256=$2
		component=$3
		version=$4
		archive_name=${source_archive##*/}
		# Keep the executable bootstrap off /tmp because enterprise hardening may
		# mount that filesystem noexec.
		case "$(uname -s)" in
		Darwin) bootstrap_parent="/Library/Application Support" ;;
		*) bootstrap_parent="/var/lib" ;;
		esac
		mkdir -p "$bootstrap_parent"
		bootstrap_dir=$(mktemp -d "$bootstrap_parent/.hubbound-bootstrap.XXXXXX")
		trap '\''rm -rf "$bootstrap_dir"'\'' EXIT INT TERM
		install -m 600 "$source_archive" "$bootstrap_dir/$archive_name"
		if command -v sha256sum >/dev/null 2>&1; then
			actual_sha256=$(sha256sum "$bootstrap_dir/$archive_name" | awk "{print \$1}")
		else
			actual_sha256=$(shasum -a 256 "$bootstrap_dir/$archive_name" | awk "{print \$1}")
		fi
		[ "$actual_sha256" = "$expected_sha256" ] || {
			printf "protected archive checksum mismatch: got %s want %s\n" "$actual_sha256" "$expected_sha256" >&2
			exit 1
		}
		mkdir "$bootstrap_dir/payload"
		tar -xzf "$bootstrap_dir/$archive_name" -C "$bootstrap_dir/payload" -- hubbound-helper
		helper=$(find "$bootstrap_dir/payload" -maxdepth 1 -type f -name hubbound-helper -print -quit)
		[ -n "$helper" ] || {
			printf "%s\n" "protected archive is missing hubbound-helper" >&2
			exit 1
		}
		chmod 700 "$helper"
		"$helper" system install --component "$component" --archive "$bootstrap_dir/$archive_name" --sha256 "$expected_sha256" --version "$version"
	' sh "$tmp/$archive" "$expected" "$COMPONENT" "$VERSION" || fail "System installation or daemon health check failed"
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
if [ "$COMPONENT" = suite ]; then
	step "Configuring your user session"
	mkdir -p "$USER_BIN"
	for bin in hubbound hubbound-agent hubbound-helper; do
		ln -sf "$root/current/$bin" "$USER_BIN/$bin"
	done
	ok "Linked Hubbound commands at $USER_BIN"
fi

path_added=0
case "$COMPONENT" in suite)
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
	;;
esac

if [ "$os" = darwin ]; then
	d="$HOME/Library/LaunchAgents"
	p="$d/net.hubbound.agent.plist"
	mkdir -p "$d"
	cat >"$p" <<EOF
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>Label</key><string>net.hubbound.agent</string><key>ProgramArguments</key><array><string>$root/current/hubbound-agent</string><string>run</string></array><key>RunAtLoad</key><true/><key>KeepAlive</key><true/></dict></plist>
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
if [ "$COMPONENT" = suite ]; then
	printf '  %shubbound auth login%s       connect your Hubbound account\n' "$cyan" "$reset"
	printf '  %shubbound daemon status%s    check the system daemon\n' "$cyan" "$reset"
	printf '  %shubbound update status%s    view update state\n' "$cyan" "$reset"
else
	printf '  %shubboundd status%s          check the system daemon\n' "$cyan" "$reset"
	printf '  %shubbound-agent run%s        run the user agent manually\n' "$cyan" "$reset"
fi
if [ "$path_added" = 1 ]; then
	printf '\n%sReload your shell to activate Hubbound:%s\n' "$bold" "$reset"
	printf '  source "%s"\n' "$shell_rc"
fi
