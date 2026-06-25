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

if [[ ! -d "$SUBMODULE/src/backend" ]]; then
  echo "Error: submodule not found at $SUBMODULE"
  echo "Run: git submodule update --init --recursive"
  exit 1
fi

# ---- fractal-web-clone — vendored component library ----
# vite.config.js aliases `fractal-components` to fractal-web-clone/components/src/lib/index.js.
# The tag is hardcoded in vite.config.js; update it there if you need a newer version.
if $BUILD_WEB; then
  FRACTAL_WEB_REF=$(grep -o "v[0-9]\+\.[0-9]\+\.[0-9]\+" "$SUBMODULE/src/frontend/vite.config.js" | head -1)
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
# The built static files are bundled into the PyInstaller binary via --add-data
# and served by FastAPI's StaticFiles mount (see backend/main.py).
if $BUILD_WEB; then
  echo "==> Building fractal-lite frontend..."
  cd "$SUBMODULE/src/frontend"
  npm ci
  npm run build
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

  cd "$SUBMODULE"

  # Electron entry point: runs uvicorn with --host/--port CLI args.
  # No pywebview — Electron's BrowserWindow replaces it.
  cat > _electron_entry.py << 'PYEOF'
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

  echo "==> Running PyInstaller..."
  # --paths src  lets PyInstaller find the backend and fractal_lite packages
  # --add-data   bundles the static frontend; backend/main.py resolves it via
  #              Path(__file__).parents[1] / "frontend" / "build" inside _MEIPASS
  uv run --with pyinstaller pyinstaller \
    --onedir \
    --name fractal-app-lite \
    --clean \
    --noconfirm \
    --add-data "src/frontend/build:frontend/build" \
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
    --paths src \
    _electron_entry.py

  rm -f _electron_entry.py

  mkdir -p "$RESOURCES_DIR"
  rm -rf "$RESOURCES_DIR/fractal-app-lite"
  cp -r dist/fractal-app-lite "$RESOURCES_DIR/fractal-app-lite"
  echo "    → resources/fractal-app-lite/"
fi

echo ""
echo "Done. Run 'npm run package' to build the distributable."
