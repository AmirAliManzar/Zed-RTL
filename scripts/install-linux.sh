#!/usr/bin/env bash
# Installs the RTL-patched Zed on Linux and keeps it up to date.
#
# This is the Linux counterpart of the Windows patcher: it downloads the
# prebuilt binary from the Zed-RTL GitHub releases, installs it under
# ~/.local (no root needed), freezes Zed's own updater so updates only ever
# come from Zed-RTL, and registers a systemd user timer that checks for new
# builds every two hours.
#
# Usage:
#   ./install-linux.sh                  # install/upgrade to the latest build
#   ./install-linux.sh --no-auto-update # install once, no timer
#   ./install-linux.sh --update-if-available  # timer entry point (quiet)
#   ./install-linux.sh --uninstall      # remove the timer, symlink and install
set -euo pipefail

repo="AmirAliManzar/Zed-RTL"
api="https://api.github.com/repos/$repo"
install_dir="${ZED_RTL_HOME:-$HOME/.local/share/zed-rtl}"
bin_dir="$HOME/.local/bin"
marker="$install_dir/installed.json"
settings="$HOME/.config/zed/settings.json"
timer_name="zed-rtl-update"

auto_update=1
update_if_available=0
uninstall=0

for arg in "$@"; do
    case "$arg" in
        --no-auto-update) auto_update=0 ;;
        --update-if-available) update_if_available=1; auto_update=0 ;;
        --uninstall) uninstall=1 ;;
        -h|--help)
            sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "unknown argument: $arg (try --help)" >&2; exit 2 ;;
    esac
done

# ---------------------------------------------------------------- helpers
gh_get() { curl -fsSL "$1"; }

# Extracts a JSON string field with grep, so the script has no jq dependency.
json_string() { grep -oP "\"$1\"\s*:\s*\"\K[^\"]+" | head -1; }

arch=""
case "$(uname -m)" in
    x86_64|amd64)  arch=x86_64 ;;
    aarch64|arm64) arch=aarch64 ;;
    *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

log() { echo "[zed-rtl] $*"; }
quiet_log() { if [ "$update_if_available" -eq 0 ]; then log "$*"; fi }

# ---------------------------------------------------------------- uninstall
if [ "$uninstall" -eq 1 ]; then
    log "uninstalling..."
    if command -v systemctl >/dev/null 2>&1; then
        systemctl --user disable --now "$timer_name.timer" 2>/dev/null || true
    fi
    rm -f "$HOME/.config/systemd/user/$timer_name.timer" \
          "$HOME/.config/systemd/user/$timer_name.service" 2>/dev/null || true
    if command -v systemctl >/dev/null 2>&1; then
        systemctl --user daemon-reload 2>/dev/null || true
    fi
    # Only remove the ~/.local/bin/zed symlink if it points at our install,
    # never a symlink the user created by hand for something else.
    if [ -L "$bin_dir/zed" ] && [ "$(readlink -f "$bin_dir/zed" 2>/dev/null)" = "$(readlink -f "$install_dir/bin/zed" 2>/dev/null)" ]; then
        rm -f "$bin_dir/zed"
    fi
    rm -rf "$install_dir"
    log "removed. Install Zed from your distro's package to go back to upstream."
    exit 0
fi

# ---------------------------------------------------------------- resolve
log "resolving the latest Zed-RTL release..."
tag=$(gh_get "$api/releases/latest" | json_string tag_name)
if [ -z "$tag" ]; then
    echo "could not resolve the latest release from $api/releases/latest" >&2
    exit 1
fi

info=$(gh_get "$api/releases/latest" | grep -oP "\"browser_download_url\"\s*:\s*\"\K[^\"]+build-info-linux-$arch\.json")
if [ -z "$info" ]; then
    echo "no Linux $arch build in release $tag yet." >&2
    echo "Windows-only releases publish until the Linux CI job finishes." >&2
    exit 1
fi
build_info=$(gh_get "$info")
asset_name=$(printf '%s' "$build_info" | json_string artifact)
asset_sha=$(printf '%s' "$build_info" | json_string sha256)
asset_url=$(gh_get "$api/releases/latest" | grep -oP "\"browser_download_url\"\s*:\s*\"\K[^\"]+/\Q$asset_name\E")

if [ -z "$asset_url" ]; then
    echo "asset $asset_name is missing from release $tag" >&2
    exit 1
fi
quiet_log "latest build: $tag ($asset_name)"

# ------------------------------------------------- already up to date?
installed_sha=""
if [ -f "$marker" ]; then
    installed_sha=$(json_string sha256 < "$marker")
fi
if [ "$installed_sha" = "$asset_sha" ] && [ -x "$install_dir/bin/zed" ]; then
    quiet_log "already on the latest build ($tag); nothing to do."
    exit 0
fi

# ---------------------------------------------------------------- download
mkdir -p "$install_dir/downloads"
download="$install_dir/downloads/$asset_name"

