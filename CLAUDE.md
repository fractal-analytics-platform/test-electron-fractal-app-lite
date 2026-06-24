# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

An Electron shell that:
1. Spawns a **fractal-server** process (FastAPI/Python, packaged with PyInstaller)
2. Spawns a **fractal-web** process (SvelteKit with adapter-node) using Electron's bundled Node.js
3. Opens a BrowserWindow pointing to `http://127.0.0.1:<web-port>`

This repo contains only the Electron wrapper. fractal-server and fractal-web are external projects cloned and built by `scripts/build-components.sh`.

## Commands

```bash
npm install                    # install Electron/TypeScript toolchain
npm run typecheck              # type-check main process TypeScript
npm run build                  # compile TypeScript → out/ (electron-vite)
npm run dev                    # run Electron with hot-reload (requires resources/ to be populated first)

npm run build-components       # clone & build fractal-server + fractal-web into resources/
npm run package                # compile + package with electron-builder → dist-electron/
npm run full-build             # build-components + package in one step
```

Override component versions at build time:
```bash
bash scripts/build-components.sh --server-ref 2.23.7 --web-ref v1.28.4
```

Pass a custom PostgreSQL database name at launch (defaults to `fractal_app`):
```bash
./dist-electron/Fractal-1.0.0.AppImage --db=my_db_name
# dev mode:
npm run dev -- -- --db=my_db_name
```
The app creates the database via `createdb` if it does not exist. The marker file that gates first-launch DB init is named `.db-initialized-<dbName>` (in `userData`), so each distinct DB name gets its own independent initialization.

## Architecture

```
src/
├── main/index.ts      # Electron main process — service lifecycle, BrowserWindow
└── preload/index.ts   # Exposes window.fractalElectron.quit() to the renderer

resources/             # Build artifacts (gitignored, populated by build-components.sh)
├── fractal-server/    # PyInstaller --onedir output; executable is resources/fractal-server/fractal-server
└── fractal-web/       # adapter-node build; entry point is resources/fractal-web/index.js

scripts/
└── build-components.sh   # Clones repos at pinned refs, runs PyInstaller + npm build

build-config.json          # Default fractal-server and fractal-web versions (repo + git ref)
electron-builder.yml       # Packaging config; extraResources copies resources/ into the app bundle
```

### Startup sequence (`src/main/index.ts`)

1. Show loading screen (inline data-URI HTML) while services start
2. `findFreePort()` × 2 — pick random available ports
3. `startFractalServer(port)` — spawn PyInstaller binary, wait for TCP port to accept connections
4. `startFractalWeb(webPort, serverPort)` — `utilityProcess.fork()` the SvelteKit server
5. Navigate `mainWindow` to `http://127.0.0.1:<webPort>`
6. On `window-all-closed` / `before-quit` — SIGTERM both processes (SIGKILL fractal-server after 5 s)

### Resource paths

`getResourcePath(...parts)` returns:
- **dev**: `<project-root>/resources/...`
- **packaged**: `process.resourcesPath/...`

## TODOs before first working build

1. **fractal-server data directory**: `app.getPath('userData')` is used as the cwd for all fractal-server commands so pydantic-settings can find `.fractal_server.env` there. On first launch the app writes the env file (with a generated `JWT_SECRET_KEY`), runs `set-db`, and runs `init-db-data`. A `.db-initialized-<dbName>` marker file prevents re-running. Edit `buildEnvContent()` in `src/main/index.ts` to change default server settings.

3. **fractal-web env vars** (`src/main/index.ts` → `startFractalWeb`): all required env vars are set inline. `FRACTAL_SERVER_HOST` points to the fractal-server port. `AUTH_COOKIE_SECURE=false` because the app runs over plain http on localhost.

4. **fractal-web adapter-node**: fractal-web must use `@sveltejs/adapter-node` so its build produces a standalone Node.js server (`build/index.js`). If it currently uses `adapter-auto` or `adapter-static`, switch the adapter before building.

5. **macOS code-signing**: PyInstaller binaries on macOS 13+ require the `com.apple.security.cs.allow-unsigned-executable-memory` entitlement. Uncomment and configure the `hardenedRuntime` / `entitlements` lines in `electron-builder.yml` when targeting macOS distribution.

6. **macOS notarization**: for public distribution you'll need an Apple Developer certificate and `CSC_LINK` / `APPLE_ID` env vars set when running `electron-builder`.
