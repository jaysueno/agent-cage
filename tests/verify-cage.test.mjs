// verify-cage.sh run on the test machine itself, which is not caged: the drills must say so.
// The full matrix (read-only root, dropped capabilities, closed networks) runs in containers:
// tests/docker-drills.sh, in CI.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:net';
import { run } from './helpers.mjs';

const DRILLS = ['egress', 'tailnet', 'syscall', 'write', 'token'];
const LINE = /^(PASS|FAIL) (egress|tailnet|syscall|write|token): /;

function verdicts(out) {
  const v = {};
  for (const line of out.split('\n')) {
    const m = line.match(LINE);
    if (m) {
      assert.ok(!(m[2] in v), `two lines for ${m[2]}`);
      v[m[2]] = m[1];
    }
  }
  assert.deepEqual(Object.keys(v).sort(), [...DRILLS].sort(), out);
  return v;
}

async function listener() {
  const srv = createServer((c) => c.end());
  await new Promise((ok) => srv.listen(0, ok));
  return srv;
}

async function closedPort() {
  const srv = await listener();
  const { port } = srv.address();
  await new Promise((ok) => srv.close(ok));
  return port;
}

const drill = (env) => run('bash', ['verify-cage.sh'], { env });

test('an open connection, a set token: FAIL lines and exit 1; a closed port: PASS', async () => {
  const srv = await listener();
  const shut = await closedPort();
  try {
    const r = drill({
      VERIFY_EGRESS_URL: `http://localhost:${srv.address().port}/`,
      VERIFY_TAILNET_HOST: 'localhost',
      VERIFY_TAILNET_PORT: String(shut),
      VERIFY_TOKEN_VARS: 'CAGE_TEST_TOKEN',
      CAGE_TEST_TOKEN: 'fake-value',
    });
    const v = verdicts(r.out);
    assert.equal(v.egress, 'FAIL');
    assert.equal(v.tailnet, 'PASS');
    assert.equal(v.token, 'FAIL');
    assert.equal(r.code, 1);
    assert.ok(!r.out.includes('fake-value'), 'the token value was printed');
  } finally {
    srv.close();
  }
});

test('a name that does not resolve counts as held; an unset token passes', async () => {
  const shut = await closedPort();
  const r = drill({
    VERIFY_EGRESS_URL: 'http://cage-drill.invalid:8080/',
    VERIFY_TAILNET_HOST: 'localhost',
    VERIFY_TAILNET_PORT: String(shut),
    VERIFY_TOKEN_VARS: 'CAGE_TEST_TOKEN',
  });
  const v = verdicts(r.out);
  assert.equal(v.egress, 'PASS');
  assert.equal(v.token, 'PASS');
});

test('a drill that cannot run is a FAIL, never a PASS', () => {
  // No tailnet host, no token names.
  let v = verdicts(drill({ VERIFY_TAILNET_HOST: '', VERIFY_TOKEN_VARS: ' ' }).out);
  assert.equal(v.tailnet, 'FAIL');
  assert.equal(v.token, 'FAIL');
  v = verdicts(drill({ VERIFY_TAILNET_HOST: 'your-other-tailnet-host' }).out);
  assert.equal(v.tailnet, 'FAIL');
  // No python3 at all: every drill FAILs.
  const r = run('/bin/bash', ['verify-cage.sh'], { env: { PATH: '/nonexistent' } });
  v = verdicts(r.out);
  assert.deepEqual(Object.values(v), ['FAIL', 'FAIL', 'FAIL', 'FAIL', 'FAIL']);
  assert.equal(r.code, 1);
});
