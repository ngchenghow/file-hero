const { app, BrowserWindow, ipcMain, dialog, shell, nativeImage } = require('electron');
const { execFile, spawn } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
const page = pathToFileURL(path.join(__dirname, 'index.html')).href;
const binaries = app.isPackaged ? process.resourcesPath : path.join(__dirname, '../build');
const binary = name => path.join(binaries, `${name}${process.platform === 'win32' ? '.exe' : ''}`);
// Explorer menu and SSD autostart point at the installed exe, so they are only managed by the packaged Windows app.
const integrated = app.isPackaged && process.platform === 'win32';
let window, root = null, device = null, busy = false, paused = false, wanted = null, polling = false;
let shares = [], shareTimer = null, settings = null;

function core(args, onProgress) {
  return new Promise((resolve, reject) => {
    const child = spawn(binary('file-hero-core'), args, { windowsHide: true });
    let out = '', partial = ''; const errors = [];
    child.stdout.setEncoding('utf8').on('data', data => { out += data; });
    child.stderr.setEncoding('utf8').on('data', data => {
      const lines = (partial + data).split('\n'); partial = lines.pop();
      for (const line of lines.map(l => l.trim()).filter(Boolean)) {
        if (!line.startsWith('@progress ')) { errors.push(line); continue; }
        const [done, total, index, count] = line.slice(10).split(' ').map(Number);
        onProgress?.({ done, total, index, count });
      }
    });
    child.on('error', reject);
    child.on('close', code => {
      const text = [...errors, partial].join('\n').trim();
      if (code) { try { reject(new Error(JSON.parse(text.split('\n').pop()).error)); } catch { reject(new Error(text || `文件引擎异常退出（${code}）`)); } }
      else { try { resolve(JSON.parse(out)); } catch { reject(new Error('文件引擎返回无效结果')); } }
    });
  });
}
function inRoot(command, relative = '', ...rest) {
  if (!root) throw new Error('未检测到 SSD，请插入 SSD 后重试');
  return core([command, root, relative, ...rest]);
}
// Resolves a renderer path strictly inside the connected file-hero folder.
function local(relative) {
  if (!root) throw new Error('未检测到 SSD，请插入 SSD 后重试');
  const parts = relative.split('/').filter(Boolean);
  if (parts.some(part => part === '.' || part === '..' || /[\\:]/.test(part))) throw new Error('路径无效');
  const full = path.join(root, ...parts);
  if (full !== root && !full.startsWith(root + path.sep)) throw new Error('路径无效');
  return full;
}
function send(type, data = {}) { if (window && !window.isDestroyed()) window.webContents.send('hero-event', { type, ...data }); }
function surface() {
  if (!window || window.isDestroyed()) return;
  if (window.isMinimized()) window.restore();
  window.show();
  // Windows blocks focus stealing from background launches (agent, second instance); briefly raising works around it.
  window.setAlwaysOnTop(true); window.focus(); window.setAlwaysOnTop(false);
}

const settingsFile = () => path.join(app.getPath('userData'), 'settings.json');
function loadSettings() {
  try { return { autostart: true, menu: true, lastDrive: null, ...JSON.parse(fs.readFileSync(settingsFile(), 'utf8')) }; }
  catch { return { autostart: true, menu: true, lastDrive: null }; }
}
function saveSettings() { fs.mkdirSync(path.dirname(settingsFile()), { recursive: true }); fs.writeFileSync(settingsFile(), JSON.stringify(settings, null, 2)); }
function integrate() {
  if (!integrated) return Promise.resolve();
  const agent = binary('file-hero-agent');
  return new Promise((resolve, reject) => execFile(agent, ['register', settings.autostart ? '1' : '0', settings.menu ? '1' : '0', process.execPath], { windowsHide: true }, error => {
    if (settings.autostart) spawn(agent, ['--app', process.execPath], { detached: true, stdio: 'ignore', windowsHide: true }).unref();
    else execFile(agent, ['stop'], { windowsHide: true }, () => {});
    if (error) reject(new Error('无法写入 Windows 设置（右键菜单 / 自动启动）')); else resolve();
  }));
}

