# agent-cage

On August 27, 2026 I gave a personal AI agent its own Unix user, a read-only
filesystem, and a firewall on a cheap VPS. Then I found the firewall did not apply to the private
network: Tailscale's forwarding chain sits above Docker's, so the egress rule was dead code for
every machine on my tailnet. Two lines fixed it, and a 60-second guard keeps them in place after a
Tailscale restart. This repo is the cage, the permission envelope, and the fire drills that prove it
holds. It has run in production since that day.

## What it does

![Diagram: the agent container runs as uid 10001 on a read-only root with every capability dropped; it can reach exactly two places, the host's allowlisting proxy and one tailnet host and port, and every other destination, including the host's other ports, is rejected.](docs/img/cage.svg)

It runs any agent you give it inside a Docker container on a Linux host, and it holds the agent
there with the kernel and the firewall, never with the model's good behavior. The agent is an
image and a command in `cage.env`. The cage does not know or care which agent it is.

Two kinds of firewall rule hold it. Rules in Docker's `DOCKER-USER` chain cover traffic that
leaves the host. Two ufw rules cover traffic to the host itself: the proxy port is allowed,
and every other port on the host is rejected, including ones ufw opens to the world.

| Layer | What holds | File |
|---|---|---|
| User | Its own Unix user (uid 10001 in the example). The entrypoint refuses to run the agent as root. | `compose.yaml`, `entrypoint.sh` |
| Filesystem | Read-only root. It writes only its home folder, an outbox for drafts, and a 128 MB `/tmp`. | `compose.yaml` |
| Kernel | Every capability dropped, `no-new-privileges`, a memory limit with no swap (4 GB in the example), 512 processes, 2 CPUs. | `compose.yaml` |
| Network out | Default deny for traffic leaving the host: one door to the web (an allowlisting proxy on the host) and one door into your tailnet (one host, one port). Everything else off the host gets a REJECT, and so does every port on the host except the proxy's. | `egress-rules.sh`, `tailnet-guard.sh`, `host/` |
| Token | A root-owned file read inside the container at start. Never in `docker inspect`, the image, a command line or a log. | `entrypoint.sh` |
| Proof | Five fire drills that try what the cage must refuse and print PASS or FAIL for each. | `verify-cage.sh` |
| Rules for the agent | GREEN, YELLOW and RED actions, and the modes it may run in. | `PERMISSION-ENVELOPE.md` |
| Limits | What the cage does not defend against. | `THREAT-MODEL.md` |

One command, `apply.sh`, builds all of it on the host, starts the agent and runs every check.
Run it twice and the second run changes nothing.

## Run it

You need an Ubuntu host (22.04 or 24.04) with Docker Engine and the compose plugin, `ufw`
active, `tinyproxy` installed, and Tailscale if the agent should reach a machine on your
tailnet. The agent image must run as an arbitrary uid on a read-only root filesystem.

```bash
sudo git clone https://github.com/jaysueno/agent-cage /opt/agent-cage   # keep it root-owned
cd /opt/agent-cage
sudo cp cage.env.example cage.env && sudo chmod 600 cage.env
sudoedit cage.env                     # fill in every value that starts with your-

# The token file: root-owned, group = AGENT_GID, mode 0640, one NAME=value line per key.
sudo install -D -m 0640 -o root -g 10001 /dev/null /etc/agent-cage/token
sudoedit /etc/agent-cage/token        # AGENT_TOKEN=...

sudo bash apply.sh --check-config     # reads cage.env and stops
sudo bash apply.sh --dry-run          # prints every change, makes none
sudo bash apply.sh                    # builds the cage, starts the agent, runs every check
```

To try the cage before you pick an agent, set `AGENT_IMAGE=python:3.12-slim`,
`AGENT_COMMAND="sleep infinity"` and `CAGE_TOKEN_KEYS=`. That image has bash and python3, so
`apply.sh` runs the drills inside the agent container as well as in a throwaway one.

Day to day:

```bash
docker compose --env-file cage.env logs -f agent                  # what it is doing
docker compose --env-file cage.env --profile verify run --rm verify   # the drills, any time
sudo bash apply.sh --verify-only                                  # every check, no changes
```

### Rebuild it at 2am

The host died, or you broke it. Everything that matters is in four places: this folder, your
`cage.env`, the token file, and the agent's home folder (`AGENT_HOME_DIR`). Back those up.

1. New host: install Docker, the compose plugin, ufw, tinyproxy and Tailscale. Turn ufw on.
2. Put this folder at `/opt/agent-cage`, owned by root. Copy `cage.env` into it.
3. Restore the token file with owner root, group `AGENT_GID`, mode 0640. Restore the home folder.
4. `sudo bash apply.sh`. Read the PASS and FAIL lines at the end. Every one should say PASS.

To take the cage back out, run the block at the top of `apply.sh` (it prints it on any
failure too):

