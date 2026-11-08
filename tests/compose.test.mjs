// compose.yaml: every service carries the full hardening, and nothing weakens it. The linter
// proves it can see each weakness on a planted copy before its verdict on the real file counts.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { ROOT } from './helpers.mjs';
import { lint, services } from './compose-lint.mjs';

const REAL = readFileSync(join(ROOT, 'compose.yaml'), 'utf8');

const plant = (find, replace) => {
  assert.ok(REAL.includes(find), `plant anchor missing: ${find}`);
  return REAL.replace(find, replace);
};

const PLANTS = [
  ['agent:READ_ONLY', () => plant('    read_only: true\n    tmpfs:\n      - /tmp:rw,noexec,nosuid,size=128m', '    tmpfs:\n      - /tmp:rw,noexec,nosuid,size=128m')],
  ['agent:CAP_DROP_ALL', () => plant('    cap_drop: [ALL]\n    security_opt:\n      - no-new-privileges:true\n\n    environment:', '    cap_drop: [NET_RAW]\n    security_opt:\n      - no-new-privileges:true\n\n    environment:')],
  ['agent:PIDS_LIMIT', () => plant('    pids_limit: 512\n', '    pids_limit: -1\n')],
  ['agent:NON_ROOT_USER', () => plant('    user: "${AGENT_UID}:${AGENT_GID}"\n\n', '    user: "0:0"\n\n')],
  ['agent:ENV_FILE', () => plant('    init: true\n', '    init: true\n    env_file: cage.env\n')],
  ['agent:PORTS', () => plant('    init: true\n', '    init: true\n    ports:\n      - "8080:8080"\n')],
  ['agent:DOCKER_SOCK', () => plant('      - ./entrypoint.sh:/cage/entrypoint.sh:ro\n', '      - ./entrypoint.sh:/cage/entrypoint.sh:ro\n      - /var/run/docker.sock:/var/run/docker.sock\n')],
  ['agent:WRITABLE_MOUNT', () => plant('${TOKEN_HOST_FILE}:${CAGE_TOKEN_FILE}:ro', '${TOKEN_HOST_FILE}:${CAGE_TOKEN_FILE}:rw')],
  ['verify:PRIVILEGED', () => plant('    working_dir: /tmp\n', '    working_dir: /tmp\n    privileged: true\n')],
  ['verify:CAP_ADD', () => plant('    working_dir: /tmp\n', '    working_dir: /tmp\n    cap_add:\n      - NET_ADMIN\n')],
  ['verify:HOST_NETWORK_MODE', () => plant('    working_dir: /tmp\n', '    working_dir: /tmp\n    network_mode: host\n')],
  ['verify:UNCONFINED', () => plant('    working_dir: /tmp\n', '    working_dir: /tmp\n    security_opt:\n      - no-new-privileges:true\n      - seccomp=unconfined\n')],
  ['verify:MEM_LIMIT', () => plant('    mem_limit: 256m\n', '')],
];

test('the linter reads both services', () => {
  assert.deepEqual(Object.keys(services(REAL)), ['agent', 'verify']);
});

test('the linter catches every planted weakness, each as exactly the expected problem', () => {
  for (const [want, make] of PLANTS) {
    assert.deepEqual(lint(make()), [want], `plant ${want}`);
  }
});

test('a hardening key that only appears in a comment does not count', () => {
  const text = plant('    read_only: true\n', '    # read_only: true\n');
  assert.deepEqual(lint(text), ['agent:READ_ONLY']);
});

test('compose.yaml: every service is fully hardened, nothing weakens it', () => {
  assert.deepEqual(lint(REAL), []);
});

test('compose.yaml: no env_file anywhere, and the agent publishes no port', () => {
  assert.ok(!/^\s*env_file\s*:/m.test(REAL), 'env_file puts its values into docker inspect');
  assert.ok(!/^\s*ports\s*:/m.test(REAL));
});
