// tailnet-guard.sh: the fix for the hole. Tailscale's jump at the top of FORWARD accepts every
// packet bound for the tailnet before DOCKER-USER sees it; the guard keeps the cage's two rules
// above that jump, and puts them back after tailscaled moves its jump to the top again.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { run, withTemp, chain, setChain, calls, TEST_NET } from './helpers.mjs';

const S = TEST_NET.CAGE_SUBNET;
const ACCEPT = `-A FORWARD -s ${S} -d 100.64.0.10/32 -o tailscale0 -p tcp -m tcp --dport 8000 -j ACCEPT`;
const REJECT = `-A FORWARD -s ${S} -o tailscale0 -j REJECT --reject-with icmp-port-unreachable`;
const TS = '-A FORWARD -j ts-forward';
const DOCKER = ['-A FORWARD -j DOCKER-USER', '-A FORWARD -j DOCKER-FORWARD'];

const guard = (st, args = [], extra = {}) =>
  run('bash', ['tailnet-guard.sh', ...args], { env: { ...TEST_NET, STUB_STATE: st, ...extra }, stubs: true });
const inserts = (st) => calls(st).filter((c) => c.startsWith('iptables -I')).length;

test('the hole: with only Tailscale and Docker rules, tailnet traffic meets ts-forward first', () => {
  withTemp((st) => {
    setChain(st, 'FORWARD', [TS, ...DOCKER]);
    assert.equal(guard(st, ['check']).code, 1, 'check passed on an unguarded chain');
    assert.equal(chain(st, 'FORWARD')[0], TS);
  });
});

test('assert puts ACCEPT then REJECT above the ts-forward jump', () => {
  withTemp((st) => {
    setChain(st, 'FORWARD', [TS, ...DOCKER]);
    const r = guard(st);
    assert.equal(r.code, 0, r.err);
    assert.deepEqual(chain(st, 'FORWARD'), [ACCEPT, REJECT, TS, ...DOCKER]);
    assert.equal(guard(st, ['check']).code, 0);
    assert.ok(calls(st).some((c) => c.startsWith('logger -t agent-cage-guard')), 'no log line on a repair');
  });
});

test('assert is silent and changes nothing when the order is already right', () => {
  withTemp((st) => {
    setChain(st, 'FORWARD', [ACCEPT, REJECT, TS, ...DOCKER]);
    const r = guard(st);
    assert.equal(r.code, 0);
    assert.equal(r.out + r.err, '');
    assert.equal(inserts(st), 0);
  });
});

test('a tailscaled restart moves its jump back to the top; the next run restores the order', () => {
  withTemp((st) => {
    setChain(st, 'FORWARD', [ACCEPT, REJECT, TS, ...DOCKER]);
    // What tailscaled does on start: its jump is re-inserted at position 1.
    setChain(st, 'FORWARD', [TS, ACCEPT, REJECT, ...DOCKER]);
    assert.equal(guard(st, ['check']).code, 1);
    assert.equal(guard(st).code, 0);
    assert.deepEqual(chain(st, 'FORWARD'), [ACCEPT, REJECT, TS, ...DOCKER]);
  });
});

test('duplicates from a crash mid-repair are collapsed to one copy of each rule', () => {
  withTemp((st) => {
    setChain(st, 'FORWARD', [TS, REJECT, ACCEPT, REJECT, ...DOCKER]);
    assert.equal(guard(st).code, 0);
    assert.deepEqual(chain(st, 'FORWARD'), [ACCEPT, REJECT, TS, ...DOCKER]);
  });
});

test('with no allowed tailnet host: only the REJECT, and an ACCEPT left by an old host is removed', () => {
  withTemp((st) => {
    const old = `-A FORWARD -s ${S} -d 100.64.0.77/32 -o tailscale0 -p tcp -m tcp --dport 8000 -j ACCEPT`;
    setChain(st, 'FORWARD', [TS, old, ...DOCKER]);
    assert.equal(guard(st, [], { TAILNET_ALLOW_HOST: '' }).code, 0);
    assert.deepEqual(chain(st, 'FORWARD'), [REJECT, TS, ...DOCKER]);
  });
});

test('remove takes out only the cage rules', () => {
  withTemp((st) => {
    setChain(st, 'FORWARD', [ACCEPT, REJECT, TS, ...DOCKER]);
    assert.equal(guard(st, ['remove']).code, 0);
    assert.deepEqual(chain(st, 'FORWARD'), [TS, ...DOCKER]);
  });
});

test('print needs no root; every other action does', () => {
  withTemp((st) => {
    const p = guard(st, ['print'], { STUB_UID: '10001' });
    assert.equal(p.code, 0);
    assert.deepEqual(p.out.trim().split('\n'), [ACCEPT.slice('-A FORWARD '.length), REJECT.slice('-A FORWARD '.length)]);
    setChain(st, 'FORWARD', [TS]);
    const r = guard(st, [], { STUB_UID: '10001' });
    assert.equal(r.code, 1);
    assert.match(r.err, /root/);
    assert.deepEqual(chain(st, 'FORWARD'), [TS]);
  });
});

test('refuses a placeholder subnet rather than install a rule that matches nothing', () => {
  withTemp((st) => {
    const r = guard(st, [], { CAGE_SUBNET: 'your-cage-subnet' });
    assert.equal(r.code, 1);
    assert.match(r.err, /CAGE_SUBNET/);
    assert.equal(calls(st).length, 0);
  });
});
