#!/usr/bin/env bash
# Builds the RTL-patched Zed for Linux (used by CI; works locally too).
#
# Clones upstream Zed at the pinned commit (UPSTREAM_REF), applies
# patch/zed-rtl.patch, compiles a release zed binary, strips it, and stages
# zed-rtl-linux-<arch>.tar.gz plus build-info JSON in artifacts/.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
patch_path="$repo_root/patch/zed-rtl.patch"
upstream_ref="${UPSTREAM_REF:-}"
target="${TARGET:-x86_64-unknown-linux-gnu}"
artifact_name="${ARTIFACT_NAME:-}"
work_dir="${WORK_DIR:-}"
out_dir="${OUT_DIR:-$repo_root/artifacts}"

if [ -z "$upstream_ref" ]; then
    upstream_ref="$(tr -d '[:space:]' < "$repo_root/UPSTREAM_REF")"
fi

arch="${target%%-*}"   # x86_64 or aarch64
if [ -z "$artifact_name" ]; then
    artifact_name="zed-rtl-linux-${arch}.tar.gz"
fi

echo "== Zed-RTL build (Linux) =="
echo "Upstream ref: $upstream_ref"
echo "Target:       $target"

# ---------------------------------------------------------------- toolchain
if ! command -v rustup >/dev/null 2>&1; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain none --profile minimal
    source "$HOME/.cargo/env"
fi
export PATH="$HOME/.cargo/bin:$PATH"

# Match the env upstream's own Linux CI builds with: it compiles C/C++ bits
# with clang, and the build scripts of some crates assume that.
export CC=clang
export CXX=clang++
export CARGO_TERM_COLOR=always
export RUST_BACKTRACE=1

# ---------------------------------------------------------------- source
if [ -z "$work_dir" ]; then
    work_dir="${RUNNER_TEMP:-/tmp}/zed-rtl-build"
fi
src_dir="$work_dir/zed"
mkdir -p "$work_dir"

if [ ! -d "$src_dir/.git" ]; then
    echo "Cloning upstream (blobless)..."
    git clone --filter=blob:none --no-checkout --quiet https://github.com/zed-industries/zed.git "$src_dir"
fi
git -C "$src_dir" fetch --quiet --depth=1 origin "$upstream_ref"
git -C "$src_dir" checkout --force --quiet "$upstream_ref"

# ---------------------------------------------------------------- dependencies
# Install exactly what upstream installs, by running its own setup script.
# Keeping a separate apt list here is how Linux builds silently break when
# upstream adds a new dependency.
echo "Installing build dependencies via upstream script/linux..."
if [ -x "$src_dir/script/linux" ]; then
    ( cd "$src_dir" && ./script/linux )
else
    echo "script/linux missing from upstream; falling back to a static apt list" >&2
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update -qq
        sudo apt-get install -y -qq \
            gcc g++ make cmake clang lld llvm \
            libasound2-dev libfontconfig-dev libgit2-dev libglib2.0-dev \
            libssl-dev libva-dev libvulkan1 libwayland-dev libx11-xcb-dev \
            libxkbcommon-x11-dev libzstd-dev libsqlite3-dev \
            jq git curl gettext-base elfutils build-essential \
            > /dev/null
    fi
fi

# Honor the channel pinned by upstream's rust-toolchain.toml so the build
# works for any UPSTREAM_REF.
channel="1.95.0"
tc_file="$src_dir/rust-toolchain.toml"
if [ -f "$tc_file" ]; then
    found="$(grep -E '^\s*channel\s*=\s*"[^"]+"' "$tc_file" | head -1 | sed -E 's/.*"([^"]+)"/\1/')"
    if [ -n "$found" ]; then channel="$found"; fi
fi
echo "Toolchain from upstream rust-toolchain.toml: $channel"
host_triple="$(rustc -vV | grep '^host:' | awk '{print $2}')"
rustup toolchain install "$channel" --profile minimal
export RUSTUP_TOOLCHAIN="$channel-$host_triple"
if [ "$target" != "$host_triple" ]; then
    rustup target add "$target" --toolchain "$channel-$host_triple"
fi
echo "Rust: $(cargo --version)"

# ---------------------------------------------------------------- patch
echo "Applying patch..."
if ! git -C "$src_dir" apply --check "$patch_path"; then
    echo "PATCH CONFLICT: patch/zed-rtl.patch does not apply to upstream $upstream_ref." >&2
    echo "Refresh the patch at the new ref, then update UPSTREAM_REF." >&2
    exit 1
fi
git -C "$src_dir" apply --verbose "$patch_path"

# ---------------------------------------------------------------- build
echo "Building (release, $target) - this takes a while..."
cd "$src_dir"
cargo build --release --target "$target" -p zed

bin="$src_dir/target/$target/release/zed"
if [ ! -f "$bin" ]; then
    echo "expected build output not found: $bin" >&2
    exit 1
fi
size_mb="$(( $(stat -c%s "$bin") / 1024 / 1024 ))"
echo "Built zed ($size_mb MB)"

# ---------------------------------------------------------------- strip
strip_bin="$(command -v strip || true)"
if [ -n "$strip_bin" ]; then
    "$strip_bin" --strip-debug "$bin" || true
    echo "Stripped debug symbols -> $(( $(stat -c%s "$bin") / 1024 / 1024 )) MB"
fi

# ---------------------------------------------------------------- package
# Layout mirrors upstream's own Linux tarball: <name>/bin/zed, plus the
# installer so a fresh download is usable without cloning this repo.
mkdir -p "$out_dir"
pkg_root="$work_dir/pkg/zed-rtl-linux-$arch"
rm -rf "$pkg_root"
mkdir -p "$pkg_root/bin"
cp "$bin" "$pkg_root/bin/zed"
chmod +x "$pkg_root/bin/zed"
if [ -f "$repo_root/scripts/install-linux.sh" ]; then
    cp "$repo_root/scripts/install-linux.sh" "$pkg_root/install.sh"
    chmod +x "$pkg_root/install.sh"
fi

tar -czf "$out_dir/$artifact_name" -C "$work_dir/pkg" "zed-rtl-linux-$arch"

hash="$(sha256sum "$out_dir/$artifact_name" | awk '{print $1}')"
echo "$hash  $artifact_name" > "$out_dir/$artifact_name.sha256"

cat > "$out_dir/build-info.json" <<EOF
{
  "artifact": "$artifact_name",
  "upstream_ref": "$upstream_ref",
  "built_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "sha256": "$hash",
  "size_bytes": $(stat -c%s "$out_dir/$artifact_name"),
  "toolchain": "$channel-$host_triple",
  "target": "$target"
}
EOF

echo "DONE. Artifact: $out_dir/$artifact_name"
echo "SHA256: $hash"
