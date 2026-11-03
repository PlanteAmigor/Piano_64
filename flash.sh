#!/usr/bin/env bash
# Download the complete audio + HDMI + teaching build.
# ./flash.sh        : volatile SRAM configuration
# ./flash.sh -f     : persistent flash configuration
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BITSTREAM="$PROJECT_DIR/impl/pnr/piano64_full.fs"
[[ -f "$BITSTREAM" ]] || { echo "Missing full build: $BITSTREAM"; exit 1; }
python3 "$PROJECT_DIR/tools/check_build.py"
if [[ "${1:-}" == "--check" ]]; then
    sha256sum "$BITSTREAM"
    exit 0
fi
printf 'Complete instrument build: %s\n' "$BITSTREAM"
sha256sum "$BITSTREAM"
openFPGALoader -b tangmega138k "$@" "$BITSTREAM"
