#!/usr/bin/env bash
# Builds the SvelteKit frontend of fractal-app-lite — compiled to plain
# HTML/JS/CSS files that FastAPI serves statically at http://127.0.0.1:<port>/.
#
# Source: submodules/fractal-app-lite/src/frontend/
# Output: submodules/fractal-app-lite/src/frontend/build/
#
# The output stays inside the submodule (gitignored there). It is consumed by
# scripts/build-backend.sh, which copies it into the PyInstaller bundle via
# --add-data. Run this script before build-backend.sh.
#
# Usage:
#   bash scripts/build-frontend.sh
set -euo pipefail

# Absolute path to the repo root (resolved from the location of this script,
# so the script works regardless of which directory you call it from).
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUBMODULE="$REPO_ROOT/submodules/fractal-app-lite"
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
