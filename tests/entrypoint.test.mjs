// entrypoint.sh: the fix for the second hole. The token comes from a read-only file into the
// agent's own process; it is never printed, and nothing but the named lines is loaded.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { run, withTemp } from './helpers.mjs';

const SECRET = 'fake-token-for-tests-0001';

function entry(dir, keys, cmd, extra = {}) {
  const file = join(dir, 'token');
  return run('sh', ['entrypoint.sh', ...cmd], {
    env: { CAGE_TOKEN_FILE: file, CAGE_TOKEN_KEYS: keys, STUB_UID: '10001', ...extra },
    stubs: true,
  });
}

test('the named keys reach the agent process; other lines do not; the value is never printed', () => {
  withTemp((dir) => {
    writeFileSync(join(dir, 'token'),
      `# comment\nAGENT_TOKEN=${SECRET}\nOTHER_SECRET=not-for-the-agent\nQUOTED="two words"\n`);
    const child = 'printf "token=%s quoted=%s other=%s\\n" "${AGENT_TOKEN:+set}" "$QUOTED" "${OTHER_SECRET:-unset}"';
    const r = entry(dir, 'AGENT_TOKEN QUOTED', ['sh', '-c', child]);
    assert.equal(r.code, 0, r.err);
    assert.match(r.out, /token=set quoted=two words other=unset/);
    assert.match(r.out, /token keys loaded: AGENT_TOKEN QUOTED/);
    assert.ok(!(r.out + r.err).includes(SECRET), 'the token value was printed');
  });
});

test('a value holding = and spaces arrives intact; the last line for a key wins', () => {
  withTemp((dir) => {
    writeFileSync(join(dir, 'token'), 'AGENT_TOKEN=old\nAGENT_TOKEN=a=b c\n');
    const r = entry(dir, 'AGENT_TOKEN', ['sh', '-c', '[ "$AGENT_TOKEN" = "a=b c" ] && echo intact']);
    assert.equal(r.code, 0, r.err);
    assert.match(r.out, /intact/);
  });
});

test('a key with no line, an empty value, or no readable file stops the start with 78', () => {
  withTemp((dir) => {
    writeFileSync(join(dir, 'token'), 'AGENT_TOKEN=\n');
    let r = entry(dir, 'AGENT_TOKEN', ['true']);
    assert.equal(r.code, 78);
    assert.match(r.err, /no value for AGENT_TOKEN/);
    r = entry(dir, 'MISSING_KEY', ['true']);
    assert.equal(r.code, 78);
    r = entry(dir, 'AGENT_TOKEN', ['true'], { CAGE_TOKEN_FILE: join(dir, 'absent') });
    assert.equal(r.code, 78);
    assert.match(r.err, /cannot read the token file/);
  });
});

test('a key name that is not a variable name is refused, so it cannot inject a sed expression', () => {
  withTemp((dir) => {
    writeFileSync(join(dir, 'token'), `AGENT_TOKEN=${SECRET}\n`);
    for (const bad of ['A.*', 'A/B', '1ABC', 'A-B']) {
      const r = entry(dir, bad, ['true']);
      assert.equal(r.code, 78, `${bad} was accepted`);
      assert.ok(!(r.out + r.err).includes(SECRET));
    }
  });
});

test('no token wanted: runs the command with nothing loaded', () => {
  withTemp((dir) => {
    const r = entry(dir, '', ['sh', '-c', 'echo ran']);
    assert.equal(r.code, 0, r.err);
    assert.match(r.out, /token keys loaded: none/);
    assert.match(r.out, /ran/);
  });
});

test('no command: exit 64. Running as root: exit 77, before the token is read', () => {
  withTemp((dir) => {
    writeFileSync(join(dir, 'token'), `AGENT_TOKEN=${SECRET}\n`);
    assert.equal(entry(dir, 'AGENT_TOKEN', []).code, 64);
    const r = entry(dir, 'AGENT_TOKEN', ['sh', '-c', 'echo ran'], { STUB_UID: '0' });
    assert.equal(r.code, 77);
    assert.ok(!r.out.includes('ran'));
  });
});
