#!/usr/bin/env node
// Derived LFS cache only. Primary protocol: git-lfs/docs/api/{batch,authentication}.md.
// No uploads, worktree edits, Git ref/history edits, credential writes or redirects.
import fs from 'node:fs/promises';
import { constants } from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';

const exec = promisify(execFile);
const OID = /^[a-f0-9]{64}$/;
const FANOUT = /^[a-f0-9]{2}$/;
const MiB = 1024 * 1024;
const defaults = { budgetBytes: 512 * MiB, targetFreeBytes: 256 * MiB,
  maxBytes: 2048 * MiB, maxObjects: 1024, maxSeconds: 120, batchSize: 64,
  requestTimeoutMs: 10000, maxScanEntries: 100000, cursor: 0, apply: false };

class Refusal extends Error { constructor(reason) { super(reason); this.reason = reason; } }
const refuse = (reason) => { throw new Refusal(reason); };
const fingerprint = (s) => [s.dev, s.ino, s.mode, s.nlink, s.size, s.mtimeNs, s.ctimeNs].join(':');
const directoryId = (s) => [s.dev, s.ino].join(':');
const safeInteger = (n) => Number.isSafeInteger(n) && n >= 0;

async function ordinaryDirectory(value) {
  const resolved = path.resolve(value);
  if (path.normalize(value) !== value || !path.isAbsolute(value)) refuse('nonliteral_repository');
  let current = path.parse(resolved).root;
  for (const part of resolved.slice(current.length).split(path.sep).filter(Boolean)) {
    current = path.join(current, part);
    const s = await fs.lstat(current, { bigint: true });
    if (!s.isDirectory() || s.isSymbolicLink()) refuse('unsafe_directory');
  }
  return resolved;
}

async function anchoredDirectory(value) {
  let directory = await fs.open(path.parse(value).root, constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW);
  try {
    for (const part of value.slice(path.parse(value).root.length).split(path.sep).filter(Boolean)) {
      const next = await fs.open(`/proc/self/fd/${directory.fd}/${part}`,
        constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW);
      await directory.close(); directory = next;
    }
    return directory;
  } catch (error) { await directory.close(); throw error; }
}

async function git(repo, args, input, remaining) {
  if (remaining() <= 0) refuse('time_limit');
  try {
    const result = await exec('git', ['-C', repo, ...args], {
      encoding: 'utf8', maxBuffer: 65536, timeout: Math.max(1, Math.min(10000, remaining())),
      env: { ...process.env, GIT_TERMINAL_PROMPT: '0', GIT_OPTIONAL_LOCKS: '0' },
      ...(input === undefined ? {} : { input }),
    });
    return result.stdout.trim();
  } catch { refuse('git_configuration_unavailable'); }
}

// execFile does not feed stdin; credential fill needs an explicitly bounded pipe.
async function credentials(repo, url, remaining, deps) {
  if (url.password) return 'Basic ' + Buffer.from(decodeURIComponent(url.username) + ':' + decodeURIComponent(url.password)).toString('base64');
  // bridge.sh composes a token-only username into its HTTPS origin URL.
  if (url.username) return 'Basic ' + Buffer.from('x-access-token:' + decodeURIComponent(url.username)).toString('base64');
  const token = (deps.env || process.env).GIT_TOKEN;
  if (token) return 'Basic ' + Buffer.from('x-access-token:' + token).toString('base64');
  const { spawn } = await import('node:child_process');
  const clean = new URL(url); clean.username = ''; clean.password = '';
  return await new Promise((resolve, reject) => {
    const child = spawn('git', ['-C', repo, 'credential', 'fill'], {
      stdio: ['pipe', 'pipe', 'ignore'],
      env: { ...process.env, GIT_TERMINAL_PROMPT: '0', GIT_ASKPASS: '/bin/false' },
    });
    let chunks = [], bytes = 0, settled = false;
    const timer = setTimeout(() => { child.kill('SIGKILL'); finish(); }, Math.max(1, Math.min(10000, remaining())));
    const finish = (value) => {
      if (settled) return;
      settled = true; clearTimeout(timer); chunks = [];
      value ? resolve(value) : reject(new Refusal('credentials_unavailable'));
    };
    child.on('error', () => finish());
    child.stdout.on('data', (chunk) => {
      bytes += chunk.length;
      if (bytes > 65536) { child.kill('SIGKILL'); finish(); } else chunks.push(chunk);
    });
    child.on('close', (code) => {
      if (settled) return;
      const fields = Object.fromEntries(Buffer.concat(chunks).toString('utf8').split('\n')
        .filter((line) => line.includes('=')).map((line) => { const i = line.indexOf('='); return [line.slice(0, i), line.slice(i + 1)]; }));
      if (code || !fields.password || !fields.username) return finish();
      finish('Basic ' + Buffer.from(fields.username + ':' + fields.password).toString('base64'));
    });
    child.stdin.on('error', () => {});
    child.stdin.end('url=' + clean.href + '\n\n');
  });
}

