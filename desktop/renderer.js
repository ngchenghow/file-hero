const $ = id => document.getElementById(id);
const hero = window.fileHero;
let folder = '', entries = [], selected = null, connected = false, working = false, sharing = null, saving = false;
const thumbs = new Map();
const bytes = n => { n = Number(n) || 0; if (!n) return '0 B'; const unit = Math.min(4, Math.floor(Math.log(n) / Math.log(1024))); return `${(n / 1024 ** unit).toFixed(unit ? 1 : 0)} ${['B','KB','MB','GB','TB'][unit]}`; };
const relative = name => folder ? `${folder}/${name}` : name;
const isReadme = name => name.toLowerCase() === 'file-readme.txt';
const previewable = name => /\.(jpe?g|png|gif|webp|bmp|heic|heif|mp4|mov|m4v|3gp|mkv|webm|avi|pdf)$/i.test(name);
const day = text => (text || 'unknown').split('T')[0];
function status(message) { $('status').textContent = message; }
function controls() {
  for (const id of ['index','mkdir','import','refresh','save','open','reveal','export','delete']) $(id).disabled = working || !connected;
  $('switchDrive').disabled = working || !connected; $('up').disabled = working || !folder;
}
async function task(fn, doing = '正在处理，请勿拔出 SSD…') {
  if (working) return; working = true; controls(); status(doing);
  try { await fn(); } catch (error) { status(`操作未完成：${error.message}`); } finally { working = false; controls(); }
}

function showDrive(state) {
  const device = state.device || {};
  $('driveName').textContent = device.label ? `${device.label} (${device.drive.replace(/\\$/, '')})` : device.drive || state.root;
  $('drivePath').textContent = state.root;
  // NTFS is read-only or invisible on most phones, so files stored there could not be opened on the phone.
  const ntfs = (device.filesystem || '').toUpperCase() === 'NTFS';
  $('fsWarning').hidden = !ntfs;
  $('fsWarning').textContent = ntfs ? '此 SSD 是 NTFS 格式，多数手机无法写入或识别。要让手机也能打开和存入，建议备份后格式化为 exFAT。' : '';
}
function setConnected(state, listing) {
  connected = true; folder = ''; thumbs.clear(); showDrive(state);
  $('welcome').hidden = true; $('library').hidden = false; $('search').value = '';
  if (listing) show(listing); else reload().catch(error => status(error.message));
  controls(); renderTray();
}
function setDisconnected(message) {
  connected = false; folder = ''; entries = []; $('details').hidden = true;
  $('welcome').hidden = false; $('library').hidden = true;
  $('driveName').textContent = '未检测到 SSD'; $('drivePath').textContent = '插入 SSD 后自动连接';
  $('capacity').value = 0; $('capacityText').textContent = ''; $('fsWarning').hidden = true;
  controls(); if (message) status(message); renderTray();
}
function renderDrives(list) {
  $('driveList').replaceChildren();
  for (const drive of list) {
    const row = document.createElement('div'); row.className = 'drive-row';
    const text = document.createElement('div');
    const name = document.createElement('strong'); name.textContent = `${drive.label || 'USB 磁盘'} (${drive.drive.replace(/\\$/, '')})`;
    const info = document.createElement('small'); info.textContent = `${drive.filesystem} · ${bytes(drive.available)} 可用 / ${bytes(drive.capacity)}${drive.setup ? ' · 已有 file-hero 文件夹' : ''}`;
    text.append(name, info);
    const button = document.createElement('button'); button.className = 'primary';
    button.textContent = drive.setup ? '连接' : '在此 SSD 启用';
    button.title = drive.setup ? '' : '将在 SSD 根目录建立 file-hero 文件夹，手机版也使用这个文件夹';
    button.onclick = () => task(async () => { const r = await hero.invoke('connect', drive.drive); setConnected(r, r.listing); status('SSD 已连接'); });
    row.append(text, button); $('driveList').append(row);
  }
  if (!list.length) { const none = document.createElement('p'); none.className = 'muted'; none.textContent = '暂未发现 USB SSD。'; $('driveList').append(none); }
}

