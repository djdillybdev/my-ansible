#!/usr/bin/env bash
set -euo pipefail

if ! command -v apt >/dev/null 2>&1; then
  echo "This script expects Ubuntu/Debian in WSL (apt required)." >&2
  exit 1
fi

sudo apt update
sudo apt install -y ansible git openssh-client

if [[ -f requirements.yml ]]; then
  if ! command -v ansible-galaxy >/dev/null 2>&1; then
    echo "ansible-galaxy not found on PATH; restart shell and re-run." >&2
    exit 1
  fi
  ansible-galaxy collection install -r requirements.yml
else
  echo "requirements.yml not found in current directory; skipping collection install." >&2
fi

echo "WSL control node setup complete."
echo "If you do not already have a key, run: ssh-keygen -t ed25519"
