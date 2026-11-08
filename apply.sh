#!/usr/bin/env bash
###############################################################################
# ROLLBACK, if anything below goes wrong (run from the folder holding this file):
#
#   docker compose --env-file cage.env down
#   systemctl disable --now agent-cage-guard.timer
#   bash tailnet-guard.sh remove
#   bash egress-rules.sh remove
#   cp -p /etc/tinyproxy/tinyproxy.conf.bak-agent-cage /etc/tinyproxy/tinyproxy.conf
#   systemctl restart tinyproxy
#   cp -p /etc/ufw/after.rules.bak-agent-cage /etc/ufw/after.rules && ufw reload
#
# Nothing in AGENT_HOME_DIR or AGENT_OUTBOX_DIR is ever deleted or rewritten here. The
# agent's state is bind-mounted, never copied.
###############################################################################
#
# apply.sh: put an agent in the cage with one idempotent command, on an Ubuntu host with
# Docker, ufw, tinyproxy and Tailscale. Run it as root from the folder that holds it (keep
# that folder root-owned, for example /opt/agent-cage):
#
#   bash apply.sh --check-config   # read cage.env and stop; needs no root
#   bash apply.sh --dry-run        # show every change; touch nothing
#   bash apply.sh                  # build the cage, start the agent, run every check
#   bash apply.sh --verify-only    # no changes; re-run the checks on what is there
#
# Running it twice changes nothing the second time and re-runs the checks. It stops at the
# first failure, prints what failed and the rollback block, and exits 1.
#
# Options: --env FILE reads FILE instead of ./cage.env.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
env_file="$here/cage.env"
mode=apply
while [ $# -gt 0 ]; do
  case "$1" in
    --env) env_file="${2:?--env needs a file}"; shift ;;
    --dry-run) mode=dry ;;
    --verify-only) mode=verify ;;
    --check-config) mode=check ;;
    *) echo "apply: unknown option $1" >&2; exit 2 ;;
  esac
  shift
done

step=""
failed=0
say() { printf '\n=== %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
rollback_block() {
  cat <<ROLLBACK
  cd $here
  docker compose --env-file cage.env down
  systemctl disable --now agent-cage-guard.timer
  bash tailnet-guard.sh remove
  bash egress-rules.sh remove
  cp -p /etc/tinyproxy/tinyproxy.conf.bak-agent-cage /etc/tinyproxy/tinyproxy.conf
  systemctl restart tinyproxy
  cp -p /etc/ufw/after.rules.bak-agent-cage /etc/ufw/after.rules && ufw reload
ROLLBACK
}
die() {
  printf '\n!!! FAILED at: %s\n!!! %s\n' "${step:-start}" "$1" >&2
  [ "$mode" = check ] || { echo "ROLLBACK:" >&2; rollback_block >&2; }
  exit 1
}
run() {  # a change: printed in dry-run and verify-only, done otherwise
  if [ "$mode" = apply ]; then "$@"; else echo "    [would run] $*"; fi
}
check() {  # $1 label, rest a command; records a FAIL and goes on
  local label="$1"; shift
  if "$@"; then echo "PASS $label"; else echo "FAIL $label"; failed=1; fi
}

# --- 1. read and check the settings (no root needed) -------------------------------------
step="read $env_file"
[ -f "$env_file" ] || die "$env_file not found: copy cage.env.example to cage.env and fill it in"
set -a
# shellcheck disable=SC1090
. "$env_file"
set +a

octet='(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])'
is_ipv4() { [[ "$1" =~ ^$octet\.$octet\.$octet\.$octet$ ]]; }
ip2int() { local IFS=.; set -- $1; echo $(( ($1 << 24) + ($2 << 16) + ($3 << 8) + $4 )); }
is_name() { [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; }

step="check the settings"
required="AGENT_IMAGE AGENT_COMMAND AGENT_UID AGENT_GID AGENT_HOME_DIR AGENT_OUTBOX_DIR
AGENT_MEM_LIMIT TOKEN_HOST_FILE CAGE_TOKEN_FILE CAGE_SUBNET CAGE_GATEWAY CAGE_BRIDGE PROXY_PORT
PROXY_ALLOWLIST TAILNET_IFACE VERIFY_EGRESS_URL VERIFY_TAILNET_HOST VERIFY_TAILNET_PORT
VERIFY_TOKEN_VARS"
missing=""
placeholder=""
for key in $required; do
  val="${!key:-}"
  [ -n "$val" ] || missing="$missing $key"
  case "$val" in your-*) placeholder="$placeholder $key" ;; esac
done
case "${TAILNET_ALLOW_HOST:-}" in your-*) placeholder="$placeholder TAILNET_ALLOW_HOST" ;; esac
[ -z "$missing" ] || die "empty in $env_file:$missing"
[ -z "$placeholder" ] || die "still a your- placeholder in $env_file:$placeholder"

