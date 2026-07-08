# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

---

## What this project is

**fractal-electron** is a desktop application built with [Electron](https://www.electronjs.org/). It wraps a Python web application — **fractal-app-lite** — inside a native window, making it feel like a regular desktop app even though the UI is a web page.

The Python application is a git submodule at `submodules/fractal-app-lite/`. Before the app can be distributed (or run in dev mode), a build step packages that Python code into a self-contained binary using PyInstaller, and places it under `resources/`.

---

## How Electron works — the essentials

Electron bundles **Chromium** (a web browser) and **Node.js** into a single runtime. Every Electron app has two distinct parts that run in separate OS processes:

### 1. The main process (`src/main/index.ts`)

This is a **Node.js** program. It is the orchestrator of the whole application. It:
- Is the entry point — Electron starts here.
- Creates and controls native windows (`BrowserWindow`).
- Has full access to the operating system: it can spawn child processes, read/write files, listen on sockets, etc.
- Runs TypeScript compiled to `out/main/index.js` by electron-vite.

There is exactly **one** main process per app.

### 2. The renderer process (the browser window)

Each `BrowserWindow` runs a **Chromium tab** — a full browser environment (HTML, CSS, JavaScript). This is what the user sees and interacts with. In our case the renderer simply displays the web app served by the Python backend; it does not contain any custom HTML/JS of our own (beyond the loading screen).

Because the renderer is a browser tab, it is **sandboxed**: by default it cannot access Node.js APIs or the file system. This is a deliberate security boundary.

### 3. The preload script (`src/preload/index.ts`)

The preload script runs in the renderer process but has access to a restricted set of Electron APIs. It is the **bridge** between the sandboxed web page and the main process. Our preload exposes one function to the web page:

```ts
contextBridge.exposeInMainWorld('fractalElectron', {
  quit: () => ipcRenderer.send('app:quit'),
})
```

This gives the web page a `window.fractalElectron.quit()` function that sends an IPC message to the main process, which then calls `app.quit()`. Without this, the web page would have no way to close the application.

**IPC** (Inter-Process Communication) is how the main process and renderer processes talk to each other. The main process listens with `ipcMain.on(...)`, the renderer sends with `ipcRenderer.send(...)` (exposed via the preload).

---

## What fractal-app-lite is

`fractal-app-lite` is a Python application that runs a **FastAPI** web server (via **uvicorn**). It serves two things from a single HTTP port:

- **`/api/*`** — REST API endpoints implemented in Python (job management, datasets, workflows, etc.)
- **`/`** — A static SvelteKit web application (HTML/CSS/JS files)

The web app in the browser calls the API, and the Python backend processes those calls. Because both the API and the frontend are on the same origin (same host and port), there are no CORS complications.

The Python source is organized as:
```
submodules/fractal-app-lite/src/
├── backend/        FastAPI application (routes, state, job runner, etc.)
├── fractal_lite/   Python library with the core domain logic
└── frontend/       SvelteKit app (adapter-static — compiles to plain HTML/JS/CSS)
```

The frontend imports a component library (`fractal-components`) from a separate repo, `fractal-web-clone`, which the build script clones locally.

---

## How Electron and fractal-app-lite fit together

```
┌─────────────────────────────────────────────────────────┐
│  OS                                                     │
│                                                         │
│  ┌──────────────────────────────────────────────────┐  │
│  │  Electron main process  (Node.js)                │  │
│  │  src/main/index.ts                               │  │
│  │                                                  │  │
│  │  1. spawns child process ─────────────────────┐  │  │
│  │  2. waits for port to open                    │  │  │
│  │  3. tells BrowserWindow to load the URL       │  │  │
│  │  4. on quit: kills child process              │  │  │
│  └──────────────────────────────────────────────────┘  │
│             │ spawn                    ↑ kill           │
│             ▼                                           │
│  ┌──────────────────────────────────────────────────┐  │
│  │  fractal-app-lite  (Python child process)        │  │
│  │  resources/fractal-app-lite/fractal-app-lite     │  │
│  │                                                  │  │
│  │  uvicorn serving FastAPI on 127.0.0.1:<port>     │  │
│  │    GET /api/*   → Python handlers                │  │
│  │    GET /*       → static HTML/JS/CSS             │  │
│  └──────────────────────────────────────────────────┘  │
│                        │ HTTP                           │
│             ┌──────────┘                               │
│             ▼                                           │
│  ┌──────────────────────────────────────────────────┐  │
│  │  Renderer process (Chromium tab)                 │  │
│  │  BrowserWindow → http://127.0.0.1:<port>         │  │
│  │                                                  │  │
│  │  The SvelteKit web app runs here.                │  │
│  │  It makes fetch() calls to /api/* and the        │  │
│  │  Python backend responds.                        │  │
│  └──────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────┘
```

The key insight: **Electron is just the container**. The main process starts the Python server and points the browser window at it. The actual application — its UI and its logic — is entirely inside `fractal-app-lite`.

---

## Startup sequence in detail (`src/main/index.ts`)

When the user launches the app, here is what happens step by step:

**Step 1 — Show loading screen immediately**

Before anything else, a `BrowserWindow` is created and a loading page is rendered. The loading page is a self-contained HTML string baked directly into `index.ts` as a `data:` URI — it shows the Fractal logo with a pulsing animation and the text "Starting services, please wait…". This appears instantly while the Python process starts in the background.

**Step 2 — Find a free port**

`findFreePort()` asks the OS to assign a free TCP port by opening a socket on port 0 (which the OS resolves to an available port), records the number, then closes the socket. This avoids hardcoding a port number that might already be in use.

**Step 3 — Spawn the Python process**

`startApp(port)` calls Node.js's `child_process.spawn()` to launch:
```
resources/fractal-app-lite/fractal-app-lite --port <port>
```
The server always binds to 127.0.0.1 (hardcoded in the entry point) so it is never reachable from the network. This is a regular OS child process. Its stdout and stderr are piped to the Electron console. The process runs uvicorn, which starts the FastAPI application.

**Step 4 — Wait for the server to be ready**

`waitForPort(port)` polls by repeatedly trying to open a TCP connection to `127.0.0.1:<port>`. It retries every 500 ms for up to 60 seconds. Once a connection succeeds, the server is ready.

**Step 5 — Navigate the window to the app**

`mainWindow.loadURL('http://127.0.0.1:<port>')` replaces the loading screen with the real application. From this point on, the user is interacting with the SvelteKit web app served by FastAPI.

**Step 6 — Shutdown**

When the window is closed (or `app.quit()` is called via IPC), `terminateAll()` sends SIGTERM to the Python process. If the process has not exited after 5 seconds, it sends SIGKILL to force-quit it.

---

## File and folder structure

```
fractal-electron/
│
├── src/
│   ├── main/index.ts          Main process: spawns Python, manages window lifecycle
│   └── preload/index.ts       Bridge: exposes window.fractalElectron.quit() to the web page
│
├── submodules/
│   └── fractal-app-lite/      Git submodule — the Python application source
│       └── src/
│           ├── backend/       FastAPI app (routes, state, job runner)
│           ├── fractal_lite/  Core Python library
│           └── frontend/      SvelteKit app (builds to static files)
│
├── resources/                 GITIGNORED — populated by build-backend.sh
│   └── fractal-app-lite/
│       ├── fractal-app-lite   The executable (fractal-app-lite.exe on Windows)
│       └── _internal/         PyInstaller bundle: Python runtime + all packages + static frontend
│           ├── backend/
│           ├── fractal_lite/
│           ├── frontend/build/    ← static SvelteKit output, served by FastAPI at /
│           └── (uvicorn, fastapi, pydantic, ngio, polars, …)
│
├── build-resources/
│   └── fractal_logo.png       App icon used in the loading screen and packaged app
│
├── scripts/
│   ├── build-frontend.sh      Builds the SvelteKit frontend from the submodule
│   ├── build-backend.sh       Builds the PyInstaller binary (frontend baked in)
│   ├── build-components.sh    Thin wrapper: runs build-frontend.sh then build-backend.sh
│   └── after-pack.js          Post-packaging hook: wraps the Linux binary with --no-sandbox
│
├── out/                       GITIGNORED — compiled TypeScript output (electron-vite)
├── dist-electron/             GITIGNORED — final distributable (AppImage / dmg / exe)
│
├── electron-builder.yml       Packaging config: targets, extra resources, app metadata
├── package.json               npm scripts and dev dependencies (Electron, TypeScript, vite)
└── .gitignore
```

---

## Build pipeline

Getting from source to a runnable app requires two independent build steps.

### Step 1 — Build the Python + frontend bundle (`npm run build-components`)

This runs `scripts/build-components.sh`, a thin wrapper that calls `scripts/build-frontend.sh` (steps 1a–1b) and then `scripts/build-backend.sh` (step 1c). Each part can also be run on its own via `npm run build-frontend` / `npm run build-backend` — but note that the backend build bakes the frontend into the PyInstaller bundle, so a frontend change requires both.

**1a. Clone `fractal-web-clone`** (skipped if already present)

The SvelteKit frontend imports a component library called `fractal-components`. That library lives in a separate GitHub repo (`fractal-analytics-platform/fractal-web`). The build script reads the pinned version tag from `vite.config.js` and shallow-clones it into `submodules/fractal-app-lite/fractal-web-clone/`. The vite config then aliases `fractal-components` to the source files in that clone.

**1b. Build the frontend**

Runs `npm ci && npm run build` inside `submodules/fractal-app-lite/src/frontend/`. SvelteKit with `adapter-static` compiles the Svelte components into plain HTML, JavaScript, and CSS files in `src/frontend/build/`. These are static files — no server-side rendering, no Node.js needed at runtime.

Because `fractal-web-clone` has no `node_modules` of its own, vite 8's bundler (rolldown) cannot resolve its dependencies at build time. The script temporarily patches `vite.config.js` to add `resolve.dedupe` — forcing those packages to resolve from the frontend's own `node_modules`. It reads the committed file content directly from git, writes the patched version, runs the build, then restores the original with `git checkout`. The submodule working tree is clean before and after.

**1c. Build the PyInstaller binary**

Creates a temporary directory outside the submodule and writes `_electron_entry.py` there:
```python
# Starts uvicorn on loopback, with the port from the --port CLI arg.
# This replaces the original shell.py which used pywebview (a native window).
# In our case, Electron's BrowserWindow takes that role.
uvicorn.run(app, host='127.0.0.1', port=args.port, log_level='info')
```

Then runs PyInstaller in `--onedir` mode, which produces a directory (not a single file) containing the executable and all its dependencies. All PyInstaller outputs (spec file, build tree, dist tree) are redirected to that temp directory via `--specpath`, `--workpath`, and `--distpath` — nothing lands in the submodule. The key flag is:
```
--add-data "<absolute-path>/src/frontend/build:frontend/build"
```
This copies the compiled SvelteKit static files into the bundle at `_internal/frontend/build/`. FastAPI's `backend/main.py` finds them at runtime using:
```python
_FRONTEND_BUILD = Path(__file__).resolve().parents[1] / "frontend" / "build"
```
Inside the PyInstaller bundle, `__file__` for any module resolves inside `_internal/`, so `parents[1]` is `_internal/` and the path resolves correctly.

The output is copied to `resources/fractal-app-lite/`. The temp directory and any stray `.spec` files are removed by a shell trap on script exit, leaving the submodule clean.

### Step 2 — Build the Electron app (`npm run build` + `npm run package`)

`npm run build` compiles `src/main/index.ts` and `src/preload/index.ts` from TypeScript to JavaScript, placing the output in `out/` (handled by electron-vite).

`npm run package` calls `electron-builder`, which:
1. Takes the compiled JS from `out/`.
2. Copies `resources/fractal-app-lite/` into the app bundle as "extra resources" (configured in `electron-builder.yml`). These end up at `process.resourcesPath` inside the packaged app.
3. Packages everything into a platform-specific distributable in `dist-electron/`: an AppImage on Linux, a dmg on macOS, an NSIS installer on Windows.

`npm run full-build` runs both steps in sequence.

---

## Dev mode (`npm run dev`)

`npm run dev` compiles the TypeScript with hot-reload and launches Electron directly from the source tree. The main process reads `resources/fractal-app-lite/` from the project root (not from `process.resourcesPath`). This means **`resources/` must be populated first** by running `npm run build-components` at least once before `npm run dev` works.

`getResourcePath()` in `src/main/index.ts` handles the two cases:
```ts
const base = app.isPackaged
  ? process.resourcesPath          // packaged app: inside the bundle
  : path.join(__dirname, '../../resources')  // dev: project root/resources/
```

---

## Commands reference

See `README.md` for the full commands reference. Key commands for development:

```bash
npm install                          # install Electron/TypeScript toolchain
git submodule update --init --recursive  # populate submodules/fractal-app-lite/
npm run build-components             # build Python binary + frontend
npm run build-frontend               # build only the SvelteKit frontend
npm run build-backend                # build only the PyInstaller binary (needs frontend build)
npm run dev                          # launch Electron with hot-reload
npm run typecheck                    # type-check TypeScript (no output = clean)
npm run full-build                   # build-components + build + package
npm version patch && git push && git push --tags  # release
```

---

## Notes

- **No database**: fractal-app-lite uses in-memory state and file-based project storage. There is no PostgreSQL or any other database.
- **Port is random**: a free port is chosen at startup. Do not hardcode any port number.
- **`fractal-web-clone` in the submodule**: the `fractal-web-clone/` directory inside `submodules/fractal-app-lite/` is not itself a submodule — it is a plain directory created by `build-frontend.sh`. It is gitignored inside the submodule. If you delete it, the next `build-frontend.sh` run will re-clone it.
- **macOS code-signing**: PyInstaller binaries on macOS 13+ require the `com.apple.security.cs.allow-unsigned-executable-memory` entitlement. Uncomment and configure the `hardenedRuntime` / `entitlements` lines in `electron-builder.yml` when targeting macOS distribution.
- **macOS notarization**: for public distribution you need an Apple Developer certificate and the `CSC_LINK` / `APPLE_ID` env vars set when running `electron-builder`.
- **Linux `--no-sandbox`**: the `scripts/after-pack.js` hook wraps the Linux Electron binary in a shell script that passes `--no-sandbox`, which is required when running as root or in certain container environments.
