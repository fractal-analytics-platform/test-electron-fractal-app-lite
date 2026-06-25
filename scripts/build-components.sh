#!/usr/bin/env bash
# Build fractal-app-lite (PyInstaller onedir) and its SvelteKit static frontend
# from the submodule at submodules/fractal-app-lite/.
# Populates resources/fractal-app-lite/ used by electron-builder.
#
# Usage:
#   bash scripts/build-components.sh                 # build both
#   bash scripts/build-components.sh --server-only   # rebuild only the Python backend
#   bash scripts/build-components.sh --web-only      # rebuild only the frontend
set -euo pipefail

BUILD_SERVER=true
BUILD_WEB=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --server-only) BUILD_WEB=false;    shift ;;
    --web-only)    BUILD_SERVER=false; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUBMODULE="$REPO_ROOT/submodules/fractal-app-lite"
RESOURCES_DIR="$REPO_ROOT/resources"
VITE_CONFIG="$SUBMODULE/src/frontend/vite.config.js"

if [[ ! -d "$SUBMODULE/src/backend" ]]; then
  echo "Error: submodule not found at $SUBMODULE"
  echo "Run: git submodule update --init --recursive"
  exit 1
fi

# ---- fractal-web-clone — vendored component library ----
# vite.config.js aliases `fractal-components` to fractal-web-clone/components/src/lib/index.js.
# The tag is hardcoded in vite.config.js; update it there if you need a newer version.
if $BUILD_WEB; then
  FRACTAL_WEB_REF=$(grep -o "v[0-9]\+\.[0-9]\+\.[0-9]\+" "$VITE_CONFIG" | head -1)
  FRACTAL_WEB_CLONE="$SUBMODULE/fractal-web-clone"
  if [[ ! -d "$FRACTAL_WEB_CLONE" ]]; then
    echo "==> Cloning fractal-web @ $FRACTAL_WEB_REF into submodule (fractal-web-clone)..."
    git clone --depth 1 --branch "$FRACTAL_WEB_REF" \
      https://github.com/fractal-analytics-platform/fractal-web.git \
      "$FRACTAL_WEB_CLONE"
  else
    echo "==> fractal-web-clone already present, skipping clone."
  fi
fi

# ---- Frontend → SvelteKit adapter-static build ----
# fractal-web-clone has no node_modules of its own, so rolldown (vite 8) can't
# resolve its deps. We temporarily patch vite.config.js to add resolve.dedupe,
# then restore the original file so the submodule stays clean.
if $BUILD_WEB; then
  echo "==> Building fractal-lite frontend..."

  # Patch vite.config.js temporarily to add resolve.dedupe (needed for vite 8 /
  # rolldown to resolve fractal-web-clone deps from this project's node_modules).
  # We read the committed version from git so the starting state of the working
  # tree doesn't matter, and restore with `git checkout` afterwards so the
  # submodule is always clean when we're done.
  restore_vite_config() {
    git -C "$SUBMODULE" checkout -- src/frontend/vite.config.js 2>/dev/null || true
  }
  trap restore_vite_config EXIT

  export VITE_CONFIG SUBMODULE
  python3 - << 'PYEOF'
import sys, os, subprocess

path = os.environ['VITE_CONFIG']
submodule = os.environ['SUBMODULE']

# Read the committed (clean) content so we always patch the same baseline.
result = subprocess.run(
    ['git', 'show', 'HEAD:src/frontend/vite.config.js'],
    cwd=submodule, capture_output=True, text=True, check=True
)
original = result.stdout
patched = original.replace(
    "alias: {\n\t\t\t'fractal-components': fractalComponents\n\t\t}\n\t},",
    "alias: {\n\t\t\t'fractal-components': fractalComponents\n\t\t},\n\t\tdedupe: ['ajv', 'ajv-formats', 'slim-select', 'svelte', 'color-hash']\n\t},"
)
if patched == original:
    print('ERROR: vite.config.js patch did not apply — structure may have changed', file=sys.stderr)
    sys.exit(1)
open(path, 'w').write(patched)
PYEOF

  cd "$SUBMODULE/src/frontend"
  npm ci
  npm run build

  restore_vite_config
  trap - EXIT

  echo "    → $SUBMODULE/src/frontend/build/"
fi

# ---- Backend → PyInstaller onedir binary ----
if $BUILD_SERVER; then
  echo ""
  echo "==> Building fractal-app-lite with PyInstaller..."

  FRONTEND_BUILD="$SUBMODULE/src/frontend/build"
  if [[ ! -d "$FRONTEND_BUILD" ]]; then
    echo "Error: frontend build not found at $FRONTEND_BUILD"
    echo "Run without --server-only to build the frontend first."
    exit 1
  fi

  # All PyInstaller outputs (spec, build/, dist/) go to a temp dir outside the
  # submodule. uv.lock and any stray .spec files are cleaned up on exit.

  BUILD_DIR=$(mktemp -d)
  trap 'rm -rf "$BUILD_DIR"; rm -f "$SUBMODULE/uv.lock" "$SUBMODULE"/*.spec' EXIT

  # Write the entry point outside the submodule.
  cat > "$BUILD_DIR/_electron_entry.py" << 'PYEOF'
import sys
import multiprocessing

if __name__ == '__main__':
    multiprocessing.freeze_support()
    import argparse
    import uvicorn
    from backend.main import app

    parser = argparse.ArgumentParser()
    parser.add_argument('--host', default='127.0.0.1')
    parser.add_argument('--port', type=int, default=8765)
    args, _ = parser.parse_known_args()

    uvicorn.run(app, host=args.host, port=args.port, log_level='info')
PYEOF

  # cd into the submodule so uv finds the project and Python path is correct.
  # All PyInstaller paths use absolute references so nothing lands in the submodule.
  cd "$SUBMODULE"

  echo "==> Running PyInstaller..."
  uv run --with pyinstaller pyinstaller \
    --onedir \
    --name fractal-app-lite \
    --clean \
    --noconfirm \
    --specpath "$BUILD_DIR" \
    --workpath "$BUILD_DIR/build" \
    --distpath "$BUILD_DIR/dist" \
    --add-data "$SUBMODULE/src/frontend/build:frontend/build" \
    --collect-all backend \
    --collect-all fractal_lite \
    --collect-all uvicorn \
    --collect-all fastapi \
    --collect-all pydantic \
    --collect-all ngio \
    --collect-all polars \
    --exclude-module webview \
    --exclude-module PyQt6 \
    --exclude-module PyQt5 \
    --paths "$SUBMODULE/src" \
    "$BUILD_DIR/_electron_entry.py"

  mkdir -p "$RESOURCES_DIR"
  rm -rf "$RESOURCES_DIR/fractal-app-lite"
  cp -r "$BUILD_DIR/dist/fractal-app-lite" "$RESOURCES_DIR/fractal-app-lite"
  echo "    → resources/fractal-app-lite/"
fi
# Trap fires here on script exit, cleaning up BUILD_DIR + submodule artifacts.

echo ""
echo "Done. Run 'npm run package' to build the distributable."
