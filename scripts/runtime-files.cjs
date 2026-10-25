const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '..');
// Explicit allowlist: private catalogs, test harnesses and machine files never ship.
const files = [
  'index.html', 'styles.css', 'core.js', 'platform.js', 'player.js', 'cast.js', 'app.js',
  'config.xml', 'assets/icon.svg', 'assets/icon.png',
  'vendor/hls.min.js', 'vendor/HLS-LICENSE',
];
function stageRuntime(destination) {
  for (const file of files) {
    const source = path.join(root, 'app', file);
    if (!fs.lstatSync(source).isFile()) throw new Error('Runtime file must be a regular file: ' + file);
    const target = path.join(destination, file);
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.copyFileSync(source, target);
  }
  for (const file of ['LICENSE', 'NOTICE.md']) fs.copyFileSync(path.join(root, file), path.join(destination, file));
}
module.exports = { files, root, stageRuntime };
