#!/bin/bash
set -euo pipefail

echo "=== Setting up container ==="

# Create user. UID 1000 matches raw.idmap and lxc exec --user 1000.
if ! id claude &>/dev/null; then
    useradd -m -u 1000 -s /bin/bash claude
    mkdir -p /home/claude/code /home/claude/.ssh /home/claude/.config
    chown claude:claude /home/claude/code /home/claude/.ssh /home/claude/.config
    chmod 700 /home/claude/.ssh
fi

echo "--- Installing packages ---"
apt update -qq
apt install -y -qq openssh-server tmux direnv curl git build-essential ca-certificates > /dev/null

echo "--- Starting SSH ---"
systemctl enable ssh
systemctl start ssh

# Node.js 22 LTS from NodeSource. Claude Code requires Node.js 18+.
echo "--- Installing Node.js ---"
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt install -y -qq nodejs > /dev/null

echo "--- Installing Claude Code ---"
npm install -g @anthropic-ai/claude-code > /dev/null

# uv for Python projects.
echo "--- Installing uv ---"
su - claude -c 'curl -LsSf https://astral.sh/uv/install.sh | sh'

echo "=== Container setup complete ==="