const sameDrive = (a, b) => !!a && !!b && a[0].toUpperCase() === b[0].toUpperCase();
// FILE_HERO_DRIVES=off keeps automated UI tests away from real SSDs plugged into the test machine.
const drives = () => process.platform === 'win32' && process.env.FILE_HERO_DRIVES !== 'off' ? core(['drives']) : Promise.resolve([]);
async function connect(target) {
  const chosen = path.resolve(target);
  const result = path.basename(chosen).toLowerCase() === 'file-hero' ? { root: chosen } : await core(['setup', chosen]);
  const list = await drives().catch(() => []);
  root = result.root; paused = false; wanted = null;
  // Instructions for an AI that writes video descriptions from the screenshots; the user's own edits are kept.
  try { fs.copyFileSync(path.join(__dirname, 'ai-guide.md'), path.join(root, GUIDE), fs.constants.COPYFILE_EXCL); } catch {}
  device = list.find(d => root.toUpperCase().startsWith(d.drive.toUpperCase())) || { drive: path.parse(root).root, label: '', filesystem: '' };
  if (list.includes(device)) { settings.lastDrive = device.drive; saveSettings(); }
  return connection();
}
const GUIDE = '给AI的说明.md';
const connection = () => ({ root, device });
// Keeps the connection in step with the hardware: drops a removed SSD, connects an inserted one.
async function poll() {
  if (polling || busy) return;
  polling = true;
  try {
    if (root && !fs.existsSync(root)) { root = null; device = null; send('disconnected'); }
    if (root) return;
    const list = await drives().catch(() => []);
    const ready = list.filter(d => d.setup);
    const pick = ready.find(d => sameDrive(d.drive, wanted)) || (paused ? null : ready.find(d => sameDrive(d.drive, settings.lastDrive)) || ready[0]);
    if (pick) send('connected', await connect(pick.drive));
    else send('drives', { drives: list, waitingForShare: shares.length > 0 });
  } catch (error) { send('notice', { message: `连接 SSD 失败：${error.message}` }); }
  finally { polling = false; }
}

// Video screenshots: a hidden window decodes each video that lacks them; the JPEGs go into the video's
// thumbs folder and are listed under Thumbnails in file-readme.txt, where an AI can read them to describe the video.
let capturer = null;
async function captureWindow() {
  if (capturer && !capturer.isDestroyed()) return capturer;
  capturer = new BrowserWindow({ show: false, webPreferences: { contextIsolation: true, nodeIntegration: false, sandbox: true, backgroundThrottling: false } });
  capturer.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  capturer.webContents.on('will-navigate', event => event.preventDefault());
  await capturer.loadFile(path.join(__dirname, 'thumbs.html'));
  return capturer;
}
async function makeThumbs(folder) {
  const videos = await inRoot('videos', folder);
  let made = 0, failed = 0;
  try {
    for (const [index, video] of videos.entries()) {
      send('notice', { message: `正在生成视频截图 ${index + 1} / ${videos.length}：${path.posix.basename(video.path)}（请勿拔出 SSD）` });
      const file = local(video.path), name = path.basename(file);
      const shots = await (await captureWindow()).webContents.executeJavaScript(`capture(${JSON.stringify(pathToFileURL(file).href)})`).catch(() => null);
      if (!Array.isArray(shots) || shots.length !== 3) { failed++; continue; }
      const dir = path.join(path.dirname(file), 'thumbs'); fs.mkdirSync(dir, { recursive: true });
      const names = shots.map((shot, n) => {
        const thumb = `${name}-${n + 1}.jpg`;
        fs.writeFileSync(path.join(dir, thumb), Buffer.from(shot.slice(shot.indexOf(',') + 1), 'base64'));
        return `thumbs/${thumb}`;
      });
      await inRoot('thumbs', video.path, names.join(' | ')); made++;
    }
  } finally { if (capturer && !capturer.isDestroyed()) capturer.destroy(); capturer = null; }
  return { made, failed };
}

