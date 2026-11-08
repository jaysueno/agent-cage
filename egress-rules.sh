#!/usr/bin/env bash
# egress-rules.sh: install, check or remove the default-deny egress rules for the cage
# network. Idempotent: run it as often as you like; the result is the same rule set, once.
#
#   bash egress-rules.sh install   # write the live rules and persist them in ufw
#   bash egress-rules.sh verify    # print the live rules; exit 1 if any is wrong or missing
#   bash egress-rules.sh verify-host   # only the two host-input rules in ufw; exit 1 if wrong
#   bash egress-rules.sh remove    # take the cage's rules back out
#   bash egress-rules.sh print     # print the rules it would install; needs no root
#
# What the cage network may reach, and nothing else:
#   1. TAILNET_ALLOW_HOST:TAILNET_ALLOW_PORT over TCP, if set (a model server, say)
#   2. the proxy on the host, CAGE_GATEWAY:PROXY_PORT, which applies its own hostname allowlist
# Everything else from CAGE_SUBNET is REJECTed. Reject, not drop, so a blocked call fails in
# milliseconds instead of hanging until the agent's socket timeout.
#
# Where the rules live, and why:
#   - Traffic from a container to anywhere off the host is FORWARDed, and Docker's chains run
#     before ufw's, so `ufw deny` does not hold a container. DOCKER-USER is the chain Docker
#     promises to jump to first and never rewrite, so rule 1 and the final REJECT go there,
#     at the top of the chain.
#   - Traffic to the host's own addresses (the proxy, and anything else listening there) is
#     INPUT, which DOCKER-USER never sees. Two ufw rules hold it, at the top of ufw's list,
#     where the first match wins:
#       [1] ALLOW  CAGE_SUBNET -> CAGE_GATEWAY port PROXY_PORT, tcp
#       [2] REJECT CAGE_SUBNET -> anything else on the host
#     The order is the point: with the REJECT first, the proxy is cut off too; with either rule
#     below a world-open allow (SSH, say), the cage reaches that port.
#   - Tailnet traffic is the exception: Tailscale's own forward chain accepts it before
#     DOCKER-USER is reached. tailnet-guard.sh handles that; see README, "How it works".
#   - Persistence: ufw's /etc/ufw/after.rules, inside its existing *filter section, between
#     marker lines. Re-running replaces the block; it never stacks a second copy.
#
# Settings come from the environment, or from cage.env next to this script when CAGE_SUBNET
# is not already set: CAGE_SUBNET, CAGE_GATEWAY, PROXY_PORT, TAILNET_ALLOW_HOST,
# TAILNET_ALLOW_PORT, UFW_AFTER_RULES.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${CAGE_SUBNET:-}" ] && [ -f "$here/cage.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$here/cage.env"
  set +a
fi

subnet="${CAGE_SUBNET:-}"
gateway="${CAGE_GATEWAY:-}"
proxy_port="${PROXY_PORT:-3128}"
allow_host="${TAILNET_ALLOW_HOST:-}"
allow_port="${TAILNET_ALLOW_PORT:-}"
after_rules="${UFW_AFTER_RULES:-/etc/ufw/after.rules}"
begin_mark="# BEGIN agent-cage egress (egress-rules.sh)"
end_mark="# END agent-cage egress"

die() { echo "egress-rules: $*" >&2; exit 1; }

octet='(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])'
is_ipv4() { [[ "$1" =~ ^$octet\.$octet\.$octet\.$octet$ ]]; }
is_cidr() { [[ "$1" =~ ^(.+)/([0-9]|[12][0-9]|3[0-2])$ ]] && is_ipv4 "${BASH_REMATCH[1]}"; }

check_settings() {
  is_cidr "$subnet" || die "CAGE_SUBNET must be an IPv4 network such as a.b.c.0/24 (got '${subnet:-empty}')"
  is_ipv4 "$gateway" || die "CAGE_GATEWAY must be an IPv4 address (got '${gateway:-empty}')"
  [[ "$proxy_port" =~ ^[0-9]+$ ]] || die "PROXY_PORT must be a number"
  if [ -n "$allow_host" ]; then
    is_ipv4 "$allow_host" || die "TAILNET_ALLOW_HOST must be an IPv4 address or empty (got '$allow_host')"
    [[ "$allow_port" =~ ^[0-9]+$ ]] || die "TAILNET_ALLOW_PORT must be a number when TAILNET_ALLOW_HOST is set"
  fi
}