async function reload() { show(await hero.invoke('list', folder)); }
function show(data) {
  entries = data.entries; selected = null; $('details').hidden = true;
  const files = entries.filter(e => !e.directory && !isReadme(e.name)), dirs = entries.filter(e => e.directory);
  $('summary').textContent = `${dirs.length} 个文件夹 · ${files.length} 个文件 · ${bytes(files.reduce((n,f) => n + f.size, 0))}`;
  $('capacity').value = data.capacity ? (data.capacity - data.available) / data.capacity * 100 : 0;
  $('capacityText').textContent = `${bytes(data.available)} 可用 / ${bytes(data.capacity)}`;
  $('breadcrumb').textContent = `file-hero${folder ? ' / ' + folder.replaceAll('/', ' / ') : ''}`; render(); prepareShare();
}
function cover(entry, large = false, fetch = true) {
  const box = document.createElement('div'); box.className = `cover${large ? ' large' : ''}`;
  const fallback = document.createElement('div'); fallback.className = 'fallback';
  const icon = document.createElement('span'); icon.textContent = entry.directory ? '▰' : /\.pdf$/i.test(entry.name) ? '▤' : '▢';
  const label = document.createElement('small'); label.textContent = entry.directory ? '文件夹' : (entry.name.includes('.') ? entry.name.split('.').pop() : '文件').toUpperCase().slice(0, 8);
  fallback.append(icon, label); box.append(fallback);
  const source = entry.directory ? entry.cover && `${relative(entry.name)}/${entry.cover}` : previewable(entry.name) && relative(entry.name);
  if (fetch && source) {
    const key = `${source}|${entry.modified}`;
    if (!thumbs.has(key)) thumbs.set(key, hero.invoke('thumb', source).catch(() => null));
    thumbs.get(key).then(url => { if (!url) return; const img = document.createElement('img'); img.alt = ''; img.src = url; box.replaceChildren(img); });
  }
  return box;
}
function render() {
  const query = $('search').value.toLocaleLowerCase(); $('files').replaceChildren();
  const visible = entries.filter(e => e.name.toLocaleLowerCase().includes(query) || (e.metadata.Description || '').toLocaleLowerCase().includes(query));
  $('empty').hidden = visible.length > 0;
  $('empty').querySelector('h3').textContent = query ? '没有匹配的文件' : '这个文件夹还是空的';
  for (const entry of visible) {
    const card = document.createElement('article'); card.className = 'card'; card.tabIndex = 0;
    const body = document.createElement('div'); body.className = 'body';
    const name = document.createElement('strong'); name.textContent = entry.name;
    const text = (entry.metadata.Description || '').trim();
    const desc = document.createElement('p'); desc.className = text ? 'desc' : 'desc empty-desc';
    desc.textContent = text || (entry.directory ? '暂无批次描述' : isReadme(entry.name) ? '批次说明，点击编辑批次描述' : '暂无描述，点击添加');
    const size = document.createElement('small'); size.textContent = entry.directory ? `${entry.fileCount ?? '—'} 个文件 · ${bytes(entry.size)}` : bytes(entry.size);
    const date = document.createElement('small'); date.textContent = `日期：${day(entry.modified)}`;
    body.append(name, desc, size, date);
    const actions = document.createElement('div'); actions.className = 'card-actions';
    if (!entry.directory) {
      const open = document.createElement('button'); open.textContent = '打开'; open.title = `用电脑默认程序打开 ${entry.name}`;
      open.onclick = event => { event.stopPropagation(); openFile(entry); }; actions.append(open);
    }
    const remove = document.createElement('button'); remove.className = 'danger'; remove.textContent = '删除'; remove.title = `删除 ${entry.name}`;
    remove.onclick = event => { event.stopPropagation(); removeEntry(entry); }; actions.append(remove);
    card.append(cover(entry), body, actions);
    const activate = () => { if (working) return; if (entry.directory) enter(relative(entry.name)); else details(entry); };
    card.addEventListener('click', activate);
    card.addEventListener('dblclick', () => { if (!entry.directory && !working) openFile(entry); });
    card.addEventListener('keydown', e => { if (e.key === 'Enter') activate(); });
    $('files').append(card);
  }
}
function enter(next) { task(async () => { const data = await hero.invoke('list', next); folder = next; $('search').value = ''; show(data); status('已打开文件夹'); }); }
function openFile(entry) { hero.invoke('open', relative(entry.name)).then(() => status(`已用默认程序打开「${entry.name}」`), error => status(`操作未完成：${error.message}`)); }
function details(entry) {
  selected = entry; $('details').hidden = false; $('detailName').textContent = entry.name;
  const readme = isReadme(entry.name);
  $('detailKind').textContent = readme ? 'BATCH DESCRIPTION' : 'FILE DETAILS';
  $('descriptionLabel').textContent = readme ? '批次描述（文件夹卡片上显示）' : '文件描述';
  $('description').value = entry.metadata.Description || ''; $('facts').replaceChildren();
  $('detailCover').replaceWith(Object.assign(cover(entry, true), { id: 'detailCover' }));
  const rows = readme
    ? [['文件数量', entry.metadata['File-Count'] || '—'], ['总容量', bytes(entry.metadata['Size-Bytes'])], ['建立日期', entry.metadata['Created-UTC'] || '未知'], ['上一次存入', entry.metadata['Last-Stored-UTC'] || '未知']]
    : [['容量', bytes(entry.size)], ['修改日期', entry.modified], ['首次建档', entry.metadata['First-Indexed-UTC'] || '尚未建档'], ['上一次存入', entry.metadata['Last-Stored-UTC'] === 'unknown' ? '未知（导入前的历史不可推断）' : entry.metadata['Last-Stored-UTC'] || '未知']];
  for (const [key, value] of rows) { const dt = document.createElement('dt'), dd = document.createElement('dd'); dt.textContent = key; dd.textContent = value; $('facts').append(dt, dd); }
}
function confirm(title, text) {
  return new Promise(resolve => {
    $('confirmTitle').textContent = title; $('confirmText').textContent = text;
    $('confirmDialog').addEventListener('close', () => resolve($('confirmDialog').returnValue === 'ok'), { once: true });
    $('confirmDialog').returnValue = ''; $('confirmDialog').showModal();
  });
}
async function removeEntry(entry) {
  if (working) return;
  const text = `「${entry.name}」\n\n${entry.directory ? '此文件夹及其中所有文件和子文件夹都会永久删除。' : '此文件将永久删除。'}此操作无法撤销。${isReadme(entry.name) ? '\n删除说明文件会丢失本批描述和历史记录。' : ''}`;
  if (!await confirm(entry.directory ? '删除文件夹？' : '删除文件？', text)) { status('已取消删除'); return; }
  task(async () => { const r = await hero.invoke('delete', relative(entry.name)); await reload(); status(`已删除「${entry.name}」。${r.warning || ''}`); });
}

