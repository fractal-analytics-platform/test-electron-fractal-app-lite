#!/usr/bin/env bash
# Builds the two pieces that the Electron app needs at runtime:
#
#   1. The SvelteKit frontend — compiled to plain HTML/JS/CSS files that FastAPI
#      serves statically at http://127.0.0.1:<port>/.
#   2. The Python backend — packaged by PyInstaller into a self-contained
#      directory (fractal-app-lite + all its Python dependencies) so it can run
#      on any machine without Python installed.
#
# Both outputs land in resources/fractal-app-lite/. electron-builder then copies
# that directory into the packaged app bundle. You must run this script at least
# once before `npm run dev` or `npm run package` will work.
#
# Source: submodules/fractal-app-lite/  (a git submodule)
# Output: resources/fractal-app-lite/
#
# Usage:
#   bash scripts/build-components.sh                 # build both
#   bash scripts/build-components.sh --server-only   # rebuild only the Python backend
#   bash scripts/build-components.sh --web-only      # rebuild only the frontend
#
# --server-only saves time when only Python code changed (skips the npm build).
# --web-only saves time when only frontend code changed (skips PyInstaller, which
# can take several minutes).
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

# Absolute path to the repo root (resolved from the location of this script,
# so the script works regardless of which directory you call it from).
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUBMODULE="$REPO_ROOT/submodules/fractal-app-lite"
RESOURCES_DIR="$REPO_ROOT/resources"
# vite.config.js holds the pinned version tag of fractal-web-clone (see below).
VITE_CONFIG="$SUBMODULE/src/frontend/vite.config.js"

# Fail early with a clear message if the submodule was never initialised.
# (A missing src/backend is the most reliable sign — the directory exists even
# when the submodule is present but its contents weren't checked out.)
if [[ ! -d "$SUBMODULE/src/backend" ]]; then
  echo "Error: submodule not found at $SUBMODULE"
  echo "Run: git submodule update --init --recursive"
  exit 1
fi

# ---- fractal-web-clone + Frontend → SvelteKit adapter-static build ----
#
# The SvelteKit frontend imports a component library called fractal-components.
# That library lives in a separate repo (fractal-web on GitHub). Rather than
# publishing it as an npm package, vite.config.js aliases the name
# `fractal-components` directly to the source files inside a local git clone of
# that repo (fractal-web-clone/). Vite's compiler then processes the .svelte
# source files of that library together with our own frontend code.
#
# The pinned version tag is written as a comment in vite.config.js. If you need
# to update the component library, change the tag there and delete
# fractal-web-clone/ so this script re-clones it at the new tag.
if $BUILD_WEB; then
  # Extract the version tag from vite.config.js with a regex (e.g. "v1.27.11").
  FRACTAL_WEB_REF=$(grep -o "v[0-9]\+\.[0-9]\+\.[0-9]\+" "$VITE_CONFIG" | head -1)
  FRACTAL_WEB_CLONE="$SUBMODULE/fractal-web-clone"
  if [[ ! -d "$FRACTAL_WEB_CLONE" ]]; then
    echo "==> Cloning fractal-web @ $FRACTAL_WEB_REF into submodule (fractal-web-clone)..."
    # --depth 1 fetches only the single commit at that tag, not the full history.
    # This is much faster and uses far less disk space.
    git clone --depth 1 --branch "$FRACTAL_WEB_REF" \
      https://github.com/fractal-analytics-platform/fractal-web.git \
      "$FRACTAL_WEB_CLONE"
  else
    echo "==> fractal-web-clone already present, skipping clone."
  fi

  echo "==> Building fractal-lite frontend..."

  # ---- Temporary vite.config.js patch ----
  #
  # Problem: fractal-web-clone is a bare git clone — it has no node_modules of
  # its own. Vite 8 switched its bundler to rolldown, which changed how it
  # resolves packages for code reached through an alias. When rolldown processes
  # a file inside fractal-web-clone (e.g. a .svelte component that imports
  # 'svelte' or 'ajv'), it looks for those packages relative to the
  # fractal-web-clone directory. Because there are no node_modules there, the
  # build fails with "cannot find module".
  #
  # Fix: resolve.dedupe tells rolldown "for these specific packages, always use
  # the single copy in the root project's node_modules, no matter where the
  # importing file lives." This is the minimal working set of packages that
  # fractal-web-clone imports but does not install itself.
  #
  # Why we can't commit this change: vite.config.js lives inside the submodule,
  # so any edit to it would show up as a dirty submodule in git. We don't want
  # to fork the submodule just to work around a Vite version mismatch.
  #
  # The approach:
  #   1. Read the committed (clean) version of vite.config.js from git — NOT
  #      from the working tree. If a previous run crashed before restoring the
  #      file, the working-tree copy would already be patched; applying the patch
  #      again would produce garbage. Reading from git always gives the baseline.
  #   2. Apply the dedupe patch and write it to disk.
  #   3. Run the build.
  #   4. Restore the original file with `git checkout`. The trap below guarantees
  #      this cleanup runs even if npm run build fails, so the submodule is
  #      always left in a clean state.
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
  # `npm ci` installs exactly the versions in package-lock.json and errors if
  # they don't match package.json — stricter and faster than `npm install`.
  npm ci
  npm run build

  # Restore vite.config.js now that the build succeeded, then clear the trap
  # so it doesn't run a second time when the script exits normally.
  restore_vite_config
  trap - EXIT

  echo "    → $SUBMODULE/src/frontend/build/"
