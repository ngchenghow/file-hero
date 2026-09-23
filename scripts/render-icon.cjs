const { app, BrowserWindow } = require('electron');
const fs = require('node:fs');
const path = require('node:path');
app.whenReady().then(async () => {
  try {
    const window = new BrowserWindow({width:512,height:512,show:false,frame:false,webPreferences:{backgroundThrottling:false,sandbox:true}});
    const svg = fs.readFileSync(path.join(__dirname,'../mobile/branding/file-hero-icon.svg'),'utf8');
    await window.loadURL('data:text/html;charset=utf-8,' + encodeURIComponent('<style>html,body{margin:0;width:512px;height:512px;background:white}svg{display:block}</style>'+svg));
    await window.webContents.executeJavaScript('new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))');
    fs.mkdirSync(path.join(__dirname,'../build'),{recursive:true});
    fs.writeFileSync(path.join(__dirname,'../build/file-hero-icon.png'),(await window.webContents.capturePage()).toPNG());
    app.exit(0);
  } catch(error) { console.error(error); app.exit(1); }
});