# Reuse a cached download from a previous run (Zed was still running then) so
# the timer does not re-fetch the same build every two hours.
skip_download=0
if [ -f "$download" ]; then
    cached_sha=$(sha256sum "$download" | awk '{print $1}')
    if [ "$cached_sha" = "$asset_sha" ]; then
        skip_download=1
        quiet_log "using the cached build already staged in $download"
    fi
fi
if [ "$skip_download" -eq 0 ]; then
    log "downloading $asset_url..."
    gh_get -o "$download" "$asset_url"
fi

actual_sha=$(sha256sum "$download" | awk '{print $1}')
if [ "$actual_sha" != "$asset_sha" ]; then
    echo "sha256 mismatch for $asset_name" >&2
    echo "  expected: $asset_sha" >&2
    echo "  actual:   $actual_sha" >&2
    rm -f "$download"
    exit 1
fi
log "sha256 verified."

# Zed keeps a lock on its own binary while running, and a swap under it would
# crash the editor. Mirror the Windows updater: download and stage now, swap
# on a later run once Zed has quit.
if pgrep -x zed >/dev/null 2>&1; then
    if [ "$update_if_available" -eq 1 ]; then
        quiet_log "Zed is running; the staged build swaps in on the next check after it quits."
    else
        log "Zed is running. The build is staged; close Zed and re-run this script to swap it in, or let the timer do it."
    fi
    exit 0
fi

# ---------------------------------------------------------------- install
tmp_extract=$(mktemp -d)
trap 'rm -rf "$tmp_extract"' EXIT
tar -xzf "$download" -C "$tmp_extract"
src_bin="$tmp_extract/zed-rtl-linux-$arch/bin/zed"
if [ ! -x "$src_bin" ]; then
    echo "tarball did not contain zed-rtl-linux-$arch/bin/zed" >&2
    exit 1
fi

mkdir -p "$install_dir/bin"
# mv across filesystems can fail; fall back to cp+rm.
if ! mv -f "$src_bin" "$install_dir/bin/zed.new"; then
    cp -f "$src_bin" "$install_dir/bin/zed.new"
    rm -f "$src_bin"
fi
chmod +x "$install_dir/bin/zed.new"
mv -f "$install_dir/bin/zed.new" "$install_dir/bin/zed"

printf '{\n  "tag": "%s",\n  "sha256": "%s",\n  "asset": "%s"\n}\n' \
    "$tag" "$asset_sha" "$asset_name" > "$marker"
rm -f "$download"

mkdir -p "$bin_dir"
ln -sf "$install_dir/bin/zed" "$bin_dir/zed"

# Freeze Zed's own updater. Without this, Zed replaces the patched binary with
# an upstream one on the next restart and the RTL caret fix disappears.
freeze_updater() {
    mkdir -p "$(dirname "$settings")"
    touch "$settings"
    if grep -qE '"auto_update"\s*:' "$settings"; then
        sed -i -E 's/"auto_update"\s*:\s*(true|false)/"auto_update": false/' "$settings"
    else
        # Insert as the first key so the object stays valid JSON in every case.
        if grep -q '^\s*{' "$settings"; then
            sed -i -E '0,/^\s*\{/s//{ "auto_update": false,/' "$settings"
        else
            printf '{ "auto_update": false }\n' > "$settings"
        fi
    fi
}
freeze_updater
log "installed $tag to $install_dir/bin/zed"
log "symlinked as $bin_dir/zed (make sure $bin_dir is on your PATH)"

# If a distro Zed is installed system-wide it may still win on PATH. Say so
# instead of silently leaving the user on the unpatched build.
if command -v zed >/dev/null 2>&1 && [ "$(readlink -f "$(command -v zed)")" != "$(readlink -f "$bin_dir/zed")" ]; then
    log "note: 'zed' on PATH resolves to $(command -v zed), not this build."
    log "      start it with $bin_dir/zed or adjust PATH so $bin_dir comes first."
fi

# ---------------------------------------------------------------- timer
if [ "$auto_update" -eq 1 ]; then
    if ! command -v systemctl >/dev/null 2>&1; then
        log "systemctl is unavailable; skipping the auto-update timer."
        log "re-run this script manually to upgrade."
    else
        mkdir -p "$HOME/.config/systemd/user"
        script_path="$(readlink -f "$0")"
        cat > "$HOME/.config/systemd/user/$timer_name.service" <<EOF
[Unit]
Description=Check for a new Zed-RTL build

[Service]
Type=oneshot
ExecStart=$script_path --update-if-available
EOF
        cat > "$HOME/.config/systemd/user/$timer_name.timer" <<EOF
[Unit]
Description=Check for a new Zed-RTL build every 2 hours

[Timer]
OnBootSec=2min
OnUnitActiveSec=2h
Persistent=true
Unit=$timer_name.service

[Install]
WantedBy=default.target
EOF
        systemctl --user daemon-reload
        systemctl --user enable --now "$timer_name.timer"
        log "auto-update timer registered (every 2 hours). Remove it with --uninstall."
    fi
fi

log "done."
