#!/usr/bin/env bash
# verify-cage.sh: the fire drills. Run it INSIDE the cage. It tries five things the cage must
# refuse and prints one line per drill:
#
#   PASS <drill>: <what happened>   the cage held
#   FAIL <drill>: <what happened>   the cage let it through, or the drill could not run
#
#   egress   a direct TCP connection to the host in VERIFY_EGRESS_URL
#   tailnet  a TCP connection to VERIFY_TAILNET_HOST:VERIFY_TAILNET_PORT
#   syscall  calls that need a capability: chown a file to another user, open a raw socket
#   write    create a file directly under /
#   token    any name in VERIFY_TOKEN_VARS holding a value, in this environment or PID 1's
#
# Exit 0 when every drill passes, 1 when any fails. A drill that cannot run is a FAIL, never a
# PASS: a test that did not happen proves nothing.
#
# Needs bash and python3 (any python:3 image has both; no curl, nc or ping). Usually run as:
#   docker compose --env-file cage.env --profile verify run --rm verify
# which starts a throwaway container on the cage network with the agent's user and hardening.
# If the agent image has bash and python3, run it in the agent container too (apply.sh does):
#   docker compose --env-file cage.env exec -T agent bash /cage/verify-cage.sh
#
# Settings (environment):
#   VERIFY_EGRESS_URL    default http://example.com/
#   VERIFY_TAILNET_HOST  no default: the drill FAILs until you name a tailnet machine
#   VERIFY_TAILNET_PORT  default 22
#   VERIFY_TOKEN_VARS    default AGENT_TOKEN
set -u

egress_url="${VERIFY_EGRESS_URL:-http://example.com/}"
tailnet_host="${VERIFY_TAILNET_HOST:-}"
tailnet_port="${VERIFY_TAILNET_PORT:-22}"
token_vars="${VERIFY_TOKEN_VARS:-AGENT_TOKEN}"

if ! command -v python3 >/dev/null 2>&1; then
  for drill in egress tailnet syscall write token; do
    echo "FAIL $drill: python3 is not in this image, so the drill could not run"
  done
  exit 1
fi

export DRILL_EGRESS_URL="$egress_url" DRILL_TAILNET_HOST="$tailnet_host" \
  DRILL_TAILNET_PORT="$tailnet_port" DRILL_TOKEN_VARS="$token_vars"

exec python3 -I - <<'PY'
import os
import socket
import tempfile
import urllib.parse

TIMEOUT = 5


def try_connect(host, port):
    """(held, why). Any failure to connect counts as held: a name that does not resolve, a
    refusal, a reset or a timeout all mean the cage did not let the connection through."""
    try:
        conn = socket.create_connection((host, int(port)), timeout=TIMEOUT)
    except socket.gaierror:
        return True, 'the name did not resolve'
    except OSError as err:
        return True, 'refused or unreachable (%s)' % type(err).__name__
    conn.close()
    return False, 'connected to %s:%s' % (host, port)


def egress():
    url = urllib.parse.urlsplit(os.environ['DRILL_EGRESS_URL'])
    if not url.hostname:
        return False, 'VERIFY_EGRESS_URL has no host, so the drill could not run'
    port = url.port or (443 if url.scheme == 'https' else 80)
    return try_connect(url.hostname, port)


def tailnet():
    host = os.environ['DRILL_TAILNET_HOST']
    if not host or host.startswith('your-'):
        return False, 'VERIFY_TAILNET_HOST is not set, so the drill could not run'
    return try_connect(host, os.environ['DRILL_TAILNET_PORT'])


def syscall():
    fd, path = tempfile.mkstemp(prefix='cage-drill-')
    os.close(fd)
    # Give the file to someone else. Without CAP_CHOWN that is refused, even for root.
    other = 65534 if os.getuid() == 0 else 0
    try:
        os.chown(path, other, other)
        chown_ok = True
    except PermissionError:
        chown_ok = False
    finally:
        os.unlink(path)
    try:
        socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_ICMP).close()
        raw_ok = True
    except PermissionError:
        raw_ok = False
    got = [name for name, ok in (('chown', chown_ok), ('raw socket', raw_ok)) if ok]
    if got:
        return False, 'allowed: %s' % ', '.join(got)
    return True, 'chown to another user and a raw socket were both refused'


def write():
    path = '/.cage-drill-%d' % os.getpid()
    try:
        with open(path, 'x') as fh:
            fh.write('drill\n')
    except OSError as err:
        return True, 'refused (%s)' % type(err).__name__
    os.unlink(path)
    return False, 'created a file under /'


def token():
    names = os.environ['DRILL_TOKEN_VARS'].split()
    if not names:
        return False, 'VERIFY_TOKEN_VARS is empty, so the drill could not run'
    found = {n for n in names if os.environ.get(n)}
    try:
        with open('/proc/1/environ', 'rb') as fh:
            pid1 = fh.read().split(b'\0')
        found |= {n for n in names
                  if any(e.startswith(n.encode() + b'=') and len(e) > len(n) + 1 for e in pid1)}
        where = 'this environment or PID 1'
    except OSError:
        where = 'this environment (PID 1 not readable)'
    if found:
        # Names only. The value is never printed.
        return False, 'holds a value: %s' % ' '.join(sorted(found))
    return True, 'none of %s holds a value in %s' % (' '.join(names), where)


held_all = True
print('verify-cage: running as uid %d' % os.getuid(), flush=True)
for name, drill in (('egress', egress), ('tailnet', tailnet), ('syscall', syscall),
                    ('write', write), ('token', token)):
    try:
        held, why = drill()
    except Exception as err:  # a broken drill is a failed drill
        held, why = False, 'the drill broke (%s)' % type(err).__name__
    held_all = held_all and held
    print('%s %s: %s' % ('PASS' if held else 'FAIL', name, why), flush=True)
print('verify-cage: %s' % ('every drill held' if held_all else 'at least one drill failed'))
raise SystemExit(0 if held_all else 1)
PY
