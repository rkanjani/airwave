// Roku channel: BrightScript core parity with app/core.js under the brs-node simulator, the channel file
// allowlist, manifest version and BrighterScript validation. Synthetic fixtures only; no network.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const core = require('../app/core.js');
const { root, rokuFiles } = require('../scripts/runtime-files.cjs');

const roku = path.join(root, 'platforms', 'roku');
const fixtures = path.join(__dirname, 'fixtures');
const BASE = 'https://lists.example/iptv/list.m3u';

// Deterministic pseudo-random ASCII and BMP strings for hash parity.
function generated() {
  let seed = 7;
  const next = () => (seed = (seed * 1103515245 + 12345) % 2147483648);
  const out = [];
  for (let n = 0; n < 40; n++) {
    let s = '';
    const length = next() % 60;
    for (let i = 0; i < length; i++) s += String.fromCharCode(n % 4 === 0 ? 0x20 + next() % 0x5f : 0x20 + next() % 0xd7d0);
    out.push(s);
  }
  return out;
}
const hashInputs = ['', 'a', 'Airwave', 'http://x.example/', 'https://live.example/live/user/pass/1001.ts', 'é', 'Café Ünïcode', '日本語のチャンネル', 'Ελληνικά', ' •·', 'x'.repeat(2000), '😀', 'a😀b', '𝐁𝐨𝐥𝐝 Name', ...generated()];

const urlCases = [
  ['http://a.example/x', null], ['HTTPS://A.Example:443/X?Q#F', null], ['http://a.example:80', null], ['http://a.example:8080/', null],
  ['http://a.example:0080/p', null], ['http://a.example:/p', null], ['http://user:pass@a.example/p', null], ['http://user:@a.example/', null],
  ['http://:pass@a.example/', null], ['http://@a.example/', null], ['http://a.example/a/b/../c/./d', null], ['http://a.example/a/b/..', null],
  ['http://a.example/a/b/.', null], ['http://a.example/../x', null], ['http://a.example/a b?c d#e f', null], ['http://a.example/"<>`{}?"<>\'#"<>`', null],
  ['http://a.example/é?é#é', null], ['http://a.example/%20already', null], ['http://a.example\\b\\c?d\\e', null], ['http:/a.example/p', null],
  ['http:///a.example/p', null], ['http://a.example?', null], ['http://a.example#', null], ['ftp://a.example/x', null], ['rtmp://a.example/x', null],
  ['javascript:alert(1)', null], ['/relative/no-base', null], ['', null], ['   ', null], ['http://', null], ['http://a.example:99999/', null],
  ['http://a.example:12ab/', null], ['http://a b.example/', null], ['http://[::1]:8080/x', null],
  ['/abs/path.ts', BASE], ['rel/path.ts', BASE], ['../up.ts', BASE], ['./same.ts', BASE], ['?q=1', BASE], ['//cdn.example/p', BASE],
  ['https:other.ts', BASE], ['http:other.ts', BASE], ['https://override.example/', BASE], ['a.example:8080/x', BASE], ['logo.png', 'http://img.example'],
  ['  http://a.example/trim  ', null], ['http://a.example/tab\there', null],
];