// Staging area: dropped items, the file picker and Explorer's "Share to SSD" all land here; main keeps the list.
function localName() { const d = new Date(), p = n => String(n).padStart(2, '0'); return `分享-${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}-${p(d.getMinutes())}-${p(d.getSeconds())}`; }
function mode() { return document.querySelector('input[name=mode]:checked').value; }
function setMode(value) { document.querySelector(`input[name=mode][value=${value}]`).checked = true; }
const stagedThumbs = new Map();
function stagedItem(item) {
  const tile = document.createElement('div'); tile.className = 'tray-item'; tile.title = item.path;
  const box = cover({ name: item.name, directory: item.directory }, false, false);
  if (!item.directory && previewable(item.name)) {
    if (!stagedThumbs.has(item.path)) stagedThumbs.set(item.path, hero.invoke('stage-thumb', item.path).catch(() => null));
    stagedThumbs.get(item.path).then(url => { if (!url) return; const img = document.createElement('img'); img.alt = ''; img.src = url; box.replaceChildren(img); });
  }
  const name = document.createElement('strong'); name.textContent = item.name;
  const info = document.createElement('small'); info.textContent = item.directory ? `文件夹 · ${item.files} 个文件 · ${bytes(item.size)}` : bytes(item.size);
  const remove = document.createElement('button'); remove.className = 'tray-remove'; remove.textContent = '✕'; remove.title = `移出 ${item.name}`; remove.setAttribute('aria-label', `移出 ${item.name}`);
  remove.onclick = () => { if (!saving) hero.invoke('unstage', item.path); };
  tile.append(remove, box, name, info);
  return tile;
}
function openShare(files) {
  const fresh = !sharing || !sharing.length;
  sharing = files.length ? files : null;
  if (sharing && fresh) {
    $('shareName').value = files.length === 1 && files[0].directory ? files[0].name : localName();
    $('shareDescription').value = ''; $('shareFileDescription').value = ''; $('shareCurrentDescription').value = '';
    $('shareError').textContent = ''; $('shareProgress').hidden = true; $('shareProgressText').textContent = '';
    // Dropping while inside a folder most likely means "put it here".
    setMode(folder ? 'current' : 'new');
  }
  renderTray();
}
function renderTray() {
  const files = sharing || [];
  $('tray').hidden = !files.length && !connected;
  $('trayEmpty').hidden = files.length > 0; $('trayFull').hidden = !files.length;
  if (!files.length) return;
  const folders = files.filter(f => f.directory), count = files.reduce((n, f) => n + (f.directory ? f.files : 1), 0);
  $('shareCount').textContent = `${folders.length ? `${files.length > folders.length ? `${files.length - folders.length} 个文件、` : ''}${folders.length} 个文件夹（共 ${count} 个文件）` : `${files.length} 个文件`} · ${bytes(files.reduce((n, f) => n + f.size, 0))}${files.some(f => f.partial) ? ' 以上' : ''}`;
  $('shareFiles').replaceChildren(...files.map(stagedItem));
  $('folderHint').hidden = !folders.length;
  prepareShare();
}
async function prepareShare() {
  if (!sharing) return;
  const hasCurrent = connected && !!folder;
  $('currentMode').classList.toggle('disabled', !hasCurrent); $('currentMode').querySelector('input').disabled = !hasCurrent;
  $('currentMode').title = hasCurrent ? '' : '先在下方打开一个文件夹';
  if (!hasCurrent && mode() === 'current') setMode('new');
  $('currentName').textContent = folder ? `file-hero / ${folder.replaceAll('/', ' / ')}` : '';
  $('shareWaiting').hidden = connected; $('shareSave').disabled = !connected || saving; $('shareClear').disabled = saving;
  for (const [id, value] of [['newFields', 'new'], ['existingFields', 'existing'], ['currentFields', 'current']]) $(id).hidden = mode() !== value;
  $('shareTarget').textContent = connected ? `存入 ${$('driveName').textContent}` : '';
  if (!connected || mode() !== 'existing') return;
  const current = $('shareFolder').value;
  try {
    const top = (await hero.invoke('list', '')).entries.filter(e => e.directory).map(e => e.name);
    const options = [...new Set([...(folder ? [folder] : []), ...top])];
    $('shareFolder').replaceChildren(...options.map(name => { const o = document.createElement('option'); o.value = name; o.textContent = name.replaceAll('/', ' / '); return o; }));
    if (options.includes(current)) $('shareFolder').value = current;
    if (!options.length) { $('shareError').textContent = 'SSD 上还没有文件夹，请选择「新建文件夹」。'; $('shareSave').disabled = true; }
  } catch (error) { $('shareError').textContent = error.message; }
}
for (const radio of document.querySelectorAll('input[name=mode]')) radio.onchange = () => { $('shareError').textContent = ''; prepareShare(); };
$('shareSave').onclick = async () => {
  if (saving || !connected || !sharing) return;
  const chosen = mode();
  const form = chosen === 'new'
    ? { mode: 'new', name: $('shareName').value.trim(), folder: '', description: $('shareDescription').value }
    : { mode: 'existing', name: '', folder: chosen === 'current' ? folder : $('shareFolder').value, description: (chosen === 'current' ? $('shareCurrentDescription') : $('shareFileDescription')).value };
  form.description = form.description.replace(/[\r\n]+/g, ' ').trim();
  if (form.mode === 'new' && !form.name) { $('shareError').textContent = '请输入新文件夹名称'; return; }
  if (form.mode === 'existing' && !form.folder) { $('shareError').textContent = '请选择要存入的文件夹'; return; }
  saving = true; working = true; controls(); $('shareSave').disabled = true; $('shareClear').disabled = true; $('shareError').textContent = '';
  $('shareProgress').hidden = false; $('shareProgress').value = 0; status('正在复制到 SSD，请勿拔出 SSD…');
  try {
    const r = await hero.invoke('share-save', '', JSON.stringify(form));
    sharing = null; stagedThumbs.clear(); renderTray();
    folder = r.path; await reload();
    status(`已复制到「${r.batch}」：${r.imported} 个文件，说明已写入 file-readme.txt。`);
  } catch (error) { $('shareError').textContent = `未能存入：${error.message}`; status('存入未完成，SSD 上没有留下这批文件'); }
  finally { saving = false; working = false; controls(); $('shareProgress').hidden = true; $('shareProgressText').textContent = ''; renderTray(); }
};
$('shareClear').onclick = () => { if (saving) return; sharing = null; stagedThumbs.clear(); hero.invoke('share-cancel'); renderTray(); status('已清空待存入区，未存入任何文件'); };

