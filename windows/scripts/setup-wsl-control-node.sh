#!/usr/bin/env bash
set -euo pipefail

if ! command -v apt >/dev/null 2>&1; then
  echo "This script expects Ubuntu/Debian in WSL (apt required)." >&2
  exit 1
fi

sudo apt update
sudo apt install -y python3 python3-pip python3-venv pipx git

pipx ensurepath
if ! command -v ansible >/dev/null 2>&1; then
  pipx install ansible
fi

if [[ -f requirements.yml ]]; then
  ansible-galaxy collection install -r requirements.yml
else
  echo "requirements.yml not found in current directory; skipping collection install." >&2
fi

echo "WSL control node setup complete."