const streamCases = [
  ['https://s.example/live/1.m3u8', 'live'], ['https://s.example/live/1.M3U8?token=a', 'live'], ['https://s.example/live/u/p/1.ts', 'live'],
  ['https://s.example/live/u/p/1.TS?token=a.ts', 'live'], ['https://s.example/live/u/p/1', 'live'], ['https://s.example/play.php?id=3', 'live'],
  ['https://s.example/m/1.mp4', 'movie'], ['https://s.example/m/1.MOV', 'movie'], ['https://s.example/m/1.m4v#t=1', 'movie'],
  ['https://s.example/m/1.mkv', 'movie'], ['https://s.example/m/1.avi', 'movie'], ['https://s.example/m/1.avi', 'live'],
  ['https://s.example/m/1.ts', 'movie'], ['https://s.example/m/1.webm', 'movie'], ['https://s.example/m/manifest.mpd', 'movie'], ['https://s.example', 'live'],
];
const streamExpected = [
  ['https://s.example/live/1.m3u8', 'hls', ''], ['https://s.example/live/1.M3U8?token=a', 'hls', ''], ['https://s.example/live/u/p/1.m3u8', 'hls', ''],
  ['https://s.example/live/u/p/1.m3u8?token=a.ts', 'hls', ''], ['https://s.example/live/u/p/1', 'hls', ''], ['https://s.example/play.php?id=3', 'hls', ''],
  ['https://s.example/m/1.mp4', 'mp4', ''], ['https://s.example/m/1.MOV', 'mp4', ''], ['https://s.example/m/1.m4v#t=1', 'mp4', ''],
  ['https://s.example/m/1.mkv', 'mkv', ''], ['https://s.example/m/1.avi', '', 'AVI'], ['https://s.example/m/1.avi', '', 'AVI'],
  ['https://s.example/m/1.ts', '', ''], ['https://s.example/m/1.webm', '', ''], ['https://s.example/m/manifest.mpd', 'dash', ''], ['https://s.example', 'hls', ''],
];

const tidyCases = [
  ['US: NEWS CHANNEL HD', 'US | News', 'live'], ['[UK] Cartoon Planet FHD', 'Kids', 'live'], ['UK | BBC ONE HD', 'UK', 'live'], ['CSI: Miami', 'Drama', 'movie'],
  ['Sports: Match Day', 'Sports', 'live'], ['Classic Feature 4K HDR', 'Cinema Club', 'movie'], ['Nature 720p 60 fps', 'Documentary', 'movie'],
  ['ESPN NEWS RAW', 'Sports', 'live'], ['THE LORD OF THE RINGS', 'Movies', 'movie'], ['Raw Deal', 'Movies', 'movie'], ['HD', '', 'live'],
  ['## ==  Divider ==  ##', '', 'live'], ['(FHD) Weather 24/7 HEVC 50fps', 'News', 'live'], ['SLING: 123 GO!', 'Sling', 'live'],
  ['A&E HD', 'US', 'live'], ['NBA TV-HD 1080p', 'Sports', 'live'], ['ROCKY II', 'Movies', 'movie'], ['PART-TIME AND FULL-TIME', '', 'movie'],
  ['DE | Sport 1 SD 576i', 'Germany', 'live'], ['[]', '', 'live'], ['  ', '', 'live'], ['Plain Name', '', 'live'],
];

const filterCases = [['', '', ''], ['news', '', ''], ['SPORTS', '', ''], ['', 'Sports', ''], ['', '', 'movie'], ['film', '', 'movie'], ['nothing here', '', ''], ['  match  ', 'All', 'live']];

function writeTemp(directory, name, text) { fs.writeFileSync(path.join(directory, name), text); }

