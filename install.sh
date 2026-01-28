#!/bin/bash
set -e

echo "🚀 Starting Bootstrap..."

# --- 1. Get Ansible ---
OS="$(uname -s)"
if [ "$OS" = "Darwin" ]; then
    if ! command -v brew &> /dev/null; then
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
    brew install ansible
elif [ -f /etc/debian_version ]; then
    sudo apt update
    sudo apt install -y curl git build-essential ansible
fi

# --- 2. Run Ansible ---
# This installs Mise, Chezmoi, System Apps, and Fonts
echo "⚙️ Running Ansible Playbook..."
cd "$(dirname "$0")"
ansible-playbook -i inventory.ini setup.yaml --ask-become-pass

# --- 3. Apply Dotfiles ---
echo "📂 Initializing Dotfiles..."
export PATH="$HOME/.local/bin:$PATH"

if [ ! -f "$HOME/.local/share/chezmoi/chezmoi.toml" ]; then
    # Replace with your repo
    # chezmoi init --apply git@github.com:djdillybdev/dotfiles.git
    echo "⚠️  Repo not set. Run: chezmoi init --apply git@github.com:USER/dotfiles.git"
else
    chezmoi apply
fi

# --- 4. Install Dev Tools ---
echo "🛠️ Installing Mise tools..."
mise install

echo "✅ Setup Complete!"