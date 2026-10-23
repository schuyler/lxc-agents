#!/bin/bash
# Host-side setup for a corvidae agent container. Configured entirely
# through environment variables; see README.md for the list.
set -euo pipefail

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")

CONTAINER="${CONTAINER:-corvidae}"
AGENT_USER="${AGENT_USER:-corvidae}"
SERVICE="${SERVICE:-corvidae}"
WORKSPACE_HOST_PATH="${WORKSPACE_HOST_PATH:?WORKSPACE_HOST_PATH is required}"
WORKSPACE_GUEST_PATH="${WORKSPACE_GUEST_PATH:-/home/${AGENT_USER}/workspace}"
CORVIDAE_SRC="${CORVIDAE_SRC:-corvidae}"
PLUGIN_DIRS="${PLUGIN_DIRS:-}"
UNIT_DROPIN="${UNIT_DROPIN:-}"
POST_SETUP_HOOK="${POST_SETUP_HOOK:-}"
SIGNAL_SOCKET_HOST="${SIGNAL_SOCKET_HOST:-}"
SIGNAL_SOCKET_GUEST="${SIGNAL_SOCKET_GUEST:-/var/lib/signal-proxy/signal.sock}"
SIGNAL_SOCKET_HOST_UID="${SIGNAL_SOCKET_HOST_UID:-1000}"
# TZ is inherited from the caller's environment; set it explicitly to be sure.
TZ="${TZ:-UTC}"
LIMITS_CPU="${LIMITS_CPU:-}"
LIMITS_MEMORY="${LIMITS_MEMORY:-}"
ROOT_SIZE="${ROOT_SIZE:-}"
SUDO="${SUDO:-0}"

# Fixed by raw.idmap below and by the unit template.
AGENT_UID=1000

die() {
    echo "ERROR: $*" >&2
    exit 1
}

