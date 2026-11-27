// SPDX-License-Identifier: MIT
// Fake Docker for disposable launcher tests. No daemon, provider, or real mounts.
import { appendFileSync, mkdirSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { runWorker } from '../../docker/worker-rpc.mjs';
const args = process.argv.slice(2), root = process.env.TEST_ROOT;
appendFileSync(process.env.FAKE_DOCKER_LOG, `${JSON.stringify(args)}\n`);
if (args[0] === 'image' && args[1] === 'inspect') {
  const result = spawnSync('bash', [join(root, 'tests/runtime-launch-selection-test.sh'), '--emit-image', args[2]], { encoding: 'utf8' });
  if (result.status !== 0) process.exit(result.status ?? 1);
  const images = JSON.parse(result.stdout);
  if (args[2].startsWith('pi-run-profile:') && process.env.FAKE_WORKER_RUNTIME_ID) images[0].Id = process.env.FAKE_WORKER_RUNTIME_ID;
  console.log(JSON.stringify(images));
  process.exit(0);
}
if (args[0] === 'ps') process.exit(process.env.FAKE_DOCKER_UNAVAILABLE === '1' ? 1 : 0);
if (args[0] === 'rm' || args[0] === 'exec') process.exit(0);
if (args[0] !== 'run') process.exit(2);
const env = {}, mounts = new Map();
for (let i = 1; i < args.length; i++) {
  if (args[i] === '--env') { const value = args[++i], at = value.indexOf('='); env[value.slice(0, at)] = value.slice(at + 1); }
  if (args[i] === '--mount') {
    const parts = Object.fromEntries(args[++i].split(',').map(p => p.split('=')));
    mounts.set(parts.dst, parts.src);
  }
}
if (args.includes('-d')) {
  writeFileSync(args[args.indexOf('--cidfile') + 1], 'c'.repeat(64)); process.exit(0);
}
if (env.PI_RUN_WORKTREE_BASE) {
  const r = spawnSync('git', ['-C', mounts.get('/workspace'), '-c', 'core.hooksPath=/dev/null', 'reset', '--hard', env.PI_RUN_WORKTREE_BASE], { stdio: ['ignore', 'ignore', 'inherit'] });
  process.exit(r.status ?? 1);
}
if (args.includes('/usr/local/bin/pi-run-network-policy-resolver')) {
  console.log(JSON.stringify({ schemaVersion: 1, modelRules: [], sshRules: [], manualRules: [{ cidr: '192.0.2.1/32', tcpPorts: [443] }] }));
  process.exit(0);
}
const adapterIndex = args.indexOf('/usr/local/lib/pi-run/worker-rpc.mjs');
if (adapterIndex < 0) process.exit(0); // Ordinary TUI launch fixture.
Object.assign(process.env, env);
const sessionHost = join(mounts.get('/profile'), 'sessions', env.PI_RUN_WORKER_SESSION_DIR.split('/').at(-1));
mkdirSync(sessionHost, { recursive: true });
process.env.FAKE_WORKER_SESSION_HOST = sessionHost;
const workerArgs = args.slice(adapterIndex + 1);
const code = await runWorker({ command: process.execPath,
  args: [join(root, 'tests/fixtures/worker-peer.mjs'), ...workerArgs],
  control: mounts.get('/run/pi-run-worker'), role: mounts.get('/run/pi-run-role.txt'),
  startupMs: 2000, shutdownMs: 300, heartbeatMs: 100,
});
process.exitCode = code;
