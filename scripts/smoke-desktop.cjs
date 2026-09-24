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
    await js("[...document.querySelectorAll('#files .card')].find(c => c.textContent.includes('notes.txt')).click(); document.getElementById('export').click()");
    await delay(300); await idle();
    assert.equal(fs.readFileSync(path.join(base, 'exported.txt'), 'utf8'), 'Imported notes');

    await js("document.getElementById('details').hidden = true; [...document.querySelectorAll('#files .card')].find(c => c.textContent.includes('notes.txt')).querySelector('.danger').click()");
    await until("document.getElementById('confirmDialog').open", 'confirm');
    await js("document.getElementById('confirmDialog').close('ok')");
    await delay(300); await idle();
    assert.equal(fs.existsSync(path.join(hero, '东京旅行', 'notes.txt')), false);
    manifest = fs.readFileSync(path.join(hero, '东京旅行', 'file-readme.txt'), 'utf8');
    assert.match(manifest, /File-Count: 1/);

    await stage([extra, album]);
    await until(`${tray}.includes('extra.txt')`, 'staged for screenshot');
    await delay(500);
    const screenshot = await window.webContents.capturePage(); fs.writeFileSync(path.resolve('build/desktop-preview.png'), screenshot.toPNG());
    console.log('PASS: share before SSD, new folder, drop into current folder, folder into existing folder, unstage, picker, clear, edit, search subfolders, export, delete; screenshot saved.');
    app.exit(0);
  } catch (error) { console.error(error); app.exit(1); }
});