[[ "$AGENT_UID" =~ ^[1-9][0-9]*$ ]] || die "AGENT_UID must be a number above 0"
[[ "$AGENT_GID" =~ ^[1-9][0-9]*$ ]] || die "AGENT_GID must be a number above 0"
# Copy the match out first: is_ipv4 runs its own match and would overwrite BASH_REMATCH.
[[ "$CAGE_SUBNET" =~ ^(.+)/(1[6-9]|2[0-9]|30)$ ]] || die "CAGE_SUBNET must be an IPv4 network between /16 and /30"
net_ip="${BASH_REMATCH[1]}"
net_bits="${BASH_REMATCH[2]}"
is_ipv4 "$net_ip" || die "CAGE_SUBNET must be an IPv4 network between /16 and /30"
is_ipv4 "$CAGE_GATEWAY" || die "CAGE_GATEWAY must be an IPv4 address"
mask=$(( (0xFFFFFFFF << (32 - net_bits)) & 0xFFFFFFFF ))
[ $(( $(ip2int "$CAGE_GATEWAY") & mask )) -eq $(( $(ip2int "$net_ip") & mask )) ] \
  || die "CAGE_GATEWAY is not inside CAGE_SUBNET"
[[ "$PROXY_PORT" =~ ^[0-9]+$ ]] || die "PROXY_PORT must be a number"
if [ -n "${TAILNET_ALLOW_HOST:-}" ]; then
  is_ipv4 "$TAILNET_ALLOW_HOST" || die "TAILNET_ALLOW_HOST must be an IPv4 address or empty"
  [[ "${TAILNET_ALLOW_PORT:-}" =~ ^[0-9]+$ ]] || die "TAILNET_ALLOW_PORT must be a number"
fi
for key in ${CAGE_TOKEN_KEYS:-} $VERIFY_TOKEN_VARS; do
  is_name "$key" || die "not a variable name in CAGE_TOKEN_KEYS or VERIFY_TOKEN_VARS: $key"
