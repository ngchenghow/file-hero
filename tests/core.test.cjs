const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const exe = path.resolve('build', `file-hero-core${process.platform === 'win32' ? '.exe' : ''}`);
function fixture(t) { const base=fs.mkdtempSync(path.join(os.tmpdir(),'file-hero-test-')); t.after(() => fs.rmSync(base,{recursive:true,force:true})); const root=path.join(base,'SSD'); fs.mkdirSync(root); return {base,root}; }
function raw(args) { return spawnSync(exe,args,{encoding:'utf8'}); }
function run(root,command,rel='',arg) { const r=raw([command,root,rel,...(arg===undefined?[]:Array.isArray(arg)?arg:[arg])]); if(r.status!==0) throw new Error(r.stderr || r.error?.message); return JSON.parse(r.stdout); }
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
  assert.throws(()=>run(root,'import','',source),/已存在/); assert.equal(fs.readFileSync(path.join(root,'a.txt'),'utf8'),'original');
  assert.throws(()=>run(root,'export','a.txt',source),/已存在/); assert.equal(fs.readFileSync(source,'utf8'),'new');
  const exported=path.join(base,'exported.txt'); run(root,'export','a.txt',exported); assert.equal(fs.readFileSync(exported,'utf8'),'original');
});
test('exports a whole folder with subfolders and never overwrites or copies into itself', t => {
  const {base,root}=fixture(t); const out=path.join(base,'out'); fs.mkdirSync(out);
  fs.mkdirSync(path.join(root,'旅行','第一天'),{recursive:true}); fs.writeFileSync(path.join(root,'旅行','a.txt'),'a'); fs.writeFileSync(path.join(root,'旅行','第一天','b.txt'),'b');
  run(root,'index'); fs.mkdirSync(path.join(out,'旅行')); fs.writeFileSync(path.join(out,'旅行','keep.txt'),'keep');
  const r=run(root,'export','旅行',out); assert.equal(r.name,'旅行 (2)'); assert.equal(r.files,4);
  assert.equal(fs.readFileSync(path.join(out,'旅行 (2)','第一天','b.txt'),'utf8'),'b'); assert.ok(fs.existsSync(path.join(out,'旅行 (2)','file-readme.txt')));
  assert.deepEqual(fs.readdirSync(path.join(out,'旅行')),['keep.txt']);
  const inside=run(root,'export','旅行',path.join(root,'旅行','第一天')); assert.equal(inside.files,4);
  assert.deepEqual(fs.readdirSync(path.join(root,'旅行','第一天','旅行')).sort(),['a.txt','file-readme.txt','第一天']);
  assert.throws(()=>run(root,'export','',out));
});
test('rejects traversal, reserved names, metadata access, and injected descriptions', t => {
  const {root}=fixture(t); fs.writeFileSync(path.join(root,'file.txt'),'x');
  for(const p of ['../','a/../../','.file-hero','.. /','C:\\Windows']) assert.throws(()=>run(root,'list',p));
  for(const name of ['../escape','CON','a:b','bad.','.file-hero']) assert.throws(()=>run(root,'mkdir','',name));
  assert.throws(()=>run(root,'describe','file.txt','bad\nLast-Stored-UTC: fake'));
  assert.throws(()=>run(root,'describe','file.txt','界'.repeat(3000)));
  run(root,'mkdir','','中文目录'); assert.equal(run(root,'list').entries[0].name,'中文目录');
});
test('listing is read-only, unfinished manifest writes (desktop .tmp or Android .backup) fail safely', t => {
  const {root}=fixture(t); fs.writeFileSync(path.join(root,'a.txt'),'a'); run(root,'list'); assert.equal(fs.existsSync(path.join(root,'.file-hero')),false);
  run(root,'index'); const meta=path.join(root,'file-readme.txt'); const before=fs.readFileSync(meta,'utf8');
  for(const suffix of ['.tmp','.backup']) {
    fs.writeFileSync(meta+suffix,'interrupted');
    assert.throws(()=>run(root,'describe','a.txt','changed'),/正忙/); assert.equal(fs.readFileSync(meta,'utf8'),before);
    fs.rmSync(meta+suffix);
  }
  fs.writeFileSync(meta+'.backup','interrupted'); fs.rmSync(meta); fs.writeFileSync(path.join(root,'b.txt'),'b');
  assert.throws(()=>run(root,'index')); assert.equal(fs.existsSync(meta),false);
});
test('batch imports into an independent folder with exactly one shared manifest', t => {
  const {base,root}=fixture(t); const a=path.join(base,'a.txt'), b=path.join(base,'照片.txt'); fs.writeFileSync(a,'abc'); fs.writeFileSync(b,'12345');
  const r=run(root,'batch','',['旅行备份','旅行原始资料',a,b]); assert.equal(r.imported,2); assert.equal(r.path,'旅行备份');
  const manifest=fs.readFileSync(path.join(root,'旅行备份','file-readme.txt'),'utf8');
  assert.match(manifest,/Format: file-hero\/batch-v1/); assert.match(manifest,/Description: 旅行原始资料/); assert.match(manifest,/Size-Bytes: 8/); assert.match(manifest,/File-Count: 2/); assert.match(manifest,/照片.txt/);
  assert.deepEqual(fs.readdirSync(path.join(root,'旅行备份')).sort(),['a.txt','file-readme.txt','照片.txt'].sort());
  run(root,'describe','旅行备份/a.txt','first file'); run(root,'describe','旅行备份/照片.txt','second file');
  run(root,'describe','旅行备份/file-readme.txt','new batch description');
  const edited=fs.readFileSync(path.join(root,'旅行备份','file-readme.txt'),'utf8');
  for(const phrase of ['Description: first file','Description: second file','Description: new batch description']) assert.ok(edited.includes(phrase));
  assert.equal(run(root,'list','旅行备份').entries.find(e=>e.name==='a.txt').metadata.Description,'first file');
  assert.equal(fs.readdirSync(path.join(root,'旅行备份')).length,3);
  assert.throws(()=>run(root,'batch','',['旅行备份','another',a]),/已存在/);
  assert.throws(()=>run(root,'batch','',['bad:name','',a])); assert.equal(fs.existsSync(path.join(root,'bad')),false);
});
test('shared names become portable like Android: reserved names prefixed, duplicates numbered', t => {
  const {base,root}=fixture(t); fs.mkdirSync(path.join(base,'x')); fs.mkdirSync(path.join(base,'y'));
  const readme=path.join(base,'file-readme.txt'), one=path.join(base,'x','photo.jpg'), two=path.join(base,'y','photo.jpg');
  fs.writeFileSync(readme,'not a manifest'); fs.writeFileSync(one,'1'); fs.writeFileSync(two,'22');
  run(root,'batch','',['混合','',readme,one,two]);
  assert.deepEqual(fs.readdirSync(path.join(root,'混合')).sort(),['file-readme.txt','photo (2).jpg','photo.jpg','shared-file-readme.txt'].sort());
  assert.equal(fs.readFileSync(path.join(root,'混合','photo (2).jpg'),'utf8'),'22');
  assert.match(fs.readFileSync(path.join(root,'混合','file-readme.txt'),'utf8'),/File-Count: 3/);
});
test('append adds to an existing folder, keeps its description, refuses name clashes without side effects', t => {
  const {base,root}=fixture(t); const a=path.join(base,'a.txt'), b=path.join(base,'b.txt'); fs.writeFileSync(a,'abc'); fs.writeFileSync(b,'12345');
  run(root,'batch','',['相册','原始描述',a]);
  const r=run(root,'append','相册',['新加入的文件',b]); assert.equal(r.imported,1); assert.equal(r.batch,'相册');
  const list=run(root,'list','相册').entries; const readme=list.find(e=>e.name==='file-readme.txt');
  assert.equal(readme.metadata.Description,'原始描述'); assert.equal(readme.metadata['File-Count'],'2'); assert.equal(readme.metadata['Size-Bytes'],'8');
  assert.equal(list.find(e=>e.name==='b.txt').metadata.Description,'新加入的文件'); assert.equal(list.find(e=>e.name==='a.txt').metadata.Description,'');
  const c=path.join(base,'c.txt'); fs.writeFileSync(c,'c');
  assert.throws(()=>run(root,'append','相册',['',c,b]),/同名/);
  assert.equal(fs.existsSync(path.join(root,'相册','c.txt')),false); assert.equal(fs.readFileSync(path.join(root,'相册','b.txt'),'utf8'),'12345');
  const folder=run(root,'list').entries[0]; assert.equal(folder.fileCount,2); assert.equal(folder.size,8); assert.equal(folder.metadata.Description,'原始描述');
});
test('folder cards carry batch description and a cover picked from previewable files', t => {
  const {base,root}=fixture(t); const doc=path.join(base,'notes.txt'), img=path.join(base,'b.png'), vid=path.join(base,'a.mp4');
  fs.writeFileSync(doc,'n'); fs.writeFileSync(img,'png'); fs.writeFileSync(vid,'mp4');
  run(root,'batch','',['旅行','京都',doc,img,vid]); run(root,'batch','',['文字','',doc]);
  const entries=run(root,'list').entries;
  assert.equal(entries.find(e=>e.name==='旅行').cover,'a.mp4'); assert.equal(entries.find(e=>e.name==='文字').cover,'');
  assert.equal(entries.find(e=>e.name==='旅行').metadata.Description,'京都');
});
test('search walks every subfolder and matches file and folder descriptions', t => {
  const {base,root}=fixture(t); const a=path.join(base,'a.txt'), b=path.join(base,'b.txt'); fs.writeFileSync(a,'a'); fs.writeFileSync(b,'b');
  run(root,'batch','',['旅行','京都 Café',a]); run(root,'batch','旅行',['第二天','',b]); run(root,'describe','旅行/第二天/b.txt','清水寺的日落');
  const hits=q=>run(root,'search','',q).entries.map(e=>e.path);
  assert.deepEqual(hits('日落'),['旅行/第二天/b.txt']);
  assert.deepEqual(hits('CAFÉ'),['旅行']);
  assert.deepEqual(hits('B.TXT'),['旅行/第二天/b.txt']);
  const hit=run(root,'search','旅行','清水').entries[0]; assert.equal(hit.name,'b.txt'); assert.equal(hit.metadata.Description,'清水寺的日落'); assert.equal(hit.size,1);
  assert.deepEqual(run(root,'search','旅行/第二天','京都').entries,[]);
  assert.throws(()=>run(root,'search','',' '));
});
test('rename moves the description with the file and never overwrites', t => {
  const {base,root}=fixture(t); const a=path.join(base,'a.txt'), b=path.join(base,'b.txt'); fs.writeFileSync(a,'a'); fs.writeFileSync(b,'bb');
  run(root,'batch','',['旅行','京都',a,b]); run(root,'describe','旅行/a.txt','第一天的票');
  assert.equal(run(root,'rename','旅行/a.txt','车票.txt').name,'车票.txt');
  const list=run(root,'list','旅行').entries; assert.equal(list.some(e=>e.name==='a.txt'),false);
  const moved=list.find(e=>e.name==='车票.txt'); assert.equal(moved.metadata.Description,'第一天的票'); assert.equal(moved.metadata.Name,'车票.txt');
  let manifest=fs.readFileSync(path.join(root,'旅行','file-readme.txt'),'utf8'); assert.match(manifest,/\[File: 车票.txt\]/); assert.doesNotMatch(manifest,/\[File: a.txt\]/); assert.match(manifest,/File-Count: 2/);
  assert.throws(()=>run(root,'rename','旅行/车票.txt','b.txt'),/同名/); assert.equal(fs.readFileSync(path.join(root,'旅行','b.txt'),'utf8'),'bb');
  for(const bad of ['file-readme.txt','a/b.txt','x:y','CON','']) assert.throws(()=>run(root,'rename','旅行/车票.txt',bad));
  assert.throws(()=>run(root,'rename','旅行/file-readme.txt','x.txt'));
  run(root,'rename','旅行/b.txt','B.txt'); assert.ok(run(root,'list','旅行').entries.some(e=>e.name==='B.txt'&&e.metadata.Name==='B.txt'));
  run(root,'rename','旅行','京都之旅'); manifest=fs.readFileSync(path.join(root,'京都之旅','file-readme.txt'),'utf8');
  assert.match(manifest,/Batch: 京都之旅/); assert.equal(run(root,'list').entries[0].metadata.Description,'京都');
  assert.throws(()=>run(root,'rename','','x'));
});
test('videos without all three screenshots are listed; screenshots are recorded, hidden, renamed and deleted with their video', t => {
  const {base,root}=fixture(t); const v=path.join(base,'trip.mp4'), w=path.join(base,'b.MOV'), doc=path.join(base,'notes.txt');
  fs.writeFileSync(v,'video'); fs.writeFileSync(w,'video2'); fs.writeFileSync(doc,'n');
  run(root,'batch','',['旅行','京都',v,w,doc]); run(root,'batch','旅行',['第二天','',v]);
  assert.deepEqual(run(root,'videos','').map(x=>x.path).sort(),['旅行/b.MOV','旅行/trip.mp4','旅行/第二天/trip.mp4']);
  const dir=path.join(root,'旅行'), thumbs=path.join(dir,'thumbs'); fs.mkdirSync(thumbs);
  const shots=[1,2,3].map(n=>`thumbs/trip.mp4-${n}.jpg`); for(const s of shots) fs.writeFileSync(path.join(dir,s),'jpg');
  run(root,'describe','旅行/trip.mp4','京都的街道');
  assert.equal(run(root,'thumbs','旅行/trip.mp4',shots.join(' | ')).Thumbnails,shots.join(' | '));
  assert.deepEqual(run(root,'videos','旅行').map(x=>x.path).sort(),['旅行/b.MOV','旅行/第二天/trip.mp4']);
  let manifest=fs.readFileSync(path.join(dir,'file-readme.txt'),'utf8');
  assert.match(manifest,/\[File: trip\.mp4\][^[]*Description: 京都的街道[^[]*Thumbnails: thumbs\/trip\.mp4-1\.jpg \| thumbs\/trip\.mp4-2\.jpg \| thumbs\/trip\.mp4-3\.jpg/);
  // A missing screenshot puts the video back on the list.
  fs.rmSync(path.join(dir,shots[1])); assert.ok(run(root,'videos','旅行').some(x=>x.path==='旅行/trip.mp4')); fs.writeFileSync(path.join(dir,shots[1]),'jpg');
  // The thumbs folder never shows up, is not searched and gets no readme of its own.
  assert.equal(run(root,'list','旅行').entries.some(e=>e.name==='thumbs'),false);
  assert.deepEqual(run(root,'search','','.jpg').entries,[]);
  run(root,'index','旅行'); assert.equal(fs.existsSync(path.join(thumbs,'file-readme.txt')),false);
  assert.equal(run(root,'list','旅行').entries.find(e=>e.name==='trip.mp4').metadata.Thumbnails,shots.join(' | '));
  assert.throws(()=>run(root,'thumbs','旅行/notes.txt','')); assert.throws(()=>run(root,'thumbs','旅行/trip.mp4','../x.jpg'));
  assert.throws(()=>run(root,'mkdir','旅行','thumbs'),/保留/); assert.throws(()=>run(root,'rename','旅行/第二天','Thumbs'),/保留/);
  // Renaming the video renames its screenshots; its description stays.
  run(root,'rename','旅行/trip.mp4','京都.mp4');
  for(const n of [1,2,3]) { assert.ok(fs.existsSync(path.join(thumbs,`京都.mp4-${n}.jpg`))); assert.equal(fs.existsSync(path.join(thumbs,`trip.mp4-${n}.jpg`)),false); }
  const moved=run(root,'list','旅行').entries.find(e=>e.name==='京都.mp4').metadata;
  assert.equal(moved.Thumbnails,[1,2,3].map(n=>`thumbs/京都.mp4-${n}.jpg`).join(' | ')); assert.equal(moved.Description,'京都的街道');
  // Deleting the last video with screenshots removes them and the empty thumbs folder.
  run(root,'delete','旅行/京都.mp4'); assert.equal(fs.existsSync(thumbs),false);
  // A folder copied in from the computer does not bring an old thumbs folder along.
  const album=path.join(base,'相册'); fs.mkdirSync(path.join(album,'thumbs'),{recursive:true}); fs.writeFileSync(path.join(album,'thumbs','x.jpg'),'j'); fs.writeFileSync(path.join(album,'c.mp4'),'v');
  run(root,'batch','',['相册','',album]); assert.equal(fs.existsSync(path.join(root,'相册','thumbs')),false);
});
test('delete removes files from the manifest, removes folders, and never removes the root', t => {
  const {base,root}=fixture(t); const a=path.join(base,'a.txt'), b=path.join(base,'b.txt'); fs.writeFileSync(a,'abc'); fs.writeFileSync(b,'12345');
  run(root,'batch','',['批次','desc',a,b]);
  assert.equal(run(root,'delete','批次/a.txt').deleted,true);
  const manifest=fs.readFileSync(path.join(root,'批次','file-readme.txt'),'utf8');
  assert.doesNotMatch(manifest,/\[File: a.txt\]/); assert.match(manifest,/File-Count: 1/); assert.match(manifest,/Description: desc/);
  assert.throws(()=>run(root,'delete','')); assert.throws(()=>run(root,'delete','../SSD'));
  run(root,'delete','批次'); assert.deepEqual(fs.readdirSync(root),[]);
});
test('setup creates the shared file-hero folder that the Android app also uses', t => {
  const {root}=fixture(t);
  const r=JSON.parse(raw(['setup',root]).stdout); assert.equal(path.basename(r.root),'file-hero'); assert.ok(fs.statSync(path.join(root,'file-hero')).isDirectory());
  assert.equal(JSON.parse(raw(['setup',root]).stdout).root,r.root);
  fs.rmdirSync(path.join(root,'file-hero')); fs.writeFileSync(path.join(root,'file-hero'),'a file');
  assert.notEqual(raw(['setup',root]).status,0);
  assert.ok(Array.isArray(JSON.parse(raw(['drives']).stdout)));
});
test('copies report progress on stderr and still print a single JSON result', t => {
  const {base,root}=fixture(t); const big=path.join(base,'big.bin'); fs.writeFileSync(big,Buffer.alloc(3*1024*1024,7));
  const r=raw(['batch',root,'','大文件','',big]); assert.equal(r.status,0);
  assert.equal(JSON.parse(r.stdout).imported,1);
  const last=r.stderr.trim().split('\n').pop(); assert.equal(last,`@progress ${3*1024*1024} ${3*1024*1024} 1 1`);
});
test('a single shared folder becomes the new folder, with a readme in every subfolder', t => {
  const {base,root}=fixture(t); const src=path.join(base,'旅行照片');
  fs.mkdirSync(path.join(src,'第一天'),{recursive:true}); fs.writeFileSync(path.join(src,'a.jpg'),'aa'); fs.writeFileSync(path.join(src,'第一天','b.txt'),'bbb');
  fs.writeFileSync(path.join(src,'Thumbs.db'),'junk'); fs.writeFileSync(path.join(src,'file-readme.txt'),'my own notes');
  const r=spawnSync(exe,['batch',root,'','旅行照片','京都之旅',src],{encoding:'utf8'}); assert.equal(r.status,0,r.stderr);
  assert.match(r.stderr.trim().split('\n').pop(),/^@progress 17 17 3 3$/);
  const dest=path.join(root,'旅行照片');
  assert.deepEqual(fs.readdirSync(dest).sort(),['a.jpg','file-readme.txt','shared-file-readme.txt','第一天'].sort());
  const top=fs.readFileSync(path.join(dest,'file-readme.txt'),'utf8'); assert.match(top,/Description: 京都之旅/); assert.match(top,/File-Count: 2/);
  assert.match(fs.readFileSync(path.join(dest,'第一天','file-readme.txt'),'utf8'),/File-Count: 1/);
  const folder=run(root,'list').entries[0]; assert.equal(folder.metadata.Description,'京都之旅'); assert.equal(folder.cover,'a.jpg');
});
test('folders mixed with files, and folders appended to an existing folder, keep their structure', t => {
  const {base,root}=fixture(t); const dir=path.join(base,'资料'), file=path.join(base,'x.txt');
  fs.mkdirSync(dir); fs.writeFileSync(path.join(dir,'y.txt'),'y'); fs.writeFileSync(file,'x');
  run(root,'batch','',['混合','',file,dir]);
  assert.ok(fs.existsSync(path.join(root,'混合','资料','y.txt'))); assert.ok(fs.existsSync(path.join(root,'混合','资料','file-readme.txt')));
  assert.match(fs.readFileSync(path.join(root,'混合','file-readme.txt'),'utf8'),/File-Count: 1/);
  run(root,'batch','',['目标','',file]); run(root,'append','目标',['',dir]);
  assert.ok(fs.existsSync(path.join(root,'目标','资料','y.txt')));
  assert.throws(()=>run(root,'append','目标',['',dir]),/同名/);
});
test('keeps descriptions when a File Hero batch folder is shared again, and never copies a folder into itself', t => {
  const {base,root}=fixture(t); const a=path.join(base,'a.txt'); fs.writeFileSync(a,'a');
  run(root,'batch','',['原批次','原描述',a]); run(root,'describe','原批次/a.txt','文件说明');
  const other=path.join(base,'other'); fs.mkdirSync(other);
  const r=spawnSync(exe,['batch',other,'','复制','',path.join(root,'原批次')],{encoding:'utf8'}); assert.equal(r.status,0,r.stderr);
  const copied=fs.readFileSync(path.join(other,'复制','file-readme.txt'),'utf8');
  assert.match(copied,/Description: 原描述/); assert.match(copied,/Description: 文件说明/); assert.deepEqual(fs.readdirSync(path.join(other,'复制')).sort(),['a.txt','file-readme.txt']);
  assert.throws(()=>run(root,'batch','原批次',['套娃','',path.join(root,'原批次')]),/自己/);
  assert.throws(()=>run(root,'append','原批次',['',root]),/自己/);
});
test('imported counts every file inside shared folders', t => {
  const {base,root}=fixture(t); const dir=path.join(base,'d'); fs.mkdirSync(path.join(dir,'e'),{recursive:true});
  fs.writeFileSync(path.join(dir,'1.txt'),'1'); fs.writeFileSync(path.join(dir,'e','2.txt'),'2');
  assert.equal(run(root,'batch','',['计数','',dir]).imported,2);
});
