# How fractal-electron is built and packaged

This document explains the full build and packaging pipeline in plain language —
what each technology is, why it is there, what order things happen in, and why.

---

## 1. What the application is

From a user's point of view: they double-click an icon, a desktop window opens,
and they see a web interface. That is it.

Under the hood, two separate programs are running at the same time:

- A **Python web server** that runs the actual application logic and serves the UI.
- An **Electron shell** that opens the desktop window and points it at that server.

These two programs talk to each other over a private local HTTP connection
(`127.0.0.1:<random port>`). Nothing is exposed to the network.

---

## 2. The technologies and their roles

### Python + FastAPI + uvicorn — the application

`fractal-app-lite` (in `submodules/fractal-app-lite/`) is a Python application.

- **FastAPI** is a Python framework for writing HTTP APIs. You define endpoints
  (e.g. `GET /api/projects`) and the functions that handle them.
- **uvicorn** is the HTTP server that actually listens on a TCP port and
  dispatches incoming requests to FastAPI. When the app starts, uvicorn is what
  opens the port.
- FastAPI also serves the compiled frontend as static files from the same port,
  so the whole application — API and UI — is reachable at a single address.

### SvelteKit — the user interface

The web UI is written in **SvelteKit**, a framework for building web interfaces.
You write components in `.svelte` files (a mix of HTML, CSS, and JavaScript in
one file). At build time, SvelteKit compiles all of those components into plain
HTML, CSS, and JavaScript files that any browser can load. The build mode used
here is `adapter-static`, which means the output is just files — no
server-side rendering, no Node.js needed at runtime. FastAPI serves these files
directly.

The frontend source lives in `submodules/fractal-app-lite/src/frontend/`.
The compiled output lands in `submodules/fractal-app-lite/src/frontend/build/`.

### PyInstaller — making Python self-contained

The Python app depends on many packages (uvicorn, fastapi, polars, ngio, …) and
requires a specific Python version. You cannot expect users to have Python
installed, let alone the right version with the right packages.

**PyInstaller** solves this by analysing the Python source, tracing every import,
and copying everything needed — the Python runtime itself, every package, and
the application code — into a single directory. The result is a standalone
executable that runs on any compatible machine without Python installed.

The PyInstaller output lives in `resources/fractal-app-lite/`. The key files are:

```
resources/fractal-app-lite/
├── fractal-app-lite          ← the executable Electron will launch
└── _internal/                ← Python runtime + all packages
    ├── backend/              ← the FastAPI application code
    ├── fractal_lite/         ← the core Python library
    ├── frontend/
    │   └── build/            ← the compiled SvelteKit files, copied in here
    └── (uvicorn, fastapi, polars, ngio, …)
```

At runtime, FastAPI finds the frontend files by looking at the path relative to
its own `__file__`, which resolves inside `_internal/`. This is why the
SvelteKit build output must be copied *into* the PyInstaller bundle.

### Electron — the desktop window

**Electron** is a framework for turning a web page into a desktop application.
It bundles two things together:

- **Chromium** — a full web browser engine. This is the window the user sees.
- **Node.js** — a JavaScript runtime with full access to the operating system.

Every Electron app has two distinct parts:

**The main process** (`src/main/index.ts`) runs on Node.js. It is the
orchestrator: it spawns the Python process, waits for it to be ready, and tells
the browser window what URL to load. It has full OS access (file system, child
processes, network sockets).

**The renderer process** is a Chromium tab. It displays whatever URL the main
process points it at — in our case, `http://127.0.0.1:<port>`, which is the
SvelteKit app served by the Python backend. The renderer is sandboxed like a
normal browser tab: it cannot access the file system or spawn processes.

**The preload script** (`src/preload/index.ts`) is a thin bridge between the
two. It runs in the renderer but has limited access to Electron APIs. It exposes
exactly one function to the web page: `window.fractalElectron.quit()`, which
sends a message to the main process telling it to shut down cleanly.

### Node.js and npm — the build toolchain

