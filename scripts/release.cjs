const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { root, stageRuntime } = require('./runtime-files.cjs');
const check = spawnSync(process.execPath, [path.join(root, 'scripts/check.cjs')], { stdio: 'inherit' });
if (check.status !== 0) process.exit(check.status || 1);
const stage = fs.mkdtempSync(path.join(os.tmpdir(), 'airwave-release-'));
try {
  stageRuntime(stage);
  fs.mkdirSync(path.join(root, 'dist'), { recursive: true });
  const output = path.join(root, 'dist', 'airwave-web-' + require('../package.json').version + '.tar.gz');
  const result = spawnSync('tar', ['-czf', output, '-C', stage, '.'], { stdio: 'inherit' });
  if (result.error) throw result.error;
  if (result.status !== 0) process.exitCode = result.status || 1;
  else console.log('Static web runtime packaged: ' + output + '\nPrivate relay is a separate local Node process; no catalog is bundled.');
} finally { fs.rmSync(stage, { recursive: true, force: true }); }
