// Runs the actual Electron UI and IPC against disposable fixture files:
// a "Share to SSD" launch arrives before any SSD is connected, then the SSD is connected and the staged items are copied.
const { app, BrowserWindow, dialog } = require('electron');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const assert = require('node:assert/strict');
const base = fs.mkdtempSync(path.resolve('build/smoke-'));
const ssd = path.join(base, 'SSD'); fs.mkdirSync(ssd);
const hero = path.join(ssd, 'file-hero');
const shared = path.join(base, '旅行计划.txt'); fs.writeFileSync(shared, 'Tokyo itinerary');
const later = path.join(base, 'notes.txt'); fs.writeFileSync(later, 'Imported notes');
const album = path.join(base, '相册'); fs.mkdirSync(path.join(album, '第一天'), { recursive: true });
fs.writeFileSync(path.join(album, 'a.txt'), 'a'); fs.writeFileSync(path.join(album, '第一天', 'b.txt'), 'bb');
const extra = path.join(base, 'extra.txt'); fs.writeFileSync(extra, 'extra');
// A short H.264 clip for the video screenshot step (skipped when ffmpeg is not installed).
const clip = path.join(base, '街景.mp4');
const hasClip = require('node:child_process').spawnSync('ffmpeg', ['-loglevel', 'error', '-y', '-f', 'lavfi', '-i', 'testsrc=duration=3:size=320x180:rate=25', '-c:v', 'libx264', '-pix_fmt', 'yuv420p', clip]).status === 0;
process.env.FILE_HERO_DRIVES = 'off';
app.setPath('userData', path.join(base, 'electron-profile'));
dialog.showOpenDialog = async (_window, options) => ({ canceled: false, filePaths: [options.properties.includes('openDirectory') ? ssd : extra] });
dialog.showSaveDialog = async () => ({ canceled: false, filePath: path.join(base, 'exported.txt') });
// What Explorer's "Share to SSD" does: the agent gathers the selection into a list file and launches the app with it.
const spool = path.join(os.tmpdir(), 'file-hero-share'); fs.mkdirSync(spool, { recursive: true });
const listFile = path.join(spool, `list-smoke-${process.pid}.txt`); fs.writeFileSync(listFile, `${shared}\n`);
process.argv.push(`--share-list=${listFile}`);
require('../desktop/main.cjs');
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
app.whenReady().then(async () => {
  try {
    const window = BrowserWindow.getAllWindows()[0];
    await new Promise(resolve => window.webContents.once('did-finish-load', resolve));
    const js = code => window.webContents.executeJavaScript(code).catch(error => { throw new Error(`${error.message} in: ${code}`); });
    const until = async (code, label) => { for (let n = 0; n < 100; n++) { if (await js(code)) return; await delay(100); } throw new Error(`Timed out: ${label}`); };
    const idle = () => until("!document.getElementById('index').disabled || document.getElementById('library').hidden", 'idle');
    const stage = paths => js(`window.fileHero.invoke('stage', '', ${JSON.stringify(JSON.stringify(paths))})`); // what a drop does
    const tray = "document.getElementById('shareFiles').textContent";
    const copied = async label => { await js("document.getElementById('shareSave').click()"); await until("document.getElementById('trayFull').hidden", label); await idle(); };

    assert.equal(await js("window.fileHero.pathFor(new File(['x'], 'x.txt'))"), ''); // in-page Files have no disk path

    await until("!document.getElementById('trayFull').hidden", 'staged share');
    assert.equal(await js("document.getElementById('shareWaiting').hidden"), false);
    assert.equal(await js("document.getElementById('shareSave').disabled"), true);
    assert.match(await js(tray), /旅行计划.txt/);
    assert.equal(fs.existsSync(listFile), false);

    await js("document.getElementById('pickFolder').click()");
    await until("!document.getElementById('shareSave').disabled", 'SSD connected while staged');
    assert.ok(fs.statSync(hero).isDirectory());
    // Connecting puts the AI guide in the file-hero folder (hidden from the list below).
    assert.match(fs.readFileSync(path.join(hero, '给AI的说明.md'), 'utf8'), /Description:/);
    await js("document.getElementById('shareName').value='东京旅行'; document.getElementById('shareDescription').value='行程和票据'");
    await copied('new folder saved');
    assert.match(fs.readFileSync(path.join(hero, '东京旅行', 'file-readme.txt'), 'utf8'), /Description: 行程和票据/);
    assert.equal(fs.readFileSync(path.join(hero, '东京旅行', '旅行计划.txt'), 'utf8'), 'Tokyo itinerary');
    assert.equal(await js("document.getElementById('breadcrumb').textContent"), 'file-hero / 东京旅行');
    assert.equal(await js("document.getElementById('trayEmpty').hidden"), false);

    // Dropped while inside a folder: "current folder" is preselected.
    await stage([later]);
    await until("!document.getElementById('trayFull').hidden", 'dropped file staged');
    assert.equal(await js("document.querySelector('input[name=mode]:checked').value"), 'current');
    assert.equal(await js("document.getElementById('currentName').textContent"), 'file-hero / 东京旅行');
    await js("document.getElementById('shareCurrentDescription').value='后来补充的笔记'");
    await copied('current folder saved');
    let manifest = fs.readFileSync(path.join(hero, '东京旅行', 'file-readme.txt'), 'utf8');
    assert.match(manifest, /File-Count: 2/); assert.match(manifest, /Description: 后来补充的笔记/); assert.match(manifest, /Description: 行程和票据/);

    // Remove one staged item, then copy a dropped folder into an existing folder from the root.
    await js("document.getElementById('up').click()"); await until("document.getElementById('breadcrumb').textContent === 'file-hero'", 'up');
    assert.equal(await js("[...document.querySelectorAll('#files .card strong')].some(s => s.textContent.includes('说明.md'))"), false);
    assert.match(await js("document.querySelector('#files .card').textContent"), /行程和票据/);
    await stage([album, extra]);
    await until(`${tray}.includes('extra.txt') && ${tray}.includes('相册')`, 'two staged');
    assert.match(await js("document.getElementById('shareCount').textContent"), /1 个文件、1 个文件夹（共 3 个文件）/);
    assert.equal(await js("document.getElementById('currentMode').querySelector('input').disabled"), true);
    await js("[...document.querySelectorAll('.tray-item')].find(t => t.textContent.includes('extra.txt')).querySelector('.tray-remove').click()");
    await until(`!${tray}.includes('extra.txt')`, 'unstaged');
    await js("document.querySelector('input[name=mode][value=existing]').click()");
    await until("document.getElementById('shareFolder').options.length === 1", 'existing folders');
    await copied('folder appended');
    assert.equal(fs.readFileSync(path.join(hero, '东京旅行', '相册', '第一天', 'b.txt'), 'utf8'), 'bb');
    assert.ok(fs.existsSync(path.join(hero, '东京旅行', '相册', 'file-readme.txt')));
    assert.equal(fs.existsSync(path.join(hero, '东京旅行', 'extra.txt')), false);

    // The file picker also stages; clearing stores nothing.
    await js("document.getElementById('import').click()");
    await until(`${tray}.includes('extra.txt')`, 'picked file staged');
    await js("document.getElementById('shareClear').click()");
    await until("document.getElementById('trayFull').hidden", 'cleared');

    assert.equal(await js("document.getElementById('breadcrumb').textContent"), 'file-hero / 东京旅行'); // opened after copying
    await js("[...document.querySelectorAll('#files .card')].find(c => c.textContent.includes('notes.txt')).click(); document.getElementById('description').value='重要的项目说明'; document.getElementById('save').click()");
    await delay(300); await idle();
    assert.match(fs.readFileSync(path.join(hero, '东京旅行', 'file-readme.txt'), 'utf8'), /重要的项目说明/);

    // Searching from the root finds file descriptions in subfolders; results can be edited in place.
    await js("document.getElementById('details').hidden = true; document.getElementById('up').click()"); await until("document.getElementById('breadcrumb').textContent === 'file-hero'", 'up for search');
    await js("{ const s = document.getElementById('search'); s.value = '项目说明'; s.dispatchEvent(new Event('input')); }");
    await until("document.querySelectorAll('#files .card').length === 1 && document.querySelector('#files .card').textContent.includes('notes.txt')", 'search result');
    assert.match(await js("document.querySelector('#files .where').textContent"), /位置：file-hero \/ 东京旅行$/);
    await js("document.querySelector('#files .card').click(); document.getElementById('description').value='重要的项目说明，已核对'; document.getElementById('save').click()");
    await delay(300); await idle();
    assert.match(fs.readFileSync(path.join(hero, '东京旅行', 'file-readme.txt'), 'utf8'), /重要的项目说明，已核对/);
    assert.match(await js("document.querySelector('#files .card').textContent"), /已核对/); // still showing results after the save
    await js("{ const s = document.getElementById('search'); s.value = '第一天'; s.dispatchEvent(new Event('input')); }");
    await until("document.querySelector('#files .where')?.textContent.endsWith('东京旅行 / 相册')", 'folder result');
    await js("document.querySelector('#files .card').click()"); await until("document.getElementById('breadcrumb').textContent === 'file-hero / 东京旅行 / 相册 / 第一天'", 'opened result folder');
    assert.equal(await js("document.getElementById('search').value"), '');
    await js("document.getElementById('up').click()"); await until("document.getElementById('breadcrumb').textContent === 'file-hero / 东京旅行 / 相册'", 'up 1'); await idle();
    await js("document.getElementById('up').click()"); await until("document.getElementById('breadcrumb').textContent === 'file-hero / 东京旅行'", 'up 2'); await idle();

    // New folder: typing a name and pressing Enter creates it (the same as clicking 创建).
    await js("document.getElementById('mkdir').click(); document.getElementById('folderName').focus()");
    const enter = async text => { // the typed text must land before Enter, or Enter is lost
      window.webContents.insertText(text); await until(`document.activeElement.value.includes(${JSON.stringify(text)})`, 'typed');
      for (const type of ['keyDown', 'char', 'keyUp']) window.webContents.sendInputEvent({ type, keyCode: type === 'char' ? String.fromCharCode(13) : 'Enter' });
    };
    await enter('收据');
    await until("[...document.querySelectorAll('#files .card strong')].some(s => s.textContent === '收据')", 'folder created with Enter');
    assert.ok(fs.statSync(path.join(hero, '东京旅行', '收据')).isDirectory());
    await js("document.getElementById('mkdir').click(); document.getElementById('folderName').value = '合同'; document.querySelector('#folderDialog button.primary').click()");
    await until("[...document.querySelectorAll('#files .card strong')].some(s => s.textContent === '合同')", 'folder created with button');
    await idle();
    await js("[...document.querySelectorAll('#files .card')].find(c => c.textContent.includes('notes.txt')).click(); document.getElementById('export').click()");
    await delay(300); await idle();
    assert.equal(fs.readFileSync(path.join(base, 'exported.txt'), 'utf8'), 'Imported notes');

    // Rename from the details panel: the extension is not selected, and the description follows the file.
    await js("[...document.querySelectorAll('#files .card')].find(c => c.textContent.includes('notes.txt')).click(); document.getElementById('rename').click()");
    assert.equal(await js("(() => { const i = document.getElementById('renameName'); return i.value.slice(i.selectionStart, i.selectionEnd); })()"), 'notes');
    await enter('会议笔记');
    await until("document.getElementById('detailName').textContent === '会议笔记.txt' && !document.getElementById('details').hidden", 'renamed file reopened');
    await idle();
    assert.ok(fs.existsSync(path.join(hero, '东京旅行', '会议笔记.txt'))); assert.equal(fs.existsSync(path.join(hero, '东京旅行', 'notes.txt')), false);
    assert.match(fs.readFileSync(path.join(hero, '东京旅行', 'file-readme.txt'), 'utf8'), /\[File: 会议笔记\.txt\][^[]*Description: 重要的项目说明，已核对/);
    assert.equal(await js("document.getElementById('description').value"), '重要的项目说明，已核对');
    await js("document.getElementById('rename').click(); document.getElementById('renameName').value = 'notes.txt'; document.querySelector('#renameDialog button.primary').click()");
    await until("document.getElementById('detailName').textContent === 'notes.txt'", 'renamed back'); await idle();
    // Folder cards have their own rename button.
    await js("document.getElementById('details').hidden = true; [...document.querySelectorAll('#files .card')].find(c => c.querySelector('strong').textContent === '合同').querySelector('[title^=重命名文件夹]').click()");
    assert.equal(await js("document.getElementById('renameTitle').textContent"), '重命名文件夹');
    await js("document.getElementById('renameName').value = '合同文件'; document.querySelector('#renameDialog button.primary').click()");
    await until("[...document.querySelectorAll('#files .card strong')].some(s => s.textContent === '合同文件')", 'folder renamed'); await idle();
    assert.ok(fs.statSync(path.join(hero, '东京旅行', '合同文件')).isDirectory());
    await js("[...document.querySelectorAll('#files .card')].find(c => c.textContent.includes('notes.txt')).click()");

    // The details panel closes on a click anywhere outside it, and on Esc.
    const clickAt = async selector => {
      const { x, y } = await js(`(() => { const r = document.querySelector(${JSON.stringify(selector)}).getBoundingClientRect(); return { x: Math.round(r.left + 10), y: Math.round(r.top + r.height / 2) }; })()`);
      for (const type of ['mouseDown', 'mouseUp']) window.webContents.sendInputEvent({ type, x, y, button: 'left', clickCount: 1 });
    };
    assert.equal(await js("document.getElementById('details').hidden"), false);
    await clickAt('#details h2'); await delay(100);
    assert.equal(await js("document.getElementById('details').hidden"), false);
    await clickAt('header h1'); await until("document.getElementById('details').hidden", 'details closed by outside click');
    await js("[...document.querySelectorAll('#files .card')].find(c => c.textContent.includes('notes.txt')).click()");
    for (const type of ['keyDown', 'keyUp']) window.webContents.sendInputEvent({ type, keyCode: 'Escape' });
    await until("document.getElementById('details').hidden", 'details closed by Esc');

    await js("document.getElementById('details').hidden = true; [...document.querySelectorAll('#files .card')].find(c => c.textContent.includes('notes.txt')).querySelector('.danger').click()");
    await until("document.getElementById('confirmDialog').open", 'confirm');
    await js("document.getElementById('confirmDialog').close('ok')");
    await delay(300); await idle();
    assert.equal(fs.existsSync(path.join(hero, '东京旅行', 'notes.txt')), false);
    manifest = fs.readFileSync(path.join(hero, '东京旅行', 'file-readme.txt'), 'utf8');
    assert.match(manifest, /File-Count: 1/);

    // Storing a video makes three 250x250 screenshots in the folder's thumbs folder, listed in file-readme.txt.
    if (hasClip) {
      await stage([clip]);
      await until("!document.getElementById('trayFull').hidden", 'video staged');
      await copied('video saved');
      await until("document.getElementById('status').textContent.includes('已为 1 个视频生成截图')", 'screenshots reported');
      const shots = [1, 2, 3].map(n => path.join(hero, '东京旅行', 'thumbs', `街景.mp4-${n}.jpg`));
      for (const shot of shots) { const jpg = fs.readFileSync(shot); assert.equal(jpg.readUInt16BE(0), 0xffd8); assert.ok(jpg.length > 1000); }
      assert.match(fs.readFileSync(path.join(hero, '东京旅行', 'file-readme.txt'), 'utf8'), /\[File: 街景\.mp4\][^[]*Thumbnails: thumbs\/街景\.mp4-1\.jpg \| thumbs\/街景\.mp4-2\.jpg \| thumbs\/街景\.mp4-3\.jpg/);
      assert.equal(await js("[...document.querySelectorAll('#files .card strong')].some(s => s.textContent === 'thumbs')"), false);
      // 更新说明 leaves finished screenshots alone and remakes a missing one.
      fs.rmSync(shots[1]);
      await js("document.getElementById('index').click()");
      await until("document.getElementById('status').textContent.includes('已为 1 个视频生成截图')", 'missing screenshot remade'); await idle();
      assert.ok(fs.existsSync(shots[1]));
    } else console.log('ffmpeg not found: skipped the video screenshot step');

    await stage([extra, album]);
    await until(`${tray}.includes('extra.txt')`, 'staged for screenshot');
    await delay(500);
    const screenshot = await window.webContents.capturePage(); fs.writeFileSync(path.resolve('build/desktop-preview.png'), screenshot.toPNG());
    console.log('PASS: share before SSD, new folder, drop into current folder, folder into existing folder, unstage, picker, clear, edit, search subfolders, new folder, export, rename, close details, delete, video screenshots; screenshot saved.');
    app.exit(0);
  } catch (error) { console.error(error); app.exit(1); }
});
