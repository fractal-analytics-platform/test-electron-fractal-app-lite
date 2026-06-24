#!/usr/bin/env bash
# Build fractal-server (PyInstaller) and fractal-web (adapter-node) from their repos.
# Populates resources/fractal-server/ and resources/fractal-web/ used by electron-builder.
#
# Usage:
#   bash scripts/build-components.sh                          # build both (versions from build-config.json)
#   bash scripts/build-components.sh --server-only            # rebuild only fractal-server
#   bash scripts/build-components.sh --web-only               # rebuild only fractal-web
#   bash scripts/build-components.sh --server-ref 2.23.7     # override server version
#   bash scripts/build-components.sh --web-ref v1.28.4       # override web version
set -euo pipefail

# ---- Argument parsing ----
SERVER_REF=""
WEB_REF=""
BUILD_SERVER=true
BUILD_WEB=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --server-ref)  SERVER_REF="$2"; shift 2 ;;
    --web-ref)     WEB_REF="$2";    shift 2 ;;
    --server-only) BUILD_WEB=false;    shift ;;
    --web-only)    BUILD_SERVER=false; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$REPO_ROOT/build-config.json"

if ! command -v jq &>/dev/null; then
  echo "Error: jq is required (brew install jq / apt-get install jq)"
  exit 1
fi

[ -z "$SERVER_REF" ] && SERVER_REF=$(jq -r '.fractalServer.ref'  "$CONFIG")
[ -z "$WEB_REF"    ] && WEB_REF=$(jq -r '.fractalWeb.ref'        "$CONFIG")
SERVER_REPO=$(jq -r '.fractalServer.repo' "$CONFIG")
WEB_REPO=$(jq -r '.fractalWeb.repo'       "$CONFIG")

RESOURCES_DIR="$REPO_ROOT/resources"
BUILD_DIR=$(mktemp -d)
trap 'rm -rf "$BUILD_DIR"' EXIT

echo "Building fractal-electron with:"
echo "  fractal-server  $SERVER_REF  ($SERVER_REPO)"
echo "  fractal-web     $WEB_REF  ($WEB_REPO)"
echo ""

# ---- fractal-server → PyInstaller binary ----
if $BUILD_SERVER; then
  echo "==> Cloning fractal-server @ $SERVER_REF ..."
  git clone --depth 1 --branch "$SERVER_REF" "$SERVER_REPO" "$BUILD_DIR/fractal-server"
  cd "$BUILD_DIR/fractal-server"

  # fractal-server entry point: fractalctl = "fractal_server.__main__:run"
  # run() uses argparse; the Electron main process invokes the binary as:
  #   fractal-server start --host 127.0.0.1 --port <PORT>
  cat > _electron_entry.py << 'PYEOF'
import sys
import multiprocessing

if __name__ == '__main__':
    multiprocessing.freeze_support()
    from fractal_server.__main__ import run
    run()
PYEOF

  echo "==> Running PyInstaller ..."
  uv run --with pyinstaller pyinstaller \
    --onedir \
    --name fractal-server \
    --clean \
    --collect-all fractal_server \
    --collect-all uvicorn \
    --collect-all pydantic_settings \
    --collect-all alembic \
    --collect-all sqlalchemy \
    _electron_entry.py

  mkdir -p "$RESOURCES_DIR"
  rm -rf "$RESOURCES_DIR/fractal-server"
  cp -r dist/fractal-server "$RESOURCES_DIR/fractal-server"
  echo "    → resources/fractal-server/"
fi

# ---- fractal-web → SvelteKit adapter-node build ----
if $BUILD_WEB; then
  echo ""
  echo "==> Cloning fractal-web @ $WEB_REF ..."
  git clone --depth 1 --branch "$WEB_REF" "$WEB_REPO" "$BUILD_DIR/fractal-web"
  cd "$BUILD_DIR/fractal-web"

  echo "==> Installing fractal-web dependencies ..."
  npm ci

  echo "==> Building fractal-web ..."
  npm run build

  if [[ ! -f build/index.js ]]; then
    echo "Error: build/index.js not found. Does fractal-web use @sveltejs/adapter-node?"
    exit 1
  fi

  # Prune devDependencies so we only copy what's needed at runtime
  echo "==> Pruning fractal-web dev dependencies ..."
  npm prune --omit=dev

  rm -rf "$RESOURCES_DIR/fractal-web"
  mkdir -p "$RESOURCES_DIR/fractal-web"

  # Copy the adapter-node build output (index.js, handler.js, server/, client/, etc.)
  cp -r build/. "$RESOURCES_DIR/fractal-web/"

  # Copy production node_modules — adapter-node leaves external deps unresolved,
  # so the runtime needs node_modules next to index.js for package resolution.
  cp -r node_modules "$RESOURCES_DIR/fractal-web/node_modules"

  # Copy package.json for ESM resolution (fractal-web declares "type": "module")
  cp package.json "$RESOURCES_DIR/fractal-web/package.json"

  echo "    → resources/fractal-web/"
fi

echo ""
echo "Done. Run 'npm run package' to build the distributable."
