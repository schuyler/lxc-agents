#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
HOST_USER="${HOST_USER:-${SUDO_USER:-$USER}}"
BRIDGE_INTERFACE="${BRIDGE_INTERFACE:-br0}"
HOST_IP=$(ip -4 addr show "${BRIDGE_INTERFACE}" | grep -oP 'inet \K[\d.]+')

if [ -z "${HOST_IP}" ]; then
    echo "ERROR: ${BRIDGE_INTERFACE} has no IPv4 address. Is the bridge up?"
    exit 1
fi

TRUST_PW="nanobot-setup-$(date +%s)"
WORKSPACE_HOST_PATH="/home/${HOST_USER}/code/llm/nanobot"

exec > >(tee -a "/tmp/nanobot-container-setup.log") 2>&1

echo "=== $(date) Starting nanobot container setup ==="
echo "Host IP: ${HOST_IP}"

# 1. Create the container.
# raw.idmap maps UID/GID 1000 between host and guest for correct file
# ownership on the workspace mount.
echo "--- Creating container ---"
if lxc info nanobot &>/dev/null; then
    echo "Container already exists, skipping."
else
    lxc launch images:debian/trixie nanobot \
        --config limits.cpu=4 \
        --config limits.memory=8GiB \
        --config boot.autostart=true \
        --config "raw.idmap=both 1000 1000"

    lxc config device override nanobot root size=40GiB
fi

# 2. Mount workspace.
echo "--- Mounting workspace ---"
lxc config device show nanobot | grep -q "workspace" || \
    lxc config device add nanobot workspace disk \
        source="${WORKSPACE_HOST_PATH}" path=/home/nanobot/code/nanobot

# 3. Run container setup (user, packages, uv, nanobot).
echo "--- Running container setup ---"
lxc exec nanobot -- bash < "${SCRIPT_DIR}/container-setup.sh"

# 4. Expose LXD on the network.
echo "--- Exposing LXD on network ---"
CURRENT_ADDR=$(lxc config get core.https_address 2>/dev/null || true)
if [ "${CURRENT_ADDR}" != "${HOST_IP}:8443" ]; then
    lxc config set core.https_address "${HOST_IP}:8443"
fi

# 5. TLS client certificate.
echo "--- Setting up TLS cert ---"
lxc exec nanobot -- mkdir -p /home/nanobot/.config/lxc

if ! lxc exec nanobot -- test -f /home/nanobot/.config/lxc/client.crt; then
    lxc exec nanobot -- openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout /home/nanobot/.config/lxc/client.key \
        -out /home/nanobot/.config/lxc/client.crt \
        -subj "/CN=nanobot"
    lxc exec nanobot -- chown -R nanobot:nanobot /home/nanobot/.config
fi

lxc file pull nanobot/home/nanobot/.config/lxc/client.crt /tmp/nanobot-lxd.crt
lxc config trust add-certificate /tmp/nanobot-lxd.crt --name nanobot 2>/dev/null || true
rm -f /tmp/nanobot-lxd.crt

# 6. Register host remote via trust password.
echo "--- Registering host remote ---"
lxc config set core.trust_password "${TRUST_PW}"

lxc exec nanobot -- su - nanobot -c "
    lxc remote show host >/dev/null 2>&1 || \
    lxc remote add host https://${HOST_IP}:8443 \
        --accept-certificate --password=${TRUST_PW}
"

lxc config unset core.trust_password

echo "--- Verifying LXD connection ---"
lxc exec nanobot -- su - nanobot -c "lxc list host:" && \
    echo "LXD connection OK" || echo "WARNING: LXD connection failed"

# 7. Copy service and environment files into place.
echo "--- Copying config files ---"
lxc file push "${SCRIPT_DIR}/envrc" nanobot/home/nanobot/code/.envrc
lxc exec nanobot -- chown nanobot:nanobot /home/nanobot/code/.envrc

lxc file push "${SCRIPT_DIR}/nanobot.service" nanobot/etc/systemd/system/nanobot.service
lxc exec nanobot -- systemctl daemon-reload
lxc exec nanobot -- systemctl enable nanobot

# 8. Copy LXC skill into workspace.
echo "--- Installing LXC skill ---"
SKILLS_DIR="${WORKSPACE_HOST_PATH}/skills"
mkdir -p "${SKILLS_DIR}" && chown "${HOST_USER}:${HOST_USER}" "${SKILLS_DIR}"
rm -rf "${SKILLS_DIR}/lxc"
cp -r "${SCRIPT_DIR}/../../skills/lxc" "${SKILLS_DIR}/"

echo ""
echo "=== $(date) Setup complete ==="
lxc list nanobot
echo ""
echo "Next:"
echo "  1. Edit config.json per nanobot-wiring.md"
echo "  2. lxc exec nanobot -- systemctl start nanobot"
echo "  3. lxc exec nanobot -- journalctl -u nanobot -f"
