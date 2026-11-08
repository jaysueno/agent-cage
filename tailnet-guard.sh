#!/usr/bin/env bash
# tailnet-guard.sh: keep the cage's tailnet rules at the very top of the FORWARD chain.
#
# Why: Tailscale installs its own forward chain and jumps to it from the top of FORWARD. That
# chain accepts everything leaving through the tailnet interface, so a packet from the cage to
# a tailnet machine is accepted before it ever reaches DOCKER-USER, and the egress rules there
# are dead code for the whole tailnet. Two rules above Tailscale's jump close it:
#
#   1. cage -> TAILNET_ALLOW_HOST:TAILNET_ALLOW_PORT over the tailnet: ACCEPT (only if set)
#   2. cage -> anything else over the tailnet: REJECT
#
# tailscaled puts its jump back at position 1 every time it starts, so the order has to be
# re-asserted, not installed once. Run this every 60 seconds (host/agent-cage-guard.timer),
# at boot, and a few seconds after tailscaled starts (host/tailscaled-agent-cage-guard.conf).
# When the order is already right it changes nothing and prints nothing.
#
# Settings come from the environment, or from cage.env next to this script when CAGE_SUBNET
# is not already set: CAGE_SUBNET, TAILNET_ALLOW_HOST, TAILNET_ALLOW_PORT, TAILNET_IFACE.
#
#   bash tailnet-guard.sh          # assert: fix the order if needed (the timer runs this)
#   bash tailnet-guard.sh check    # exit 1 if the rules are not on top; change nothing
#   bash tailnet-guard.sh print    # print the rules; needs no root
#   bash tailnet-guard.sh remove   # take the rules out (stop the timer first)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${CAGE_SUBNET:-}" ] && [ -f "$here/cage.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$here/cage.env"
  set +a
fi

subnet="${CAGE_SUBNET:-}"
allow_host="${TAILNET_ALLOW_HOST:-}"
allow_port="${TAILNET_ALLOW_PORT:-}"
iface="${TAILNET_IFACE:-tailscale0}"

die() { echo "tailnet-guard: $*" >&2; exit 1; }

octet='(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])'
is_ipv4() { [[ "$1" =~ ^$octet\.$octet\.$octet\.$octet$ ]]; }
is_cidr() { [[ "$1" =~ ^(.+)/([0-9]|[12][0-9]|3[0-2])$ ]] && is_ipv4 "${BASH_REMATCH[1]}"; }

is_cidr "$subnet" || die "CAGE_SUBNET must be an IPv4 network (got '${subnet:-empty}')"
[[ "$iface" =~ ^[A-Za-z0-9_.-]+$ ]] || die "TAILNET_IFACE is not an interface name"
if [ -n "$allow_host" ]; then
  is_ipv4 "$allow_host" || die "TAILNET_ALLOW_HOST must be an IPv4 address or empty"
  [[ "$allow_port" =~ ^[0-9]+$ ]] || die "TAILNET_ALLOW_PORT must be a number"
fi

# The rules, written exactly as `iptables -S` prints them, so one string serves to insert,
# delete and compare.
accept_rule="-s $subnet -d $allow_host/32 -o $iface -p tcp -m tcp --dport $allow_port -j ACCEPT"
reject_rule="-s $subnet -o $iface -j REJECT --reject-with icmp-port-unreachable"
wanted=()
[ -n "$allow_host" ] && wanted+=("$accept_rule")
wanted+=("$reject_rule")

action="${1:-assert}"
case "$action" in
  assert | check | print | remove) ;;
  *) echo "usage: $0 [assert|check|print|remove]" >&2; exit 2 ;;
esac
if [ "$action" = print ]; then
  printf '%s\n' "${wanted[@]}"
  exit 0
fi
[ "$(id -u)" -eq 0 ] || die "must run as root"

# Remove every FORWARD rule from the cage subnet out the tailnet interface: ours, including
# one left by an older TAILNET_ALLOW_HOST. The grep finds nothing on a first run, hence
# || true under pipefail.
delete_ours() {
  { iptables -S FORWARD | grep -F -- "-s $subnet " | grep -F -- "-o $iface " || true; } \
    | sed 's/^-A /-D /' | while read -r rule; do
      # shellcheck disable=SC2086
      iptables $rule
    done
}

if [ "$action" = remove ]; then
  delete_ours
  echo "tailnet-guard: the cage's tailnet rules are removed"
  exit 0
fi

# `iptables -S FORWARD` prints the policy on line 1, then the rules in order.
expected="$(printf -- '-A FORWARD %s\n' "${wanted[@]}")"
actual="$(iptables -S FORWARD | sed -n "2,$((${#wanted[@]} + 1))p")"
if [ "$actual" = "$expected" ]; then
  [ "$action" = check ] && echo "tailnet-guard: the cage's rules are at the top of FORWARD"
  exit 0
fi
if [ "$action" = check ]; then
  echo "tailnet-guard: the cage's rules are NOT at the top of FORWARD" >&2
  exit 1
fi

# Out of order or missing: take ours out, then put the wanted ones back on top.
delete_ours
pos=1
for rule in "${wanted[@]}"; do
  # shellcheck disable=SC2086
  iptables -I FORWARD "$pos" $rule
  pos=$((pos + 1))
done
msg="re-asserted the cage's tailnet rules at the top of FORWARD"
echo "tailnet-guard: $msg"
command -v logger >/dev/null 2>&1 && logger -t agent-cage-guard "$msg"
exit 0