// Folder totals for the share dialog; stops counting after 20000 entries so huge folders still open quickly.
function measure(folder) {
  const total = { size: 0, files: 0, partial: false }; const stack = [folder]; let seen = 0;
  while (stack.length) {
    let entries; try { entries = fs.readdirSync(stack.pop(), { withFileTypes: true }); } catch { continue; }
    for (const entry of entries) {
      if (++seen > 20000) { total.partial = true; return total; }
      const full = path.join(entry.parentPath ?? entry.path, entry.name);
      if (entry.isDirectory()) stack.push(full);
      else if (entry.isFile()) { total.files++; try { total.size += fs.statSync(full).size; } catch {} }
    }
  }
  return total;
}
function sharePayload() {
  return shares.map(file => {
    try {
      const stat = fs.statSync(file);
      return stat.isDirectory() ? { path: file, name: path.basename(file), directory: true, ...measure(file) } : { path: file, name: path.basename(file), size: stat.size };
    } catch { return { path: file, name: path.basename(file), size: 0 }; }
  });
}
// Explorer may start one process per selected item; collect them for a moment so they become one batch.
// Drops and the file picker add to the staging area immediately.
function queueShare(files, delay = 600) {
  let skipped = 0;
  for (const file of files) {
    try { const stat = fs.statSync(file); if (!stat.isFile() && !stat.isDirectory()) { skipped++; continue; } } catch { skipped++; continue; }
    if (!shares.some(existing => existing.toLowerCase() === file.toLowerCase())) shares.push(file);
  }
  if (skipped) send('notice', { message: `已略过 ${skipped} 个无法读取的项目` });
  clearTimeout(shareTimer);
  shareTimer = setTimeout(() => { if (shares.length) { send('share', { files: sharePayload() }); if (delay) surface(); } }, delay);
}
function handleArgs(argv, cwd) {
  const files = [];
  for (const arg of argv.slice(app.isPackaged ? 1 : 2)) {
    if (arg.startsWith('--ssd=')) { wanted = `${arg.slice(6, 7).toUpperCase()}:\\`; paused = false; continue; }
    // The agent gathers an Explorer multi-selection into one list file (one path per line).
    if (arg.startsWith('--share-list=')) {
      const list = path.resolve(arg.slice(13));
      try { files.push(...fs.readFileSync(list, 'utf8').split('\n').map(line => line.trim()).filter(Boolean)); } catch {}
      if (path.dirname(list).toLowerCase() === path.join(os.tmpdir(), 'file-hero-share').toLowerCase()) fs.rm(list, { force: true }, () => {});
      continue;
    }
    if (arg.startsWith('-')) continue;
    files.push(path.resolve(cwd, arg));
  }
  if (files.length) queueShare(files);
  if (wanted && root && !sameDrive(device?.drive, wanted)) { root = null; device = null; send('disconnected'); }
  if (wanted) poll().then(surface);
}

