#!/usr/bin/env bash
# docker-drills.sh: run verify-cage.sh in real containers and check every verdict.
#
#   npm run test:docker
#
# Needs Docker. CI runs it on every push. Three containers, built to disagree on purpose, so a
# drill that guesses or reads one condition for all five cannot pass:
#
#   caged   read-only root, uid 10001, every capability dropped, no network, no token
#           -> every drill PASS, exit 0
#   open    writable root, root with every capability, a reachable host, a token set
#           -> every drill FAIL, exit 1
#   mixed   read-only root, uid 10001, capabilities dropped, a reachable host, a token set
#           -> egress FAIL, tailnet FAIL, syscall PASS, write PASS, token FAIL, exit 1
#
# The reachable host is a listener container on a throwaway network. Every container and the
# network carry a label and are removed on exit, pass or fail. It also checks that compose.yaml
# renders with a filled-in copy of cage.env.example.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
image="python:3.12-slim"
tag="agent-cage-drills-$$"
net="$tag-net"
failures=0

cleanup() {
  local ids
  ids="$(docker ps -aq --filter "label=$tag" 2>/dev/null || true)"
  [ -n "$ids" ] && docker rm -f $ids >/dev/null 2>&1 || true
  docker network rm "$net" >/dev/null 2>&1 || true
  rm -rf "${tmp:-}"
}
trap cleanup EXIT

docker info >/dev/null 2>&1 || { echo "docker-drills: Docker is not running" >&2; exit 2; }
docker image inspect "$image" >/dev/null 2>&1 || docker pull -q "$image" >/dev/null

# compose.yaml renders with every setting filled in.
tmp="$(mktemp -d)"
sed -e 's|^AGENT_IMAGE=.*|AGENT_IMAGE=example/agent:1.0|' \
    -e 's|^AGENT_COMMAND=.*|AGENT_COMMAND="example-agent run"|' \
    -e 's|^CAGE_SUBNET=.*|CAGE_SUBNET=203.0.113.0/24|' \
    -e 's|^CAGE_GATEWAY=.*|CAGE_GATEWAY=203.0.113.1|' \
    -e 's|^TAILNET_ALLOW_HOST=.*|TAILNET_ALLOW_HOST=100.64.0.10|' \
    -e 's|^VERIFY_TAILNET_HOST=.*|VERIFY_TAILNET_HOST=100.64.0.20|' \
    "$root/cage.env.example" >"$tmp/cage.env"
if docker compose --env-file "$tmp/cage.env" -f "$root/compose.yaml" --profile verify config -q; then
  echo "ok   compose.yaml renders with a filled cage.env"
else
  echo "FAIL compose.yaml does not render"; failures=$((failures + 1))
fi

docker network create --label "$tag" "$net" >/dev/null
docker run -d --rm --label "$tag" --network "$net" --network-alias listener \
  --read-only --cap-drop ALL --security-opt no-new-privileges:true --user 65534:65534 \
  "$image" python3 -c '
import socket
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("", 8080)); s.listen(16)
while True:
    c, _ = s.accept(); c.close()' >/dev/null
sleep 2

drill() {  # $1 name, $2 expected verdicts (e t s w k as P/F), $3 expected exit, rest docker flags
  local name="$1" want="$2" want_rc="$3" out rc got=""
  shift 3
  set +e
  out="$(docker run --rm --label "$tag" --pids-limit 64 --memory 256m \
    --tmpfs /tmp:rw,noexec,nosuid,size=16m --workdir /tmp -v "$root/verify-cage.sh:/cage/verify-cage.sh:ro" \
    -e VERIFY_EGRESS_URL=http://listener:8080/ -e VERIFY_TAILNET_HOST=listener -e VERIFY_TAILNET_PORT=8080 \
    -e VERIFY_TOKEN_VARS=DRILL_FAKE_TOKEN "$@" "$image" bash /cage/verify-cage.sh 2>&1)"
  rc=$?
  set -e
  for d in egress tailnet syscall write token; do
    case "$(printf '%s\n' "$out" | grep -E "^(PASS|FAIL) $d:" | cut -c1)" in
      P) got="${got}P" ;; F) got="${got}F" ;; *) got="${got}?" ;;
    esac
  done
  if [ "$got" = "$want" ] && [ "$rc" = "$want_rc" ]; then
    echo "ok   $name: $got, exit $rc"
  else
    echo "FAIL $name: got $got exit $rc, expected $want exit $want_rc"
    printf '%s\n' "$out" | sed 's/^/       | /'
    failures=$((failures + 1))
  fi
}

locked=(--read-only --user 10001:10001 --cap-drop ALL --security-opt no-new-privileges:true)
drill caged PPPPP 0 "${locked[@]}" --network none
drill open FFFFF 1 --user 0:0 --cap-add ALL --security-opt seccomp=unconfined --network "$net" \
  -e DRILL_FAKE_TOKEN=fake-value-for-drills
drill mixed FFPPF 1 "${locked[@]}" --network "$net" -e DRILL_FAKE_TOKEN=fake-value-for-drills

echo
if [ "$failures" -ne 0 ]; then
  echo "docker-drills: $failures problem(s)"
  exit 1
fi
echo "docker-drills: every verdict matched"
