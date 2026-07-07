# Fractal Lite

> **⚠️ WARNING — READ BEFORE USING**
>
> This application is **under active development and entirely provisional**.
> It has been built largely with AI-generated code that has **not been formally reviewed or audited**.
> It is **not considered safe for production use**, may contain bugs, security vulnerabilities, or data loss scenarios.
>
> **Use it entirely at your own risk.**
> No guarantees are made about correctness, stability, or fitness for any purpose.

---

Fractal Lite is a desktop application that packages [fractal-app-lite](https://github.com/fractal-analytics-platform/fractal-server) into a native window using [Electron](https://www.electronjs.org/). It lets you run the Fractal workflow manager locally without a browser or a server setup — just download, install, and open.

The Python backend (FastAPI + uvicorn) and the SvelteKit frontend are bundled as a self-contained binary via PyInstaller. No Python installation is required on the user's machine.

---

## Download and install

Pre-built installers are available on the [Releases](../../releases) page.

| Platform | File |
|---|---|
| macOS (Apple Silicon) | `FractalLite-x.y.z-mac-arm64.dmg` |
| macOS (Intel) | `FractalLite-x.y.z-mac-x64.dmg` |
| Windows | `FractalLite-x.y.z-win-x64.exe` |
| Linux | `FractalLite-x.y.z-linux-x86_64.AppImage` |

### macOS

The app is not notarized. macOS will block it on first launch.  
Go to **System Settings → Privacy & Security → scroll down → "Open Anyway"**.

### Linux

The AppImage must be marked executable before running:

```bash
chmod +x FractalLite-*.AppImage
./FractalLite-*.AppImage
```

### Windows

Run the installer (`.exe`). Windows Defender SmartScreen may warn about an unknown publisher — click "More info → Run anyway".

---

## How it works

When you launch Fractal Lite, Electron starts a Python server (`fractal-app-lite`) in the background, waits for it to be ready, then opens a browser window pointing at it. The entire UI and application logic lives inside the Python/SvelteKit bundle — Electron is only the container.

```
Electron (main process)
  │
  ├─ spawns ──► fractal-app-lite  (Python / uvicorn / FastAPI)
  │                │
  │                ├─ GET /api/*   → Python handlers
  │                └─ GET /*       → static SvelteKit frontend
  │
  └─ opens ───► BrowserWindow → http://127.0.0.1:<random port>
```

The port is chosen randomly at startup, so there are no conflicts with other services.

---

## Building from source

### Prerequisites

- [Node.js](https://nodejs.org/) 22+
- [Python](https://www.python.org/) 3.12+
- Git

### Setup

```bash
# After cloning the repo, pull the Python submodule
git submodule update --init --recursive

# Install Node dependencies
npm install
```

### Build the Python backend and frontend

This step compiles the SvelteKit frontend and packages the Python backend into a self-contained binary using PyInstaller. It only needs to be re-run when the Python code or frontend changes.

```bash
npm run build-components
```

Partial rebuilds (note: the backend build bakes the frontend into the PyInstaller bundle, so after a frontend change you need `build-frontend` **and** `build-backend` for the app to pick it up):

```bash
npm run build-frontend   # rebuild only the SvelteKit frontend (scripts/build-frontend.sh)
npm run build-backend    # rebuild only the Python binary (scripts/build-backend.sh)
```

### Run in development mode

```bash
npm run dev
```

This compiles the TypeScript with hot-reload and launches Electron directly from the source tree. `npm run build-components` must have been run at least once first.

### Build a distributable

```bash
npm run package          # build for the current platform → dist-electron/
npm run full-build       # build-components + package in one step
```

### Other useful commands

```bash
npm run typecheck        # type-check the main process TypeScript (no output = clean)
npm run build            # compile TypeScript only → out/
```

---

## Releasing a new version

```bash
npm version patch        # or: minor, major
git push && git push --tags
```

`npm version` bumps `package.json`, creates a git commit, and creates the version tag (e.g. `v0.2.0`). Pushing the tag triggers the CI workflow, which builds for all platforms and uploads the distributables to a GitHub Release automatically.

To trigger a build without creating a release (useful for testing), run the workflow manually from the **Actions** tab. Artifacts are kept for 7 days.

---

## Notes

- **No database** — fractal-app-lite uses in-memory state and file-based project storage.
- **macOS code-signing** — for public distribution, uncomment the `hardenedRuntime` / `entitlements` lines in `electron-builder.yml` and provide an Apple Developer certificate.
- **macOS notarization** — requires an Apple Developer account and the `CSC_LINK` / `APPLE_ID` environment variables set when running `electron-builder`.
- **`fractal-web-clone`** — the `submodules/fractal-app-lite/fractal-web-clone/` directory is created by `build-components.sh` (not a git submodule). Delete it and re-run the build script to refresh it.

---

## License

See [LICENSE](LICENSE) if present. Otherwise assume no license is granted.