// Drag files or folders from Explorer anywhere onto the window.
let dragDepth = 0;
const carriesFiles = event => [...(event.dataTransfer?.types || [])].includes('Files');
window.addEventListener('dragenter', event => { if (!carriesFiles(event)) return; event.preventDefault(); dragDepth++; $('dropOverlay').hidden = saving; });
window.addEventListener('dragleave', event => { if (!carriesFiles(event)) return; if (--dragDepth <= 0) { dragDepth = 0; $('dropOverlay').hidden = true; } });
window.addEventListener('dragover', event => { if (!carriesFiles(event)) return; event.preventDefault(); event.dataTransfer.dropEffect = saving ? 'none' : 'copy'; });
window.addEventListener('drop', event => {
  event.preventDefault(); dragDepth = 0; $('dropOverlay').hidden = true;
  if (saving) { status('正在复制，完成后再拖入'); return; }
  const paths = [...event.dataTransfer.files].map(file => hero.pathFor(file)).filter(Boolean);
  if (!paths.length) { status('没有可以存入的文件'); return; }
  hero.invoke('stage', '', JSON.stringify(paths)).then(() => status(`已加入 ${paths.length} 项到待存入区`), error => status(`操作未完成：${error.message}`));
});

hero.on(event => {
  if (event.type === 'connected') { if (!connected) { setConnected(event); status('SSD 已连接'); } }
  else if (event.type === 'disconnected') setDisconnected('SSD 已移除');
  else if (event.type === 'drives') { if (!connected) renderDrives(event.drives); }
  else if (event.type === 'share') openShare(event.files);
  else if (event.type === 'notice') status(event.message);
  else if (event.type === 'progress') {
    $('shareProgress').value = event.total ? event.done / event.total * 100 : 100;
    $('shareProgressText').textContent = `${Math.min(event.index + 1, event.count)} / ${event.count} 个文件 · ${bytes(event.done)} / ${bytes(event.total)}`;
  }
});
$('search').oninput = render;
$('refresh').onclick = () => task(async () => { await reload(); status('已刷新'); });
$('up').onclick = () => enter(folder.split('/').slice(0, -1).join('/'));
$('import').onclick = () => task(async () => { status(await hero.invoke('pick-files') ? '已加入待存入区' : '已取消选择'); });
$('index').onclick = () => task(async () => { const r = await hero.invoke('index', folder); await reload(); status(`已将 ${r.indexed} 个文件的信息更新到各文件夹的 file-readme.txt`); });
$('mkdir').onclick = () => { $('folderName').value = ''; $('folderDialog').showModal(); };
$('folderDialog').addEventListener('close', () => { if ($('folderDialog').returnValue === 'create') task(async () => { await hero.invoke('mkdir', folder, $('folderName').value.trim()); await reload(); status('文件夹已创建'); }); });
$('close').onclick = () => { $('details').hidden = true; };
$('save').onclick = () => task(async () => { const file = selected; const desc = $('description').value.replace(/[\r\n]+/g, ' '); await hero.invoke('describe', relative(file.name), desc); await reload(); details(entries.find(e => e.name === file.name)); status('说明已保存到 SSD'); });
$('open').onclick = () => openFile(selected);
$('reveal').onclick = () => hero.invoke('reveal', relative(selected.name));
$('export').onclick = () => task(async () => { const r = await hero.invoke('export', relative(selected.name)); status(r ? '文件副本已导出（说明仍保留在 SSD）' : '已取消导出'); });
$('delete').onclick = () => removeEntry(selected);
$('switchDrive').onclick = () => task(async () => { await hero.invoke('disconnect'); setDisconnected('请选择 SSD'); renderDrives(await hero.invoke('drives')); });
$('pickFolder').onclick = () => task(async () => { const r = await hero.invoke('pick-folder'); if (!r) { status('已取消'); return; } setConnected(r, r.listing); status('已连接'); });
for (const id of ['autostart', 'menu']) $(id).onchange = () => task(async () => { await hero.invoke('settings', '', JSON.stringify({ autostart: $('autostart').checked, menu: $('menu').checked })); status('电脑整合设置已更新'); });

hero.invoke('state').then(state => {
  $('autostart').checked = state.settings.autostart; $('menu').checked = state.settings.menu;
  $('autostart').disabled = $('menu').disabled = !state.settings.integrated;
  $('integrationNote').textContent = state.settings.integrated ? 'Windows 11 中「Share to SSD」位于右键 →「显示更多选项」。' : '安装版才会注册右键菜单和自动启动。';
  if (state.root) setConnected(state); else setDisconnected();
  if (state.shares.length) openShare(state.shares);
  controls();
});
