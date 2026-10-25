// Packages the Roku channel as dist/airwave-roku-<version>.zip (manifest at the root, plus LICENSE and NOTICE.md).
// `--install` also side-loads it to a Roku in developer mode: set ROKU_HOST to its address and ROKU_DEV_PASSWORD to the
// developer password. The password is only sent as an HTTP digest response; it is never printed or written to disk.
const fs = require('node:fs');
const path = require('node:path');
const zlib = require('node:zlib');
const http = require('node:http');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');
const { root, rokuFiles } = require('./runtime-files.cjs');

const CRC_TABLE = Array.from({ length: 256 }, (_, n) => {
  let c = n;
  for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  return c >>> 0;
});
function crc32(buffer) {
  let c = 0xffffffff;
  for (const byte of buffer) c = CRC_TABLE[(c ^ byte) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

// A minimal ZIP writer: deflate when it helps, store otherwise, fixed timestamps so the same files give the same bytes.
function zip(entries) {
  const time = 0, date = ((2026 - 1980) << 9) | (1 << 5) | 1;
  const locals = [], centrals = [];
  let offset = 0;
  for (const { name, data } of entries) {
    const nameBytes = Buffer.from(name, 'utf8');
    const deflated = zlib.deflateRawSync(data, { level: 9 });
    const method = deflated.length < data.length ? 8 : 0;
    const body = method === 8 ? deflated : data;
    const crc = crc32(data);
    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0); local.writeUInt16LE(20, 4); local.writeUInt16LE(0x0800, 6); local.writeUInt16LE(method, 8);
    local.writeUInt16LE(time, 10); local.writeUInt16LE(date, 12); local.writeUInt32LE(crc, 14); local.writeUInt32LE(body.length, 18);
    local.writeUInt32LE(data.length, 22); local.writeUInt16LE(nameBytes.length, 26); local.writeUInt16LE(0, 28);
    const central = Buffer.alloc(46);
    central.writeUInt32LE(0x02014b50, 0); central.writeUInt16LE((3 << 8) | 20, 4); central.writeUInt16LE(20, 6); central.writeUInt16LE(0x0800, 8);
    central.writeUInt16LE(method, 10); central.writeUInt16LE(time, 12); central.writeUInt16LE(date, 14); central.writeUInt32LE(crc, 16);
    central.writeUInt32LE(body.length, 20); central.writeUInt32LE(data.length, 24); central.writeUInt16LE(nameBytes.length, 28);
    central.writeUInt32LE((0o100644 << 16) >>> 0, 38); central.writeUInt32LE(offset, 42);
    locals.push(local, nameBytes, body);
    centrals.push(central, nameBytes);
    offset += local.length + nameBytes.length + body.length;
  }
  const directory = Buffer.concat(centrals);
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0); end.writeUInt16LE(entries.length, 8); end.writeUInt16LE(entries.length, 10);
  end.writeUInt32LE(directory.length, 12); end.writeUInt32LE(offset, 16);
  return Buffer.concat([...locals, directory, end]);
}

function channelEntries() {
  const entries = rokuFiles.map(file => {
    const source = path.join(root, 'platforms', 'roku', file);
    if (!fs.lstatSync(source).isFile()) throw new Error('Roku file must be a regular file: ' + file);
    return { name: file, data: fs.readFileSync(source) };
  });
  for (const file of ['LICENSE', 'NOTICE.md']) entries.push({ name: file, data: fs.readFileSync(path.join(root, file)) });
  return entries;
}

function md5(text) { return crypto.createHash('md5').update(text).digest('hex'); }

// ROKU_HOST is the device address; an optional :port is accepted for testing against a local stand-in.
function request(address, headers, body) {
  const [, host, port] = /^(.*?)(?::(\d+))?$/.exec(address);
  return new Promise((resolve, reject) => {
    const req = http.request({ host, port: Number(port) || 80, path: '/plugin_install', method: 'POST', headers: { ...headers, 'Content-Length': body.length }, timeout: 120000 }, res => {
      const chunks = [];
      res.on('data', chunk => chunks.push(chunk));
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body: Buffer.concat(chunks).toString('utf8') }));
    });
    req.on('timeout', () => req.destroy(new Error('The Roku did not answer within two minutes.')));
    req.on('error', reject);
    req.end(body);
  });
}