Node.js and npm are used in two ways here:

1. **Building the Electron app**: the Electron main and preload scripts are
   written in TypeScript. `electron-vite` compiles them to JavaScript. `npm` is
   the package manager that installs Electron, TypeScript, and the build tools.

2. **Building the SvelteKit frontend**: SvelteKit is a Node.js tool. `npm ci`
   and `npm run build` inside the submodule's `src/frontend/` directory compile
   the Svelte components into static files.

---

## 3. Runtime architecture

This is what happens when a user launches the app:

```
┌─────────────────────────────────────────────────────────┐
│  Operating system                                       │
│                                                         │
│  ┌──────────────────────────────────────────────────┐  │
│  │  Electron main process  (Node.js)                │  │
│  │  out/main/index.js                               │  │
│  │                                                  │  │
│  │  1. Shows a loading screen immediately           │  │
│  │  2. Asks the OS for a free TCP port              │  │
│  │  3. Spawns the Python process ────────────────┐  │  │
│  │  4. Polls that port until it responds         │  │  │
│  │  5. Tells the browser window to load the URL  │  │  │
│  │  6. On quit: kills the Python process         │  │  │
│  └──────────────────────────────────────────────────┘  │
│                                    │ spawn / kill        │
│                                    ▼                     │
│  ┌──────────────────────────────────────────────────┐  │
│  │  fractal-app-lite  (Python child process)        │  │
│  │  resources/fractal-app-lite/fractal-app-lite     │  │
│  │                                                  │  │
│  │  uvicorn → FastAPI on 127.0.0.1:<port>           │  │
│  │    GET /api/*   → Python handlers                │  │
│  │    GET /*       → static HTML/JS/CSS (Svelte)    │  │
│  └──────────────────────────────────────────────────┘  │
│                         │ HTTP                          │
│              ┌──────────┘                              │
│              ▼                                          │
│  ┌──────────────────────────────────────────────────┐  │
│  │  Renderer process (Chromium tab)                 │  │
│  │  http://127.0.0.1:<port>                         │  │
│  │                                                  │  │
│  │  Displays the SvelteKit web app.                 │  │
│  │  JavaScript calls fetch('/api/...') and          │  │
│  │  the Python backend responds.                    │  │
│  └──────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────┘
```

The port is chosen randomly each launch by asking the OS for a free one. This
avoids any conflict with other software running on the machine. Electron always
passes the chosen port to Python explicitly via `--port <number>`, so the
default value in the Python entry point is never used in normal operation.

---

## 4. The build pipeline

Before the app can be packaged and distributed, three independent build steps
must happen. They must happen in this exact order because each step's output is
an input to the next.

```
Step 1: Build the SvelteKit frontend
        (scripts/build-frontend.sh — npm ci + npm run build inside the submodule)
        Output: submodules/fractal-app-lite/src/frontend/build/
              │
              ▼ (copied into the bundle by PyInstaller)
Step 2: Bundle the Python backend with PyInstaller
        (scripts/build-backend.sh)
        Output: resources/fractal-app-lite/
              │
              ▼ (electron-builder picks up resources/)
Step 3: Compile the Electron TypeScript
        (npm run build = electron-vite build)
        Output: out/main/index.js, out/preload/index.js
              │
              ▼
Step 4: Package everything with electron-builder
        (electron-builder --linux / --mac / --win)
        Output: dist-electron/FractalLite-<version>-<os>-<arch>.<ext>
```

### Step 1 — Build the SvelteKit frontend

The SvelteKit source in `submodules/fractal-app-lite/src/frontend/` is compiled
into plain HTML/CSS/JS files. This is a standard Node.js build:

```bash
cd submodules/fractal-app-lite/src/frontend
npm ci          # install dependencies from package-lock.json
npm run build   # compile .svelte → HTML/JS/CSS
```

The output lands in `src/frontend/build/` and is just static files — no
server-side code, no Node.js needed to serve them.

**The fractal-web-clone complication**

