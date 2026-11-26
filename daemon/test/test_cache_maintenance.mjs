import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import http from 'node:http';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { maintainCache } from '../cache-maintenance.mjs';

async function fixture(t, responder) {
  const base = await fs.mkdtemp(path.join(await fs.realpath(os.tmpdir()), 'lfs-cache-test-'));
  t.after(() => fs.rm(base, { recursive: true, force: true }));
  const repo = path.join(base, 'worker'), remote = path.join(base, 'origin.git');
  const git = (...args) => execFileSync('git', ['-C', repo, ...args], { stdio: ['ignore', 'pipe', 'ignore'] }).toString().trim();
  execFileSync('git', ['init', '--bare', remote], { stdio: 'ignore' });
  execFileSync('git', ['clone', remote, repo], { stdio: 'ignore' });
  await fs.writeFile(path.join(repo, 'source.md'), 'worktree source must survive');
  const requests = [];
  const server = http.createServer(async (request, response) => {
    const chunks = []; for await (const chunk of request) chunks.push(chunk);
    const raw = Buffer.concat(chunks).toString();
    let body; try { body = JSON.parse(raw); } catch { body = {}; }
    requests.push({ method: request.method, url: request.url, body, authorization: request.headers.authorization });
    response.setHeader('Content-Type', 'application/vnd.git-lfs+json');
    if (responder) return responder(body, response, request);
    response.end(JSON.stringify(ack(body)));
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise((resolve) => { server.close(resolve); server.closeAllConnections(); }));
  git('remote', 'set-url', 'origin', `http://127.0.0.1:${server.address().port}/owner/repo.git`);
  const root = path.join(repo, '.git', 'lfs', 'objects');
  await fs.mkdir(root, { recursive: true });
  const put = async (body) => {
    const oid = createHash('sha256').update(body).digest('hex');
    const filename = path.join(root, oid.slice(0, 2), oid.slice(2, 4), oid);
    await fs.mkdir(path.dirname(filename), { recursive: true }); await fs.writeFile(filename, body);
    return { oid, filename, body, size: body.length };
  };
  const run = (options = {}, deps = {}) => maintainCache({ repoDir: repo, budgetBytes: 0, targetFreeBytes: 0,
    ...options }, { allowHttpLoopback: true, env: { GIT_TOKEN: 'dummy-secret-token' }, ...deps });
  return { base, repo, git, root, put, run, requests };
}
const ack = (request) => ({ transfer: 'basic', objects: request.objects.map((object) => ({ ...object,
  actions: { download: { href: 'https://download.invalid/object?signature=private-signed-url' } } })) });
const exists = async (filename) => fs.access(filename).then(() => true, () => false);

test('default dry-run verifies recoverability without changing cache, source or refs', async (t) => {
  const f = await fixture(t); const object = await f.put(Buffer.from('recoverable bytes'));
  const report = await f.run();
  assert.equal(report.status, 'dry_run'); assert.equal(report.verifiedObjects, 1); assert.equal(report.removedBytes, 0);
  assert.equal(await exists(object.filename), true);
  assert.equal(await fs.readFile(path.join(f.repo, 'source.md'), 'utf8'), 'worktree source must survive');
  assert.equal(f.requests.length, 1); assert.equal(f.requests[0].body.operation, 'download');
  assert.equal(f.requests[0].authorization, 'Basic ' + Buffer.from('x-access-token:dummy-secret-token').toString('base64'));
  const output = JSON.stringify(report);
  for (const secret of ['dummy-secret-token', 'private-signed-url', object.oid, 'source.md', 'download.invalid']) assert.equal(output.includes(secret), false);
});

test('apply only evicts exact locally hashed, remotely acknowledged LFS cache objects', async (t) => {
  const f = await fixture(t); const a = await f.put(Buffer.from('first')); const b = await f.put(Buffer.from('second'));
  const report = await f.run({ apply: true });
  assert.equal(report.status, 'complete'); assert.equal(report.removedObjects, 2); assert.equal(report.removedBytes, a.size + b.size);
  assert.equal(await exists(a.filename), false); assert.equal(await exists(b.filename), false);
  assert.equal(await exists(path.join(f.repo, 'source.md')), true);
  assert.equal(await exists(path.join(f.repo, '.git', 'HEAD')), true);
  assert.ok(f.requests.every((request) => request.method === 'POST' && request.body.operation === 'download'));
});

test('GitHub application/json batch response acknowledges exact recoverable objects', async (t) => {
  const f = await fixture(t, (body, response) => {
    response.setHeader('Content-Type', 'application/json; charset=utf-8');
    response.end(JSON.stringify({ objects: body.objects.map((object) => ({ ...object,
      authenticated: true, actions: { download: {
        href: 'https://download.invalid/object?signature=private-signed-url',
        expires_in: 3600, expires_at: new Date(Date.now() + 3600000).toISOString(),
      } },
    })) }));
  });
  const object = await f.put(Buffer.from('GitHub response compatibility'));
  const report = await f.run({ apply: true });
  assert.equal(report.status, 'complete'); assert.equal(report.removedObjects, 1);
  assert.equal(await exists(object.filename), false);
  assert.equal(JSON.stringify(report).includes(object.oid), false);
  assert.equal(JSON.stringify(report).includes('private-signed-url'), false);
});

test('401, redirects, missing remote objects and malformed responses preserve every cache object', async (t) => {
  const cases = [
    (_, r) => { r.statusCode = 401; r.end('private unauthorized body'); },
    (_, r) => { r.statusCode = 302; r.setHeader('Location', 'https://untrusted.invalid/token'); r.end(); },
    (_, r) => r.end('not json signed-secret'),
    (b, r) => r.end(JSON.stringify({ objects: [{ ...ack(b).objects[0], oid: 'f'.repeat(64) }] })),
    (b, r) => r.end(JSON.stringify({ objects: [{ ...ack(b).objects[0], size: b.objects[0].size + 1 }] })),
    (_, r) => r.end(JSON.stringify({ objects: [] })),
    (b, r) => r.end(JSON.stringify({ objects: b.objects.map(({ oid, size }) => ({ oid, size })) })),
    (b, r) => { const result = ack(b); result.objects[0].actions.download.expires_in = 0; r.end(JSON.stringify(result)); },
    (b, r) => { const result = ack(b); result.objects[0].actions.download.expires_at = '2000-01-01T00:00:00Z'; r.end(JSON.stringify(result)); },
    (b, r) => { const result = ack(b); result.objects[0].actions.download.header = { Authorization: 42 }; r.end(JSON.stringify(result)); },
  ];
  for (const responder of cases) await t.test('rejects invalid recovery acknowledgement', async (t) => {
    const f = await fixture(t, responder); const object = await f.put(Buffer.from('must remain'));
    const report = await f.run({ apply: true });
    assert.equal(report.status, 'blocked'); assert.equal(report.removedObjects, 0);
    assert.equal(await exists(object.filename), true);
    assert.equal(f.requests.length, 1);
    assert.equal(JSON.stringify(report).includes('private'), false);
  });
});

test('all batches must acknowledge before the first eviction', async (t) => {
  let calls = 0;
  const f = await fixture(t, (body, response) => {
    if (++calls === 2) { response.statusCode = 401; response.end(); }
    else response.end(JSON.stringify(ack(body)));
  });
  const a = await f.put(Buffer.from('a')), b = await f.put(Buffer.from('b'));
  const report = await f.run({ apply: true, batchSize: 1 });
  assert.equal(report.removedObjects, 0); assert.equal(report.status, 'blocked');
  assert.equal(await exists(a.filename), true); assert.equal(await exists(b.filename), true);
});

test('mixed complete batch preserves 404 objects while evicting only exact remote ACKs', async (t) => {
  let missingOid;
  const f = await fixture(t, (body, response) => {
    const result = ack(body);
    result.objects = result.objects.map((object) => object.oid === missingOid
      ? { oid: object.oid, size: object.size, error: { code: 404, message: 'not uploaded' } } : object);
    response.end(JSON.stringify(result));
  });
  const missing = await f.put(Buffer.from('unpushed cache bytes')); missingOid = missing.oid;
  const good = await f.put(Buffer.from('recoverable cache bytes'));
  const report = await f.run({ apply: true });
  assert.equal(report.removedObjects, 1); assert.equal(report.verifiedObjects, 1); assert.equal(report.skipped.remote_unavailable, 1);
  assert.equal(report.status, 'incomplete'); assert.equal(await exists(missing.filename), true); assert.equal(await exists(good.filename), false);
});

test('per-object 404 in one batch cannot block verified objects in another; all 404 evicts nothing', async (t) => {
  let allMissing = false, missingOid;
  const f = await fixture(t, (body, response) => response.end(JSON.stringify({ objects: body.objects.map((object) =>
    allMissing || object.oid === missingOid ? { ...object, error: { code: 404, message: 'not uploaded' } } : ack({ objects: [object] }).objects[0]) })));
  const missing = await f.put(Buffer.from('keep missing')); missingOid = missing.oid;
  const good = await f.put(Buffer.from('reclaim good'));
  let report = await f.run({ apply: true, batchSize: 1 });
  assert.equal(f.requests.length, 2); assert.equal(report.removedObjects, 1);
  assert.equal(await exists(missing.filename), true); assert.equal(await exists(good.filename), false);
  allMissing = true;
  report = await f.run({ apply: true });
  assert.equal(report.removedObjects, 0); assert.equal(report.reason, 'no_remote_recoverable_objects');
  assert.equal(await exists(missing.filename), true);
});

test('count-only cursor reaches recoverable objects after an all-404 bounded prefix', async (t) => {
  const unavailable = new Set();
  const f = await fixture(t, (body, response) => response.end(JSON.stringify({ objects: body.objects.map((object) =>
    unavailable.has(object.oid) ? { ...object, error: { code: 404, message: 'not uploaded' } }
      : ack({ objects: [object] }).objects[0]) })));
  const bodies = Array.from({ length: 5 }, (_, index) => Buffer.from(`cursor fixture ${index}`));
  bodies.sort((a, b) => createHash('sha256').update(b).digest('hex').localeCompare(createHash('sha256').update(a).digest('hex')));
  const objects = [];
  for (const body of bodies) objects.push(await f.put(body));
  objects.sort((a, b) => a.oid.localeCompare(b.oid));
  objects.slice(0, 2).forEach((object) => unavailable.add(object.oid));
  const limits = { apply: true, maxObjects: 2, maxBytes: 4096 };
  let report = await f.run(limits);
  assert.equal(report.reason, 'no_remote_recoverable_objects'); assert.equal(report.removedObjects, 0);
  assert.equal(report.nextCursor, 2);
  assert.deepEqual(f.requests[0].body.objects.map((object) => object.oid), objects.slice(0, 2).map((object) => object.oid));
  let removed = 0;
  for (let round = 0; round < 3; round++) {
    report = await f.run({ ...limits, cursor: report.nextCursor }); removed += report.removedObjects;
    assert.ok(Number.isSafeInteger(report.nextCursor) && report.nextCursor >= 0);
    assert.ok(report.candidateObjects <= 2); assert.ok(report.candidateBytes <= 4096);
  }
  assert.equal(removed, 3);
  for (const object of objects) assert.equal(await exists(object.filename), unavailable.has(object.oid));
  for (const object of objects) assert.equal(JSON.stringify(report).includes(object.oid), false);
});

test('oversized first object cannot starve smaller recoverable objects or exceed byte budget', async (t) => {
  const f = await fixture(t);
  const large = await f.put(Buffer.alloc(4096, 3));
  let body;
  for (let index = 0; ; index++) {
    body = Buffer.from(`small ${index}`);
    if (createHash('sha256').update(body).digest('hex') > large.oid) break;
  }
  const small = await f.put(body);
  const report = await f.run({ apply: true, maxBytes: 1024, maxObjects: 1 });
  assert.equal(report.removedObjects, 1); assert.equal(report.removedBytes, small.size);
  assert.equal(report.skipped.byte_limit, 1); assert.ok(report.candidateBytes <= 1024);
  assert.equal(await exists(large.filename), true); assert.equal(await exists(small.filename), false);
});

test('invalid cursors fail closed before requests or changes', async (t) => {
  const f = await fixture(t); const object = await f.put(Buffer.from('must remain'));
  for (const cursor of [-1, 0.5, Infinity, Number.MAX_SAFE_INTEGER + 1, '1']) {
    const report = await f.run({ apply: true, cursor });
    assert.equal(report.reason, 'invalid_limits'); assert.equal(report.removedObjects, 0);
    assert.equal(await exists(object.filename), true); assert.equal(f.requests.length, 0);
  }
});

test('corruption, hardlinks and symlinks are preserved and never advertised as verified', async (t) => {
  const f = await fixture(t);
  const bad = await f.put(Buffer.from('good')), linked = await f.put(Buffer.from('linked')), symbolic = await f.put(Buffer.from('symlink'));
  await fs.writeFile(bad.filename, 'evil'); await fs.link(linked.filename, path.join(f.base, 'hardlink-copy'));
  await fs.unlink(symbolic.filename); await fs.symlink(path.join(f.repo, 'source.md'), symbolic.filename);
  const report = await f.run({ apply: true });
  assert.equal(report.status, 'blocked'); assert.equal(report.removedObjects, 0); assert.equal(f.requests.length, 0);
  assert.equal(await exists(bad.filename), true); assert.equal(await exists(linked.filename), true);
  assert.equal((await fs.lstat(symbolic.filename)).isSymbolicLink(), true);
  assert.equal(report.skipped.hash_mismatch, 1); assert.equal(report.skipped.hardlink, 1); assert.equal(report.skipped.symlink, 1);
});

test('streaming hashes use bounded reads and reject content/inode changes before unlink', async (t) => {
  const f = await fixture(t); const body = Buffer.alloc(3 * 1024 * 1024, 7); const object = await f.put(body);
  let largest = 0, calls = 0;
  const report = await f.run({ apply: true }, { afterChunk: async (_, size) => { largest = Math.max(largest, size); calls++; },
    beforeUnlink: async () => { await fs.unlink(object.filename); await fs.writeFile(object.filename, body); } });
  assert.ok(calls > 1); assert.ok(largest <= 65536);
  assert.equal(report.removedObjects, 0); assert.equal(report.skipped.object_changed, 1);
  assert.equal(await exists(object.filename), true);
});

test('mutation during hashing is refused before remote requests', async (t) => {
  const f = await fixture(t); const object = await f.put(Buffer.alloc(131072, 8)); let changed = false;
  const report = await f.run({ apply: true }, { afterChunk: async () => {
    if (!changed) { changed = true; await fs.writeFile(object.filename, Buffer.alloc(131072, 9)); }
  } });
  assert.equal(report.removedObjects, 0); assert.equal(f.requests.length, 0); assert.equal(report.skipped.object_changed, 1);
});

test('object, byte and time budgets bound one recovery run', async (t) => {
  const f = await fixture(t); for (let i = 0; i < 5; i++) await f.put(Buffer.alloc(1024, i));
  const report = await f.run({ apply: true, maxObjects: 2, maxBytes: 2048, batchSize: 1 });
  assert.equal(report.removedObjects, 2); assert.equal(report.removedBytes, 2048); assert.equal(report.status, 'incomplete');
  assert.equal(f.requests.length, 2);
  let clock = 0;
  const expired = await f.run({ apply: true, maxSeconds: 1 }, { now: () => clock += 1000 });
  assert.equal(expired.removedObjects, 0); assert.equal(expired.reason, 'time_limit');
});

test('remote request timeout preserves cache without leaking response or credential data', async (t) => {
  const f = await fixture(t, () => {}); const object = await f.put(Buffer.from('keep'));
  const report = await f.run({ apply: true, requestTimeoutMs: 30 });
  assert.equal(report.reason, 'remote_request_failed'); assert.equal(report.removedObjects, 0);
  assert.equal(await exists(object.filename), true);
});

test('symlinked cache root and alternate configured endpoints are refused', async (t) => {
  const f = await fixture(t); const object = await f.put(Buffer.from('keep'));
  f.git('config', 'lfs.url', 'https://untrusted.invalid/owner/repo.git/info/lfs');
  let report = await f.run({ apply: true });
  assert.equal(report.reason, 'unsupported_lfs_endpoint'); assert.equal(f.requests.length, 0);
  f.git('config', '--unset', 'lfs.url');
  const saved = f.root + '-saved'; await fs.rename(f.root, saved); await fs.symlink(saved, f.root);
  report = await f.run({ apply: true });
  assert.equal(report.reason, 'unsafe_directory'); assert.equal(report.removedObjects, 0);
  assert.equal(await exists(path.join(saved, object.oid.slice(0, 2), object.oid.slice(2, 4), object.oid)), true);
});

test('existing URL credentials win and existing credential helper is queried without storing secrets', async (t) => {
  const f = await fixture(t); await f.put(Buffer.from('keep'));
  const original = f.git('remote', 'get-url', 'origin');
  const credentialUrl = new URL(original); credentialUrl.username = 'existing-user'; credentialUrl.password = 'existing-secret';
  f.git('remote', 'set-url', 'origin', credentialUrl.href);
  let report = await f.run(); assert.equal(report.status, 'dry_run');
  assert.equal(f.requests.at(-1).authorization, 'Basic ' + Buffer.from('existing-user:existing-secret').toString('base64'));
  f.git('remote', 'set-url', 'origin', original);
  f.git('config', 'credential.helper', '!f() { echo username=helper-user; echo password=helper-secret; }; f');
  report = await f.run({}, { env: {} }); assert.equal(report.status, 'dry_run');
  assert.equal(f.requests.at(-1).authorization, 'Basic ' + Buffer.from('helper-user:helper-secret').toString('base64'));
  assert.equal(JSON.stringify(report).includes('secret'), false);
});

test('response byte limit and unsafe repository LFS configuration fail closed', async (t) => {
  const f = await fixture(t, (_, response) => response.end('x'.repeat(2 * 1024 * 1024)));
  const object = await f.put(Buffer.from('must remain'));
  let report = await f.run({ apply: true });
  assert.equal(report.reason, 'remote_response_too_large'); assert.equal(report.removedObjects, 0);
  assert.equal(await exists(object.filename), true);
  await fs.writeFile(path.join(f.repo, '.lfsconfig'), '[lfs]\nurl = https://untrusted.invalid/repo/info/lfs\n');
  report = await f.run({ apply: true });
  assert.equal(report.reason, 'unsupported_lfs_endpoint'); assert.equal(report.removedObjects, 0);
});

test('replacing a cache parent with a symlink cannot redirect removal to source bytes', async (t) => {
  const f = await fixture(t); const object = await f.put(Buffer.from('same valid bytes'));
  const outside = path.join(f.base, 'outside'); await fs.mkdir(outside);
  const outsideObject = path.join(outside, object.oid); await fs.writeFile(outsideObject, object.body);
  const report = await f.run({ apply: true }, { beforeUnlink: async () => {
    const parent = path.dirname(object.filename); await fs.rename(parent, parent + '-preserved'); await fs.symlink(outside, parent);
  } });
  assert.equal(report.removedObjects, 0); assert.equal(await exists(outsideObject), true);
  assert.equal(await fs.readFile(outsideObject, 'utf8'), 'same valid bytes');
});
