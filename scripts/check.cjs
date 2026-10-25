const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const YAML = require('yaml');
const { files, root } = require('./runtime-files.cjs');
process.chdir(root);
function run(command, args) {
  const result = spawnSync(command, args, { stdio: 'inherit' });
  if (result.error) throw result.error;
  if (result.status !== 0) process.exit(result.status || 1);
}
function walk(directory) {
  return fs.readdirSync(directory, { withFileTypes: true }).flatMap(entry => {
    const file = path.join(directory, entry.name);
    return entry.isDirectory() ? (entry.name === 'vendor' ? [] : walk(file)) : [file];
  });
}
for (const file of ['app', 'server', 'scripts', 'tests'].flatMap(walk).filter(x => /\.(c?js)$/.test(x))) run(process.execPath, ['--check', file]);
for (const file of files) assert.ok(fs.statSync(path.join('app', file)).isFile(), 'Missing runtime file: ' + file);
function runtimeTree(dir) { return fs.readdirSync(dir, { withFileTypes: true }).flatMap(entry => entry.isDirectory() ? runtimeTree(path.join(dir, entry.name)) : [path.relative('app', path.join(dir, entry.name)).split(path.sep).join('/')]); }
assert.deepEqual(runtimeTree('app').sort(), [...files].sort(), 'Apple bundles app/ in full: unexpected runtime files must be removed or explicitly allowlisted');
const html = fs.readFileSync('app/index.html', 'utf8');
for (const match of html.matchAll(/(?:src|href)="([^"]+)"/g)) {
  if (!/^(?:https?:|#)/.test(match[1])) assert.ok(files.includes(match[1]), 'HTML reference missing from release: ' + match[1]);
}
for (const match of fs.readFileSync('app/styles.css', 'utf8').matchAll(/url\(['"]?([^)'"\s]+)['"]?\)/g)) assert.ok(files.includes(match[1]), 'CSS asset missing from release: ' + match[1]);
assert.deepEqual(fs.readFileSync('app/vendor/hls.min.js'), fs.readFileSync('node_modules/hls.js/dist/hls.min.js'), 'Vendored HLS differs from pinned npm dependency');
const workflow = YAML.parse(fs.readFileSync('.github/workflows/check.yml', 'utf8'));
assert.deepEqual(workflow.permissions, { contents: 'read' });
assert.ok(workflow.on.pull_request !== undefined && workflow.on.push && workflow.on.workflow_dispatch !== undefined);
const steps = workflow.jobs.check.steps;
assert.ok(steps.some(step => step.run === 'npm run check'));
for (const step of steps.filter(x => x.uses)) assert.match(step.uses, /^[\w.-]+\/[\w.-]+@[a-f0-9]{40}$/);
assert.equal(steps.find(x => x.uses?.startsWith('actions/checkout@')).with['persist-credentials'], false);
const tracked = spawnSync('git', ['ls-files', '-z'], { encoding: 'utf8' });
if (tracked.status !== 0) throw new Error('Run checks from a Git checkout');
for (const file of tracked.stdout.split('\0').filter(Boolean)) {
  assert.ok(!/(^|\/)(node_modules|build|dist|private|work|xcuserdata|\.gradle|\.kotlin)\/|\.(?:p12|pem|key|jks|keystore|mobileprovision|encrypted|log|wgt|ipa|apk|aab|pkg|zip)$|(^|\/)local\.properties$|(^|\/)\.env(?:\.|$)|\.claude\/(?:settings\.local\.json|worktrees\/)/i.test(file), 'Private/build file tracked: ' + file);
  if (/\.(?:md|json|c?js|swift|kt|kts|properties|brs|m3u|xml|plist|yml|pbxproj)$|(^|\/)manifest$/.test(file) && !file.includes('/vendor/')) {
    const text = fs.readFileSync(file, 'utf8');
    assert.ok(!/\/Users\/[a-zA-Z][^/\s]*\//.test(text), 'Machine-specific home path in ' + file);
    assert.ok(!/-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|gh[pousr]_[A-Za-z0-9]{30,}/.test(text), 'Possible credential in ' + file);
  }
}
run(process.execPath, ['--test', ...fs.readdirSync('tests').filter(x => x.endsWith('.test.cjs')).map(x => path.join('tests', x))]);
console.log('Airwave checks passed: syntax, runtime references, vendor integrity, CI policy, tracked-file hygiene and tests.');
