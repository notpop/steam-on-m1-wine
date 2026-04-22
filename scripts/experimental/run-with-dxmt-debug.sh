#!/usr/bin/env bash
#
# run-with-dxmt-debug.sh — Launch Steam with DXMT verbose logging so a
# crashed or transparent game leaves behind per-process log files in
# /tmp/dxmt-logs/.
#
# DXMT reads two environment variables (source: strings on d3d11.dll):
#   DXMT_LOG_LEVEL     0=silent, 3=debug (highest available in v0.74)
#   DXMT_LOG_PATH      directory; the DLL creates `<ProcessName>_<subsystem>.log`
#
# When MonsterFarm.exe (or any game) is launched from Steam, the
# envvars propagate through wineserver into the game process, so both
# Steam's own CEF subsystem and the game appear in the same log dir.

# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
require_wine_installed
require_prefix_initialised

LOG_DIR="${DXMT_LOG_PATH:-/tmp/dxmt-logs}"
LEVEL="${DXMT_LOG_LEVEL:-3}"
mkdir -p "$LOG_DIR"
# Start each run clean so we do not re-read old output.
rm -f "$LOG_DIR"/*.log

log_step "Launching Steam with DXMT_LOG_LEVEL=$LEVEL DXMT_LOG_PATH=$LOG_DIR"

export DXMT_LOG_LEVEL="$LEVEL"
export DXMT_LOG_PATH="$LOG_DIR"

exec "$REPO_ROOT/scripts/launch-steam.sh" --detach
