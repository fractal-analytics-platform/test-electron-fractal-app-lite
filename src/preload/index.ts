import { contextBridge, ipcRenderer } from 'electron'

// Expose a minimal API to the fractal-web renderer so it can signal
// the Electron shell without needing nodeIntegration enabled.
contextBridge.exposeInMainWorld('fractalElectron', {
  quit: () => ipcRenderer.send('app:quit'),
})
