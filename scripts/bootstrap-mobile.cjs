// Generate the SDK-version-matched Android runner; preserve the authored activity/UI.
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const root = path.join(__dirname, '../mobile');
const paths = ['lib/main.dart', 'pubspec.yaml', 'android/app/src/main/AndroidManifest.xml', 'android/app/src/main/kotlin/com/filehero/file_hero/MainActivity.kt'];
const saved = paths.map(p => [p, fs.readFileSync(path.join(root,p))]);
const result = spawnSync(process.platform === 'win32' ? 'flutter.bat' : 'flutter', ['create', '--platforms=android', '--org', 'com.filehero', '--project-name', 'file_hero', '.'], {cwd: root, stdio: 'inherit', shell: process.platform === 'win32'});
for (const [p, contents] of saved) { fs.mkdirSync(path.dirname(path.join(root,p)), {recursive: true}); fs.writeFileSync(path.join(root,p), contents); }
if(result.error || result.status !== 0) { console.error(result.error || 'Flutter scaffolding failed'); process.exit(1); }
const gradle = ['android/app/build.gradle.kts','android/app/build.gradle'].map(p => path.join(root,p)).find(p => fs.existsSync(p));
let content = fs.readFileSync(gradle,'utf8');
if(!content.includes('androidx.documentfile:documentfile')) content += '\ndependencies {\n    implementation("androidx.documentfile:documentfile:1.0.1")\n}\n';
fs.writeFileSync(gradle,content);
const generatedTest = path.join(root,'test/widget_test.dart');
if(fs.existsSync(generatedTest) && fs.readFileSync(generatedTest,'utf8').includes('MyApp')) fs.unlinkSync(generatedTest);
console.log('Android runner ready. Run: cd mobile && flutter pub get && flutter build apk --debug');
