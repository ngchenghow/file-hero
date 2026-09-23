const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const exe = path.resolve('build', `file-hero-core${process.platform === 'win32' ? '.exe' : ''}`);
function fixture(t) { const base=fs.mkdtempSync(path.join(os.tmpdir(),'file-hero-test-')); t.after(() => fs.rmSync(base,{recursive:true,force:true})); const root=path.join(base,'SSD'); fs.mkdirSync(root); return {base,root}; }
function run(root,command,rel='',arg) { const r=spawnSync(exe,[command,root,rel,...(arg===undefined?[]:[arg])],{encoding:'utf8'}); if(r.status!==0) throw new Error(r.stderr || r.error?.message); return JSON.parse(r.stdout); }
test('imports Unicode names, writes complete readme, preserves storage date on edits', t => {
  const {base,root}=fixture(t); const source=path.join(base,'旅行 照片.txt'); fs.writeFileSync(source,'hello 世界');
  run(root,'import','',source); const file=run(root,'list').entries[0];
  assert.equal(file.name,'旅行 照片.txt'); assert.equal(file.size,Buffer.byteLength('hello 世界'));
  assert.equal(file.metadata.Format,'file-hero/v1'); assert.match(file.metadata['Last-Stored-UTC'],/^\d{4}-/);
  const edited=run(root,'describe',file.name,'日本旅行：原始资料'); assert.equal(edited.Description,'日本旅行：原始资料'); assert.equal(edited['Last-Stored-UTC'],file.metadata['Last-Stored-UTC']);
  assert.match(fs.readFileSync(path.join(root,'.file-hero',file.name,'file-readme.txt'),'utf8'),/Size-Bytes: 12/);
});
test('index is recursive, metadata is hidden and unknown historical dates stay unknown', t => {
  const {root}=fixture(t); fs.mkdirSync(path.join(root,'photos')); fs.writeFileSync(path.join(root,'photos','a.txt'),'abc'); fs.writeFileSync(path.join(root,'b.txt'),'12345');
  assert.equal(run(root,'index').indexed,2); assert.equal(run(root,'index').indexed,2);
  assert.equal(run(root,'list').entries.length,2);
  assert.equal(run(root,'list','photos').entries[0].metadata['Last-Stored-UTC'],'unknown');
  run(root,'describe','photos/a.txt','description'); fs.appendFileSync(path.join(root,'photos','a.txt'),'more'); run(root,'index');
  const f=run(root,'list','photos').entries[0]; assert.equal(f.metadata.Description,'description'); assert.equal(f.metadata['Size-Bytes'],'7');
});
test('never overwrites an existing import or export destination', t => {
  const {base,root}=fixture(t); const source=path.join(base,'a.txt'); fs.writeFileSync(source,'new'); fs.writeFileSync(path.join(root,'a.txt'),'original');
  assert.throws(()=>run(root,'import','',source),/already exists/); assert.equal(fs.readFileSync(path.join(root,'a.txt'),'utf8'),'original');
  assert.throws(()=>run(root,'export','a.txt',source),/already exists/); assert.equal(fs.readFileSync(source,'utf8'),'new');
  const exported=path.join(base,'exported.txt'); run(root,'export','a.txt',exported); assert.equal(fs.readFileSync(exported,'utf8'),'original');
});
test('rejects traversal, reserved names, metadata access, and injected descriptions', t => {
  const {root}=fixture(t); fs.writeFileSync(path.join(root,'file.txt'),'x');
  for(const p of ['../','a/../../','.file-hero','.. /','C:\\Windows']) assert.throws(()=>run(root,'list',p));
  for(const name of ['../escape','CON','a:b','bad.','.file-hero']) assert.throws(()=>run(root,'mkdir','',name));
  assert.throws(()=>run(root,'describe','file.txt','bad\nLast-Stored-UTC: fake'));
  assert.throws(()=>run(root,'describe','file.txt','界'.repeat(3000)));
  run(root,'mkdir','','中文目录'); assert.equal(run(root,'list').entries[0].name,'中文目录');
});
test('listing is read-only, malformed metadata temporary path fails safely', t => {
  const {root}=fixture(t); fs.writeFileSync(path.join(root,'a.txt'),'a'); run(root,'list'); assert.equal(fs.existsSync(path.join(root,'.file-hero')),false);
  run(root,'index'); const meta=path.join(root,'.file-hero','a.txt','file-readme.txt'); const before=fs.readFileSync(meta,'utf8'); fs.writeFileSync(meta+'.tmp','interrupted');
  assert.throws(()=>run(root,'describe','a.txt','changed'),/busy/); assert.equal(fs.readFileSync(meta,'utf8'),before);
});