done
allowlist="$PROXY_ALLOWLIST"
case "$allowlist" in /*) ;; *) allowlist="$here/$allowlist" ;; esac
[ -f "$allowlist" ] || die "PROXY_ALLOWLIST file not found: $PROXY_ALLOWLIST"
grep -qv '^[[:space:]]*\(#\|$\)' "$allowlist" || die "PROXY_ALLOWLIST has no pattern lines"
if [ "$mode" = check ]; then
  echo "apply: the settings in $env_file look complete"
  exit 0
fi

compose() { docker compose --env-file "$env_file" -f "$here/compose.yaml" "$@"; }

# --- 2. preflight -------------------------------------------------------------------------
step="preflight"; say "$step"
[ "$(id -u)" -eq 0 ] || die "run as root"
for tool in docker ufw iptables systemctl tinyproxy stat; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is not installed"
done
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is not installed"
ufw status | grep -q '^Status: active' || die "ufw is not active: the proxy port would be open to everyone"
[ "$(stat -c %u "$here")" = 0 ] || die "$here must be owned by root, so the agent cannot edit the scripts it runs under"
note "mode=$mode cage=$CAGE_SUBNET gateway=$CAGE_GATEWAY proxy port=$PROXY_PORT"

# --- 3. the host user and its folders -----------------------------------------------------
step="host user"; say "$step"
if getent group agent >/dev/null; then
  [ "$(getent group agent | cut -d: -f3)" = "$AGENT_GID" ] || die "group agent exists with a gid other than AGENT_GID"
else
  run groupadd --gid "$AGENT_GID" agent
fi
if id agent >/dev/null 2>&1; then
  [ "$(id -u agent)" = "$AGENT_UID" ] || die "user agent exists with a uid other than AGENT_UID"
else
  run useradd --uid "$AGENT_UID" --gid "$AGENT_GID" --home-dir "$AGENT_HOME_DIR" \
    --no-create-home --shell /usr/sbin/nologin agent
fi
for dir in "$AGENT_HOME_DIR" "$AGENT_OUTBOX_DIR"; do
  run install -d -m 0750 -o "$AGENT_UID" -g "$AGENT_GID" "$dir"
done
run chmod 0755 "$here/entrypoint.sh" "$here/verify-cage.sh" "$here/tailnet-guard.sh" "$here/egress-rules.sh"
run chmod 0600 "$env_file"

# --- 4. the token file --------------------------------------------------------------------
step="token file"; say "$step"
if [ ! -e "$TOKEN_HOST_FILE" ]; then
  [ -z "${CAGE_TOKEN_KEYS:-}" ] || die "$TOKEN_HOST_FILE is missing. Create it with:
    install -D -m 0640 -o root -g $AGENT_GID /dev/null $TOKEN_HOST_FILE
  then add one NAME=value line per name in CAGE_TOKEN_KEYS, and run this again"
  # No token wanted: an empty file, so Docker does not create a folder in its place.
  run install -D -m 0640 -o root -g "$AGENT_GID" /dev/null "$TOKEN_HOST_FILE"
fi
if [ -e "$TOKEN_HOST_FILE" ]; then
  perms="$(stat -c '%u %g %a' "$TOKEN_HOST_FILE")"
  [ "$perms" = "0 $AGENT_GID 640" ] || die "$TOKEN_HOST_FILE must be owner root, group $AGENT_GID, mode 640 (it is: $perms)"
  for key in ${CAGE_TOKEN_KEYS:-}; do
    grep -q "^$key=." "$TOKEN_HOST_FILE" || die "$TOKEN_HOST_FILE has no line for $key"
  done
  note "token file: root:$AGENT_GID 640, lines present for: ${CAGE_TOKEN_KEYS:-none}"
fi

# --- 5. the proxy -------------------------------------------------------------------------
step="egress proxy"; say "$step"
tp_conf=/etc/tinyproxy/tinyproxy.conf
tp_list=/etc/tinyproxy/agent-cage-allowlist
rendered="$(mktemp)"
sed -e "s|@PROXY_PORT@|$PROXY_PORT|g" -e "s|@CAGE_SUBNET@|$CAGE_SUBNET|g" -e "s|@ALLOWLIST@|$tp_list|g" \
  "$here/host/tinyproxy.conf.template" >"$rendered"
if cmp -s "$rendered" "$tp_conf" && cmp -s "$allowlist" "$tp_list"; then
  note "proxy config and allowlist already current"
else
  diff -u "$tp_conf" "$rendered" | sed 's/^/    | /'
  [ -f "$tp_conf" ] && [ ! -f "$tp_conf.bak-agent-cage" ] && run cp -p "$tp_conf" "$tp_conf.bak-agent-cage"
  run install -m 0644 -o root -g root "$rendered" "$tp_conf"
  run install -m 0644 -o root -g root "$allowlist" "$tp_list"
  run systemctl restart tinyproxy
fi
rm -f "$rendered"
if ufw status | grep -qE "^${PROXY_PORT}(/tcp)?[[:space:]]+ALLOW( IN)?[[:space:]]+Anywhere"; then
  die "ufw has port $PROXY_PORT open to anywhere: close it, then run this again"
fi

# --- 6. the network and the egress rules ----------------------------------------------------
step="cage network"; say "$step"
if docker network inspect agent-cage >/dev/null 2>&1; then
  have="$(docker network inspect agent-cage --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}')"
  [ "$have" = "$CAGE_SUBNET" ] || die "network agent-cage exists with another subnet: remove it or fix CAGE_SUBNET"
  note "network agent-cage already exists with the right subnet"
else
  run docker network create --driver bridge --subnet "$CAGE_SUBNET" --gateway "$CAGE_GATEWAY" \
    --opt "com.docker.network.bridge.name=$CAGE_BRIDGE" agent-cage
fi
step="egress rules"; say "$step"
if [ "$mode" = apply ]; then
  bash "$here/egress-rules.sh" install || die "the egress rules did not install"
else
  bash "$here/egress-rules.sh" print | sed 's/^/    [would install] /'
fi

# --- 7. the tailnet guard -------------------------------------------------------------------
step="tailnet guard"; say "$step"
for unit in agent-cage-guard.service agent-cage-guard.timer; do
  run sh -c "sed 's|@CAGE_DIR@|$here|g' '$here/host/$unit' > '/etc/systemd/system/$unit'"
done
run install -d /etc/systemd/system/tailscaled.service.d
run sh -c "sed 's|@CAGE_DIR@|$here|g' '$here/host/tailscaled-agent-cage-guard.conf' > /etc/systemd/system/tailscaled.service.d/agent-cage-guard.conf"
run systemctl daemon-reload
run systemctl enable --now agent-cage-guard.timer
if [ "$mode" = apply ]; then
  bash "$here/tailnet-guard.sh" || die "the tailnet guard failed"
fi

# --- 8. start the agent ---------------------------------------------------------------------
step="start the agent"; say "$step"
run compose up -d agent
if [ "$mode" = apply ]; then
  for _ in $(seq 1 30); do
    [ "$(docker inspect -f '{{.State.Running}}' agent 2>/dev/null)" = true ] && break
    sleep 2
  done
  [ "$(docker inspect -f '{{.State.Running}}' agent 2>/dev/null)" = true ] \
    || { docker logs --tail 30 agent 2>&1 | sed 's/^/    | /'; die "the agent container is not running"; }
fi
if [ "$mode" = dry ]; then
  echo
  echo "apply: dry run complete. Nothing was changed."
  exit 0
fi

###############################################################################
# 9. Checks. Each prints PASS or FAIL; any FAIL makes the run exit 1.
###############################################################################
step="checks"; say "$step"
inspect() { docker inspect agent --format "$1" 2>/dev/null; }

# The token never sits in the container's configuration (the env_file mistake). Names only.
env_names="$(inspect '{{range .Config.Env}}{{println .}}{{end}}' | cut -d= -f1)"
exposed=""
for key in $(printf '%s\n' ${CAGE_TOKEN_KEYS:-} $VERIFY_TOKEN_VARS | sort -u); do
  printf '%s\n' "$env_names" | grep -qx "$key" && exposed="$exposed $key"
done
[ -z "$exposed" ] || note "found in docker inspect:$exposed"
check "token names absent from docker inspect" test -z "$exposed"

check "runs as $AGENT_UID" test "$(inspect '{{.Config.User}}')" = "$AGENT_UID:$AGENT_GID"
check "read-only root filesystem" test "$(inspect '{{.HostConfig.ReadonlyRootfs}}')" = true
check "not privileged" test "$(inspect '{{.HostConfig.Privileged}}')" = false
check "every capability dropped, none added" \
  test "$(inspect '{{.HostConfig.CapDrop}}|{{.HostConfig.CapAdd}}')" = "[ALL]|[]"
check "no-new-privileges" sh -c "docker inspect agent --format '{{.HostConfig.SecurityOpt}}' | grep -q no-new-privileges"
limits_set() {
  local mem pids
  read -r mem pids <<<"$(inspect '{{.HostConfig.Memory}} {{.HostConfig.PidsLimit}}')"
  [[ "$mem" =~ ^[1-9][0-9]*$ ]] && [[ "$pids" =~ ^[1-9][0-9]*$ ]]
}
check "memory and process limits set" limits_set
check "no published ports" test -z "$(inspect '{{range $p, $b := .HostConfig.PortBindings}}{{$p}}{{end}}')"
check "only on the cage network" test "$(inspect '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}')" = "agent-cage "

# The proxy refuses a destination that is not on its list. An IP literal matches no line of
# either shipped allowlist, so tinyproxy must answer the CONNECT with 403.
proxy_probe='import os, socket
s = socket.create_connection((os.environ["GW"], int(os.environ["PP"])), timeout=8)
s.sendall(b"CONNECT 203.0.113.7:443 HTTP/1.1\r\nHost: 203.0.113.7:443\r\n\r\n")
line = s.recv(200).split(b"\r\n")[0].decode("latin-1")
print(line)
raise SystemExit(0 if " 403 " in line + " " else 1)'
check "proxy refuses a destination off its list" \
  docker run --rm --network agent-cage --user "$AGENT_UID:$AGENT_GID" --read-only --cap-drop ALL \
    --security-opt no-new-privileges:true -e GW="$CAGE_GATEWAY" -e PP="$PROXY_PORT" \
    python:3.12-slim python3 -c "$proxy_probe"

check "egress rules in place" bash "$here/egress-rules.sh" verify
check "host input: proxy ALLOW is ufw rule 1, cage REJECT is rule 2" bash "$here/egress-rules.sh" verify-host
check "tailnet rules at the top of FORWARD" bash "$here/tailnet-guard.sh" check
check "the guard timer is active" systemctl is-active --quiet agent-cage-guard.timer

say "fire drills (verify-cage.sh in a throwaway container on the cage network)"
check "fire drills, throwaway container" compose --profile verify run --rm verify
if compose exec -T agent sh -c 'command -v bash && command -v python3' >/dev/null 2>&1; then
  say "fire drills (verify-cage.sh inside the agent container)"
  check "fire drills, agent container" compose exec -T \
    -e VERIFY_EGRESS_URL="$VERIFY_EGRESS_URL" -e VERIFY_TAILNET_HOST="$VERIFY_TAILNET_HOST" \
    -e VERIFY_TAILNET_PORT="$VERIFY_TAILNET_PORT" -e VERIFY_TOKEN_VARS="$VERIFY_TOKEN_VARS" \
    agent bash /cage/verify-cage.sh
else
  note "the agent image has no bash or python3: the drills ran in the throwaway container only"
fi

echo
if [ "$failed" -ne 0 ]; then
  echo "apply: at least one check FAILED. Read the FAIL lines above before changing any rule."
  echo "ROLLBACK:"
  rollback_block
  exit 1
fi
echo "apply: every check passed."
