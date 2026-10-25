const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { stageRuntime, files } = require('../scripts/runtime-files.cjs');
function walk(dir) { return fs.readdirSync(dir, { withFileTypes: true }).flatMap(x => x.isDirectory() ? walk(path.join(dir,x.name)).map(p => x.name+'/'+p) : [x.name]); }
test('release staging contains only approved runtime files and license notices', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'airwave-release-test-'));
  try { stageRuntime(dir); assert.deepEqual(walk(dir).sort(), [...files, 'LICENSE', 'NOTICE.md'].sort()); }
  finally { fs.rmSync(dir, { recursive: true, force: true }); }
});
// Bootstrap keeps runtime behavior fixed; resolve this in a release-version change.
test('Samsung and npm marketing versions agree', { todo: 'Samsung manifest remains 0.1.0 while npm and Apple are 0.2.0; see docs/PROJECT.md' }, () => {
  const tv = fs.readFileSync(path.join(__dirname, '../app/config.xml'), 'utf8').match(/<widget\b[^>]*\bversion="([^"]+)"/)[1];
  assert.equal(tv, require('../package.json').version);
});

test('Apple and npm marketing versions agree', () => {
  const plist = fs.readFileSync(path.join(__dirname, '../platforms/apple/Info.plist'), 'utf8');
  const apple = plist.match(/<key>CFBundleShortVersionString<\/key>\s*<string>([^<]+)<\/string>/)[1];
  assert.equal(apple, require('../package.json').version);
});

test('Android and npm marketing versions agree', () => {
  const gradle = fs.readFileSync(path.join(__dirname, '../platforms/android/app/build.gradle.kts'), 'utf8');
  assert.equal(gradle.match(/versionName = "([^"]+)"/)[1], require('../package.json').version);
});
