// Shared helpers for the tests. Node built-ins only.
import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync, readFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

export const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
export const STUBS = join(ROOT, 'tests', 'stubs');

// Run a command; return { code, out, err }. env is merged over a minimal environment, so the
// developer's own shell settings (a CAGE_SUBNET export, say) never reach a test.
export function run(cmd, args, { env = {}, input, cwd = ROOT, stubs = false } = {}) {
  const base = { PATH: (stubs ? `${STUBS}:` : '') + process.env.PATH, HOME: process.env.HOME || '/tmp', LANG: 'C' };
  const r = spawnSync(cmd, args, { cwd, env: { ...base, ...env }, input, encoding: 'utf8', timeout: 60000 });
  return { code: r.status, out: r.stdout || '', err: r.stderr || '' };
}

// A fresh temp folder, removed when the callback returns or throws.
export function withTemp(fn) {
  const dir = mkdtempSync(join(tmpdir(), 'agent-cage-test-'));
  try {
    return fn(dir);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

export function chain(state, name) {
  const f = join(state, `chain.${name}`);
  return existsSync(f) ? readFileSync(f, 'utf8').split('\n').filter(Boolean) : [];
}

export function setChain(state, name, lines) {
  writeFileSync(join(state, `chain.${name}`), lines.map((l) => l + '\n').join(''));
}

export function calls(state) {
  const f = join(state, 'calls');
  return existsSync(f) ? readFileSync(f, 'utf8').split('\n').filter(Boolean) : [];
}

// Documentation-range settings for tests (RFC 5737 TEST-NET-3 and the 100.64.0.x example
// range). They are never real hosts.
export const TEST_NET = {
  CAGE_SUBNET: '203.0.113.0/24',
  CAGE_GATEWAY: '203.0.113.1',
  PROXY_PORT: '3128',
  TAILNET_ALLOW_HOST: '100.64.0.10',
  TAILNET_ALLOW_PORT: '8000',
  TAILNET_IFACE: 'tailscale0',
};
