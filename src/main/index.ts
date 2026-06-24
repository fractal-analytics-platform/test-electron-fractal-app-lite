import { app, BrowserWindow, dialog, ipcMain, utilityProcess } from 'electron'
import type { UtilityProcess } from 'electron'
import { spawn } from 'child_process'
import type { ChildProcess } from 'child_process'
import * as path from 'path'
import * as net from 'net'
import * as fs from 'fs'
import * as crypto from 'crypto'

let serverProcess: ChildProcess | null = null
let webProcess: UtilityProcess | null = null
let mainWindow: BrowserWindow | null = null

// ---- Path helpers ----

function getResourcePath(...parts: string[]): string {
  const base = app.isPackaged
    ? process.resourcesPath
    : path.join(__dirname, '../../resources')
  return path.join(base, ...parts)
}

function getServerBinPath(): string {
  const binName = process.platform === 'win32' ? 'fractal-server.exe' : 'fractal-server'
  return getResourcePath('fractal-server', binName)
}

// ---- Persistent data directory ----
// fractal-server reads .fractal_server.env from its cwd via pydantic-settings.
// We use userData so data persists across app launches.

const DEFAULT_ENV = `JWT_EXPIRE_SECONDS=100000
FRACTAL_RUNNER_BACKEND=local
POSTGRES_DB=fractal_test
POSTGRES_USER=postgres
POSTGRES_PASSWORD=postgres
FRACTAL_DEFAULT_GROUP_NAME=All
FRACTAL_ENABLE_TASK_GROUP_RESET=true
`

