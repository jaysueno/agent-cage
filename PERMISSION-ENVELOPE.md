# Permission envelope

A template. Copy it, edit it for your agent, and sign it before the agent runs unattended.
After that, any change to what the agent may do is the owner's decision, made in this file,
never the agent's.

## The rule under all the others

Treat the model as obedient to whoever wrote its last input. That is why no limit here asks it
to say no. The kernel, the firewall, code that checks a request, or a person who approves it
holds each one, and each would hold with a model that never refuses anything.

## Three tiers of action

- **GREEN: it acts alone.** Work with no side effect outside the cage: read its own memory and
  workspace, read allowlisted web pages (Researcher mode only), write drafts into the outbox
  marked for review, and send status to its owner on the one chat channel. Nothing else.
- **YELLOW: it drafts, a human approves.** Anything that changes something outside the cage or
  touches code: open a branch or a pull request, call a named test endpoint, propose a message.
  The agent drafts, a deterministic check validates the draft, and the owner approves that one
  action. It never runs on its own.
- **RED: never on its own, ever.** Anything that costs or moves money, messages anyone other
  than the owner, shares personal data, reads a secret, pushes to a protected branch, or
  deploys. Each one needs the owner's go for that single action, and where money or other
  people are involved, a deterministic check that can refuse it. No track record ever promotes
  a RED action to GREEN.

## Five modes, one per session

A session runs in exactly one mode. Modes are configuration the owner approves.

| Mode | Tools | Network | Credentials | Default |
|---|---|---|---|---|
| Messenger | chat with the owner | the chat API host, through the proxy | its own bot token | on, and part of every mode |
| Researcher | read and summarize web pages | allowlisted web hosts, through the proxy | none | off |
| Worker | read and write code in its workspace, commit on its own branches | none beyond Messenger | none, so it cannot push | off |
| Tester | Worker, plus calls to named test endpoints | the named test hosts only | scoped and short-lived, issued by a broker | off |
| Operator | outward writes: post, submit, reply | an allowlist per action | per action, issued by a broker | off |

**Never two modes in one session.** Three things make a prompt injection pay off: text from
outside (a web page), data worth taking (a workspace, a test system), and a channel to send it
out. Give a session all three and a planted line can use them together. No mode here combines
all three. Shipping code has no mode at all. The agent opens a pull request; a person merges
it; your usual pipeline does the rest.

How the modes map to the cage:

- Messenger: `PROXY_ALLOWLIST=host/proxy-allowlist.messenger` with your chat API host.
- Researcher: a list of your own with the hosts it may read. Read `THREAT-MODEL.md` first:
  every name you add is resolved and fetched from the host.
- The model server, if the agent thinks on another machine, is the tailnet door
  (`TAILNET_ALLOW_HOST`). It belongs to every mode.
- Worker: the workspace is a git working copy with no remote and no credential. A machine you
  control fetches the agent's branches and opens the pull requests, so nothing in the cage can
  push.

## Secrets

- The agent runs as its own Unix user. Every other secret on the host belongs to another user
  with tight permissions, so the kernel refuses the agent's reads. That is file permissions, not
  configuration someone can forget.
- It holds exactly one credential: its own bot token, separate from any other bot you run, in a
  root-owned file it can read and cannot edit.
- A YELLOW capability that needs a credential gets it from a broker: one action, one narrow
  scope, a short expiry. Raw credential files stay out of the agent's reach.

## Kill switches

Any one of these stops it on its own:

1. `docker compose --env-file cage.env down` on the host, from a phone over SSH if need be.
2. Close the tailnet door (empty `TAILNET_ALLOW_HOST` and re-run `apply.sh`, or remove the
   host from your tailnet's access rules). If its model lives there, it can no longer think.
3. Egress is default deny, so there is no open internet to cut.
4. Remove the `agent` user and its two folders. Nothing of the agent survives that.

Take a snapshot of the whole host before the first install. That is the undo for everything.

## If it goes haywire

- **It can:** use up its own CPU and memory share, fill its home folder, drop nonsense into the
  outbox, and message its owner far too often.
- **It cannot:** read the host's secrets, reach anything beyond its two doors, push code,
  deploy, or message anyone but its owner.

## Sign-off

Approved by: ______________________  Date: ____________

What changed since the last approval: ______________________
