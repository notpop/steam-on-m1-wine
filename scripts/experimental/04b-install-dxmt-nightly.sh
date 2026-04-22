#!/usr/bin/env bash
#
# 04b-install-dxmt-nightly.sh — Replace the pinned DXMT v0.74 install
# with the latest successful nightly build from 3Shain/dxmt's GitHub
# Actions.
#
# Why this exists
# ---------------
# v0.74 (the tag that scripts/04-install-dxmt.sh pins) cannot paint
# Unity 6000 titles on macOS Tahoe 26.x: Present() succeeds but the
# on-screen CAMetalLayer stays transparent. Master has a handful of
# commits after v0.74 (notably 40fae03 "set present rect for d3dkmt"
# and 719d247 "defatalize IDXGISwapChain1/2/3 stubs") that may
# influence the path. This script fetches whatever master's latest
# green artifact is so we can test without re-building locally.
#
# How
# ---
# 1. `gh run list` → pick newest successful `CI Build` run on master
# 2. `gh api .../artifacts` → find the `dxmt-<sha>` tarball artifact
# 3. curl the zip, unzip, untar
# 4. Place DLLs / .so into the same spots as scripts/04-install-dxmt.sh
# 5. Keep the v0.74 copy in vendor/dxmt-v074-backup/ for instant
#    roll-back via scripts/experimental/04b-revert-to-dxmt-v0.74.sh
#
# Requirements
# ------------
# - gh CLI authenticated (`gh auth status`)
# - Wine already installed via scripts/01-install-wine.sh
# - DXMT v0.74 already installed via scripts/04-install-dxmt.sh (so
#   the backup of stock DLLs exists before we overwrite them)

# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
require_wine_installed
require_prefix_initialised
require_cmd gh
require_cmd curl
require_cmd unzip

BACKUP_DIR="$REPO_ROOT/vendor/dxmt-v074-backup"
WINE_LIB_UNIX="$WINE_APP/Contents/Resources/wine/lib/wine/x86_64-unix"
WINE_LIB_WIN64="$WINE_APP/Contents/Resources/wine/lib/wine/x86_64-windows"
WINE_LIB_WIN32="$WINE_APP/Contents/Resources/wine/lib/wine/i386-windows"
PREFIX_SYS32="$WINEPREFIX/drive_c/windows/system32"
PREFIX_SYSWOW64="$WINEPREFIX/drive_c/windows/syswow64"

log_step "Installing DXMT nightly (master)"

# -- Step 1: take a backup of the current (v0.74) placement so we can
#    roll back.
if [[ ! -d "$BACKUP_DIR" ]]; then
    mkdir -p "$BACKUP_DIR/x86_64-windows" "$BACKUP_DIR/i386-windows"
    cp -p "$WINE_LIB_UNIX/winemetal.so"          "$BACKUP_DIR/"
    for dll in winemetal.dll d3d11.dll dxgi.dll d3d10core.dll; do
        cp -p "$WINE_LIB_WIN64/$dll" "$BACKUP_DIR/x86_64-windows/"
        cp -p "$WINE_LIB_WIN32/$dll" "$BACKUP_DIR/i386-windows/"
    done
    log_ok "v0.74 baseline snapshot saved to $BACKUP_DIR"
else
    log_ok "Existing v0.74 backup found at $BACKUP_DIR (kept untouched)"
fi

# -- Step 2: resolve the newest successful master run.
log_info "Querying DXMT CI for the newest master artifact"
RUN_ID=$(gh run list --repo 3Shain/dxmt --limit 20 --json status,conclusion,headBranch,databaseId,workflowName \
    | python3 -c '
import json, sys
runs = json.load(sys.stdin)
for r in runs:
    if (r.get("status") == "completed"
            and r.get("conclusion") == "success"
            and r.get("headBranch") == "main"
            and r.get("workflowName") == "CI Build"):
        print(r["databaseId"])
        break
')
[[ -n "$RUN_ID" ]] || die "Could not find a recent successful master CI run"
log_ok "Newest CI run: $RUN_ID"

# -- Step 3: find the `dxmt-<sha>` artifact (not the per-arch builds).
ARTIFACT_JSON=$(gh api "repos/3Shain/dxmt/actions/runs/${RUN_ID}/artifacts")
read -r ARTIFACT_ID ARTIFACT_NAME <<< "$(
    printf '%s' "$ARTIFACT_JSON" \
    | python3 -c '
import json, sys
d = json.load(sys.stdin)
for a in d.get("artifacts", []):
    name = a.get("name", "")
    if name.startswith("dxmt-") and "-windows-cross" not in name and "-macos" not in name:
        print(a["id"], name)
        break
'
)"
[[ -n "$ARTIFACT_ID" ]] || die "Could not find the main dxmt-<sha> artifact in run $RUN_ID"
log_ok "Artifact: $ARTIFACT_NAME (id=$ARTIFACT_ID)"

# -- Step 4: download + unzip + untar into vendor/.
NIGHTLY_DIR="$REPO_ROOT/vendor/${ARTIFACT_NAME}"
mkdir -p "$NIGHTLY_DIR"
ZIP_PATH="$NIGHTLY_DIR/artifact.zip"
if [[ ! -f "$ZIP_PATH" ]]; then
    curl -fL -sS \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer $(gh auth token)" \
        -o "$ZIP_PATH" \
        "https://api.github.com/repos/3Shain/dxmt/actions/artifacts/${ARTIFACT_ID}/zip"
fi

EXTRACT_DIR="$NIGHTLY_DIR/extracted"
rm -rf "$EXTRACT_DIR"
mkdir -p "$EXTRACT_DIR"
unzip -o -q "$ZIP_PATH" -d "$NIGHTLY_DIR"
TARBALL=$(find "$NIGHTLY_DIR" -maxdepth 1 -name "${ARTIFACT_NAME}.tar.gz" | head -n1)
[[ -f "$TARBALL" ]] || die "Tarball missing after unzip"
tar -xzf "$TARBALL" -C "$EXTRACT_DIR"

# The tarball contains a single top-level directory named after the SHA.
SRC_DIR=$(find "$EXTRACT_DIR" -mindepth 1 -maxdepth 1 -type d | head -n1)
[[ -d "$SRC_DIR/x86_64-unix" ]] || die "Layout mismatch: $SRC_DIR"

# -- Step 5: place everything where 04-install-dxmt.sh expected.
install_file() {
    local src=$1 dst=$2
    cp "$src" "$dst"
    log_ok "$(basename "$src") -> $dst"
}
install_file "$SRC_DIR/x86_64-unix/winemetal.so" "$WINE_LIB_UNIX/winemetal.so"
for dll in winemetal.dll d3d11.dll dxgi.dll d3d10core.dll; do
    install_file "$SRC_DIR/x86_64-windows/$dll" "$WINE_LIB_WIN64/$dll"
    install_file "$SRC_DIR/i386-windows/$dll"   "$WINE_LIB_WIN32/$dll"
done
install_file "$SRC_DIR/x86_64-windows/winemetal.dll" "$PREFIX_SYS32/winemetal.dll"
install_file "$SRC_DIR/i386-windows/winemetal.dll"  "$PREFIX_SYSWOW64/winemetal.dll"

log_ok "DXMT nightly installed. Artifact: $ARTIFACT_NAME"
log_info "Roll back any time with scripts/experimental/04b-revert-to-dxmt-v0.74.sh"