# Preflight. Everything here is checked before anything is created.
[[ "${CONTAINER}" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]] || die "bad CONTAINER: ${CONTAINER}"
[[ "${AGENT_USER}" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "bad AGENT_USER: ${AGENT_USER}"
[[ "${SERVICE}" =~ ^[A-Za-z0-9_.-]+$ ]] || die "bad SERVICE: ${SERVICE}"
[[ "${WORKSPACE_GUEST_PATH}" =~ ^/[A-Za-z0-9_./-]*$ ]] ||
    die "WORKSPACE_GUEST_PATH must be absolute and use only letters, digits, and _ . / -"
[[ "${TZ}" =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$ && -f "/usr/share/zoneinfo/${TZ}" ]] ||
    die "TZ is not a zone name under /usr/share/zoneinfo on this host: ${TZ}"
[[ "${SIGNAL_SOCKET_GUEST}" == /* ]] || die "SIGNAL_SOCKET_GUEST must be absolute"
[[ "${SIGNAL_SOCKET_HOST_UID}" =~ ^[0-9]+$ ]] || die "bad SIGNAL_SOCKET_HOST_UID"
[ -d "${WORKSPACE_HOST_PATH}" ] || die "WORKSPACE_HOST_PATH is not a directory: ${WORKSPACE_HOST_PATH}"
[ -f "${WORKSPACE_HOST_PATH}/${CORVIDAE_SRC}/pyproject.toml" ] ||
    die "no pyproject.toml in ${WORKSPACE_HOST_PATH}/${CORVIDAE_SRC}; clone corvidae there first"
if [ -n "${UNIT_DROPIN}" ] && [ ! -f "${UNIT_DROPIN}" ]; then
    die "UNIT_DROPIN is not a file: ${UNIT_DROPIN}"
fi
if [ -n "${SIGNAL_SOCKET_HOST}" ] && [ ! -S "${SIGNAL_SOCKET_HOST}" ]; then
    echo "WARNING: ${SIGNAL_SOCKET_HOST} is not a socket right now. Adding the proxy device anyway."
fi

exec > >(tee -a "/tmp/${CONTAINER}-setup.log") 2>&1

echo "=== $(date) Starting ${CONTAINER} setup ==="

# 1. Refuse if the container exists. This script never deletes anything.
if lxc info "${CONTAINER}" &>/dev/null; then
    die "container '${CONTAINER}' already exists. Remove it yourself if you want a rebuild."
fi

# 2. Create the container. raw.idmap maps UID/GID 1000 between host and guest
# so the workspace mount has the right ownership.
echo "--- Creating container ---"
launch_args=(
    --config "raw.idmap=both ${AGENT_UID} ${AGENT_UID}"
    --config boot.autostart=true
)
[ -z "${LIMITS_CPU}" ] || launch_args+=(--config "limits.cpu=${LIMITS_CPU}")
[ -z "${LIMITS_MEMORY}" ] || launch_args+=(--config "limits.memory=${LIMITS_MEMORY}")
lxc launch images:debian/trixie "${CONTAINER}" "${launch_args[@]}"
if [ -n "${ROOT_SIZE}" ]; then
    lxc config device override "${CONTAINER}" root "size=${ROOT_SIZE}"
fi

echo "--- Waiting for container to boot ---"
lxc exec "${CONTAINER}" -- systemctl is-system-running --wait &>/dev/null || true
for _ in $(seq 1 60); do
    lxc exec "${CONTAINER}" -- getent hosts deb.debian.org &>/dev/null && break
    sleep 1
done

# 3. Mount the workspace.
echo "--- Mounting workspace ---"
lxc config device add "${CONTAINER}" workspace disk \
    source="${WORKSPACE_HOST_PATH}" path="${WORKSPACE_GUEST_PATH}"

# 4. Run container-setup.sh. It is pushed as a file rather than piped to
# bash, so nothing it runs can swallow the rest of the script from stdin.
echo "--- Running container setup ---"
lxc file push "${SCRIPT_DIR}/container-setup.sh" "${CONTAINER}/root/container-setup.sh"
lxc exec "${CONTAINER}" \
    --env "AGENT_USER=${AGENT_USER}" \
    --env "WORKSPACE=${WORKSPACE_GUEST_PATH}" \
    --env "CORVIDAE_SRC=${CORVIDAE_SRC}" \
    --env "PLUGIN_DIRS=${PLUGIN_DIRS}" \
    --env "SIGNAL_SOCKET_GUEST=${SIGNAL_SOCKET_GUEST}" \
    --env "TZ=${TZ}" \
    --env "SUDO=${SUDO}" \
    -- bash /root/container-setup.sh
lxc exec "${CONTAINER}" -- rm -f /root/container-setup.sh

lxc file push --uid "${AGENT_UID}" --gid "${AGENT_UID}" --mode 0644 \
    "${SCRIPT_DIR}/envrc" "${CONTAINER}/home/${AGENT_USER}/.envrc"

# 5. Signal proxy device. bind=container makes LXD's forkproxy listen inside
# the container and dial the host socket once per connection;
# security.uid/gid is the host user that owns the socket.
if [ -n "${SIGNAL_SOCKET_HOST}" ]; then
    echo "--- Adding Signal proxy device ---"
    lxc config device add "${CONTAINER}" signal proxy \
        "connect=unix:${SIGNAL_SOCKET_HOST}" \
        "listen=unix:${SIGNAL_SOCKET_GUEST}" \
        bind=container \
        "uid=${AGENT_UID}" "gid=${AGENT_UID}" mode=0660 \
        "security.uid=${SIGNAL_SOCKET_HOST_UID}" \
        "security.gid=${SIGNAL_SOCKET_HOST_UID}"
fi

# 6. Render the unit template and install it, plus the optional drop-in.
# Bash substitution rather than sed. The replacements are quoted so that `&`
# is literal on bash 5.2+; WORKSPACE_GUEST_PATH is restricted in preflight.
echo "--- Installing systemd unit ---"
unit=$(< "${SCRIPT_DIR}/corvidae.service")
unit=${unit//@AGENT_USER@/"${AGENT_USER}"}
unit=${unit//@WORKSPACE@/"${WORKSPACE_GUEST_PATH}"}
unit=${unit//@SERVICE@/"${SERVICE}"}
rendered=$(mktemp)
trap 'rm -f "${rendered}"' EXIT
printf '%s\n' "${unit}" > "${rendered}"
lxc file push --mode 0644 "${rendered}" "${CONTAINER}/etc/systemd/system/${SERVICE}.service"

if [ -n "${UNIT_DROPIN}" ]; then
    lxc exec "${CONTAINER}" -- mkdir -p "/etc/systemd/system/${SERVICE}.service.d"
    lxc file push --mode 0644 "${UNIT_DROPIN}" \
        "${CONTAINER}/etc/systemd/system/${SERVICE}.service.d/$(basename "${UNIT_DROPIN}")"
fi

# 7. Post-setup hook: runs as the agent user, in the workspace.
if [ -n "${POST_SETUP_HOOK}" ]; then
    echo "--- Running post-setup hook ---"
    lxc exec "${CONTAINER}" \
        --user "${AGENT_UID}" --group "${AGENT_UID}" --cwd "${WORKSPACE_GUEST_PATH}" \
        --env "HOME=/home/${AGENT_USER}" \
        --env "VIRTUAL_ENV=/home/${AGENT_USER}/venv" \
        --env "PATH=/home/${AGENT_USER}/venv/bin:/home/${AGENT_USER}/.local/bin:/usr/local/bin:/usr/bin:/bin" \
        -- bash -c "${POST_SETUP_HOOK}"
fi

# 8. Enable, but do not start.
echo "--- Enabling service ---"
lxc exec "${CONTAINER}" -- systemctl daemon-reload
lxc exec "${CONTAINER}" -- systemctl enable "${SERVICE}"

echo ""
echo "=== $(date) Setup complete ==="
lxc list "${CONTAINER}"
echo ""
echo "Next:"
echo "  1. Put agent.yaml in ${WORKSPACE_HOST_PATH}"
echo "  2. lxc exec ${CONTAINER} -- systemctl start ${SERVICE}"
echo "  3. lxc exec ${CONTAINER} -- journalctl -u ${SERVICE} -f"
