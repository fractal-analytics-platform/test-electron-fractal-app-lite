import { app, BrowserWindow, dialog, ipcMain } from 'electron'
import { spawn } from 'child_process'
import type { ChildProcess } from 'child_process'
import * as path from 'path'
import * as net from 'net'
import * as fs from 'fs'

const appStart = Date.now()
const t = (label: string): void => console.log(`[TIMING] ${label}: ${Date.now() - appStart}ms`)

let serverProcess: ChildProcess | null = null
let mainWindow: BrowserWindow | null = null

// ---- Path helpers ----

function getResourcePath(...parts: string[]): string {
  const base = app.isPackaged
    ? process.resourcesPath
    : path.join(__dirname, '../../resources')
  return path.join(base, ...parts)
}

function getAppBinPath(): string {
  const binName = process.platform === 'win32' ? 'fractal-app-lite.exe' : 'fractal-app-lite'
  return getResourcePath('fractal-app-lite', binName)
}

// ---- Port utilities ----

function findFreePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const srv = net.createServer()
    srv.unref()
    srv.on('error', reject)
    srv.listen(0, '127.0.0.1', () => {
      const { port } = srv.address() as net.AddressInfo
      srv.close(() => resolve(port))
    })
  })
}

async function waitForPort(port: number, timeoutMs = 60_000): Promise<void> {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    const ready = await new Promise<boolean>((resolve) => {
      const socket = net.connect({ port, host: '127.0.0.1' })
      socket.once('connect', () => { socket.destroy(); resolve(true) })
      socket.once('error', () => { socket.destroy(); resolve(false) })
      socket.setTimeout(1000, () => { socket.destroy(); resolve(false) })
    })
    if (ready) return
    await new Promise((r) => setTimeout(r, 500))
  }
  throw new Error(`Service on port ${port} did not start within ${timeoutMs}ms`)
}

// ---- Service launcher ----
// fractal-app-lite is a single FastAPI/uvicorn process that serves both
// the REST API (/api/*) and the static SvelteKit frontend from one port.

async function startApp(port: number): Promise<void> {
  const binPath = getAppBinPath()
  serverProcess = spawn(binPath, ['--host', '127.0.0.1', '--port', String(port)], {
    env: { ...process.env },
  })
  t('python spawned')

  serverProcess.stdout?.on('data', (d: Buffer) =>
    console.log('[fractal-app-lite]', d.toString().trimEnd()))
  serverProcess.stderr?.on('data', (d: Buffer) =>
    console.error('[fractal-app-lite]', d.toString().trimEnd()))
  serverProcess.on('exit', (code) => {
    if (code !== 0 && code !== null)
      console.error(`fractal-app-lite exited with code ${code}`)
  })

  await waitForPort(port)
  t('backend ready')
  console.log(`fractal-app-lite ready on :${port}`)
}

// ---- Cleanup ----

function terminateAll(): void {
  if (serverProcess && !serverProcess.killed) {
    serverProcess.kill('SIGTERM')
    const timeout = setTimeout(() => serverProcess?.kill('SIGKILL'), 5_000)
    serverProcess.once('exit', () => clearTimeout(timeout))
  }
}

// ---- Window / bootstrap ----

function getLogoDataURI(): string {
  const logoPath = app.isPackaged
    ? path.join(process.resourcesPath, 'fractal_logo.png')
    : path.join(__dirname, '../../build-resources/fractal_logo.png')
  try {
    return 'data:image/png;base64,' + fs.readFileSync(logoPath).toString('base64')
  } catch {
    return ''
  }
}

function createLoadingHTML(): string {
  return `<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>Fractal Lite</title>
<style>
  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
  html, body { height: 100%; }
  body {
    font-family: system-ui, -apple-system, sans-serif;
    background: #1e1e2e;
    color: #cdd6f4;
    display: flex;
    align-items: center;
    justify-content: center;
  }
  .container { text-align: center; }
  .logo {
    width: 180px;
    height: 180px;
    margin-bottom: 1.8rem;
    animation: pulse 2.4s ease-in-out infinite;
  }
  @keyframes pulse {
    0%, 100% {
      transform: scale(1);
      filter: drop-shadow(0 4px 18px rgba(137, 180, 250, 0.18));
    }
    50% {
      transform: scale(1.10);
      filter: drop-shadow(0 8px 32px rgba(137, 180, 250, 0.42));
    }
  }
  h1 { font-size: 2.2rem; font-weight: 300; letter-spacing: .14em; margin-bottom: .5rem; }
  p  { opacity: .5; font-size: .85rem; letter-spacing: .04em; }
</style>
</head>
<body>
<div class="container">
  <img class="logo" src="${getLogoDataURI()}" alt="Fractal">
  <h1>Fractal Lite</h1>
  <p>Starting services, please wait…</p>
</div>
</body>
</html>`
}

async function bootstrap(): Promise<void> {
  mainWindow = new BrowserWindow({
    width: 1400,
    height: 900,
    show: false,
    title: 'Fractal Lite',
    webPreferences: {
      preload: path.join(__dirname, '../preload/index.js'),
      contextIsolation: true,
      nodeIntegration: false,
    },
  })

  mainWindow.on('page-title-updated', (evt) => evt.preventDefault())

  await mainWindow.loadURL(
    'data:text/html;charset=utf-8,' + encodeURIComponent(createLoadingHTML()),
  )
  mainWindow.show()
  t('loading screen shown')

  try {
    const port = await findFreePort()
    t('port found')
    await startApp(port)
    mainWindow.webContents.once('did-finish-load', () => t('page loaded'))
    t('navigation started')
    await mainWindow.loadURL(`http://127.0.0.1:${port}`)
  } catch (err) {
    terminateAll()
    dialog.showErrorBox('Startup failed', String(err))
    app.quit()
  }
}

// ---- App lifecycle ----

app.whenReady().then(bootstrap)

app.on('window-all-closed', () => {
  terminateAll()
  app.quit()
})

app.on('before-quit', terminateAll)

// Allow the renderer to quit the app cleanly
ipcMain.on('app:quit', () => app.quit())
