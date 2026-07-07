#!/usr/bin/env bash
# Builds the two pieces that the Electron app needs at runtime, by calling the
# dedicated scripts in order:
#
#   1. scripts/build-frontend.sh — the SvelteKit frontend, compiled to plain
#      HTML/JS/CSS files that FastAPI serves statically.
#   2. scripts/build-backend.sh  — the Python backend, packaged by PyInstaller
#      into a self-contained directory (with the frontend baked in).
#
# Both outputs land in resources/fractal-app-lite/. electron-builder then copies
# that directory into the packaged app bundle. You must run this script at least
# once before `npm run dev` or `npm run package` will work.
#
# To rebuild only one part, run the individual script (or its npm alias
# `npm run build-frontend` / `npm run build-backend`). Note that the backend
# build bakes the frontend into the PyInstaller bundle, so after a frontend
# change both must be rebuilt.
#
# Usage:
#   bash scripts/build-components.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

bash "$SCRIPT_DIR/build-frontend.sh"
echo ""
bash "$SCRIPT_DIR/build-backend.sh"

echo ""
echo "Done. Run 'npm run package' to build the distributable."