let harness;
function runHarness() {
  if (harness) return harness;
  const app = fs.mkdtempSync(path.join(os.tmpdir(), 'airwave-roku-test-'));
  try {
    fs.mkdirSync(path.join(app, 'source'));
    fs.copyFileSync(path.join(fixtures, 'roku-harness.brs'), path.join(app, 'source', 'main.brs'));
    fs.copyFileSync(path.join(roku, 'source', 'core.brs'), path.join(app, 'source', 'core.brs'));
    for (const name of ['playlist.m3u', 'catalog-v2.json']) fs.copyFileSync(path.join(fixtures, name), path.join(app, name));
    writeTemp(app, 'not-m3u.txt', '<html>Not a playlist</html>');
    writeTemp(app, 'no-streams.m3u', '#EXTM3U\n#EXTINF:-1,Only RTMP\nrtmp://live.example/x\n');
    writeTemp(app, 'leading-space.m3u', '\n   #EXTM3U\nhttps://s.example/a.m3u8\n');
    writeTemp(app, 'too-many.m3u', '#EXTM3U\n' + Array.from({ length: 10001 }, (_, i) => 'https://s.example/' + i + '.m3u8').join('\n'));
    writeTemp(app, 'too-large.m3u', '#EXTM3U\n#' + 'x'.repeat(5 * 1024 * 1024));
    writeTemp(app, 'not-json.json', '{ "items": [ broken');
    writeTemp(app, 'wrong-version.json', JSON.stringify({ version: 3, name: 'x', items: [{ id: 'a', name: 'A', url: 'https://s.example/a.m3u8', kind: 'live' }] }));
    writeTemp(app, 'no-valid.json', JSON.stringify({ version: 2, items: [{ id: 'a', name: 'A', url: 'rtmp://s.example/a', kind: 'live' }] }));
    writeTemp(app, 'no-version.json', JSON.stringify({ items: [{ id: 'a', name: 'A', url: 'https://s.example/a.m3u8', kind: 'live' }] }));
    const input = {
      hash: hashInputs, url: urlCases, stream: streamCases, tidy: tidyCases, filter: filterCases,
      m3u: [['playlist.m3u', BASE], ['playlist.m3u', null], ['not-m3u.txt', BASE], ['no-streams.m3u', BASE], ['leading-space.m3u', BASE], ['too-many.m3u', BASE], ['too-large.m3u', BASE]],
      catalog: ['catalog-v2.json', 'not-json.json', 'wrong-version.json', 'no-valid.json', 'no-version.json'],
      clock: [0, -5, 59.9, 61, 3599, 3600, 3725, 86399],
      groups: ['US | News', 'UK | News', 'Sports HD', 'Sports SD', 'Movies', 'MOVIES'],
      favorites: ['aaaaaaaaaa', 'bbbbbbbbbb', 'cccccccccc', 'dddddddddd', 'eeeeeeeeee', 42],
      progress: { old: { t: 100, d: 200, u: 1 }, mid: { t: 100, d: 200, u: 5 }, new: { t: 100, d: 200, u: 9 }, bad: { t: 'x', d: 1, u: 1 } },
    };
    writeTemp(app, 'input.json', JSON.stringify(input));
    const cli = path.join(root, 'node_modules', 'brs-node', 'bin', 'brs.cli.js');
    const run = spawnSync(process.execPath, [cli, '-n', '-r', app], { encoding: 'utf8', timeout: 60000, maxBuffer: 64 * 1024 * 1024 });
    const line = (run.stdout || '').split('\n').find(x => x.startsWith('AIRWAVE_RESULT '));
    assert.ok(line, 'brs-node harness produced no result:\n' + run.stdout + run.stderr);
    harness = JSON.parse(line.slice('AIRWAVE_RESULT '.length));
    return harness;
  } finally { fs.rmSync(app, { recursive: true, force: true }); }
}

function jsParse(text, base) { try { return { items: core.parseM3U(text, base), error: '' }; } catch (e) { return { items: [], error: e.message }; } }

test('BrightScript hash equals the JavaScript hash, including astral characters', () => {
  assert.deepEqual(runHarness().hash, hashInputs.map(core.hash));
});

test('BrightScript URL normalisation matches the URL parser for playlist cases', () => {
  const expected = urlCases.map(([value, base]) => core.httpUrl(value, base || undefined));
  runHarness().url.forEach((actual, i) => assert.equal(actual, expected[i], 'URL case ' + JSON.stringify(urlCases[i])));
});