async function configuredEndpoint(repo, remaining, deps) {
  const remote = await git(repo, ['remote', 'get-url', 'origin'], undefined, remaining);
  let origin;
  try { origin = new URL(remote); } catch { refuse('unsupported_origin'); }
  const loopback = ['127.0.0.1', '[::1]', 'localhost'].includes(origin.hostname);
  if (origin.protocol !== 'https:' && !(deps.allowHttpLoopback && origin.protocol === 'http:' && loopback)) refuse('unsupported_origin');
  if (origin.search || origin.hash || !origin.pathname || origin.pathname === '/') refuse('unsupported_origin');
  const authorization = await credentials(repo, origin, remaining, deps);
  origin.username = ''; origin.password = '';
  const base = origin.href.replace(/\/$/, '').replace(/\.git$/, '') + '.git/info/lfs';
  let configured = '';
  // A configured same-origin endpoint is accepted, never an arbitrary URL supplied by CLI.
  for (const key of ['remote.origin.lfsurl', 'lfs.url']) {
    configured = await git(repo, ['config', '--default', '', '--get', key], undefined, remaining);
    if (configured) break;
  }
  if (!configured) {
    const file = path.join(repo, '.lfsconfig');
    try {
      const info = await fs.lstat(file);
      if (!info.isFile() || info.isSymbolicLink() || info.size > 65536) refuse('unsupported_lfs_configuration');
      configured = await git(repo, ['config', '--file', file, '--default', '', '--get', 'lfs.url'], undefined, remaining);
    } catch (error) { if (error.code !== 'ENOENT') throw error; }
  }
  let endpoint;
  try { endpoint = new URL(configured || base); } catch { refuse('unsupported_lfs_endpoint'); }
  const expected = new URL(base);
  if (endpoint.origin !== origin.origin || endpoint.pathname !== expected.pathname || endpoint.search || endpoint.hash
      || endpoint.username || endpoint.password) refuse('unsupported_lfs_endpoint');
  endpoint.pathname += '/objects/batch';
  return { endpoint, authorization };
}

async function freeBytes(repo, deps) {
  const s = await (deps.statfs || fs.statfs)(repo, { bigint: true });
  const value = Number(s.bavail * s.bsize);
  if (!safeInteger(value)) refuse('storage_probe_unavailable');
  return value;
}

async function scanCache(root, options, checkTime, report) {
  const candidates = [];
  let entries = 0;
  async function visit(folder, level, prefix = '') {
    const directory = await fs.opendir(folder);
    for await (const entry of directory) {
      checkTime();
      if (++entries > options.maxScanEntries) refuse('scan_limit');
      const filename = path.join(folder, entry.name);
      const s = await fs.lstat(filename, { bigint: true });
      if (s.isSymbolicLink()) { report.skipped.symlink = (report.skipped.symlink || 0) + 1; continue; }
      if (s.isDirectory() && level < 2 && FANOUT.test(entry.name)) {
        await visit(filename, level + 1, prefix + entry.name);
      } else if (s.isFile()) {
        const size = Number(s.size);
        if (!safeInteger(size)) refuse('unsupported_object_size');
        report.cacheBytes += size; report.scannedObjects++;
        if (level !== 2 || !OID.test(entry.name) || !entry.name.startsWith(prefix)) {
          report.skipped.layout = (report.skipped.layout || 0) + 1; continue;
        }
        if (s.nlink !== 1n) { report.skipped.hardlink = (report.skipped.hardlink || 0) + 1; continue; }
        candidates.push({ filename, parent: folder, oid: entry.name, size, fingerprint: fingerprint(s) });
      } else report.skipped.layout = (report.skipped.layout || 0) + 1;
    }
  }
  await visit(root, 0);
  // Stable order makes the count-only cursor independent of filesystem readdir
  // order. The scan-entry bound also bounds this metadata list; bytes are read
  // only for the separately bounded window selected below.
  return candidates.sort((left, right) => left.oid < right.oid ? -1 : left.oid > right.oid ? 1 : 0);
}

