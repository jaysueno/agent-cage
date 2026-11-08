# Threat model

Assume the agent is hostile. Not because the model is evil, but because anyone who can put
text in front of it (a web page, a message, a file in its workspace) can steer it. So the
question is never "will the agent behave?" It is "what can a fully steered agent reach?"

The attacker here is the agent process and anything it runs. The host, its root user and the
people in its `docker` group are trusted.

## What the cage defends against

| Threat | What stops it | How you check it |
|---|---|---|
| Reading files on the host | The container sees only its own image, its home folder, the outbox, the token file and two scripts mounted read-only. | `docker inspect agent` mounts |
| Writing outside its folders | Read-only root filesystem; `/tmp` is a small tmpfs mounted `noexec`. | the `write` drill |
| Becoming root, or using root's powers | Its own uid, every capability dropped, `no-new-privileges`, and an entrypoint that refuses uid 0. | the `syscall` drill |
| Reaching the internet directly | `DOCKER-USER`: forwarded traffic from the cage subnet is rejected except replies and the one tailnet port. | the `egress` drill |
| Reaching the host's own services | Traffic to the host's addresses is INPUT, which `DOCKER-USER` never sees. Two ufw rules at the top of ufw's list hold it: [1] allow the cage subnet to the proxy port, [2] reject the cage subnet to anything else. Rule 1 must sit above rule 2, and both above any world-open allow, because ufw stops at the first match. | `egress-rules.sh verify-host`, run by `apply.sh` |
| Reaching the internet through the proxy | tinyproxy serves only the cage subnet, only the hostnames on its allowlist (one chat API host as shipped), HTTPS only on 443. | `apply.sh`: a request for an address off the list must get a 403 |
| Reaching other machines on the tailnet | Two rules above Tailscale's forward chain, re-asserted every 60 seconds. | the `tailnet` drill, `tailnet-guard.sh check` |
| Cloud metadata | Off the host, so forwarded: `DOCKER-USER` rejects it. | the `egress` drill with that address |
| The token exposed in `docker inspect` and other tooling | Read from a root-owned file inside the container; never in `docker inspect`, the image, a command line or a log. | the `token` drill, `apply.sh` |
| Starving the host | Memory with no swap, 512 processes, 2 CPUs. | `docker inspect agent` limits |
| Editing its own cage | The scripts, `cage.env` and the token file are root-owned; the entrypoint and the drill are mounted read-only. | `ls -l /opt/agent-cage` |

## What the cage does not defend against

- **A kernel or container-runtime escape.** The agent shares the host's kernel. A kernel bug
  that breaks out of a container breaks out of this one. If that risk matters to you, run the
  agent in a VM or under gVisor, and keep this cage inside it.
- **Exfiltration through the doors you opened.** The chat API host on the proxy list carries
  whatever the agent writes into it, and so does any host you add. The cage limits where data
  can go; it cannot judge what the data is.
- **A wider proxy allowlist.** Widening the proxy allowlist lets a public name that resolves to
  a private address (loopback, cloud metadata, a tailnet machine) reach that address from the
  host, outside the cage's rules.
- **DNS as a side channel.** Docker's embedded resolver answers the container's lookups, and
  depending on the Docker version it forwards them from the host's own network namespace,
  outside the cage's rules. An agent can encode small amounts of data in lookups for a domain
  someone else controls. To close it, point the cage at a resolver you run that answers only
  the names you allow (`dns:` in `compose.yaml`).
- **Root and the `docker` group on the host.** Either can exec into the container, read the
  agent's environment (token included), change the rules or stop the cage. Keep that group
  to the people who own the box.
- **Misuse of what it is allowed to do.** A steered agent can spam its owner through its own
  bot token, delete or corrupt its own memory, fill its home folder, and write drafts in the
  outbox that look trustworthy and are not. The human who reviews those drafts is a target too:
  read them as untrusted input.
- **Filling the host's disk.** The home folder and the outbox have no quota. Put them on their
  own filesystem or set a quota if the host runs anything else that matters.
- **The service behind the tailnet port.** Whatever listens on `TAILNET_ALLOW_HOST:TAILNET_ALLOW_PORT`
  is fully reachable, including its bugs. Expose a model server there, not an admin port.
- **IPv6.** The rules are IPv4 only, and the cage network has no IPv6. Turn IPv6 on for that
  network and you need the same rules for it.
- **The agent image itself.** The image you choose runs with the agent's reach and holds its
  token. The cage bounds what a bad image can do; it does not make a bad image safe to feed
  your token.

## Assumptions

- The host is patched, and its kernel, Docker and Tailscale get updates.
- ufw is active with default deny incoming. `apply.sh` refuses to run otherwise. Nobody adds a
  ufw rule above the cage's two; `egress-rules.sh verify-host` fails if someone does.
- Only the owners are in the `docker` group and have root.
- This folder, `cage.env` and the token file stay root-owned. `apply.sh` checks the folder and
  the token file.
- The tailnet's own access rules are the outer wall. The cage is the inner one.

## Check it yourself

```bash
sudo bash apply.sh --verify-only                                     # every check, no changes
docker compose --env-file cage.env --profile verify run --rm verify  # the five drills
sudo bash tailnet-guard.sh check                                     # the two rules are on top
docker inspect agent --format '{{json .Config.Env}}'                 # no token names in here
```
