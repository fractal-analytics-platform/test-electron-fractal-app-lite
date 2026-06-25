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

## Download

Pre-built installers are available on the [Releases](../../releases) page.

| Platform | File |
|---|---|
| macOS (Apple Silicon) | `FractalLite-x.y.z-mac-arm64.dmg` |
| macOS (Intel) | `FractalLite-x.y.z-mac-x64.dmg` |
| Windows | `FractalLite-x.y.z-win-x64.exe` |
| Linux | `FractalLite-x.y.z-linux-x86_64.AppImage` |

### macOS note

The app is not notarized. macOS will block it on first launch. To open it:  
**System Settings → Privacy & Security → scroll down → "Open Anyway"**.

### Linux note

The AppImage must be marked as executable before running:
```bash
chmod +x FractalLite-*.AppImage
./FractalLite-*.AppImage
```

## Building from source

### Prerequisites

- [Node.js](https://nodejs.org/) 20+
- [pixi](https://pixi.sh/)
- Git

### Steps

```bash
# 1. Pull submodules
git submodule update --init --recursive

# 2. Install Node dependencies
npm install

# 3. Build the Python backend and SvelteKit frontend
npm run build-components

# 4. Launch in development mode
npm run dev

# — or — build a distributable
npm run package
```

## Architecture

Electron spawns the `fractal-app-lite` binary as a child process, waits for its HTTP server to be ready, then points a `BrowserWindow` at it. The entire application UI and logic lives inside the Python/SvelteKit bundle; Electron is only the container.

## License

See [LICENSE](LICENSE) if present. Otherwise assume no license is granted.
