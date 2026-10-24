const { spawnSync } = require('node:child_process');
const path = require('node:path');
const fs = require('node:fs');
const os = require('node:os');
const { root, stageRuntime } = require('./runtime-files.cjs');
const profile = process.env.AIRWAVE_CERT_PROFILE;
if (!profile) {
  console.error('Set AIRWAVE_CERT_PROFILE to your Samsung certificate profile name. No unsigned widget will be labelled installable. See README.md.');
  process.exit(1);
}
const check = spawnSync(process.execPath, [path.join(root, 'scripts/check.cjs')], { stdio: 'inherit' });
if (check.status !== 0) process.exit(check.status || 1);
const stage = fs.mkdtempSync(path.join(os.tmpdir(), 'airwave-tizen-'));
try {
  stageRuntime(stage);
  fs.mkdirSync(path.join(root, 'dist'), { recursive: true });
  const result = spawnSync('tizen', ['package', '-t', 'wgt', '-s', profile, '-o', path.join(root, 'dist'), '--', stage], { stdio: 'inherit' });
  if (result.error) { console.error('Tizen CLI is unavailable. Install Tizen Studio with Samsung TV support and configure signing.'); process.exitCode = 1; }
  else process.exitCode = result.status || (result.signal ? 1 : 0);
} finally { fs.rmSync(stage, { recursive: true, force: true }); }
