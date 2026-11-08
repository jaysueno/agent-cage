// egress-rules.sh: the rule set, its order, idempotent install, persistence and removal.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { run, withTemp, chain, calls, TEST_NET } from './helpers.mjs';

const S = TEST_NET.CAGE_SUBNET;

test('print: tailnet ACCEPT first, then the two conntrack lines, REJECT last', () => {
  const r = run('bash', ['egress-rules.sh', 'print'], { env: TEST_NET });
  assert.equal(r.code, 0, r.err);
  assert.deepEqual(r.out.trim().split('\n'), [
    `-s ${S} -d 100.64.0.10/32 -p tcp -m tcp --dport 8000 -j ACCEPT`,
    `-s ${S} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT`,
    `-d ${S} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT`,
    `-s ${S} -j REJECT --reject-with icmp-port-unreachable`,
  ]);
});

test('print: with no tailnet host there is no ACCEPT to the tailnet at all', () => {
  const r = run('bash', ['egress-rules.sh', 'print'], { env: { ...TEST_NET, TAILNET_ALLOW_HOST: '' } });
  assert.equal(r.code, 0, r.err);
  const lines = r.out.trim().split('\n');
  assert.equal(lines.length, 3);
  assert.ok(!lines.some((l) => l.includes('--dport')));
  assert.match(lines.at(-1), /-j REJECT/);
});

test('refuses a placeholder, a hostname and a bad network instead of writing a broken rule', () => {
  for (const [key, value] of [
    ['CAGE_SUBNET', 'your-cage-subnet'],
    ['CAGE_SUBNET', '203.0.113.0'],
    ['CAGE_GATEWAY', 'gateway.example.com'],
    ['TAILNET_ALLOW_HOST', 'model-server.example.com'],
  ]) {
    const r = run('bash', ['egress-rules.sh', 'print'], { env: { ...TEST_NET, [key]: value } });
    assert.equal(r.code, 1, `${key}=${value} was accepted`);
    assert.match(r.err, new RegExp(key));
    assert.equal(r.out, '');
  }
});

test('install refuses to run as a normal user', () => {
  withTemp((st) => {
    const r = run('bash', ['egress-rules.sh', 'install'], { env: { ...TEST_NET, STUB_STATE: st, STUB_UID: '10001' }, stubs: true });
    assert.equal(r.code, 1);
    assert.match(r.err, /root/);
  });
});

function afterRules(dir) {
  const f = join(dir, 'after.rules');
  writeFileSync(f, '*filter\n:ufw-after-input - [0:0]\n-A ufw-after-input -j RETURN\nCOMMIT\n*nat\nCOMMIT\n');
  return f;
}

test('install twice: same rules once, on top of DOCKER-USER above a RETURN, persisted once before the first COMMIT', () => {
  withTemp((st) => {
    const ar = afterRules(st);
    // Some Docker versions create DOCKER-USER with a RETURN rule. An appended rule would be dead.
    writeFileSync(join(st, 'chain.DOCKER-USER'), '-A DOCKER-USER -j RETURN\n');
    const env = { ...TEST_NET, STUB_STATE: st, UFW_AFTER_RULES: ar };
    for (let i = 0; i < 2; i++) {
      const r = run('bash', ['egress-rules.sh', 'install'], { env, stubs: true });
      assert.equal(r.code, 0, r.out + r.err);
      assert.match(r.out, /verify ok/);
    }
    const live = chain(st, 'DOCKER-USER');
    assert.equal(live.length, 5, live.join('\n'));
    assert.match(live[0], /--dport 8000 -j ACCEPT/);
    assert.match(live[3], /-j REJECT/);
    assert.equal(live[4], '-A DOCKER-USER -j RETURN');
    const text = readFileSync(ar, 'utf8');
    assert.equal(text.split('# BEGIN agent-cage egress').length - 1, 1, 'the block was stacked');
    assert.ok(text.indexOf('# END agent-cage egress') < text.indexOf('COMMIT'), 'the block is not inside *filter');
    assert.equal(readFileSync(join(st, 'ufw'), 'utf8').trim().split('\n').length, 2, 'the ufw rules were stacked');
  });
});

test('verify fails when the REJECT is missing or a RETURN sits above it', () => {
  withTemp((st) => {
    const ar = afterRules(st);
    const env = { ...TEST_NET, STUB_STATE: st, UFW_AFTER_RULES: ar };
    assert.equal(run('bash', ['egress-rules.sh', 'install'], { env, stubs: true }).code, 0);
    const live = chain(st, 'DOCKER-USER');
    writeFileSync(join(st, 'chain.DOCKER-USER'), ['-A DOCKER-USER -j RETURN', ...live].join('\n') + '\n');
    let r = run('bash', ['egress-rules.sh', 'verify'], { env, stubs: true });
    assert.equal(r.code, 1);
    assert.match(r.out, /RETURN rule sits above/);
    writeFileSync(join(st, 'chain.DOCKER-USER'), live.filter((l) => !l.includes('REJECT')).join('\n') + '\n');
    r = run('bash', ['egress-rules.sh', 'verify'], { env, stubs: true });
    assert.equal(r.code, 1);
    assert.match(r.out, /FAIL missing: .*REJECT/);
  });
});

