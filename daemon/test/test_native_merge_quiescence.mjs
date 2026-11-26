import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { spawn, execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const BRIDGE = process.env.BRIDGE_UNDER_TEST || fileURLToPath(new URL('../bridge.sh', import.meta.url));
const REAL_GIT = execFileSync('sh', ['-c', 'command -v git'], { encoding: 'utf8' }).trim();
const exists = (p) => fs.access(p).then(() => true, () => false);
const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
async function until(check, ms = 7000) {
  const deadline = Date.now() + ms;
  while (Date.now() < deadline) { if (await check()) return; await delay(25); }
  assert.fail('fixture condition did not complete before its deadline');
}

async function fixture(t, { fastForward = false, refuseStop = false, refuseAbort = false, holdMerge = false,
  partialForward = false, crashForward = false, createFailure = false, partialIntent = false,
  zeroIntent = false, symlinkIntent = false, zeroAfterMerge = false, finalWrite = false,
  oversizedFinalWrite = false, freshCheckout = false, partialCheckout = false, checkoutProfile = 'full' } = {}) {
  const base = await fs.mkdtemp(path.join(await fs.realpath(os.tmpdir()), 'native-merge-quiescence-'));
  const repo = path.join(base, 'worker'), author = path.join(base, 'author'), origin = path.join(base, 'origin.git');
  const bin = path.join(base, 'bin'), config = path.join(base, 'gitconfig'); await fs.mkdir(bin); await fs.writeFile(config, '');
  const env = { ...process.env, GIT_CONFIG_GLOBAL: config, GIT_CONFIG_SYSTEM: config, GIT_CONFIG_NOSYSTEM: '1',
    GIT_TERMINAL_PROMPT: '0', GIT_OPTIONAL_LOCKS: '0', QUIESCENCE_LAB: base, QUIESCENCE_GIT: REAL_GIT };
  for (const name of ['GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'VAULT_LFS_CACHE_BUDGET_BYTES', 'VAULT_CHECKOUT_PROFILE']) delete env[name];
  const git = (cwd, ...args) => execFileSync(REAL_GIT, ['-C', cwd, ...args], { env, stdio: ['ignore', 'pipe', 'ignore'] }).toString().trim();
  execFileSync(REAL_GIT, ['init', '--bare', origin], { env, stdio: 'ignore' });
  execFileSync(REAL_GIT, ['init', '--initial-branch=main', author], { env, stdio: 'ignore' });
  git(author, 'config', 'user.name', 'fixture'); git(author, 'config', 'user.email', 'fixture@example.invalid');
  await fs.mkdir(path.join(author, '.obsidian')); await fs.writeFile(path.join(author, '.obsidian/app.json'), '{"side":"base"}\n');
  await fs.writeFile(path.join(author, 'visible.md'), 'unchanged visible note\n');
  git(author, 'add', '-A'); git(author, 'commit', '-m', 'base'); git(author, 'remote', 'add', 'origin', origin);
  git(author, 'push', 'origin', 'main'); git(origin, 'symbolic-ref', 'HEAD', 'refs/heads/main');
  execFileSync(REAL_GIT, ['clone', origin, repo], { env, stdio: 'ignore' });
  git(repo, 'config', 'user.name', 'fixture'); git(repo, 'config', 'user.email', 'fixture@example.invalid');
  if (!fastForward) {
    await fs.writeFile(path.join(repo, '.obsidian/app.json'), '{"side":"device"}\n');
    git(repo, 'add', '-A'); git(repo, 'commit', '-m', 'device');
  }
  await fs.writeFile(path.join(author, '.obsidian/app.json'), '{"side":"origin"}\n');
  git(author, 'add', '-A'); git(author, 'commit', '-m', 'origin'); git(author, 'push', 'origin', 'main');
  for (const [enabled, flag] of [[refuseStop, 'refuse-stop'], [refuseAbort, 'refuse-abort'], [holdMerge, 'hold-merge'],
    [partialForward, 'partial-ff'], [crashForward, 'crash-ff'], [createFailure, 'create-failure'],
    [partialIntent, 'partial-intent'], [zeroAfterMerge, 'zero-after-merge'], [finalWrite, 'final-write'],
    [oversizedFinalWrite, 'oversized-final-write'], [partialCheckout, 'partial-checkout']])
    if (enabled) await fs.writeFile(path.join(base, flag), '');
  const intent = path.join(repo, '.git/vaultsync-mutation-intent');
  if (zeroIntent) await fs.writeFile(intent, '');
  if (symlinkIntent) { await fs.writeFile(path.join(base, 'unknown-marker-target'), 'preserve unknown bytes'); await fs.symlink(path.join(base, 'unknown-marker-target'), intent); }
  if (freshCheckout) await fs.rm(repo, { recursive: true });
  const native = `#!${process.execPath}
const fs=require('node:fs'),path=require('node:path');const lab=process.env.QUIESCENCE_LAB;
if(process.argv[2]!=='sync')process.exit(0);
let timer;process.on('SIGTERM',()=>{if(fs.existsSync(path.join(lab,'refuse-stop'))){fs.appendFileSync(path.join(lab,'refused'),'1\\n');return;}
 if(fs.existsSync(path.join(lab,'final-write'))&&!fs.existsSync(path.join(lab,'final-written'))){
  fs.writeFileSync(path.join(lab,'worker/final-native.md'),fs.existsSync(path.join(lab,'oversized-final-write'))?Buffer.alloc(6*1024*1024,120):'legitimate final Native save\\n');fs.writeFileSync(path.join(lab,'final-written'),'1');}
 clearInterval(timer);try{fs.unlinkSync(path.join(lab,'native.pid'));}catch{}fs.appendFileSync(path.join(lab,'stops'),'1\\n');process.exit(0);});
fs.appendFileSync(path.join(lab,'starts'),'1\\n');fs.writeFileSync(path.join(lab,'native.pid'),String(process.pid));console.log('Fully synced');
const observe=()=>{try{const body=fs.readFileSync(path.join(lab,'worker/.obsidian/app.json'),'utf8');if(body.includes('<<<<<<<'))fs.writeFileSync(path.join(lab,'marker-captured'),'1');if(body.includes('partial-checkout'))fs.writeFileSync(path.join(lab,'partial-captured'),'1');}catch{}};observe();timer=setInterval(observe,5);
`;
  const gitWrapper = `#!${process.execPath}
const fs=require('node:fs'),path=require('node:path'),cp=require('node:child_process');const lab=process.env.QUIESCENCE_LAB,a=process.argv.slice(2);
const pause=()=>Atomics.wait(new Int32Array(new SharedArrayBuffer(4)),0,0,10);
if(a.includes('status')){const end=Date.now()+5000;while(!fs.existsSync(path.join(lab,'armed'))&&Date.now()<end)pause();}
const merging=a.includes('merge'),abort=a.includes('--abort');
if(merging&&abort&&fs.existsSync(path.join(lab,'refuse-abort')))process.exit(99);
const intent=path.join(lab,'worker/.git/vaultsync-mutation-intent');
if(merging&&!abort){fs.appendFileSync(path.join(lab,'merge-observers'),String(fs.existsSync(path.join(lab,'native.pid')))+'\\n');
 fs.appendFileSync(path.join(lab,'intent-observers'),String(fs.existsSync(intent)&&fs.statSync(intent).size>0)+'\\n');
 if(fs.existsSync(path.join(lab,'final-write')))fs.appendFileSync(path.join(lab,'final-write-indexed'),String(cp.spawnSync(process.env.QUIESCENCE_GIT,['-C',path.join(lab,'worker'),'cat-file','-e','HEAD:final-native.md']).status===0)+'\\n');
 if(fs.existsSync(path.join(lab,'partial-ff'))){fs.writeFileSync(path.join(lab,'worker/.obsidian/app.json'),'partial-checkout ENOSPC');fs.writeFileSync(path.join(lab,'partial-written'),'1');if(fs.existsSync(path.join(lab,'crash-ff')))process.kill(process.ppid,'SIGKILL');process.exit(28);}}
const r=cp.spawnSync(process.env.QUIESCENCE_GIT,a,{encoding:null,stdio:['inherit','pipe','pipe']});if(r.stdout)process.stdout.write(r.stdout);if(r.stderr)process.stderr.write(r.stderr);
if(a.includes('read-tree')&&fs.existsSync(path.join(lab,'partial-checkout'))){fs.writeFileSync(path.join(lab,'worker/.obsidian/app.json'),'partial-checkout ENOSPC');fs.writeFileSync(path.join(lab,'partial-written'),'1');process.exit(28);}
if(merging&&!abort&&fs.existsSync(path.join(lab,'zero-after-merge')))fs.writeFileSync(intent,'');
if(merging&&!abort){fs.writeFileSync(path.join(lab,'merge-created'),'1');const end=Date.now()+5000;
 while(fs.existsSync(path.join(lab,'hold-merge'))&&Date.now()<end)pause();Atomics.wait(new Int32Array(new SharedArrayBuffer(4)),0,0,250);}
process.exit(r.status===null?1:r.status);
`;
  await fs.writeFile(path.join(bin, 'ob'), native, { mode: 0o755 }); await fs.writeFile(path.join(bin, 'git'), gitWrapper, { mode: 0o755 });
  const nodeWrapper = `#!${process.execPath}
const fs=require('node:fs'),path=require('node:path'),cp=require('node:child_process'),a=process.argv.slice(2),lab=process.env.QUIESCENCE_LAB;
if(a.includes('create-intent')&&fs.existsSync(path.join(lab,'create-failure')))process.exit(28);
if(a.includes('create-intent')&&fs.existsSync(path.join(lab,'partial-intent'))){fs.writeFileSync(path.join(lab,'worker/.git/vaultsync-mutation-intent'),'');process.exit(28);}
const r=cp.spawnSync(${JSON.stringify(process.execPath)},a,{stdio:'inherit'});process.exit(r.status===null?1:r.status);
`;
  await fs.writeFile(path.join(bin, 'node'), nodeWrapper, { mode: 0o755 });
  let child, log = '';
  const start = () => {
    child = spawn('bash', [BRIDGE], { env: { ...env, PATH: bin + path.delimiter + process.env.PATH,
      VAULT_NAME: 'native-quiescence', VAULT_REPO: origin, VAULT_DIR: repo, VAULT_SYNC_REMOTE: 'fixture',
      VAULT_EXCLUDE_AGENT_MEMORY: '0', OBSIDIAN_AUTH_TOKEN: 'fixture', VAULT_HEALTH_DIR: path.join(base, 'health'),
      VAULT_CHECKOUT_PROFILE: checkoutProfile,
      XDG_CONFIG_HOME: path.join(base, 'state'), VAULT_BRIDGE_INTERVAL: '.2', VAULT_HEARTBEAT_SECS: '0' },
      stdio: ['ignore', 'pipe', 'pipe'] });
    child.stdout.on('data', (b) => { log += b; }); child.stderr.on('data', (b) => { log += b; }); return child;
  };
  const stop = async () => {
    await fs.rm(path.join(base, 'refuse-stop'), { force: true }); await fs.rm(path.join(base, 'hold-merge'), { force: true });
    if (child && child.exitCode === null) { child.kill('SIGTERM'); await until(() => child.exitCode !== null || child.signalCode !== null, 7000); }
  };
  t.after(async () => {
    try { await stop(); } catch { child?.kill('SIGKILL'); }
    try { process.kill(Number(await fs.readFile(path.join(base, 'native.pid'), 'utf8')), 'SIGTERM'); } catch {}
    await fs.rm(base, { recursive: true, force: true });
  });
  const lines = async (name) => (await fs.readFile(path.join(base, name), 'utf8').catch(() => '')).trim().split('\n').filter(Boolean);
  const arm = async () => { await until(() => exists(path.join(base, 'native.pid'))); await fs.writeFile(path.join(base, 'armed'), ''); };
  return { base, repo, intent, git, start, stop, arm, lines, log: () => log, child: () => child };
}

test('Native Sync cannot observe real hidden-conflict markers before the merge aborts', async (t) => {
  const f = await fixture(t); f.start(); await f.arm();
  await until(() => f.log().includes('merge failed and conflicted-copy resolution also failed'));
  assert.equal(await exists(path.join(f.base, 'marker-captured')), false, 'a real Native watcher observed transient Git conflict markers');
  assert.ok((await f.lines('merge-observers')).length > 0);
  assert.ok((await f.lines('merge-observers')).every((value) => value === 'false'), 'Native must exit before Git starts mutating');
  assert.equal(f.git(f.repo, 'show', 'HEAD:.obsidian/app.json'), '{"side":"device"}');
  assert.equal(await exists(path.join(f.repo, '.git/MERGE_HEAD')), false);
  assert.equal(await exists(f.intent), false, 'verified clean abort clears only its own intent');
  await until(async () => (await f.lines('starts')).length >= 2);
});

if (process.env.QUIESCENCE_CASE !== 'conflict') {
  test('fast-forward pauses Native through checkout and idle passes do not restart it', async (t) => {
    const f = await fixture(t, { fastForward: true }); f.start(); await f.arm();
    await until(async () => (await f.lines('starts')).length === 2);
    assert.equal(f.git(f.repo, 'rev-parse', 'HEAD'), f.git(f.repo, 'rev-parse', 'origin/main'));
    assert.deepEqual(await f.lines('merge-observers'), ['false']);
    assert.deepEqual(await f.lines('intent-observers'), ['true']);
    assert.equal(await exists(f.intent), false);
    await delay(600); assert.equal((await f.lines('starts')).length, 2);
    assert.equal(await fs.readFile(path.join(f.repo, 'visible.md'), 'utf8'), 'unchanged visible note\n');
  });

  test('an uncooperative managed Native child prevents every remote worktree mutation', async (t) => {
    const f = await fixture(t, { refuseStop: true }); f.start(); await f.arm();
    await until(() => f.log().includes('Git merge held: managed Native Sync has not stopped'), 12000);
    assert.equal((await f.lines('merge-observers')).length, 0); assert.equal(await exists(path.join(f.base, 'marker-captured')), false);
    assert.equal(await fs.readFile(path.join(f.repo, '.obsidian/app.json'), 'utf8'), '{"side":"device"}\n');
    assert.equal((await f.lines('starts')).length, 1);
  });

  test('a failed abort keeps Native stopped, including a fresh bridge restart', async (t) => {
    const f = await fixture(t, { refuseAbort: true }); f.start(); await f.arm();
    await until(() => f.log().includes('git_operation_in_progress'));
    assert.equal(await exists(path.join(f.repo, '.git/MERGE_HEAD')), true);
    assert.equal((await f.lines('starts')).length, 1); assert.equal(await exists(path.join(f.base, 'marker-captured')), false);
    await f.stop(); const restarted = f.start();
    await until(() => restarted.exitCode !== null);
    assert.equal((await f.lines('starts')).length, 1); assert.equal(await exists(path.join(f.base, 'native.pid')), false);
  });

  test('shutdown during a merge never restarts Native on the intermediate tree', async (t) => {
    const f = await fixture(t, { holdMerge: true }); f.start(); await f.arm();
    await until(() => exists(path.join(f.base, 'merge-created')));
    f.child().kill('SIGTERM'); await fs.rm(path.join(f.base, 'hold-merge'));
    await until(() => f.child().exitCode !== null || f.child().signalCode !== null);
    assert.equal((await f.lines('starts')).length, 1); assert.equal(await exists(path.join(f.base, 'native.pid')), false);
    assert.equal(await exists(path.join(f.base, 'marker-captured')), false);
  });

  test('partial failed FF without MERGE_HEAD retains its intent and never resumes Native', async (t) => {
    const f = await fixture(t, { fastForward: true, partialForward: true }); f.start(); await f.arm();
    await until(() => f.log().includes('Git abort did not complete'));
    await delay(300);
    assert.equal(await exists(path.join(f.repo, '.git/MERGE_HEAD')), false);
    assert.equal(await exists(f.intent), true);
    assert.deepEqual(await f.lines('intent-observers'), ['true']);
    assert.equal((await f.lines('starts')).length, 1);
    assert.equal(await exists(path.join(f.base, 'partial-captured')), false);
    assert.equal(await fs.readFile(path.join(f.repo, '.obsidian/app.json'), 'utf8'), 'partial-checkout ENOSPC');
  });

  test('crash after a partial FF remains fenced on fresh bridge restart without a Git marker', async (t) => {
    const f = await fixture(t, { fastForward: true, partialForward: true, crashForward: true }); f.start(); await f.arm();
    await until(() => f.child().exitCode !== null || f.child().signalCode !== null);
    const intent = await fs.readFile(f.intent);
    assert.equal(await exists(path.join(f.repo, '.git/MERGE_HEAD')), false);
    await fs.rm(path.join(f.base, 'partial-ff')); await fs.rm(path.join(f.base, 'crash-ff'));
    const restarted = f.start(); await until(() => restarted.exitCode !== null);
    assert.equal((await f.lines('starts')).length, 1);
    assert.equal(await exists(path.join(f.base, 'partial-captured')), false);
    assert.deepEqual(await fs.readFile(f.intent), intent);
    assert.equal(await fs.readFile(path.join(f.repo, '.obsidian/app.json'), 'utf8'), 'partial-checkout ENOSPC');
  });

  test('failure to create or fsync a complete intent prevents the incoming merge', async (t) => {
    for (const option of ['createFailure', 'partialIntent']) await t.test(option, async (t) => {
      const f = await fixture(t, { fastForward: true, [option]: true }); f.start(); await f.arm();
      await until(() => f.log().includes('durable intent could not be created')); await delay(250);
      assert.deepEqual(await f.lines('merge-observers'), []);
      assert.equal((await f.lines('starts')).length, 1);
      assert.equal(await fs.readFile(path.join(f.repo, '.obsidian/app.json'), 'utf8'), '{"side":"base"}\n');
      if (option === 'partialIntent') assert.equal((await fs.stat(f.intent)).size, 0);
    });
  });

  test('unknown empty or symlinked intent holds startup without deleting unknown bytes', async (t) => {
    for (const option of ['zeroIntent', 'symlinkIntent']) await t.test(option, async (t) => {
      const f = await fixture(t, { fastForward: true, [option]: true }); const child = f.start();
      await until(() => child.exitCode !== null);
      assert.equal((await f.lines('starts')).length, 0); assert.deepEqual(await f.lines('merge-observers'), []);
      assert.equal(await exists(f.intent), true);
      if (option === 'symlinkIntent') assert.equal(await fs.readFile(path.join(f.base, 'unknown-marker-target'), 'utf8'), 'preserve unknown bytes');
      else assert.equal((await fs.stat(f.intent)).size, 0);
    });
  });

  test('zeroing an owned intent during a clean FF cannot certify or clear it', async (t) => {
    const f = await fixture(t, { fastForward: true, zeroAfterMerge: true }); f.start(); await f.arm();
    await until(() => f.log().includes('Git worktree mutation incomplete'));
    assert.equal((await fs.stat(f.intent)).size, 0); assert.equal((await f.lines('starts')).length, 1);
    assert.equal(f.git(f.repo, 'rev-parse', 'HEAD'), f.git(f.repo, 'rev-parse', 'origin/main'));
  });

  test('final Native writes after the first commit defer mutation and enter history before merging', async (t) => {
    const f = await fixture(t, { fastForward: true, finalWrite: true }); f.start(); await f.arm();
    await until(() => f.log().includes('final Native writes remain for the next local commit'));
    await until(async () => (await f.lines('merge-observers')).length > 0);
    assert.ok((await f.lines('final-write-indexed')).every((value) => value === 'true'));
    assert.equal(await fs.readFile(path.join(f.repo, 'final-native.md'), 'utf8'), 'legitimate final Native save\n');
    assert.equal(await exists(path.join(f.base, 'partial-captured')), false);
  });

  test('size-cap-held final Native bytes are never reset to force an incoming merge', async (t) => {
    const f = await fixture(t, { fastForward: true, finalWrite: true, oversizedFinalWrite: true }); f.start(); await f.arm();
    await until(() => f.log().includes('exceeds sync cap')); await delay(300);
    assert.equal((await fs.stat(path.join(f.repo, 'final-native.md'))).size, 6 * 1024 * 1024);
    assert.deepEqual(await f.lines('merge-observers'), []);
    assert.equal(await exists(f.intent), false, 'no Git mutation began, so no persistent intent is needed');
  });

  test('partial initial full and sparse checkouts are fenced before Native can start', async (t) => {
    for (const checkoutProfile of ['full', 'obsidian']) await t.test(checkoutProfile, async (t) => {
      const f = await fixture(t, { fastForward: true, freshCheckout: true, partialCheckout: true, checkoutProfile });
      const child = f.start(); await until(() => child.exitCode !== null, 10000);
      assert.equal(await exists(path.join(f.base, 'partial-written')), true, f.log());
      assert.equal(await exists(f.intent), true); assert.equal((await f.lines('starts')).length, 0);
      assert.equal(await exists(path.join(f.repo, '.git/MERGE_HEAD')), false);
      await fs.rm(path.join(f.base, 'partial-checkout')); const restarted = f.start();
      await until(() => restarted.exitCode !== null);
      assert.equal((await f.lines('starts')).length, 0);
      assert.equal(await fs.readFile(path.join(f.repo, '.obsidian/app.json'), 'utf8'), 'partial-checkout ENOSPC');
    });
  });

  test('an unchanged sparse profile preserves legitimate dirty visible saves on restart', async (t) => {
    const f = await fixture(t, { fastForward: true, checkoutProfile: 'obsidian' });
    f.git(f.repo, 'sparse-checkout', 'set', '--no-cone', '/*', '!**/.*', '**/.gitignore', '**/.gitattributes',
      '!**/.gitignore/', '!**/.gitattributes/', '/.obsidian/**');
    await fs.writeFile(path.join(f.repo, 'owner-visible.md'), 'legitimate visible startup save\n');
    f.start(); await f.arm(); await until(async () => (await f.lines('starts')).length >= 2);
    assert.equal(await fs.readFile(path.join(f.repo, 'owner-visible.md'), 'utf8'), 'legitimate visible startup save\n');
    assert.equal(f.git(f.repo, 'show', 'HEAD:owner-visible.md'), 'legitimate visible startup save');
    assert.equal(f.log().includes('checkout policy change deferred'), false);
    assert.equal(await exists(f.intent), false);
  });
}
