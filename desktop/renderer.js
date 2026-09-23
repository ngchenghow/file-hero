const $ = id => document.getElementById(id);
let folder = '', entries = [], selected = null, connected = false, working = false;
const bytes = n => { if (!n) return '0 B'; const unit = Math.min(4, Math.floor(Math.log(n) / Math.log(1024))); return `${(n / 1024 ** unit).toFixed(unit ? 1 : 0)} ${['B','KB','MB','GB','TB'][unit]}`; };
const relative = name => folder ? `${folder}/${name}` : name;
function status(message) { $('status').textContent = message; }
function controls() { for (const id of ['connect','index','mkdir','import','refresh','save','export']) $(id).disabled = working || (id !== 'connect' && !connected); $('up').disabled = working || !folder; }
async function task(fn) { if (working) return; working = true; controls(); status('正在处理，请勿拔出 SSD…'); try { await fn(); } catch(error) { status(`操作未完成：${error.message}`); } finally { working = false; controls(); } }
async function reload() { const data = await window.fileHero.invoke('list', folder); show(data); }
function show(data) {
  entries = data.entries; selected = null; $('details').hidden = true;
  const files = entries.filter(e => !e.directory && e.name.toLowerCase() !== 'file-readme.txt');
  $('count').textContent = files.length; $('total').textContent = bytes(files.reduce((n,f) => n + f.size, 0));
  $('documented').textContent = files.filter(e => e.metadata.Format).length;
  $('capacity').value = data.capacity ? (data.capacity - data.available) / data.capacity * 100 : 0;
  $('capacityText').textContent = `${bytes(data.available)} 可用 / ${bytes(data.capacity)}`;
  $('breadcrumb').textContent = `我的 SSD${folder ? ' / ' + folder.replaceAll('/', ' / ') : ''}`; render();
}
function render() {
  const query = $('search').value.toLocaleLowerCase(); $('files').replaceChildren();
  const visible = entries.filter(e => e.name.toLocaleLowerCase().includes(query));
  $('empty').hidden = visible.length > 0;
  if (connected) { $('empty').querySelector('h3').textContent = query ? '没有匹配的文件' : '这个文件夹还是空的'; $('empty').querySelector('p').textContent = query ? '试试其他关键词。' : '导入文件，开始建立你的随身文件库。'; }
  for (const entry of visible) {
    const row = document.createElement('tr'); row.tabIndex = 0;
    const name = document.createElement('td'); const icon = document.createElement('span'); icon.className = 'file-icon'; icon.textContent = entry.directory ? '▰' : '▤'; name.append(icon, document.createTextNode(entry.name)); row.append(name);
    for (const text of [entry.directory ? '—' : bytes(entry.size), entry.modified.slice(0,10), entry.directory ? '文件夹' : entry.metadata.Format ? '已建档' : '待建档']) { const cell = document.createElement('td'); cell.textContent = text; row.append(cell); }
    const open = () => { if (working) return; if (entry.directory) task(async () => { const next = relative(entry.name); const data = await window.fileHero.invoke('list',next); folder = next; $('search').value = ''; show(data); status('已打开文件夹'); }); else details(entry); };
    row.addEventListener('click',open); row.addEventListener('keydown',e => { if(e.key === 'Enter') open(); }); $('files').append(row);
  }
}
function details(entry) {
  selected = entry; $('details').hidden = false; $('detailName').textContent = entry.name; $('description').value = entry.metadata.Description || ''; $('facts').replaceChildren();
  for (const [key,value] of [['容量',bytes(entry.size)],['修改日期',entry.modified],['首次建档',entry.metadata['First-Indexed-UTC'] || '尚未建档'],['上一次存入日期',entry.metadata['Last-Stored-UTC'] === 'unknown' ? '未知（导入前的历史不可推断）' : entry.metadata['Last-Stored-UTC'] || '未知']]) { const dt = document.createElement('dt'), dd = document.createElement('dd'); dt.textContent = key; dd.textContent = value; $('facts').append(dt,dd); }
}
$('connect').onclick = () => task(async () => { const data = await window.fileHero.invoke('connect'); if (!data) {status('已取消连接'); return;} connected = true; folder = ''; $('driveName').textContent = data.root.split(/[\\/]/).filter(Boolean).pop() || data.root; $('drivePath').textContent = data.root; $('search').value = ''; show(data); status('已连接。点击「生成 / 更新说明」为已有文件递归建档。'); });
$('search').oninput = render;
$('refresh').onclick = () => task(async () => { await reload(); status('已刷新'); });
$('up').onclick = () => task(async () => { const next = folder.split('/').slice(0,-1).join('/'); const data = await window.fileHero.invoke('list',next); folder = next; $('search').value = ''; show(data); status('已返回上层'); });
$('import').textContent = '↑ 新批次存入';
$('import').onclick = () => { $('batchName').value = `批次-${new Date().toISOString().replace(/[:.]/g,'-').slice(0,19)}`; $('batchDescription').value = ''; $('batchDialog').showModal(); };
$('batchDialog').addEventListener('close',() => { if ($('batchDialog').returnValue === 'import') task(async () => {
  const r = await window.fileHero.invoke('import',folder,JSON.stringify({name: $('batchName').value.trim(), description: $('batchDescription').value.replace(/[\r\n]+/g,' ')}));
  await reload(); status(r ? `已将 ${r.imported} 个文件存入「${r.batch}」，批次说明已保存为 file-readme.txt` : '已取消存入');
}); });
$('index').onclick = () => task(async () => { const r = await window.fileHero.invoke('index',folder); await reload(); status(`已将 ${r.indexed} 个文件的信息更新到各文件夹的 file-readme.txt`); });
$('mkdir').onclick = () => { $('folderName').value = ''; $('folderDialog').showModal(); };
$('folderDialog').addEventListener('close',() => { if ($('folderDialog').returnValue === 'create') task(async () => { await window.fileHero.invoke('mkdir',folder,$('folderName').value.trim()); await reload(); status('文件夹已创建'); }); });
$('close').onclick = () => { $('details').hidden = true; };
$('save').onclick = () => task(async () => { const file = selected; const desc = $('description').value.replace(/[\r\n]+/g,' '); await window.fileHero.invoke('describe',relative(file.name),desc); await reload(); details(entries.find(e => e.name === file.name)); status('说明已保存到 SSD'); });
$('export').onclick = () => task(async () => { const r = await window.fileHero.invoke('export',relative(selected.name)); status(r ? '文件副本已导出（说明仍保留在 SSD）' : '已取消导出'); });