test('remove takes out the live rules, the ufw rule and the persisted block, and nothing else', () => {
  withTemp((st) => {
    const ar = afterRules(st);
    const before = readFileSync(ar, 'utf8');
    writeFileSync(join(st, 'chain.DOCKER-USER'), '-A DOCKER-USER -s 203.0.113.99/32 -j DROP\n');
    const env = { ...TEST_NET, STUB_STATE: st, UFW_AFTER_RULES: ar };
    assert.equal(run('bash', ['egress-rules.sh', 'install'], { env, stubs: true }).code, 0);
    const r = run('bash', ['egress-rules.sh', 'remove'], { env, stubs: true });
    assert.equal(r.code, 0, r.err);
    assert.deepEqual(chain(st, 'DOCKER-USER'), ['-A DOCKER-USER -s 203.0.113.99/32 -j DROP']);
    assert.equal(readFileSync(ar, 'utf8'), before);
    assert.equal(readFileSync(join(st, 'ufw'), 'utf8').trim(), '');
  });
});

// Host input: traffic from the cage to the host's own addresses is INPUT, which DOCKER-USER
// never sees. ufw holds it with two rules at the top of its list, first match wins:
// [1] the proxy ALLOW, [2] a REJECT for the rest of the cage subnet.
const G = TEST_NET.CAGE_GATEWAY;
const ALLOW = `allow from ${S} to ${G} port 3128 proto tcp`;
const REJECT = `reject from ${S}`;
const WORLD_SSH = 'allow 22/tcp';
const ufwRules = (st) => readFileSync(join(st, 'ufw'), 'utf8').trim().split('\n').filter(Boolean);
const setUfw = (st, rules) => writeFileSync(join(st, 'ufw'), rules.map((r) => r + '\n').join(''));
const hostEnv = (st) => ({ ...TEST_NET, STUB_STATE: st, UFW_AFTER_RULES: afterRules(st) });

test('host input: install puts the proxy ALLOW at rule 1 and the cage REJECT at rule 2, above a world-open port', () => {
  withTemp((st) => {
    setUfw(st, [WORLD_SSH]);
    const env = hostEnv(st);
    const r = run('bash', ['egress-rules.sh', 'install'], { env, stubs: true });
    assert.equal(r.code, 0, r.out + r.err);
    assert.deepEqual(ufwRules(st), [ALLOW, REJECT, WORLD_SSH]);
    const v = run('bash', ['egress-rules.sh', 'verify-host'], { env, stubs: true });
    assert.equal(v.code, 0, v.out);
    assert.match(v.out, /host input ok/);
  });
});

test('host input: with no ufw rules at all, the first rule is added, then the ALLOW goes above it', () => {
  withTemp((st) => {
    const r = run('bash', ['egress-rules.sh', 'install'], { env: hostEnv(st), stubs: true });
    assert.equal(r.code, 0, r.out + r.err);
    assert.deepEqual(ufwRules(st), [ALLOW, REJECT]);
  });
});

test('host input: a second run changes nothing', () => {
  withTemp((st) => {
    setUfw(st, [WORLD_SSH]);
    const env = hostEnv(st);
    assert.equal(run('bash', ['egress-rules.sh', 'install'], { env, stubs: true }).code, 0);
    const before = calls(st).length;
    assert.equal(run('bash', ['egress-rules.sh', 'install'], { env, stubs: true }).code, 0);
    const second = calls(st).slice(before).filter((c) => /^ufw (--force )?(insert|delete|allow|reject)/.test(c));
    assert.deepEqual(second, [], 'the second run rewrote ufw rules');
    assert.deepEqual(ufwRules(st), [ALLOW, REJECT, WORLD_SSH]);
  });
});

test('host input: verify fails when the REJECT is missing', () => {
  withTemp((st) => {
    setUfw(st, [ALLOW, WORLD_SSH]);
    const r = run('bash', ['egress-rules.sh', 'verify-host'], { env: hostEnv(st), stubs: true });
    assert.equal(r.code, 1);
    assert.match(r.out, /no ufw REJECT for the cage subnet/);
  });
});

test('host input: verify fails when the REJECT sits above the proxy ALLOW', () => {
  withTemp((st) => {
    setUfw(st, [REJECT, ALLOW, WORLD_SSH]);
    const r = run('bash', ['egress-rules.sh', 'verify-host'], { env: hostEnv(st), stubs: true });
    assert.equal(r.code, 1);
    assert.match(r.out, /proxy ALLOW is not ufw rule 1/);
  });
});

test('host input: verify fails when a world-open rule sits above the cage REJECT', () => {
  withTemp((st) => {
    setUfw(st, [ALLOW, WORLD_SSH, REJECT]);
    const r = run('bash', ['egress-rules.sh', 'verify-host'], { env: hostEnv(st), stubs: true });
    assert.equal(r.code, 1);
    assert.match(r.out, /cage REJECT is not ufw rule 2/);
  });
});

test('host input: install repairs a wrong order, and the full verify fails on it first', () => {
  withTemp((st) => {
    const env = hostEnv(st);
    assert.equal(run('bash', ['egress-rules.sh', 'install'], { env, stubs: true }).code, 0);
    setUfw(st, [REJECT, ALLOW, WORLD_SSH]);
    assert.equal(run('bash', ['egress-rules.sh', 'verify'], { env, stubs: true }).code, 1);
    assert.equal(run('bash', ['egress-rules.sh', 'install'], { env, stubs: true }).code, 0);
    assert.deepEqual(ufwRules(st), [ALLOW, REJECT, WORLD_SSH]);
  });
});
