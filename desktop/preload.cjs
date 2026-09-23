const { contextBridge, ipcRenderer } = require('electron');
contextBridge.exposeInMainWorld('fileHero', { invoke: (action, relative, value) => ipcRenderer.invoke('hero', action, relative, value) });