```bash
cd /opt/agent-cage
docker compose --env-file cage.env down
systemctl disable --now agent-cage-guard.timer
bash tailnet-guard.sh remove
bash egress-rules.sh remove
cp -p /etc/tinyproxy/tinyproxy.conf.bak-agent-cage /etc/tinyproxy/tinyproxy.conf && systemctl restart tinyproxy
cp -p /etc/ufw/after.rules.bak-agent-cage /etc/ufw/after.rules && ufw reload
```

## Test it

[![ci](https://github.com/jaysueno/agent-cage/actions/workflows/ci.yml/badge.svg)](https://github.com/jaysueno/agent-cage/actions/workflows/ci.yml)

```bash
npm ci
npm test               # offline: no Docker, no root, no network
npm run test:docker    # the drills in real containers (needs Docker)
```

Node 20 or newer, no dependencies. The host scripts run against stand-ins for `iptables`,
`ufw` and `id` (`tests/stubs/`), so the tests never touch a real firewall.

- `tests/tailnet-guard.test.mjs` replays the hole: a FORWARD chain with Tailscale's jump on top
  fails the check; the guard puts its two rules above the jump; a tailscaled restart moves the
  jump back to the top and the next run repairs it; a second run changes nothing.
- `tests/egress-rules.test.mjs` checks the rule order (the REJECT is always last), that install
  twice leaves one copy of everything, that rules go above a RETURN some Docker versions add,
  and that remove leaves other rules alone. For the two host-input rules it checks that they
  land at ufw rules 1 and 2 above a world-open port, that a second run changes nothing, and that
  verify fails when the REJECT is missing, sits above the ALLOW, or sits below a world-open rule.
- `tests/entrypoint.test.mjs` proves the token reaches the agent process and is never printed,
  that only named lines load, and that a missing token, a bad key name or a root user stops
  the start.
- `tests/compose.test.mjs` checks every service for the full hardening and for anything that
  weakens it (`privileged`, `cap_add`, host networking, the Docker socket, `env_file`, a
  published port). It plants each weakness in a copy first and must catch every one before its
  verdict on the real file counts.
- `tests/verify-cage.test.mjs` runs the drills on the test machine, which is not caged, so they
  must report FAIL where the door is open, and FAIL when a drill cannot run.
- `tests/config.test.mjs` checks that `cage.env.example` lists every setting, and that
  `apply.sh --check-config` refuses the placeholders and every setting that would build a
  weaker cage.
- `tests/docker-drills.sh` runs `verify-cage.sh` in three containers built to disagree: fully
  caged (five PASS), wide open (five FAIL), and mixed. CI runs it on every push.

On the host, `apply.sh` ends with the real thing: the posture of the running container read
from `docker inspect`, a proxy request for an address off the allowlist (it must get a 403),
the firewall rules, and the five drills on the cage network.

## How it works

![Diagram: before the fix, a packet from the cage to the tailnet hit Tailscale's forward chain first and was accepted before the cage's REJECT in DOCKER-USER; after the fix, two cage rules sit above Tailscale's jump and a guard restores them every 60 seconds.](docs/img/forward-chain.svg)

```text
             the web                              your tailnet
                ^                                      ^
                | allowlisted names, port 443          | one host, one port
     +----------+-----------+            +-------------+-------------+
     | tinyproxy on the host |            | FORWARD rules 1 and 2     |
     | host/proxy-allowlist  |            | above Tailscale's jump    |
     +----------^-----------+            +-------------^-------------+
                | ufw: the proxy port only             | tailnet-guard.sh, every 60 s
     +----------+--------------------------------------+-------------+
     | cage network CAGE_SUBNET          DOCKER-USER: REJECT the rest |  egress-rules.sh
     |   +-----------------------------------------------------+      |
     |   | agent  uid 10001, read-only root, no capabilities,  |      |
     |   |        memory and process limits, no ports          |      |
     |   |        token read from a file by entrypoint.sh      |      |
     |   +-----------------------------------------------------+      |
     +---------------------------------------------------------------+
```

When the cage talks to another machine, Linux passes the packet through the FORWARD chain, and
Docker puts its own chains in front of ufw's there. A ufw deny rule never sees that packet. So
the cage writes its rules into `DOCKER-USER`, which Docker evaluates first and leaves as it is:
accept the one tailnet host and port, accept replies, reject the rest of the cage subnet. A
reject gets an answer at once; a drop would leave the agent waiting for its own timeout.

`DOCKER-USER` covers forwarded traffic only. A packet from the cage to one of the host's own
addresses (the cage gateway, the public address, the host's tailnet address) is INPUT, and ufw
decides it. Two ufw rules sit at the top of ufw's list, where the first match wins:

```text
[1] ALLOW   cage subnet -> cage gateway, proxy port, tcp
[2] REJECT  cage subnet -> anything else on the host
```

The order is the whole rule. With the REJECT first, the proxy is cut off and the agent cannot
talk at all. With either rule below an allow that opens a port to the world (SSH, a web
server), the cage reaches that port, because ufw stops at the first match. ufw will not move a
rule that already exists, so `egress-rules.sh` deletes both and inserts them again at position
1, the REJECT first and then the ALLOW above it. When they are already in place it changes
nothing. `egress-rules.sh verify-host` fails if either is missing or out of order.

The proxy is tinyproxy. With `FilterDefaultDeny Yes` its filter file can only allow, so the
file is the whole allowlist. The shipped list, `host/proxy-allowlist.messenger`, holds one chat
API host. `ConnectPort 443` limits HTTPS through the proxy to port 443. Read `THREAT-MODEL.md`
before you add hosts: the proxy resolves every name you allow and connects from the host.

### The hole in the firewall (2026-08-27)

On 2026-08-27, the day the cage went live, the egress rules sat in `DOCKER-USER` and held for
the internet. They did nothing for the tailnet. Tailscale adds its own chain, `ts-forward`, and
jumps to it from the top of `FORWARD`. That chain accepts every packet that leaves through
`tailscale0`. A packet from the cage to any tailnet machine was accepted there, before it ever
reached Docker's chains, so the rule that allowed one port on one machine was dead code. Every
port on every tailnet machine the host could reach was open to the agent.

Two rules at the very top of `FORWARD` close it:

```bash
iptables -I FORWARD 1 -s "$CAGE_SUBNET" -d "$TAILNET_ALLOW_HOST/32" -o tailscale0 -p tcp -m tcp --dport "$TAILNET_ALLOW_PORT" -j ACCEPT
iptables -I FORWARD 2 -s "$CAGE_SUBNET" -o tailscale0 -j REJECT --reject-with icmp-port-unreachable
```

Installing them once is not enough. tailscaled puts its jump back at position 1 every time it
starts, so the next restart or upgrade would reopen the hole without a word. `tailnet-guard.sh`
compares the top of `FORWARD` with what it should be and repairs it when it differs. Two
systemd pieces call it: a timer, once at boot and then once a minute, and a drop-in on
`tailscaled.service` that waits 5 seconds after each start, since tailscaled installs its rules
shortly after it says it is up.

### The token in docker inspect (2026-08-27)

The first compose file passed the agent's bot token with `env_file`. That works, and it copies
every value into the container's configuration, which `docker inspect` prints in full. So
does every monitoring tool, support bundle or log that records container configuration.

Now the token lives in a file on the host owned by root, group `agent`, mode 0640, mounted
read-only. `entrypoint.sh` reads only the lines named in `CAGE_TOKEN_KEYS` and exports them into
the process it execs. `docker inspect` shows a file path and key names. `apply.sh` reads the
container's configuration on every run and fails if a token name is in it, and the token drill
in `verify-cage.sh` fails if a token name holds a value in the container's environment or in
PID 1's. This keeps the token out of tooling. It does not keep it from root on the host, who
can read any process's environment (`THREAT-MODEL.md`).

### The fire drills

`verify-cage.sh` runs inside the cage and tries five things. PASS means the cage held.

| Drill | What it tries | PASS when |
|---|---|---|
| egress | a direct TCP connection to `VERIFY_EGRESS_URL` | refused, unreachable, or the name does not resolve |
| tailnet | a TCP connection to `VERIFY_TAILNET_HOST:VERIFY_TAILNET_PORT` | refused or unreachable |
| syscall | chown a file to another user; open a raw socket | both refused |
| write | create a file directly under `/` | refused |
| token | read each name in `VERIFY_TOKEN_VARS` from its environment and PID 1's | none holds a value |

A drill that cannot run (no python3, no tailnet host set) prints FAIL. It exits 0 only when all
five pass. Point `VERIFY_TAILNET_HOST` at a real machine with an open port that is not the
allowed one; a machine that is switched off passes the drill and proves nothing.

### The permission envelope

The cage limits what the agent can reach. `PERMISSION-ENVELOPE.md` says what it may do with
that reach: GREEN actions it takes alone, YELLOW actions it drafts for a human to approve, RED
actions it never takes, and five modes, one per session, so no session holds private data,
untrusted content and a way out at the same time.

When the agent needs data that lives behind a credential, give it a broker instead of the
credential. A small service on the host listens on the cage gateway, holds the credential
itself, and answers a short list of typed, read-only questions with only the rows that question
allows. The agent asks; it never sees a password, never writes a query, and cannot ask for
anything the broker does not offer. Open the broker's port with one more ufw allow from the
cage subnet to the gateway, inserted above the cage's REJECT the same way as the proxy's.

## What it will not do

- It will not stop a kernel or container-runtime escape. It is a container, not a VM.
- It will not stop the agent from misusing what you let through: the hosts on the proxy list,
  the tailnet port, and its own token.
- It will not protect the token from root or the docker group on the host.
- It will not install, update or name an agent. You bring the image.
- It does not cover IPv6. The cage network is IPv4 only; enable IPv6 on it and you need rules
  for it too.

The full list, and what each layer does defend, is in [THREAT-MODEL.md](THREAT-MODEL.md).

## License

MIT. See [LICENSE](LICENSE).
