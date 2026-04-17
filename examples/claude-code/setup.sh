#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")

exec > >(tee -a "/tmp/claude-code-setup.log") 2>&1

echo "=== $(date) Starting claude-code setup ==="

# 1. Create container.
# raw.idmap maps UID/GID 1000 between host and guest for correct file
# ownership on mounted directories.
echo "--- Creating container ---"
if lxc info claude-code &>/dev/null; then
    echo "Container already exists, skipping."
else
    lxc launch images:debian/trixie claude-code \
        --config limits.cpu=4 \
        --config limits.memory=8GiB \
        --config boot.autostart=true \
        --config "raw.idmap=both 1000 1000"
    lxc config device override claude-code root size=40GiB
fi

# 2. Run container setup (user, packages, Node.js, Claude Code).
echo "--- Running container setup ---"
lxc exec claude-code -- bash < "${SCRIPT_DIR}/container-setup.sh"

# 3. Push SSH config (after openssh-server creates the directory).
echo "--- Pushing SSH config ---"
lxc file push "${SCRIPT_DIR}/sshd-hardened.conf" claude-code/etc/ssh/sshd_config.d/hardened.conf
lxc exec claude-code -- systemctl restart ssh

# 4. Push config files.
echo "--- Pushing config files ---"
lxc file push "${SCRIPT_DIR}/claude-code.env" claude-code/home/claude/.config/claude-code.env
lxc exec claude-code -- chown claude:claude /home/claude/.config/claude-code.env
lxc exec claude-code -- chmod 600 /home/claude/.config/claude-code.env

lxc file push "${SCRIPT_DIR}/envrc" claude-code/home/claude/code/.envrc
lxc exec claude-code -- chown claude:claude /home/claude/code/.envrc

lxc exec claude-code -- bash -c 'grep -q "direnv hook bash" /home/claude/.bashrc || cat >> /home/claude/.bashrc' < "${SCRIPT_DIR}/profile.sh"

# 5. Push SSH key.
_SSH_HOME=$(getent passwd "${SUDO_USER:-$USER}" | cut -d: -f6)
SSH_PUBKEY=$(ls "$_SSH_HOME/.ssh/id_ed25519.pub" "$_SSH_HOME/.ssh/id_ecdsa.pub" "$_SSH_HOME/.ssh/id_rsa.pub" 2>/dev/null | head -1)
if [ -n "${SSH_PUBKEY}" ]; then
    echo "--- Setting up SSH key ---"
    lxc file push "${SSH_PUBKEY}" claude-code/home/claude/.ssh/authorized_keys
    lxc exec claude-code -- chown claude:claude /home/claude/.ssh/authorized_keys
    lxc exec claude-code -- chmod 600 /home/claude/.ssh/authorized_keys
else
    echo "--- Skipping SSH key (no public key found in ~/.ssh/) ---"
fi

# 6. Enable service.
echo "--- Enabling service ---"
lxc file push "${SCRIPT_DIR}/claude-code.service" claude-code/etc/systemd/system/claude-code.service
lxc exec claude-code -- systemctl daemon-reload
lxc exec claude-code -- systemctl enable claude-code

echo ""
echo "=== $(date) Setup complete ==="
lxc list claude-code
echo ""
echo "Next:"
echo "  Set your API key:"
echo "    lxc exec claude-code -- nano /home/claude/.config/claude-code.env"
echo ""
echo "  Run locally:"
echo "    ./lxc-claude.sh"
echo ""
echo "  Or start the service for remote SSH + tmux access:"
echo "    lxc exec claude-code -- systemctl start claude-code"
