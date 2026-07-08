import { contextBridge, ipcRenderer } from 'electron'

// Expose a minimal API to the web app in the renderer so it can signal
// the Electron shell without needing nodeIntegration enabled.
contextBridge.exposeInMainWorld('fractalElectron', {
  quit: () => ipcRenderer.send('app:quit'),
})