async function openCandidate(candidate, rootHandle) {
  let parent;
  if (rootHandle) {
    const first = await fs.open(`/proc/self/fd/${rootHandle.fd}/${candidate.oid.slice(0, 2)}`,
      constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW);
    try { parent = await fs.open(`/proc/self/fd/${first.fd}/${candidate.oid.slice(2, 4)}`,
      constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW); }
    finally { await first.close(); }
  } else {
    await ordinaryDirectory(candidate.parent);
    parent = await fs.open(candidate.parent, constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW);
  }
  const parentStat = await parent.stat({ bigint: true });
  // Linux production uses held directory descriptors, so replaced ancestors cannot redirect unlink.
  const filename = process.platform === 'linux' ? `/proc/self/fd/${parent.fd}/${candidate.oid}` : candidate.filename;
  return { parent, parentId: directoryId(parentStat), filename };
}

async function verifyCandidate(candidate, options, checkTime, deps, rootHandle) {
  const opened = await openCandidate(candidate, rootHandle);
  let file;
  try {
    file = await fs.open(opened.filename, constants.O_RDONLY | constants.O_NOFOLLOW);
    const before = await file.stat({ bigint: true });
    if (!before.isFile() || fingerprint(before) !== candidate.fingerprint) refuse('object_changed');
    const digest = createHash('sha256'), buffer = Buffer.alloc(65536);
    let position = 0;
    while (true) {
      checkTime();
      const { bytesRead } = await file.read(buffer, 0, buffer.length, position);
      if (!bytesRead) break;
      position += bytesRead; digest.update(buffer.subarray(0, bytesRead));
      await deps.afterChunk?.(candidate, bytesRead);
    }
    if (position !== candidate.size || fingerprint(await file.stat({ bigint: true })) !== candidate.fingerprint) refuse('object_changed');
    if (digest.digest('hex') !== candidate.oid) refuse('hash_mismatch');
    candidate.parentId = opened.parentId;
  } finally { await file?.close(); await opened.parent.close(); }
}

