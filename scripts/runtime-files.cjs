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
// Roku channel: every file under platforms/roku, listed explicitly (tests/roku.test.cjs checks the tree matches).
const rokuFiles = [
  'manifest',
  'source/main.brs', 'source/core.brs',
  'components/MainScene.xml', 'components/MainScene.brs', 'components/LoadTask.xml', 'components/LoadTask.brs',
  'components/PlayerView.xml', 'components/PlayerView.brs', 'components/TileItem.xml', 'components/TileItem.brs',
  'components/Fonts.brs',
  'images/icon_focus_fhd.png', 'images/icon_focus_hd.png', 'images/splash_fhd.png', 'images/splash_hd.png',
  'images/brand.png', 'images/tile.9.png', 'images/pill.9.png', 'images/panel.9.png',
];
// Copies the channel with its manifest at the root, plus the license notices, into destination.
function stageRoku(destination) {
  for (const file of rokuFiles) {
    const source = path.join(root, 'platforms', 'roku', file);
    if (!fs.lstatSync(source).isFile()) throw new Error('Roku file must be a regular file: ' + file);
    const target = path.join(destination, file);
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.copyFileSync(source, target);
  }
  for (const file of ['LICENSE', 'NOTICE.md']) fs.copyFileSync(path.join(root, file), path.join(destination, file));
}
module.exports = { files, root, stageRuntime, rokuFiles, stageRoku };