// HTTP digest (RFC 7616, MD5, qop=auth) against the Roku developer web server, user "rokudev".
async function install(file) {
  const host = process.env.ROKU_HOST, password = process.env.ROKU_DEV_PASSWORD;
  if (!host || !password) throw new Error('Set ROKU_HOST and ROKU_DEV_PASSWORD to install on a Roku in developer mode.');
  const boundary = '----airwave' + crypto.randomBytes(12).toString('hex');
  const body = Buffer.concat([
    Buffer.from('--' + boundary + '\r\nContent-Disposition: form-data; name="mysubmit"\r\n\r\nInstall\r\n'),
    Buffer.from('--' + boundary + '\r\nContent-Disposition: form-data; name="archive"; filename="' + path.basename(file) + '"\r\nContent-Type: application/zip\r\n\r\n'),
    fs.readFileSync(file),
    Buffer.from('\r\n--' + boundary + '--\r\n'),
  ]);
  const contentType = { 'Content-Type': 'multipart/form-data; boundary=' + boundary };
  const challenge = await request(host, contentType, Buffer.alloc(0));
  const header = String(challenge.headers['www-authenticate'] || '');
  if (challenge.status !== 401 || !/^Digest /i.test(header)) throw new Error('The Roku at ' + host + ' did not ask for developer sign-in (HTTP ' + challenge.status + '). Is developer mode on?');
  const field = name => (new RegExp(name + '="?([^",]*)"?', 'i').exec(header) || [])[1] || '';
  const realm = field('realm'), nonce = field('nonce'), opaque = field('opaque'), qop = /auth/.test(field('qop')) ? 'auth' : '';
  const cnonce = crypto.randomBytes(8).toString('hex'), nc = '00000001', uri = '/plugin_install';
  const ha1 = md5('rokudev:' + realm + ':' + password), ha2 = md5('POST:' + uri);
  const response = qop ? md5([ha1, nonce, nc, cnonce, qop, ha2].join(':')) : md5([ha1, nonce, ha2].join(':'));
  let authorization = 'Digest username="rokudev", realm="' + realm + '", nonce="' + nonce + '", uri="' + uri + '", response="' + response + '", algorithm=MD5';
  if (qop) authorization += ', qop=' + qop + ', nc=' + nc + ', cnonce="' + cnonce + '"';
  if (opaque) authorization += ', opaque="' + opaque + '"';
  const result = await request(host, { ...contentType, Authorization: authorization }, body);
  if (result.status === 401) throw new Error('The Roku rejected the developer password.');
  const message = (/Install Success|Identical to previous version|Install Failure[^<]*/i.exec(result.body) || [])[0];
  if (result.status !== 200 || !message || /Failure/i.test(message)) throw new Error('Install failed (HTTP ' + result.status + ')' + (message ? ': ' + message : '.'));
  return message;
}

async function main() {
  const check = spawnSync(process.execPath, [path.join(root, 'scripts/check.cjs')], { stdio: 'inherit' });
  if (check.status !== 0) process.exit(check.status || 1);
  fs.mkdirSync(path.join(root, 'dist'), { recursive: true });
  const output = path.join(root, 'dist', 'airwave-roku-' + require('../package.json').version + '.zip');
  fs.writeFileSync(output, zip(channelEntries()));
  const test = spawnSync('unzip', ['-tq', output], { encoding: 'utf8' });
  if (test.error) console.log('unzip is unavailable; archive written without an integrity check.');
  else if (test.status !== 0) throw new Error('Archive check failed:\n' + test.stdout + test.stderr);
  console.log('Roku channel packaged: ' + output + '\nSide-load it from the Roku developer page, or run with --install and ROKU_HOST/ROKU_DEV_PASSWORD.');
  if (process.argv.includes('--install')) console.log('Roku: ' + await install(output));
}

if (require.main === module) main().catch(error => { console.error(error.message); process.exit(1); });
module.exports = { zip, crc32, channelEntries };
