#!/bin/bash
# Rebuilds and restarts CineNotch. Extra arguments are passed to the app, e.g. --debug-notch.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build.sh
# SIGTERM lets the running copy put the PiP window back before it exits.
pkill -TERM -f "CineNotch.app/Contents/MacOS/CineNotch" 2>/dev/null && sleep 0.5 || true
open -n build/CineNotch.app --args "$@"
