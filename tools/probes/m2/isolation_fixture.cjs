// Development-only adversarial fixture. No real contract or user secret data.
const fs = require('node:fs');
const net = require('node:net');
const assert = require('node:assert/strict');
let input = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', chunk => {
  input += chunk;
  if (input.length > 8192) process.exit(3);
});
process.stdin.on('end', async () => {
  try {
    const frame = JSON.parse(input);
    const namespaces = Object.fromEntries(['user', 'pid', 'net', 'mnt'].map(name =>
      [name, fs.readlinkSync('/proc/self/ns/' + name)]));
    for (const name of Object.keys(namespaces).filter(name => name !== 'net' || frame.networkBoundary !== 'seccomp'))
      assert.notEqual(namespaces[name], frame.namespaces[name], name + ' namespace was not isolated');
    assert.equal(process.env.BUSYAPI_PROBE_PRIVATE, undefined);
    assert.equal(process.env.NODE_OPTIONS, undefined);
    assert.equal(process.env.NODE_PATH, undefined);
    for (const path of [frame.canary, '/etc/passwd', '/proc/1/root' + frame.canary]) {
      assert.throws(() => fs.readFileSync(path), error =>
        ['ENOENT', 'EACCES', 'EPERM'].includes(error.code));
    }
    assert.throws(() => fs.writeFileSync('/busyapi/fixture.cjs', 'changed'), error =>
      ['EROFS', 'EACCES', 'EPERM'].includes(error.code));
    assert.throws(() => fs.writeFileSync('/busyapi/new-file', 'changed'), error =>
      ['EROFS', 'EACCES', 'EPERM'].includes(error.code));
    const connection = await new Promise((resolve, reject) => {
      const socket = net.connect({host: '127.0.0.1', port: frame.port});
      socket.on('connect', () => {socket.destroy(); reject(Error('Reached the host namespace listener'));});
      socket.on('error', error => resolve(error.code));
      socket.setTimeout(1000, () => {socket.destroy(); reject(Error('Network denial did not finish'));});
    });
    assert(['ECONNREFUSED', 'ENETUNREACH', 'EACCES', 'EPERM'].includes(connection));
    // Real code still works on explicit input; a denial-only smoke is not a
    // demonstration that approved project functions could execute usefully.
    const findings = frame.example.title ? [] : [{code: 'missing-title', path: ['title']}];
    assert.deepEqual(findings, [{code: 'missing-title', path: ['title']}]);
    process.stdout.write(JSON.stringify({version: 1, complete: true,
      namespaces: Object.keys(namespaces).filter(name => name !== 'net' || frame.networkBoundary !== 'seccomp'), hostFilesystem: 'denied',
      codeWrites: 'denied', inheritedEnvironment: 'absent',
      hostNetwork: connection, findings}) + '\n');
  } catch (error) {
    // This fixture contains no actual data, but retain the production habit of
    // keeping operational diagnostics separate from the machine response.
    process.stderr.write(String(error) + '\n');
    process.exitCode = 2;
  }
});