need_root() { [ "$(id -u)" -eq 0 ] || die "must run as root"; }

# One rule per line, in the order they must sit in DOCKER-USER. The REJECT is always last.
cage_rules() {
  if [ -n "$allow_host" ]; then
    echo "-s $subnet -d $allow_host/32 -p tcp -m tcp --dport $allow_port -j ACCEPT"
  fi
  echo "-s $subnet -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"
  echo "-d $subnet -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"
  echo "-s $subnet -j REJECT --reject-with icmp-port-unreachable"
}

# Delete every DOCKER-USER rule that names the cage subnet. Running this before appending is
# what makes install idempotent instead of additive.
delete_ours() {
  local esc="${subnet//\//\\/}"
  # The grep finds nothing on a first run; without || true, pipefail would end the script.
  { iptables -S DOCKER-USER 2>/dev/null | grep -E -- "(-s|-d) $esc( |$)" || true; } \
    | sed 's/^-A /-D /' | while read -r rule; do
      # shellcheck disable=SC2086
      iptables $rule 2>/dev/null || true
    done
}

install_live() {
  iptables -N DOCKER-USER 2>/dev/null || true
  delete_ours
  # Inserted at the top, in order, not appended: some Docker versions end DOCKER-USER with a
  # RETURN rule, and a rule appended after it would never run.
  local pos=1
  while read -r rule; do
    # shellcheck disable=SC2086
    iptables -I DOCKER-USER "$pos" $rule
    pos=$((pos + 1))
  done < <(cage_rules)
  install_host_input
}

# The two host-input rules, read from `ufw status`: the first two rule lines must be the proxy
# allow and then the cage reject. Prints a FAIL line and returns 1 otherwise.
host_input_ok() {
  local rules first second
  # Rule lines follow the "--" separator under the header. IPv4 rules come before IPv6 ones.
  rules="$(ufw status | sed -n '/^--/,$p' | sed '1d' | grep -v '^[[:space:]]*$' || true)"
  first="$(printf '%s\n' "$rules" | sed -n 1p)"
  second="$(printf '%s\n' "$rules" | sed -n 2p)"
  if ! printf '%s\n' "$rules" | grep -F "$subnet" | grep -qw REJECT; then
    echo "FAIL host input: no ufw REJECT for the cage subnet"; return 1
  fi
  if ! printf '%s\n' "$rules" | grep -F "$subnet" | grep -F "$gateway $proxy_port/tcp" | grep -qw ALLOW; then
    echo "FAIL host input: no ufw ALLOW from the cage subnet to the proxy port"; return 1
  fi
  case "$first" in
    *"$gateway $proxy_port/tcp"*ALLOW*"$subnet"*) ;;
    *) echo "FAIL host input: the proxy ALLOW is not ufw rule 1"; return 1 ;;
  esac
  case "$second" in
    Anywhere*REJECT*"$subnet"*) ;;
    *) echo "FAIL host input: the cage REJECT is not ufw rule 2, right under the proxy ALLOW"; return 1 ;;
  esac
  return 0
}

# Put the two rules at the top of ufw's list, allow above reject. ufw will not move an existing
# rule, so both are deleted first and inserted again. When they are already in place, nothing
# changes.
install_host_input() {
  host_input_ok >/dev/null && return 0
  while ufw --force delete allow from "$subnet" to "$gateway" port "$proxy_port" proto tcp >/dev/null 2>&1; do :; done
  while ufw --force delete reject from "$subnet" >/dev/null 2>&1; do :; done
  if ufw status numbered | grep -q '^\['; then
    ufw insert 1 reject from "$subnet" comment 'agent-cage: nothing else on the host' >/dev/null
  else
    ufw reject from "$subnet" comment 'agent-cage: nothing else on the host' >/dev/null
  fi
  ufw insert 1 allow from "$subnet" to "$gateway" port "$proxy_port" proto tcp comment 'agent-cage to proxy' >/dev/null
}