The frontend imports a component library called `fractal-components`. That
library lives in a separate GitHub repository (`fractal-web`) and is not
published to npm. Instead of installing it as a package, the build script
shallow-clones it locally into `fractal-web-clone/` and `vite.config.js` tells
the Vite bundler to resolve the name `fractal-components` to that local clone.

`fractal-web-clone` has no `node_modules` of its own (it is just a code
snapshot, not a fully installed project). Vite 8 changed how it resolves
packages for code reached through such an alias — it now looks for packages like
`svelte` or `ajv` relative to `fractal-web-clone/`, where they do not exist.
The build fails without a workaround.

The fix is `resolve.dedupe` in `vite.config.js`: this tells Vite "for these
specific packages, always use the single copy from the root project's
`node_modules/`, regardless of where the importing code lives." Because
`vite.config.js` belongs to the submodule, we cannot commit this change without
dirtying the submodule. So `build-frontend.sh` applies the patch temporarily
just for the duration of the build, then restores the original file.

### Step 2 — Bundle the Python backend with PyInstaller

PyInstaller analyses `_electron_entry.py` (a custom entry point written by the
build script), traces every import recursively, and copies the entire dependency
tree into `resources/fractal-app-lite/`.

The custom entry point is needed because the original `fractal-app-lite` entry
point (`shell.py`) uses `pywebview` to open a native desktop window. We do not
want that — Electron provides the window. The replacement entry point simply
starts the uvicorn HTTP server and exits when told to.

The compiled SvelteKit files from Step 1 are bundled into the PyInstaller output
via `--add-data`, placing them at `_internal/frontend/build/` inside the bundle.
FastAPI finds them there at runtime using a path relative to its own `__file__`.

All PyInstaller intermediate files (spec file, build cache, dist output) are
written to a temporary directory outside the submodule, so the submodule working
tree is never modified.

### Step 3 — Compile the Electron TypeScript

`src/main/index.ts` and `src/preload/index.ts` are TypeScript files. Electron's
Node.js runtime cannot run TypeScript directly, so they must be compiled to
JavaScript first. `electron-vite build` does this, placing the output in `out/`.

### Step 4 — Package with electron-builder

`electron-builder` assembles the final distributable. It takes:

- The compiled Electron JS from `out/` (the main and preload scripts).
- The Electron runtime itself (Chromium + Node.js) — downloaded automatically.
- `resources/fractal-app-lite/` — the Python bundle from Step 2, copied into
  the app bundle as "extra resources" (accessible at `process.resourcesPath`
  inside the packaged app).

The output depends on the platform:

| Platform | Format   | What it is                               |
|----------|----------|------------------------------------------|
| Linux    | AppImage | A single portable executable file        |
| macOS    | dmg      | A disk image the user mounts to install  |
| Windows  | exe      | An NSIS installer                        |

**The Linux `--no-sandbox` wrapper**

Electron requires the `--no-sandbox` flag to run in certain environments:
containers, systems where the user is root, and some Linux distributions that
restrict the sandboxing kernel features Chromium relies on. Because this flag
cannot be embedded in the binary, `scripts/after-pack.js` runs after
electron-builder finishes packing the Linux build. It renames the real
`FractalLite` binary to `FractalLite.bin` and creates a small shell script
named `FractalLite` in its place that calls `FractalLite.bin --no-sandbox "$@"`.
From the outside, nothing changes — you still run `FractalLite`.

---

## 5. The git submodule

`submodules/fractal-app-lite/` is a **git submodule**: a separate git
repository embedded inside this one. This repo does not store the Python source
itself; it stores only a pointer to a specific commit in the `fractal-app-lite`
repo. Running `git submodule update --init --recursive` checks out that exact
commit into `submodules/fractal-app-lite/`.

`fractal-web-clone/` (inside the submodule) is *not* a submodule. It is a plain
directory created by `build-frontend.sh` and listed in the submodule's
`.gitignore`. If you delete it, the next run of `build-frontend.sh` will
re-clone it.

