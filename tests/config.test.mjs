// cage.env.example and apply.sh --check-config: the example lists every setting, refuses to run
// until the placeholders are filled, and a filled copy passes the same checks the host run does.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { ROOT, run, withTemp } from './helpers.mjs';

const EXAMPLE = readFileSync(join(ROOT, 'cage.env.example'), 'utf8');
const keys = (text) => Object.fromEntries(
  text.split('\n').map((l) => l.match(/^([A-Z_][A-Z0-9_]*)=(.*)$/)).filter(Boolean).map((m) => [m[1], m[2]]));

const FILLED = {
  AGENT_IMAGE: 'example/agent:1.0',
  AGENT_COMMAND: '"example-agent run"',
  CAGE_SUBNET: '203.0.113.0/24',
  CAGE_GATEWAY: '203.0.113.1',
  TAILNET_ALLOW_HOST: '100.64.0.10',
  VERIFY_TAILNET_HOST: '100.64.0.20',
};

function envFile(dir, overrides) {
  const lines = EXAMPLE.split('\n').map((l) => {
    const m = l.match(/^([A-Z_][A-Z0-9_]*)=/);
    return m && m[1] in overrides ? `${m[1]}=${overrides[m[1]]}` : l;
  });
  const f = join(dir, 'cage.env');
  writeFileSync(f, lines.join('\n'));
  return f;
}

const checkConfig = (f) => run('bash', ['apply.sh', '--check-config', '--env', f]);

test('every ${NAME} in compose.yaml and every VERIFY_ setting has a line in the example', () => {
  const have = keys(EXAMPLE);
  const compose = readFileSync(join(ROOT, 'compose.yaml'), 'utf8');
  for (const m of compose.matchAll(/\$\{([A-Z_][A-Z0-9_]*)/g)) assert.ok(m[1] in have, `${m[1]} missing`);
  for (const v of ['VERIFY_EGRESS_URL', 'VERIFY_TAILNET_HOST', 'VERIFY_TAILNET_PORT', 'VERIFY_TOKEN_VARS'])
    assert.ok(v in have, `${v} missing`);
});

test('the example holds no secret and no numeric address, only placeholders', () => {
  assert.ok(!/([0-9]{1,3}\.){3}[0-9]{1,3}/.test(EXAMPLE), 'a numeric address in the example');
  assert.match(EXAMPLE, /^CAGE_SUBNET=your-/m);
  assert.ok(!/TOKEN=.+[A-Za-z0-9]{20,}/.test(EXAMPLE));
});

test('apply.sh refuses the example as it ships and names every placeholder', () => {
  withTemp((dir) => {
    const r = checkConfig(envFile(dir, {}));
    assert.equal(r.code, 1);
    for (const k of ['AGENT_IMAGE', 'AGENT_COMMAND', 'CAGE_SUBNET', 'CAGE_GATEWAY', 'TAILNET_ALLOW_HOST', 'VERIFY_TAILNET_HOST'])
      assert.match(r.err, new RegExp(k));
    assert.ok(!r.err.includes('ROLLBACK'), 'a config check printed the rollback block');
  });
});

test('a filled copy passes; an empty tailnet host is allowed', () => {
  withTemp((dir) => {
    let r = checkConfig(envFile(dir, FILLED));
    assert.equal(r.code, 0, r.err);
    assert.match(r.out, /look complete/);
    r = checkConfig(envFile(dir, { ...FILLED, TAILNET_ALLOW_HOST: '' }));
    assert.equal(r.code, 0, r.err);
  });
});

test('apply.sh refuses settings that would build a broken or weaker cage', () => {
  const cases = [
    [{ AGENT_UID: '0' }, /AGENT_UID/],
    [{ CAGE_GATEWAY: '100.64.0.1' }, /not inside CAGE_SUBNET/],
    [{ CAGE_SUBNET: '203.0.113.0/8' }, /CAGE_SUBNET/],
    [{ TAILNET_ALLOW_HOST: 'model.example.com' }, /TAILNET_ALLOW_HOST/],
    [{ CAGE_TOKEN_KEYS: '"AGENT TOKEN-2"' }, /not a variable name/],
    [{ PROXY_ALLOWLIST: 'host/no-such-file' }, /PROXY_ALLOWLIST/],
    [{ AGENT_IMAGE: '' }, /empty in .*AGENT_IMAGE/],
  ];
  withTemp((dir) => {
    for (const [bad, why] of cases) {
      const r = checkConfig(envFile(dir, { ...FILLED, ...bad }));
      assert.equal(r.code, 1, `accepted ${JSON.stringify(bad)}`);
      assert.match(r.err, why);
    }
  });
});

test('every shell script parses, and stops on unset variables', () => {
  for (const f of readdirSync(ROOT).filter((f) => f.endsWith('.sh'))) {
    const shell = f === 'entrypoint.sh' ? 'sh' : 'bash';
    const r = run(shell, ['-n', f]);
    assert.equal(r.code, 0, `${f}: ${r.err}`);
    assert.match(readFileSync(join(ROOT, f), 'utf8'), /^set -[eo]*u/m, `${f} has no set -u`);
  }
});
