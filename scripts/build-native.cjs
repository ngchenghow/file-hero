const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
process.chdir(path.join(__dirname, '..'));
fs.mkdirSync('build', { recursive: true });
const win = process.platform === 'win32';
const compiler = process.env.CXX || (win && fs.existsSync('C:/msys64/mingw64/bin/g++.exe') ? 'C:/msys64/mingw64/bin/g++.exe' : 'g++');
const targets = [['native/main.cpp', 'file-hero-core', []]];
// The SSD watcher / Explorer integration agent only exists on Windows.
if (win) targets.push(['native/agent.cpp', 'file-hero-agent', ['-mwindows', '-lshell32', '-lole32', '-luuid']]);
for (const [source, name, extra] of targets) {
  const result = spawnSync(compiler, ['-std=c++17', '-O2', '-Wall', '-Wextra', ...(win ? ['-municode', '-static'] : []), source, '-o', `build/${name}${win ? '.exe' : ''}`, ...extra], { stdio: 'inherit' });
  if (result.error) console.error('Install a C++17 compiler or set CXX:', result.error.message);
  if (result.status !== 0) process.exit(result.status ?? 1);
}
