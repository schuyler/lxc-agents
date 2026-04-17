#!/bin/bash
set -euo pipefail

echo "=== Setting up container ==="

# Create user. UID 1000 matches raw.idmap in setup.sh.
if ! id nanobot &>/dev/null; then
    useradd -m -u 1000 -s /bin/bash nanobot
    echo "nanobot ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/nanobot
    mkdir -p /home/nanobot/code
    chown nanobot:nanobot /home/nanobot/code
fi

# Install packages. lxd-client is needed so the agent can talk to the host's LXD.
echo "--- Installing packages ---"
apt update -qq
apt install -y -qq lxd-client curl git build-essential openssl ca-certificates > /dev/null

# Install uv and nanobot.
echo "--- Installing uv and nanobot ---"
su - nanobot -c 'curl -LsSf https://astral.sh/uv/install.sh | sh'

su - nanobot -c "
    export PATH=\"\$HOME/.local/bin:\$PATH\"
    cd ~/code
    uv venv .venv
    uv pip install nanobot-ai
"

echo "=== Container setup complete ==="