test('BrightScript M3U parsing matches parseM3U on the synthetic playlist and its errors', () => {
  const result = runHarness();
  const playlist = fs.readFileSync(path.join(fixtures, 'playlist.m3u'), 'utf8');
  const expected = jsParse(playlist, BASE);
  assert.equal(expected.error, '');
  assert.ok(expected.items.length >= 15, 'fixture should exercise many entries');
  assert.deepEqual(result.m3u[0], expected);
  // Without a base, relative entries are dropped in both.
  assert.deepEqual(result.m3u[1], jsParse(playlist, undefined));
  assert.deepEqual(result.m3u[2], jsParse('<html>Not a playlist</html>', BASE));
  assert.deepEqual(result.m3u[3], jsParse('#EXTM3U\n#EXTINF:-1,Only RTMP\nrtmp://live.example/x\n', BASE));
  assert.deepEqual(result.m3u[4], jsParse('\n   #EXTM3U\nhttps://s.example/a.m3u8\n', BASE));
  for (const [i, message] of [[5, 'This library has over 10,000 entries. Import a smaller playlist.'], [6, 'Playlist is too large. Use a playlist smaller than 5 MB.']]) {
    assert.deepEqual(result.m3u[i], { items: [], error: message });
  }
  // The fixture covers quoted commas, duplicates, relative URLs and each movie rule.
  const byName = Object.fromEntries(expected.items.map(x => [x.name, x]));
  assert.equal(byName['[UK] Cartoon Planet FHD'].group, 'Kids, Family');
  assert.equal(byName['Match Day, Live'].url, 'http://live.example/live/user/secret/1003.m3u8?token=abc%20def');
  assert.equal(byName['The Long Film (2019)'].kind, 'movie');
  assert.equal(byName['Plain Name'].kind, 'movie');
  assert.equal(byName['Nature 720p 60 fps'].kind, 'movie');
  assert.equal(expected.items.filter(x => x.url.endsWith('1001.ts')).length, 1);
});

test('catalog v2 keeps valid items and skips invalid ones', () => {
  const [valid, broken, version, none, unversioned] = runHarness().catalog;
  assert.equal(valid.error, '');
  assert.equal(valid.name, 'Synthetic Library');
  assert.deepEqual(valid.items.map(x => x.id), ['live-1', 'live-2', 'movie-1', 'movie-2']);
  assert.deepEqual(valid.items[0], { id: 'live-1', url: 'https://live.example/live/user/pass/1.ts', name: 'US: NEWS ONE HD', group: 'US | News', epgId: 'news.one', logo: 'https://img.example/1.png', kind: 'live', favorite: true, color: 2 });
  assert.equal(valid.items[1].group, 'Unsorted');
  assert.equal(valid.items[1].color, 1); // "13" -> 13 % 6
  assert.equal(valid.items[2].logo, ''); // ftp logo dropped
  assert.equal(valid.items[2].color, 3); // -2.5 -> |floor| % 6
  assert.equal(valid.items[3].favorite, false); // non-boolean favorite ignored
  assert.equal(valid.items[3].color, parseInt(core.hash('movie-2'), 36) % 6);
  assert.equal(broken.error, 'This is not an Airwave library file.');
  assert.equal(version.error, 'This library file uses an unsupported version.');
  assert.equal(none.error, 'This library has no HTTP or HTTPS entries.');
  assert.equal(unversioned.error, '');
  assert.equal(unversioned.name, 'My library');
});

test('stream format selection rewrites live MPEG-TS to HLS and refuses AVI', () => {
  runHarness().stream.forEach((actual, i) => {
    const [url, format, error] = streamExpected[i];
    assert.equal(actual.url, url, 'stream case ' + i);
    assert.equal(actual.format, format, 'stream case ' + i);
    if (error) assert.match(actual.error, /AVI files cannot play on Roku/); else assert.equal(actual.error, '');
  });
});

test('tidy names match tidyName for ASCII playlist names', () => {
  runHarness().tidy.forEach((actual, i) => {
    const [name, group, kind] = tidyCases[i];
    assert.deepEqual(actual, core.tidyName(name, { group, kind }), 'tidy case ' + JSON.stringify(tidyCases[i]));
  });
  const groups = ['US | News', 'UK | News', 'Sports HD', 'Sports SD', 'Movies', 'MOVIES'];
  const labels = core.tidyGroups(groups);
  assert.deepEqual(runHarness().groups, groups.map(g => [g, labels[g]]));
});

