// Runs the actual Electron UI and IPC against disposable fixture files.
const { app, BrowserWindow, dialog } = require('electron');
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const base = fs.mkdtempSync(path.resolve('build/smoke-'));
const root = path.join(base, 'SSD'); fs.mkdirSync(root);
fs.mkdirSync(path.join(root,'Photos'));
fs.writeFileSync(path.join(root,'旅行计划.txt'),'Tokyo itinerary');
const imported = path.join(base, 'notes.txt'); fs.writeFileSync(imported,'Imported notes');
app.setPath('userData', path.join(base, 'electron-profile'));
dialog.showOpenDialog = async (_window, options) => ({canceled:false,filePaths:[options.properties.includes('openDirectory') ? root : imported]});
dialog.showSaveDialog = async () => ({canceled:false,filePath:path.join(base,'exported.txt')});
require('../desktop/main.cjs');
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
app.whenReady().then(async () => {
  try {
    const window = BrowserWindow.getAllWindows()[0];
    await new Promise(resolve => window.webContents.once('did-finish-load', resolve));
    const js = code => window.webContents.executeJavaScript(code);
    const click = async id => {
      await js(`document.getElementById('${id}').click()`);
      for(let n=0;n<100;n++) { await delay(100); if(await js("!document.getElementById('connect').disabled")) return; }
      throw new Error(`Timed out: ${id}`);
    };
    await click('connect'); assert.equal(await js("document.querySelectorAll('#files tr').length"),2);
    await click('index'); assert.equal(await js("document.getElementById('documented').textContent"),'1');
    await js("document.getElementById('import').click(); document.getElementById('batchName').value='项目资料批次'; document.getElementById('batchDescription').value='本次项目的笔记'; document.getElementById('batchDialog').close('import');");
    for(let n=0;n<100;n++) { await delay(100); if(await js("!document.getElementById('connect').disabled")) break; }
    assert.equal(await js("document.querySelectorAll('#files tr').length"),4);
    assert.match(fs.readFileSync(path.join(root,'项目资料批次','file-readme.txt'),'utf8'),/本次项目的笔记/);
    await js("[...document.querySelectorAll('#files tr')].find(row=>row.textContent.includes('项目资料批次')).click()");
    for(let n=0;n<100;n++) { await delay(100); if(await js("!document.getElementById('connect').disabled")) break; }
    await js("[...document.querySelectorAll('#files tr')].find(row=>row.textContent.includes('notes.txt')).click(); document.getElementById('description').value='重要的项目说明';");
    await click('save'); assert.match(fs.readFileSync(path.join(root,'项目资料批次','file-readme.txt'),'utf8'),/重要的项目说明/);
    assert.equal(fs.readdirSync(path.join(root,'项目资料批次')).length,2);
    await click('export'); assert.equal(fs.readFileSync(path.join(base,'exported.txt'),'utf8'),'Imported notes');
    const screenshot = await window.webContents.capturePage(); fs.writeFileSync(path.resolve('build/desktop-preview.png'),screenshot.toPNG());
    console.log('PASS: Electron connect, index, import, edit description, export; screenshot saved.');
    app.exit(0);
  } catch(error) { console.error(error); app.exit(1); }
});