function ensureEnvFile(dataDir: string): void {
  const envFile = path.join(dataDir, '.fractal_server.env')
  if (!fs.existsSync(envFile)) {
    const jwtSecret = crypto.randomBytes(32).toString('hex')
    fs.mkdirSync(dataDir, { recursive: true })
    fs.writeFileSync(envFile, `JWT_SECRET_KEY=${jwtSecret}\n${DEFAULT_ENV}`)
    console.log(`Created ${envFile}`)
  }
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

// ---- One-shot command runner (for set-db / init-db-data) ----

function runCommand(binPath: string, args: string[], cwd: string): Promise<void> {
  return new Promise((resolve, reject) => {
    const proc = spawn(binPath, args, { cwd, env: { ...process.env } })
    proc.stdout?.on('data', (d: Buffer) =>
      console.log(`[fractal-server ${args[0]}]`, d.toString().trimEnd()))
    proc.stderr?.on('data', (d: Buffer) =>
      console.error(`[fractal-server ${args[0]}]`, d.toString().trimEnd()))
    proc.on('error', reject)
    proc.on('exit', (code) => {
      if (code === 0 || code === null) resolve()
      else reject(new Error(`fractal-server ${args[0]} exited with code ${code}`))
    })
  })
}

// ---- DB initialization (first launch only) ----

async function initDatabaseIfNeeded(dataDir: string): Promise<void> {
  const marker = path.join(dataDir, '.db-initialized')
  if (fs.existsSync(marker)) return

  console.log('First launch: initializing database…')
  const binPath = getServerBinPath()
  const projectDir = path.join(dataDir, 'projects')
  fs.mkdirSync(projectDir, { recursive: true })

  await runCommand(binPath, ['set-db'], dataDir)
  await runCommand(binPath, [
    'init-db-data',
    '--admin-email', 'admin@fractal.xy',
    '--admin-pwd', '1234',
    '--admin-project-dir', projectDir,
    '--resource', 'default',
    '--profile', 'default',
  ], dataDir)

  fs.writeFileSync(marker, '')
  console.log('Database initialized.')
}

// ---- Service launchers ----

async function startFractalServer(port: number): Promise<void> {
  const dataDir = app.getPath('userData')
  ensureEnvFile(dataDir)
  await initDatabaseIfNeeded(dataDir)

  const binPath = getServerBinPath()
  serverProcess = spawn(binPath, ['start', '--host', '127.0.0.1', '--port', String(port)], {
    cwd: dataDir, // pydantic-settings reads .fractal_server.env from cwd
    env: { ...process.env },
  })

  serverProcess.stdout?.on('data', (d: Buffer) =>
    console.log('[fractal-server]', d.toString().trimEnd()))
  serverProcess.stderr?.on('data', (d: Buffer) =>
    console.error('[fractal-server]', d.toString().trimEnd()))
  serverProcess.on('exit', (code) => {
    if (code !== 0 && code !== null)
      console.error(`fractal-server exited with code ${code}`)
  })

  await waitForPort(port)
  console.log(`fractal-server ready on :${port}`)
}

async function startFractalWeb(port: number, serverPort: number): Promise<void> {
  // SvelteKit adapter-node build produces a standalone Node.js server at build/index.js.
  // utilityProcess.fork() runs the script using Electron's bundled Node.js,
  // so no separate Node.js installation is required in the packaged app.
  const scriptPath = getResourcePath('fractal-web', 'index.js')
  const dataDir = app.getPath('userData')

  webProcess = utilityProcess.fork(scriptPath, [], {
    stdio: 'pipe',
    env: {
      ...process.env,
      HOST: '127.0.0.1',
      PORT: String(port),
      ORIGIN: `http://127.0.0.1:${port}`,
      FRACTAL_SERVER_HOST: `http://127.0.0.1:${serverPort}`,
      FRACTAL_RUNNER_BACKEND: 'local',
      FRACTAL_DEFAULT_GROUP_NAME: 'All',
      AUTH_COOKIE_NAME: 'fastapiusersauth',
      AUTH_COOKIE_SECURE: 'false', // http-only, no TLS
      AUTH_COOKIE_DOMAIN: '127.0.0.1',
      AUTH_COOKIE_PATH: '/',
      AUTH_COOKIE_SAME_SITE: 'lax',
      LOG_LEVEL_CONSOLE: 'warn',
      LOG_LEVEL_FILE: 'info',
      LOG_FILE: path.join(dataDir, 'fractal-web.log'),
    },
  })

  webProcess.stdout?.on('data', (d: Buffer) =>
    console.log('[fractal-web]', d.toString().trimEnd()))
  webProcess.stderr?.on('data', (d: Buffer) =>
    console.error('[fractal-web]', d.toString().trimEnd()))

  // Fail immediately if the process exits before the port is ready
  // (e.g. missing env var causes exit(2) in environment-variables.js)
  const earlyExit = new Promise<never>((_, reject) => {
    webProcess!.once('exit', (code) =>
      reject(new Error(`fractal-web exited with code ${code} before becoming ready`)))
  })

  await Promise.race([waitForPort(port), earlyExit])
  console.log(`fractal-web ready on :${port}`)
}

// ---- Cleanup ----

function terminateAll(): void {
  if (serverProcess && !serverProcess.killed) {
    serverProcess.kill('SIGTERM')
    const timeout = setTimeout(() => serverProcess?.kill('SIGKILL'), 5_000)
    serverProcess.once('exit', () => clearTimeout(timeout))
  }
  webProcess?.kill()
}

// ---- Window / bootstrap ----

function createLoadingHTML(): string {
  return `<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>Fractal</title>
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
  h1 { font-size: 2.5rem; font-weight: 300; letter-spacing: .12em; margin-bottom: .6rem; }
  p  { opacity: .55; font-size: .9rem; }
</style>
</head>
<body>
<div style="text-align:center">
  <h1>Fractal</h1>
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
    title: 'Fractal',
    webPreferences: {
      preload: path.join(__dirname, '../preload/index.js'),
      contextIsolation: true,
      nodeIntegration: false,
    },
  })

  await mainWindow.loadURL(
    'data:text/html;charset=utf-8,' + encodeURIComponent(createLoadingHTML()),
  )
  mainWindow.show()

  try {
    const serverPort = await findFreePort()
    const webPort = await findFreePort()
    await startFractalServer(serverPort)
    await startFractalWeb(webPort, serverPort)
    await mainWindow.loadURL(`http://127.0.0.1:${webPort}`)
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

// Allow fractal-web (running in the BrowserWindow) to quit the app cleanly
ipcMain.on('app:quit', () => app.quit())
