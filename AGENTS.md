# AGENTS.md

Instructions for an AI agent working in this repo. You are editing the cage, not living in it.

## Install

```bash
npm ci
```

Node 20 or newer (CI tests 20 and 22). There are no dependencies; `npm ci` only checks the
lockfile. The tests also need `bash`, `sh` and `python3`. The Docker drills need Docker.

## Run

The cage runs on a Linux host as root, through `apply.sh`. Never run `apply.sh`,
`egress-rules.sh install`, `tailnet-guard.sh` or any `iptables` or `ufw` command on a machine
you were not asked to change. To read what they would do:

```bash
bash apply.sh --check-config --env cage.env    # reads the settings and stops
bash egress-rules.sh print                     # the egress rules it would install
bash tailnet-guard.sh print                    # the two FORWARD rules
node docs/img/make.mjs                         # rebuild the two README diagrams
```

## Test

```bash
npm test               # offline, no root: iptables, ufw and id are stubbed in tests/stubs/
npm run test:docker    # verify-cage.sh in three real containers; needs Docker
```

CI runs both (`.github/workflows/ci.yml`). A new behavior in a script needs a new assertion.

## Where you may edit

- `*.sh`, `compose.yaml`, `host/`: the cage. Keep every script idempotent.
- `tests/`: the tests and stubs. A stub may only grow to cover what a script really calls.
- `cage.env.example`: every setting a script or `compose.yaml` reads has a line here, with a
  comment. Addresses stay as `your-` placeholders.
- `docs/img/make.mjs`, then rerun it. Never hand-edit the SVGs.
- `README.md`, `THREAT-MODEL.md`, `AGENTS.md`: plain technical prose.

## Where you may not edit

- The first section of `README.md` (the story under the title) is the owner's words. Leave it.
- `PERMISSION-ENVELOPE.md` changes only on the owner's decision.
- `LICENSE`.

## Never

- Never weaken `compose.yaml`: no `privileged`, `cap_add`, host networking, host pid or ipc, a
  Docker socket mount, an `unconfined` security option, `read_only: false`, a published port,
  or a root user. `tests/compose.test.mjs` fails on each.
- Never pass a secret through `env_file` or `environment:`. Tokens go in the token file.
- Never move the cage's rules below Tailscale's jump in FORWARD, or append to DOCKER-USER
  instead of inserting at the top.
- Never print a token value, not in a script, a test or a log line. Names only.
- Never let a drill that could not run print PASS.
- Never write a real address, hostname, account name or chat id, not even in a test. Use
  `localhost`, never a numeric loopback, and the documentation ranges `203.0.113.x` and
  `100.64.0.x` in tests.
- Never name a specific agent product. The cage runs whatever `AGENT_IMAGE` says.
- Never use em dashes in prose.

## Before each commit

Run an identity and secret scan over the tree and the history: no names, home paths,
addresses, emails, hostnames or key shapes. Then run `npm test`.
