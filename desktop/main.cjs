const { app, BrowserWindow, ipcMain, dialog } = require('electron');
const { execFile } = require('node:child_process');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
let window, root, busy = false;
const page = pathToFileURL(path.join(__dirname, 'index.html')).href;
function core(command, relative = '', argument) {
  if (!root) throw new Error('请先连接 SSD 文件夹');
  const exe = path.join(app.isPackaged ? process.resourcesPath : path.join(__dirname, '../build'), `file-hero-core${process.platform === 'win32' ? '.exe' : ''}`);
  return new Promise((resolve, reject) => execFile(exe, [command, root, relative, ...(argument === undefined ? [] : [argument])], { windowsHide: true, maxBuffer: 32 * 1024 * 1024, timeout: 0 }, (error, stdout, stderr) => {
    if (error) { try { reject(new Error(JSON.parse(stderr).error)); } catch { reject(new Error(stderr || error.message)); } }
    else { try { resolve(JSON.parse(stdout)); } catch { reject(new Error('文件引擎返回无效结果')); } }
  }));
}
app.whenReady().then(() => {
  window = new BrowserWindow({ width: 1280, height: 850, minWidth: 900, minHeight: 600, backgroundColor: '#f5f7fa', autoHideMenuBar: true, webPreferences: { preload: path.join(__dirname, 'preload.cjs'), contextIsolation: true, nodeIntegration: false, sandbox: true } });
  window.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  window.webContents.on('will-navigate', event => event.preventDefault());
  window.webContents.session.setPermissionRequestHandler((_contents, _permission, callback) => callback(false));
  ipcMain.handle('hero', async (event, action, relative = '', value = '') => {
    if (event.sender !== window.webContents || event.senderFrame !== window.webContents.mainFrame || event.senderFrame.url !== page) throw new Error('Invalid sender');
    if (typeof relative !== 'string' || typeof value !== 'string') throw new Error('Invalid arguments');
    if (busy) throw new Error('文件操作仍在进行');
    busy = true;
    try {
      if (action === 'connect') {
        const result = await dialog.showOpenDialog(window, { title: '选择 portable SSD 或文件夹', properties: ['openDirectory'] });
        if (result.canceled) return null;
        root = result.filePaths[0]; return { root, ...await core('list') };
      }
      if (action === 'import') {
        const result = await dialog.showOpenDialog(window, { title: '导入到 SSD', properties: ['openFile', 'multiSelections'] });
        let imported = 0; const errors = [];
        if (!result.canceled) for (const source of result.filePaths) {
          try { await core('import', relative, source); imported++; } catch (error) { errors.push(`${path.basename(source)}: ${error.message}`); }
        }
        return { imported, errors };
      }
      if (action === 'export') {
        const result = await dialog.showSaveDialog(window, { title: '导出副本（请选择新文件名）', defaultPath: path.basename(relative) });
        return result.canceled ? null : core('export', relative, result.filePath);
      }
      if (['list', 'index', 'mkdir', 'describe'].includes(action)) return await core(action, relative, ['mkdir', 'describe'].includes(action) ? value : undefined);
      throw new Error('Unknown action');
    } finally { busy = false; }
  });
  window.loadFile(path.join(__dirname, 'index.html'));
});
app.on('window-all-closed', () => app.quit());