---

## 6. The CI pipeline

The GitHub Actions workflow (`.github/workflows/build.yml`) runs the full build
on four machines in parallel, one per platform:

| Runner          | Produces                          |
|-----------------|-----------------------------------|
| ubuntu-22.04    | Linux AppImage (x64)              |
| macos-26        | macOS dmg (arm64, Apple Silicon)  |
| macos-15-intel  | macOS dmg (x64, Intel)            |
| windows-2025    | Windows NSIS installer (x64)      |

Each machine runs the exact same sequence of steps:

```
1. Checkout — git clone + submodule init (submodules: recursive)
2. Set version — extract version number from the git tag (e.g. v0.1.5 → 0.1.5)
              and write it into package.json (npm version)
3. Set up Node.js 22
4. Set up Python 3.12  ← needed by the vite.config.js patch (a Python heredoc)
                          and by PyInstaller
5. npm install         ← installs Electron, TypeScript, electron-vite, electron-builder
6. build-components.sh ← wrapper: build-frontend.sh (Step 1) + build-backend.sh (Step 2)
7. npm run build       ← Step 3 (compile TypeScript)
8. electron-builder    ← Step 4 (package)
9. Upload result
```

**Why four separate machines and not cross-compilation?**

PyInstaller bundles the Python runtime for the machine it runs on. A PyInstaller
build on Linux produces a Linux binary; it cannot produce a macOS binary. The
same is true for the Electron runtime bundled by electron-builder. So each
platform requires a real runner of that platform.

**When does it run?**

- **On a tag push** (e.g. `git push --tags` after `npm version patch`): the
  workflow runs and uploads the four distributables to a GitHub Release. This
  is the normal release flow.
- **On manual trigger** (`workflow_dispatch` from the Actions tab): the workflow
  runs but uploads the results as temporary workflow artifacts (kept for 7 days)
  instead of publishing a release. Useful for testing the build without releasing.

---

## 7. From source to running app — the complete picture

```
Source code (git)
│
├── submodules/fractal-app-lite/src/
│   ├── frontend/          ← Svelte components
│   │     │  npm ci + npm run build
│   │     ▼
│   │   frontend/build/    ← plain HTML/JS/CSS  ──────────────────┐
│   │                                                              │ --add-data
│   └── backend/           ← Python / FastAPI                      │
│   └── fractal_lite/      ← Python library                        │
│         │  PyInstaller                                            │
│         ▼                                                         ▼
│   resources/fractal-app-lite/         ← standalone Python bundle
│   ├── fractal-app-lite (executable)     (includes the frontend files)
│   └── _internal/ …
│
├── src/
│   ├── main/index.ts      ← Electron main process (TypeScript)
│   └── preload/index.ts   ← bridge script (TypeScript)
│         │  electron-vite build
│         ▼
│   out/main/index.js
│   out/preload/index.js
│
│  electron-builder
▼
dist-electron/
└── FractalLite-0.1.5-linux-x64.AppImage   (or .dmg / .exe)
    │
    ├── Electron runtime (Chromium + Node.js)
    ├── out/main/index.js + out/preload/index.js
    └── resources/
        ├── fractal_logo.png
        └── fractal-app-lite/   ← the entire Python bundle
```

When a user runs the AppImage / dmg / exe:

1. Electron starts and runs `out/main/index.js`.
2. The main process shows the loading screen.
3. The main process picks a free port and launches `resources/fractal-app-lite/fractal-app-lite --port <N>`.
4. Python starts, uvicorn binds to that port, FastAPI registers its routes, and mounts the static frontend files at `/`.
5. The main process detects the port is open and loads `http://127.0.0.1:<N>` in the browser window.
6. The user sees the SvelteKit UI. Every button click that needs data calls `fetch('/api/...')`, which the Python backend handles.
7. The user closes the window. The main process sends SIGTERM to the Python process (SIGKILL after 5 seconds if it has not exited).
