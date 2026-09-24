const { contextBridge, ipcRenderer, webUtils } = require('electron');
contextBridge.exposeInMainWorld('fileHero', {
  invoke: (action, relative, value) => ipcRenderer.invoke('hero', action, relative, value),
  on: listener => ipcRenderer.on('hero-event', (_event, data) => listener(data)),
  // Dropped File objects carry no path in the page; Electron resolves them here. Pass one File per call:
  // a File inside a FileList or array is copied across the context bridge and loses its path.
  pathFor: file => webUtils.getPathForFile(file),
});