fi

# ---- Backend → PyInstaller onedir binary ----
#
# PyInstaller analyses the Python source, traces all imports, and assembles
# a self-contained directory (--onedir) containing:
#   - The fractal-app-lite executable
#   - A full Python runtime
#   - All imported packages (uvicorn, fastapi, pydantic, ngio, polars, …)
#   - The compiled SvelteKit static files (bundled in via --add-data)
#
# The result can run on any compatible OS without Python installed.
# We use --onedir (a directory) rather than --onefile (a single compressed
# binary) because --onefile must unpack itself to a temp directory on every
# launch, which adds noticeable startup delay. --onedir unpacks nothing —
# the files are already on disk.
if $BUILD_SERVER; then
  echo ""
  echo "==> Building fractal-app-lite with PyInstaller..."

  # The frontend build must exist before we run PyInstaller, because PyInstaller
  # copies it into the bundle via --add-data. If only --server-only was passed
  # but no frontend has been built yet, bail out with a clear error.
  FRONTEND_BUILD="$SUBMODULE/src/frontend/build"
  if [[ ! -d "$FRONTEND_BUILD" ]]; then
    echo "Error: frontend build not found at $FRONTEND_BUILD"
    echo "Run without --server-only to build the frontend first."
    exit 1
  fi

  # All PyInstaller outputs (spec file, build cache, dist output) go into a
  # temporary directory outside the submodule, so the submodule working tree
  # is never touched. The trap deletes the temp dir and any stray .spec files
  # that PyInstaller might drop in the submodule root, regardless of whether
  # the build succeeds or fails.
  BUILD_DIR=$(mktemp -d)
  trap 'rm -rf "$BUILD_DIR"; rm -f "$SUBMODULE"/*.spec' EXIT

  # ---- Custom entry point ----
  #
  # The original fractal-app-lite was designed to be launched as a standalone
  # desktop app using pywebview (a native window). Its entry point (shell.py)
  # opens a pywebview window, which we don't want — Electron's BrowserWindow
  # is our window.
  #
  # We write a replacement entry point that simply starts the uvicorn HTTP
  # server on the host/port passed by Electron, with no GUI. This file lives
  # outside the submodule so it doesn't dirty the submodule working tree.
  #
  # multiprocessing.freeze_support() must be the very first call in a frozen
  # (PyInstaller) app on Windows. Without it, spawning a subprocess causes
  # Windows to re-execute the main module for each new process, leading to
  # infinite recursive spawning. On Linux/macOS it is a no-op.
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

  # ---- --add-data argument (cross-platform) ----
  #
  # --add-data tells PyInstaller to copy the compiled SvelteKit files into the
  # bundle at _internal/frontend/build/. FastAPI then serves them at runtime.
  # The format is "source:destination" on Linux/macOS and "source;destination"
  # on Windows.
  #
  # On Windows under Git Bash / MSYS2, there is an extra complication: MSYS2
  # automatically converts POSIX-style paths in arguments passed to Windows
  # executables. The colon separator in "source:dest" collides with drive-letter
  # syntax (C:\...), so MSYS2 mangles it — "/d/a/.../build" becomes
  # "\d\a\...\build" (wrong drive letter) instead of "D:\a\...\build". To avoid
  # this: use cygpath to convert the source path to a native Windows path, and
  # use ";" as the separator so MSYS2 does not touch the argument at all.
  if command -v cygpath >/dev/null 2>&1; then
    _frontend_native="$(cygpath -w "$SUBMODULE/src/frontend/build")"
    _add_data="${_frontend_native};frontend/build"
  else
    _add_data="$SUBMODULE/src/frontend/build:frontend/build"
  fi

  # cd into the submodule so that `pip install .` finds pyproject.toml and
  # installs fractal-app-lite together with all its declared dependencies.
  # All PyInstaller output paths are absolute, so nothing gets written here.
  cd "$SUBMODULE"

  # Create an isolated virtual environment in the temp dir so we don't pollute
  # the system Python. Then install the project and PyInstaller into it.
  # `pip install .` reads pyproject.toml and installs fractal-app-lite plus
  # every package it depends on (uvicorn, fastapi, ngio, polars, …).
  python3 -m venv "$BUILD_DIR/venv"
  if [[ -d "$BUILD_DIR/venv/Scripts" ]]; then
    VENV_PYTHON="$BUILD_DIR/venv/Scripts/python"  # Windows (Git Bash)
  else
    VENV_PYTHON="$BUILD_DIR/venv/bin/python"       # Linux / macOS
  fi
  "$VENV_PYTHON" -m pip install --quiet . pyinstaller

  # On macOS, tell PyInstaller which CPU architecture to target. Without this,
  # if the system Python is a "universal2" binary (supports both arm64 and
  # x86_64), PyInstaller may produce a universal2 bundle that doesn't work
  # correctly on the current machine. uname -m returns "arm64" or "x86_64".
  PYINSTALLER_ARCH_ARGS=()
  if [[ "$(uname -s)" == "Darwin" ]]; then
    PYINSTALLER_ARCH_ARGS=(--target-arch "$(uname -m)")
  fi

  # --collect-all forces PyInstaller to include the entire package directory,
  # not just the files it detects through static import analysis. Some packages
  # (uvicorn, fastapi) load plugins and middleware dynamically at runtime using
  # importlib or entry_points — those dynamic imports are invisible to static
  # analysis and would be silently missing from the bundle without --collect-all.
  #
  # --exclude-module drops packages from the original pywebview-based entry
  # point. They are declared as optional dependencies so PyInstaller's analysis
  # would pull them in; excluding them keeps the bundle smaller.
  #
  # --paths adds submodules/fractal-app-lite/src to the Python path so that
  # "from backend.main import app" in our entry point resolves correctly.
  echo "==> Running PyInstaller..."
  "$VENV_PYTHON" -m PyInstaller \
    --onedir \
    --name fractal-app-lite \
    --clean \
    --noconfirm \
    --specpath "$BUILD_DIR" \
    --workpath "$BUILD_DIR/build" \
    --distpath "$BUILD_DIR/dist" \
    --add-data "$_add_data" \
    --collect-all backend \
    --collect-all fractal_lite \
    --collect-all uvicorn \
    --collect-all websockets \
    --collect-all fastapi \
    --collect-all pydantic \
    --collect-all ngio \
    --collect-all polars \
    --exclude-module webview \
    --exclude-module PyQt6 \
    --exclude-module PyQt5 \
    --paths "$SUBMODULE/src" \
    "${PYINSTALLER_ARCH_ARGS[@]}" \
    "$BUILD_DIR/_electron_entry.py"

  mkdir -p "$RESOURCES_DIR"
  # Remove any previous build before copying so we don't end up with a mix of
  # old and new files if the directory structure changes between builds.
  rm -rf "$RESOURCES_DIR/fractal-app-lite"
  cp -r "$BUILD_DIR/dist/fractal-app-lite" "$RESOURCES_DIR/fractal-app-lite"
  echo "    → resources/fractal-app-lite/"
fi
# The trap fires here on normal exit, deleting BUILD_DIR and any stray .spec files.

echo ""
echo "Done. Run 'npm run package' to build the distributable."