strip_block() {  # $1 file: print it without our marked block
  awk -v b="$begin_mark" -v e="$end_mark" '$0==b {skip=1} skip && $0==e {skip=0; next} !skip {print}' "$1"
}

persist() {
  [ -f "$after_rules" ] || die "$after_rules is missing (is ufw installed?)"
  [ -f "$after_rules.bak-agent-cage" ] || cp -p "$after_rules" "$after_rules.bak-agent-cage"
  local body block
  body="$(mktemp)"
  block="$(mktemp)"
  strip_block "$after_rules" >"$body"
  grep -q '^COMMIT$' "$body" || die "$after_rules has no COMMIT line to insert before"
  {
    echo "$begin_mark"
    echo "# Default-deny egress for the agent cage. Re-applied on every ufw reload."
    echo ":DOCKER-USER - [0:0]"
    cage_rules | sed 's/^/-A DOCKER-USER /'
    echo "$end_mark"
  } >"$block"
  # Insert before the first COMMIT, which closes ufw's existing *filter table. A second
  # *filter section would be read inconsistently by iptables-restore.
  awk -v blockfile="$block" '
    /^COMMIT$/ && !done { while ((getline l < blockfile) > 0) print l; done = 1 }
    { print }
  ' "$body" >"$after_rules.new"
  mv "$after_rules.new" "$after_rules"
  chmod 640 "$after_rules"
  rm -f "$body" "$block"
}

verify() {
  local bad=0 live last
  live="$(iptables -S DOCKER-USER 2>/dev/null || true)"
  echo "--- DOCKER-USER ---"
  printf '%s\n' "$live"
  while read -r rule; do
    printf '%s\n' "$live" | grep -qxF -- "-A DOCKER-USER $rule" || { echo "FAIL missing: $rule"; bad=1; }
  done < <(cage_rules)
  # The REJECT must be the last rule naming the subnet, and no RETURN may come before it, or
  # traffic leaves the chain before it is refused.
  last="$(printf '%s\n' "$live" | grep -F -- "-s $subnet" | tail -n 1)"
  case "$last" in *REJECT*) ;; *) echo "FAIL the REJECT is not the last cage rule"; bad=1 ;; esac
  if printf '%s\n' "$live" | sed -n '/-j REJECT/q;p' | grep -q -- '-j RETURN'; then
    echo "FAIL a RETURN rule sits above the cage's REJECT"; bad=1
  fi
  echo "--- ufw ---"
  ufw status | grep -F "$subnet" || true
  host_input_ok || bad=1
  echo "--- $after_rules ---"
  grep -n -A8 -F "$begin_mark" "$after_rules" || { echo "FAIL the rules are not persisted"; bad=1; }
  [ "$bad" -eq 0 ] && echo "egress-rules: verify ok"
  return "$bad"
}

remove() {
  delete_ours
  while ufw --force delete allow from "$subnet" to "$gateway" port "$proxy_port" proto tcp >/dev/null 2>&1; do :; done
  while ufw --force delete reject from "$subnet" >/dev/null 2>&1; do :; done
  if [ -f "$after_rules" ]; then
    strip_block "$after_rules" >"$after_rules.new" && mv "$after_rules.new" "$after_rules"
  fi
  echo "egress-rules: cage rules removed"
}

case "${1:-verify}" in
  print)   check_settings; cage_rules ;;
  install) check_settings; need_root; install_live; persist; verify ;;
  verify)  check_settings; need_root; verify ;;
  verify-host)
    check_settings; need_root
    host_input_ok && echo "egress-rules: host input ok (proxy ALLOW is rule 1, cage REJECT is rule 2)" ;;
  remove)  check_settings; need_root; remove ;;
  *) echo "usage: $0 install|verify|verify-host|remove|print" >&2; exit 2 ;;
esac
