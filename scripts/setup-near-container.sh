#!/usr/bin/env bash
set -euo pipefail

ROOT_HOME_TARGET="${ROOT_HOME_TARGET:-/home/agent/.root-home}"
IRONCLAW_BIN="${IRONCLAW_BIN:-/usr/local/bin/ironclaw}"

# Re-run as root because /root and /usr/local/bin require privileged writes.
if [ "$(id -u)" -ne 0 ]; then
  exec sudo -n bash "$0" "$@"
fi

# Move root's home onto the persistent agent volume.
if [ ! -e "$ROOT_HOME_TARGET" ]; then
  mkdir -p "$ROOT_HOME_TARGET"
  cp -a /root/. "$ROOT_HOME_TARGET"/
  chown -R root:root "$ROOT_HOME_TARGET"
  chmod 700 "$ROOT_HOME_TARGET"
fi

# Replace /root with a symlink to the persistent home directory.
if [ -L /root ]; then
  :
elif [ -d /root ]; then
  rm -rf /root
  ln -s "$ROOT_HOME_TARGET" /root
else
  mv /root "/root.unexpected.$(date +%s)"
  ln -s "$ROOT_HOME_TARGET" /root
fi

# Install root-user tooling and reset Node/Yarn/opencode environment.
apt update
apt install -y git make lsof nano

rm -rf \
  /usr/local/bin/node \
  /usr/local/bin/npm \
  /usr/local/bin/npx \
  /usr/local/bin/corepack \
  /usr/local/lib/node_modules \
  /usr/local/lib/node \
  /usr/local/include/node \
  /usr/local/share/man/man1/node.1 \
  /root/n
if command -v node >/dev/null 2>&1; then
  node -v
else
  printf 'node removed\n'
fi

rm -rf \
  /usr/local/bin/yarn \
  /usr/local/bin/yarnpkg \
  /opt/yarn-v1.22.22 \
  /root/.cache/yarn \
  /root/.yarnrc
if command -v yarn >/dev/null 2>&1; then
  yarn -v
else
  printf 'yarn removed\n'
fi

curl -L https://bit.ly/n-install | bash -s -- -y
# shellcheck disable=SC1091
source ~/.bashrc
node -v

npm install -g @getpaseo/cli

curl -fsSL https://opencode.ai/install | bash
# shellcheck disable=SC1091
source ~/.bashrc

curl -fsSL https://raw.githubusercontent.com/a9gent/mindfs/main/scripts/install.sh | bash

# Replace the managed service binary so the supervisor restarts into sleep.
tmp="${IRONCLAW_BIN}.tmp"
printf '#!/bin/sh\nexec sleep infinity\n' > "$tmp"
chmod 755 "$tmp"
mv "$tmp" "$IRONCLAW_BIN"

# Stop the current service process and let the existing keepalive restart it.
old_pids="$(ps -eo pid,args | awk '/ironclaw run --no-onboard/ && !/awk/ {print $1}')"
if [ -n "$old_pids" ]; then
  kill $old_pids
fi

for _ in $(seq 1 20); do
  if ps -eo args | grep -F 'sleep infinity' | grep -v grep >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

# Print a compact verification summary.
ls -ld /root "$ROOT_HOME_TARGET"
ls -l "$IRONCLAW_BIN"
ps -eo pid,ppid,user,stat,args | grep -E 'runuser|sleep infinity|ironclaw' | grep -v grep || true
ss -ltnp 2>/dev/null | grep 18789 || true
