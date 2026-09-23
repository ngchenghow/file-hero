const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const exe = path.resolve('build', `file-hero-core${process.platform === 'win32' ? '.exe' : ''}`);
function fixture(t) { const base=fs.mkdtempSync(path.join(os.tmpdir(),'file-hero-test-')); t.after(() => fs.rmSync(base,{recursive:true,force:true})); const root=path.join(base,'SSD'); fs.mkdirSync(root); return {base,root}; }
function run(root,command,rel='',arg) { const r=spawnSync(exe,[command,root,rel,...(arg===undefined?[]:Array.isArray(arg)?arg:[arg])],{encoding:'utf8'}); if(r.status!==0) throw new Error(r.stderr || r.error?.message); return JSON.parse(r.stdout); }
test('imports Unicode names, writes complete readme, preserves storage date on edits', t => {
  const {base,root}=fixture(t); const source=path.join(base,'旅行 照片.txt'); fs.writeFileSync(source,'hello 世界');
  run(root,'import','',source); const file=run(root,'list').entries.find(e=>e.name==='旅行 照片.txt');
  assert.equal(file.name,'旅行 照片.txt'); assert.equal(file.size,Buffer.byteLength('hello 世界'));
  assert.equal(file.metadata.Format,'file-hero/batch-v1'); assert.match(file.metadata['Last-Stored-UTC'],/^\d{4}-/);
  const edited=run(root,'describe',file.name,'日本旅行：原始资料'); assert.equal(edited.Description,'日本旅行：原始资料'); assert.equal(edited['Last-Stored-UTC'],file.metadata['Last-Stored-UTC']);
  assert.match(fs.readFileSync(path.join(root,'file-readme.txt'),'utf8'),/Size-Bytes: 12/);
});
test('index is recursive, metadata is hidden and unknown historical dates stay unknown', t => {
  const {root}=fixture(t); fs.mkdirSync(path.join(root,'photos')); fs.writeFileSync(path.join(root,'photos','a.txt'),'abc'); fs.writeFileSync(path.join(root,'b.txt'),'12345');
  assert.equal(run(root,'index').indexed,2); assert.equal(run(root,'index').indexed,2);
  assert.equal(run(root,'list').entries.length,3);
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
  run(root,'index'); const meta=path.join(root,'file-readme.txt'); const before=fs.readFileSync(meta,'utf8'); fs.writeFileSync(meta+'.tmp','interrupted');
  assert.throws(()=>run(root,'describe','a.txt','changed'),/busy/); assert.equal(fs.readFileSync(meta,'utf8'),before);
});
test('batch imports into an independent folder with exactly one shared manifest', t => {
  const {base,root}=fixture(t); const a=path.join(base,'a.txt'), b=path.join(base,'照片.txt'); fs.writeFileSync(a,'abc'); fs.writeFileSync(b,'12345');
  const r=run(root,'batch','',['旅行备份','旅行原始资料',a,b]); assert.equal(r.imported,2);
  const manifest=fs.readFileSync(path.join(root,'旅行备份','file-readme.txt'),'utf8');
  assert.match(manifest,/Format: file-hero\/batch-v1/); assert.match(manifest,/Description: 旅行原始资料/); assert.match(manifest,/Size-Bytes: 8/); assert.match(manifest,/File-Count: 2/); assert.match(manifest,/照片.txt/);
  assert.deepEqual(fs.readdirSync(path.join(root,'旅行备份')).sort(),['a.txt','file-readme.txt','照片.txt'].sort());
  run(root,'describe','旅行备份/a.txt','first file'); run(root,'describe','旅行备份/照片.txt','second file');
  run(root,'describe','旅行备份/file-readme.txt','new batch description');
  const edited=fs.readFileSync(path.join(root,'旅行备份','file-readme.txt'),'utf8');
  for(const phrase of ['Description: first file','Description: second file','Description: new batch description']) assert.ok(edited.includes(phrase));
  assert.equal(run(root,'list','旅行备份').entries.find(e=>e.name==='a.txt').metadata.Description,'first file');
  assert.equal(fs.readdirSync(path.join(root,'旅行备份')).length,3);
  assert.throws(()=>run(root,'batch','',['旅行备份','another',a]),/already exists/);
  const reserved=path.join(base,'file-readme.txt'); fs.writeFileSync(reserved,'original');
  assert.throws(()=>run(root,'batch','',['bad','',reserved]),/reserved/); assert.equal(fs.existsSync(path.join(root,'bad')),false);
  assert.throws(()=>run(root,'batch','',['duplicate','',a,a]),/Duplicate/); assert.equal(fs.existsSync(path.join(root,'duplicate')),false);
});