async function acknowledge(endpoint, authorization, candidates, options, remaining, deps) {
  const body = JSON.stringify({ operation: 'download', transfers: ['basic'], hash_algo: 'sha256',
    objects: candidates.map(({ oid, size }) => ({ oid, size })) });
  let response;
  try {
    response = await (deps.fetch || fetch)(endpoint, { method: 'POST', redirect: 'manual',
      headers: { Accept: 'application/vnd.git-lfs+json', 'Content-Type': 'application/vnd.git-lfs+json', Authorization: authorization },
      body, signal: AbortSignal.timeout(Math.max(1, Math.min(options.requestTimeoutMs, remaining()))) });
  } catch { refuse('remote_request_failed'); }
  if (response.status !== 200) { await response.body?.cancel(); refuse('remote_http_error'); }
  if (!/^application\/(?:vnd\.git-lfs\+json|json)(?:;|$)/i.test(response.headers.get('content-type') || '')) {
    await response.body?.cancel(); refuse('remote_response_invalid');
  }
  const reader = response.body?.getReader();
  if (!reader) refuse('remote_response_invalid');
  const chunks = []; let length = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      length += value.length;
      if (length > MiB) { await reader.cancel(); refuse('remote_response_too_large'); }
      chunks.push(value);
    }
  } catch (error) { if (error instanceof Refusal) throw error; refuse('remote_request_failed'); }
  let result;
  try { result = JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { refuse('remote_response_invalid'); }
  if (!result || typeof result !== 'object' || 'hash_algo' in result && result.hash_algo !== 'sha256'
      || 'transfer' in result && result.transfer !== 'basic' || !Array.isArray(result.objects)
      || result.objects.length !== candidates.length) refuse('remote_response_invalid');
  const expected = new Map(candidates.map((candidate) => [candidate.oid, candidate]));
  const acknowledged = []; let unavailable = 0;
  for (const object of result.objects) {
    if (!object || !expected.has(object.oid) || object.size !== expected.get(object.oid).size
        || 'authenticated' in object && typeof object.authenticated !== 'boolean') refuse('remote_object_unacknowledged');
    const candidate = expected.get(object.oid);
    if ('error' in object) {
      if (!object.error || typeof object.error !== 'object' || Array.isArray(object.error)
          || !Number.isInteger(object.error.code) || object.error.code < 400 || object.error.code > 599
          || typeof object.error.message !== 'string' || object.actions !== undefined) refuse('remote_response_invalid');
      expected.delete(object.oid); unavailable++; continue;
    }
    const action = object.actions?.download;
    if (!action || typeof action.href !== 'string' || Object.keys(object.actions).some((key) => key !== 'download')) refuse('remote_object_unacknowledged');
    if (action.header !== undefined && (!action.header || typeof action.header !== 'object' || Array.isArray(action.header)
        || Object.entries(action.header).some(([key, value]) => !/^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/.test(key)
          || typeof value !== 'string' || /[\r\n]/.test(value)))) refuse('remote_response_invalid');
    if (action.expires_in !== undefined && (!Number.isInteger(action.expires_in) || action.expires_in <= 0)) refuse('remote_response_invalid');
    if (action.expires_at !== undefined && action.expires_in === undefined
        && (typeof action.expires_at !== 'string' || !Number.isFinite(Date.parse(action.expires_at))
          || Date.parse(action.expires_at) <= Date.now())) refuse('remote_response_invalid');
    let url;
    try { url = new URL(action.href); } catch { refuse('remote_response_invalid'); }
    if (url.protocol !== 'https:' || url.username || url.password) refuse('remote_response_invalid');
    expected.delete(object.oid); acknowledged.push(candidate);
  }
  if (expected.size) refuse('remote_object_unacknowledged');
  return { acknowledged, unavailable };
}

// Read-only origin acknowledgement for retained operator recovery bytes. The
// caller must hash its own source; nothing here writes cache/worktree/history.
export async function verifyRemoteObjects(repo, { objects, limits = {} } = {}, deps = {}) {
  const options = { ...defaults, ...limits }, now = deps.now || (() => Date.now());
  const deadline = now() + options.maxSeconds * 1000, remaining = () => deadline - now();
  try {
    for (const key of ['maxBytes', 'maxObjects', 'maxSeconds', 'batchSize', 'requestTimeoutMs'])
      if (!safeInteger(options[key]) || !options[key]) refuse('invalid_limits');
    if (options.maxObjects > 10000 || options.maxBytes > defaults.maxBytes || options.maxSeconds > 600 || options.batchSize > 128
        || !Array.isArray(objects) || objects.length > options.maxObjects) refuse('invalid_limits');
    const requested = [], unique = new Set(); let bytes = 0;
    for (const object of objects) {
      if (!object || Object.keys(object).sort().join(',') !== 'oid,size' || typeof object.oid !== 'string' || !OID.test(object.oid)
          || !safeInteger(object.size) || unique.has(object.oid)) refuse('invalid_objects');
      bytes += object.size; if (!safeInteger(bytes) || bytes > options.maxBytes) refuse('byte_limit');
      unique.add(object.oid); requested.push({ oid: object.oid, size: object.size });
    }
    if (!requested.length) return { status: 'verified', reason: 'no_objects', confirmed: [], unavailable: 0 };
    repo = await ordinaryDirectory(repo);
    await ordinaryDirectory(path.join(repo, '.git'));
    if (await git(repo, ['rev-parse', '--show-toplevel'], undefined, remaining) !== repo) refuse('unsupported_repository');
    const { endpoint, authorization } = await configuredEndpoint(repo, remaining, deps);
    const confirmed = []; let unavailable = 0;
    for (let index = 0; index < requested.length; index += options.batchSize) {
      if (remaining() <= 0) refuse('time_limit');
      const result = await acknowledge(endpoint, authorization, requested.slice(index, index + options.batchSize), options, remaining, deps);
      confirmed.push(...result.acknowledged); unavailable += result.unavailable;
    }
    return { status: 'verified', reason: 'remote_acknowledged', confirmed, unavailable };
  } catch (error) {
    // An earlier valid batch never authorizes deletion after a later failure.
    return { status: 'blocked', reason: error instanceof Refusal ? error.reason : 'operation_unavailable', confirmed: [], unavailable: 0 };
  }
}