if (!app.requestSingleInstanceLock({ argv: process.argv, cwd: process.cwd() })) app.quit();
else {
  app.on('second-instance', (_event, argv, cwd, extra) => { handleArgs(extra?.argv || argv, extra?.cwd || cwd); surface(); });
  app.whenReady().then(() => {
    settings = loadSettings();
    window = new BrowserWindow({ width: 1280, height: 850, minWidth: 900, minHeight: 600, backgroundColor: '#f5f7fa', autoHideMenuBar: true, title: 'File Hero', webPreferences: { preload: path.join(__dirname, 'preload.cjs'), contextIsolation: true, nodeIntegration: false, sandbox: true } });
    window.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
    window.webContents.on('will-navigate', event => event.preventDefault());
    window.webContents.session.setPermissionRequestHandler((_contents, _permission, callback) => callback(false));
    ipcMain.handle('hero', async (event, action, relative = '', value = '') => {
      if (event.sender !== window.webContents || event.senderFrame !== window.webContents.mainFrame || event.senderFrame.url !== page) throw new Error('Invalid sender');
      if (typeof relative !== 'string' || typeof value !== 'string') throw new Error('Invalid arguments');
      // Read-only actions stay available during long copies.
      if (action === 'state') return { ...connection(), shares: sharePayload(), settings: { autostart: settings.autostart, menu: settings.menu, integrated } };
      if (action === 'list') return inRoot('list', relative);
      if (action === 'search') return inRoot('search', relative, value);
      if (action === 'drives') return drives();
      if (action === 'thumb') {
        try { return (await nativeImage.createThumbnailFromPath(local(relative), { width: 192, height: 192 })).toDataURL(); } catch { return null; }
      }
      if (action === 'open') { const error = await shell.openPath(local(relative)); if (error) throw new Error(`无法打开：${error}`); return true; }
      if (action === 'reveal') { shell.showItemInFolder(local(relative)); return true; }
      if (action === 'share-cancel') { shares = []; return true; }
      if (action === 'stage-thumb') {
        if (!shares.includes(relative)) return null;
        try { return (await nativeImage.createThumbnailFromPath(relative, { width: 192, height: 192 })).toDataURL(); } catch { return null; }
      }
      if (busy) throw new Error('文件操作仍在进行');
      busy = true;
      try {
        if (action === 'connect') { const result = await connect(relative); const listing = await inRoot('list'); return { ...result, listing }; }
        if (action === 'disconnect') { root = null; device = null; paused = true; return true; }
        if (action === 'pick-folder') {
          const result = await dialog.showOpenDialog(window, { title: '选择 SSD 或文件夹（将在其中使用 file-hero 文件夹）', properties: ['openDirectory'] });
          if (result.canceled) return null;
          const connected = await connect(result.filePaths[0]); return { ...connected, listing: await inRoot('list') };
        }
        if (action === 'pick-files') {
          const result = await dialog.showOpenDialog(window, { title: '选择要存入 SSD 的文件（可多选；文件夹可在资源管理器右键「Share to SSD」）', properties: ['openFile', 'multiSelections'] });
          if (result.canceled || !result.filePaths.length) return null;
          queueShare(result.filePaths, 0); return true;
        }
        if (action === 'stage') {
          const paths = JSON.parse(value);
          if (!Array.isArray(paths) || paths.some(p => typeof p !== 'string' || !path.isAbsolute(p))) throw new Error('拖入的项目无效');
          queueShare(paths, 0); return true;
        }
        if (action === 'unstage') {
          shares = shares.filter(file => file !== relative); send('share', { files: sharePayload() }); return true;
        }
        if (action === 'settings') {
          const next = JSON.parse(value);
          settings.autostart = !!next.autostart; settings.menu = !!next.menu; saveSettings();
          await integrate(); return true;
        }
        if (action === 'share-save') {
          const form = JSON.parse(value);
          if (!shares.length) throw new Error('没有待存入的文件');
          if (typeof form.name !== 'string' || typeof form.description !== 'string' || typeof form.folder !== 'string') throw new Error('存入信息无效');
          const progress = p => send('progress', p);
          const args = form.mode === 'existing' ? ['append', root, form.folder, form.description, ...shares] : ['batch', root, form.folder, form.name, form.description, ...shares];
          if (!root) throw new Error('未检测到 SSD，请插入 SSD 后重试');
          const result = await core(args, progress);
          shares = [];
          // The files are safely stored; screenshots that cannot be made are only reported.
          try { result.thumbs = await makeThumbs(result.path); } catch (error) { result.thumbs = { made: 0, failed: 0, error: error.message }; }
          return result;
        }
        if (action === 'export' && value === 'directory') {
          const result = await dialog.showOpenDialog(window, { title: `导出文件夹「${path.basename(relative)}」到…（会在所选位置新建同名文件夹）`, properties: ['openDirectory', 'createDirectory'] });
          return result.canceled ? null : await inRoot('export', relative, result.filePaths[0]);
        }
        if (action === 'export') {
          const result = await dialog.showSaveDialog(window, { title: '导出副本（请选择新文件名）', defaultPath: path.basename(relative) });
          return result.canceled ? null : await inRoot('export', relative, result.filePath);
        }
        if (action === 'delete') return await inRoot('delete', relative);
        if (action === 'index') { const result = await inRoot('index', relative); result.thumbs = await makeThumbs(relative); return result; }
        if (['mkdir', 'describe', 'rename'].includes(action)) return await inRoot(action, relative, value);
        throw new Error('Unknown action');
      } finally { busy = false; }
    });
    window.loadFile(path.join(__dirname, 'index.html'));
    window.webContents.once('did-finish-load', () => { handleArgs(process.argv, process.cwd()); poll(); });
    setInterval(poll, 3000);
    integrate().catch(error => send('notice', { message: error.message }));
  });
  app.on('window-all-closed', () => app.quit());
}
