#!/usr/bin/env bash
# Reproducible complete build; refuse to mark a timing-failed/stale result ready.
set -euo pipefail
TASK_PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$TASK_PROJECT_DIR"
TASK_GOWIN_SH="${GOWIN_SH:-/mnt/project/ov-cli/Gowin/IDE/bin/gw_sh}"
if [[ ! -x "$TASK_GOWIN_SH" ]]; then TASK_GOWIN_SH="$(command -v gw_sh)"; fi
mkdir -p work/cache
python3 tools/check_build.py --capture work/build_inputs.json
QT_QPA_PLATFORM=offscreen XDG_CACHE_HOME="$TASK_PROJECT_DIR/work/cache" "$TASK_GOWIN_SH" build_full.tcl 2>&1 | tee work/build_full.log
python3 tools/check_build.py --record --inputs work/build_inputs.json