test('search, clock, tone and registry bounds follow the shared rules', () => {
  const result = runHarness();
  const items = core.parseM3U(fs.readFileSync(path.join(fixtures, 'playlist.m3u'), 'utf8'), BASE);
  assert.deepEqual(result.filter, filterCases.map(([q, g, k]) => core.filter(items, q, g, k).map(x => x.id)));
  assert.deepEqual(result.clock, [0, -5, 59.9, 61, 3599, 3600, 3725, 86399].map(core.clock));
  assert.deepEqual(result.tone, [parseInt(core.hash('abc'), 36) % 6, 1, 3, parseInt(core.hash('abc'), 36) % 6]);
  // 60 bytes holds four 10-character IDs as JSON; the oldest goes and the non-string entry is dropped.
  assert.deepEqual(result.bounds.favorites, ['bbbbbbbbbb', 'cccccccccc', 'dddddddddd', 'eeeeeeeeee']);
  assert.deepEqual(Object.keys(result.bounds.progress).sort(), ['mid', 'new']);
  assert.deepEqual(result.bounds.resumable, [true, false, true, false, false]);
});

function walk(directory) {
  return fs.readdirSync(directory, { withFileTypes: true }).filter(entry => entry.name !== '.DS_Store').flatMap(entry => entry.isDirectory() ? walk(path.join(directory, entry.name)) : [path.relative(roku, path.join(directory, entry.name)).split(path.sep).join('/')]);
}

test('the Roku allowlist names exactly the channel files and the manifest version matches npm', () => {
  assert.deepEqual(walk(roku).sort(), [...rokuFiles].sort(), 'platforms/roku files must be allowlisted in scripts/runtime-files.cjs');
  const manifest = Object.fromEntries(fs.readFileSync(path.join(roku, 'manifest'), 'utf8').split(/\r?\n/).filter(x => /^\w+=/.test(x)).map(x => [x.slice(0, x.indexOf('=')), x.slice(x.indexOf('=') + 1)]));
  const version = require('../package.json').version;
  assert.equal([manifest.major_version, manifest.minor_version, manifest.build_version].map(Number).join('.'), version);
  assert.equal(manifest.title, 'Airwave');
  for (const key of ['mm_icon_focus_fhd', 'mm_icon_focus_hd', 'splash_screen_fhd', 'splash_screen_hd']) {
    assert.ok(rokuFiles.includes(manifest[key].replace(/^pkg:\//, '')), key + ' must point at an allowlisted image');
  }
  for (const file of rokuFiles.filter(x => x.endsWith('.xml'))) {
    const xml = fs.readFileSync(path.join(roku, file), 'utf8');
    for (const match of xml.matchAll(/uri="pkg:\/([^"]+)"/g)) assert.ok(rokuFiles.includes(match[1]), file + ' references missing ' + match[1]);
  }
});

test('BrighterScript validates the channel without errors', () => {
  const cli = path.join(root, 'node_modules', 'brighterscript', 'dist', 'cli.js');
  const run = spawnSync(process.execPath, [cli, '--root-dir', roku, '--create-package', 'false', '--copy-to-staging', 'false', '--diagnostic-level', 'error', '--files', '**/*'], { cwd: root, encoding: 'utf8', timeout: 60000 });
  assert.equal(run.status, 0, 'bsc reported errors:\n' + run.stdout + run.stderr);
});

test('the Roku package is a valid zip with the manifest at its root', () => {
  const { zip, crc32, channelEntries } = require('../scripts/roku.cjs');
  assert.equal(crc32(Buffer.from('123456789')), 0xcbf43926);
  const entries = channelEntries();
  assert.deepEqual(entries.map(x => x.name), [...rokuFiles, 'LICENSE', 'NOTICE.md']);
  const archive = zip(entries);
  assert.deepEqual(zip(entries), archive, 'packaging is reproducible');
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'airwave-roku-zip-'));
  try {
    const file = path.join(directory, 'channel.zip');
    fs.writeFileSync(file, archive);
    const check = spawnSync('unzip', ['-tq', file], { encoding: 'utf8' });
    if (check.error) return; // unzip is not installed; the structure is still covered by the reproducibility check.
    assert.equal(check.status, 0, check.stdout + check.stderr);
    fs.mkdirSync(path.join(directory, 'out'));
    assert.equal(spawnSync('unzip', ['-q', file, '-d', path.join(directory, 'out')]).status, 0);
    for (const entry of entries) assert.deepEqual(fs.readFileSync(path.join(directory, 'out', entry.name)), entry.data, entry.name);
  } finally { fs.rmSync(directory, { recursive: true, force: true }); }
});
