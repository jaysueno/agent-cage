#!/bin/sh
# entrypoint.sh: load the agent's token from a read-only file into the agent's own process,
# then run the agent. POSIX sh, so it works in any image that has /bin/sh.
#
# Why a file and not compose's env_file: env_file puts every value into the container's
# configuration, and `docker inspect` prints that configuration to anyone who can talk to the
# Docker daemon. Read here, the token exists only in the environment of the process this
# script execs. It never reaches an image layer, a command line, a log, or `docker inspect`.
#
# Settings (both come from compose, see cage.env.example):
#   CAGE_TOKEN_FILE  the file, mounted read-only (default /run/cage/token)
#   CAGE_TOKEN_KEYS  space-separated names to take from it; every other line is ignored
#
# Exit codes: 64 no command given, 77 running as root, 78 a requested token is missing.
# A token value is never printed, not even its length.
set -u

token_file="${CAGE_TOKEN_FILE:-/run/cage/token}"
keys="${CAGE_TOKEN_KEYS:-}"

if [ "$#" -eq 0 ]; then
  echo "entrypoint: no command to run. Set AGENT_COMMAND in cage.env." >&2
  exit 64
fi

# compose sets user: to the agent's uid. If someone removes that line, stop here rather than
# hand root to the agent.
if [ "$(id -u)" -eq 0 ]; then
  echo "entrypoint: refusing to run the agent as root. Set user: in compose.yaml." >&2
  exit 77
fi

loaded=""
if [ -n "$keys" ]; then
  if [ ! -r "$token_file" ]; then
    echo "entrypoint: cannot read the token file at $token_file" >&2
    exit 78
  fi
  for key in $keys; do
    case "$key" in
      [!A-Za-z_]* | *[!A-Za-z0-9_]*)
        echo "entrypoint: not a valid variable name in CAGE_TOKEN_KEYS: $key" >&2
        exit 78
        ;;
    esac
    # Take only this key's line; the last one wins, as in a shell file.
    value="$(sed -n "s/^$key=//p" "$token_file" | tail -n 1)"
    # Allow one pair of surrounding quotes, as people write them in env files.
    case "$value" in
      \"*\") value="${value#\"}"; value="${value%\"}" ;;
      \'*\') value="${value#\'}"; value="${value%\'}" ;;
    esac
    if [ -z "$value" ]; then
      echo "entrypoint: the token file has no value for $key" >&2
      exit 78
    fi
    export "$key=$value"
    loaded="$loaded $key"
  done
  value=""
  unset value
fi

# Names only, so a failed start can be diagnosed without anyone opening the token file.
echo "entrypoint: uid=$(id -u) gid=$(id -g) token keys loaded:${loaded:- none}"
exec "$@"