export async function maintainCache(input = {}, deps = {}) {
  const options = { ...defaults, ...input };
  const report = { status: 'blocked', reason: 'unverified', apply: !!options.apply,
    scannedObjects: 0, cacheBytes: 0, candidateObjects: 0, candidateBytes: 0,
    verifiedObjects: 0, verifiedBytes: 0, removedObjects: 0, removedBytes: 0,
    freeBytesBefore: null, freeBytesAfter: null, nextCursor: 0, skipped: {} };
  const now = deps.now || (() => Date.now());
  const deadline = now() + options.maxSeconds * 1000;
  const remaining = () => deadline - now();
  const checkTime = () => { if (remaining() <= 0) refuse('time_limit'); };
  let rootHandle;
  try {
    for (const key of ['budgetBytes', 'targetFreeBytes', 'maxBytes', 'maxObjects', 'maxSeconds', 'batchSize', 'requestTimeoutMs', 'maxScanEntries', 'cursor'])
      if (!safeInteger(options[key])) refuse('invalid_limits');
    if (!options.repoDir || !options.maxBytes || !options.maxObjects || options.maxObjects > 10000 || !options.maxSeconds
        || options.maxSeconds > 600 || !options.batchSize || options.batchSize > 128 || !options.maxScanEntries) refuse('invalid_limits');
    const repo = await ordinaryDirectory(path.resolve(options.repoDir));
    const gitDir = await ordinaryDirectory(path.join(repo, '.git'));
    if (await git(repo, ['rev-parse', '--show-toplevel'], undefined, remaining) !== repo) refuse('unsupported_repository');
    const root = path.join(gitDir, 'lfs', 'objects');
    report.freeBytesBefore = await freeBytes(repo, deps);
    try { await ordinaryDirectory(root); } catch (error) {
      if (error.code !== 'ENOENT') throw error;
      report.status = report.freeBytesBefore >= options.targetFreeBytes ? 'complete' : 'incomplete';
      report.reason = 'no_cache'; report.freeBytesAfter = report.freeBytesBefore; return report;
    }
    if (process.platform === 'linux') rootHandle = await anchoredDirectory(root);
    const candidates = await scanCache(rootHandle ? `/proc/self/fd/${rootHandle.fd}` : root, options, checkTime, report);
    const needed = Math.max(0, report.cacheBytes - options.budgetBytes, options.targetFreeBytes - report.freeBytesBefore);
    if (!needed) { report.status = 'complete'; report.reason = 'targets_met'; report.freeBytesAfter = report.freeBytesBefore; return report; }
    const selected = []; let selectedBytes = 0;
    const start = candidates.length ? options.cursor % candidates.length : 0;
    for (let visited = 0; visited < candidates.length && selected.length < options.maxObjects
        && selectedBytes < needed && selectedBytes < options.maxBytes; visited++) {
      checkTime();
      const index = (start + visited) % candidates.length;
      const candidate = candidates[index];
      // Advance even for an oversized/unavailable object. Carrying this number
      // in the existing receipt lets later rounds reach beyond an all-404 prefix
      // without adding state writes to a full disk or disclosing object IDs.
      report.nextCursor = (index + 1) % candidates.length;
      if (candidate.size > options.maxBytes - selectedBytes) {
        report.skipped.byte_limit = (report.skipped.byte_limit || 0) + 1; continue;
      }
      selected.push(candidate); selectedBytes += candidate.size;
    }
    report.candidateObjects = selected.length; report.candidateBytes = selectedBytes;
    const verified = [];
    for (const candidate of selected) {
      checkTime();
      try { await verifyCandidate(candidate, options, checkTime, deps, rootHandle); verified.push(candidate); }
      catch (error) {
        if (!(error instanceof Refusal) || !['object_changed', 'hash_mismatch'].includes(error.reason)) throw error;
        report.skipped[error.reason] = (report.skipped[error.reason] || 0) + 1;
      }
    }
    if (!verified.length) refuse('no_verified_candidates');
    const { endpoint, authorization } = await configuredEndpoint(repo, remaining, deps);
    // Every selected object's remote ACK is validated before the first unlink.
    const confirmed = [];
    for (let index = 0; index < verified.length; index += options.batchSize) {
      checkTime(); const result = await acknowledge(endpoint, authorization, verified.slice(index, index + options.batchSize), options, remaining, deps);
      confirmed.push(...result.acknowledged);
      if (result.unavailable) report.skipped.remote_unavailable = (report.skipped.remote_unavailable || 0) + result.unavailable;
    }
    report.verifiedObjects = confirmed.length; report.verifiedBytes = confirmed.reduce((total, candidate) => total + candidate.size, 0);
    if (!confirmed.length) {
      report.status = 'incomplete'; report.reason = 'no_remote_recoverable_objects'; report.freeBytesAfter = report.freeBytesBefore; return report;
    }
    if (!options.apply) { report.status = 'dry_run'; report.reason = 'verified_no_changes'; report.freeBytesAfter = report.freeBytesBefore; return report; }
    for (const candidate of confirmed) {
      checkTime(); await deps.beforeUnlink?.(candidate);
      const opened = await openCandidate(candidate, rootHandle);
      try {
        const current = await fs.lstat(opened.filename, { bigint: true });
        if (opened.parentId !== candidate.parentId || !current.isFile() || fingerprint(current) !== candidate.fingerprint) {
          report.skipped.object_changed = (report.skipped.object_changed || 0) + 1; continue;
        }
        await fs.unlink(opened.filename);
        report.removedObjects++; report.removedBytes += candidate.size;
      } finally { await opened.parent.close(); }
    }
    report.freeBytesAfter = await freeBytes(repo, deps);
    const met = report.cacheBytes - report.removedBytes <= options.budgetBytes && report.freeBytesAfter >= options.targetFreeBytes;
    report.status = met ? 'complete' : 'incomplete'; report.reason = met ? 'targets_met' : 'bounded_recovery_incomplete';
  } catch (error) {
    report.status = report.removedObjects ? 'incomplete' : 'blocked';
    report.reason = error instanceof Refusal ? error.reason : 'operation_unavailable';
  } finally { await rootHandle?.close(); }
  return report;
}

export async function main(argv = process.argv.slice(2)) {
  const names = { '--repo-dir': 'repoDir', '--budget-bytes': 'budgetBytes', '--target-free-bytes': 'targetFreeBytes',
    '--max-bytes': 'maxBytes', '--max-objects': 'maxObjects', '--max-seconds': 'maxSeconds', '--cursor': 'cursor' };
  const options = {};
  for (let index = 0; index < argv.length; index++) {
    const flag = argv[index];
    if (flag === '--apply') options.apply = true;
    else if (names[flag] && argv[index + 1] !== undefined) options[names[flag]] = flag === '--repo-dir' ? argv[++index] : Number(argv[++index]);
    else { console.log(JSON.stringify({ status: 'blocked', reason: 'invalid_arguments', removedObjects: 0, removedBytes: 0 })); return 1; }
  }
  const report = await maintainCache(options);
  console.log(JSON.stringify(report));
  return report.status === 'complete' || report.status === 'dry_run' ? 0 : report.status === 'incomplete' ? 2 : 1;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) process.exitCode = await main();
