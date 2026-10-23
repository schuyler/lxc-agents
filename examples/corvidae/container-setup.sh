#!/bin/bash
# Runs inside the container as root. setup.sh passes the variables below
# with `lxc exec --env`.
set -euo pipefail

: "${AGENT_USER:?}" "${WORKSPACE:?}" "${CORVIDAE_SRC:?}" "${SIGNAL_SOCKET_GUEST:?}" "${TZ:?}"
PLUGIN_DIRS="${PLUGIN_DIRS:-}"
SUDO="${SUDO:-0}"

# Keep in step with raw.idmap in setup.sh and the unit template.
AGENT_UID=1000
UV_VERSION="0.9.30"
PYTHON_VERSION="3.14"

export DEBIAN_FRONTEND=noninteractive

echo "=== Setting up container ==="

# 1. User. LXD creates the workspace mount point (and so /home/$AGENT_USER)
# as root before this script runs, so fix ownership explicitly.
echo "--- Creating user ${AGENT_USER} ---"
existing=$(getent passwd "${AGENT_UID}" | cut -d: -f1 || true)
if [ -n "${existing}" ] && [ "${existing}" != "${AGENT_USER}" ]; then
    echo "ERROR: uid ${AGENT_UID} already belongs to '${existing}'." >&2
    exit 1
fi
if [ -z "${existing}" ]; then
    useradd -m -u "${AGENT_UID}" -s /bin/bash "${AGENT_USER}"
fi
home="/home/${AGENT_USER}"
chown "${AGENT_UID}:${AGENT_UID}" "${home}"
for f in .bashrc .profile .bash_logout; do
    [ -e "${home}/${f}" ] || install -o "${AGENT_UID}" -g "${AGENT_UID}" "/etc/skel/${f}" "${home}/${f}"
done

# 2. Packages. dbus-user-session provides the user D-Bus that
# `systemd-run --user` needs. Every dependency has a Linux wheel, so no
# compiler; add build-essential here if that changes.
echo "--- Installing packages ---"
pkgs=(git ca-certificates curl sqlite3 jq procps less tzdata dbus-user-session)
if [ "${SUDO}" = 1 ]; then
    pkgs+=(sudo)
fi
apt-get update -qq
apt-get install -y -qq "${pkgs[@]}" > /dev/null

if [ "${SUDO}" = 1 ]; then
    echo "${AGENT_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${AGENT_USER}"
    chmod 0440 "/etc/sudoers.d/${AGENT_USER}"
fi

# 3. Timezone. timedatectl needs timedated, which can be missing in a
# container; fall back to the files it would write.
echo "--- Setting timezone ${TZ} ---"
if [ ! -f "/usr/share/zoneinfo/${TZ}" ]; then
    echo "ERROR: unknown timezone '${TZ}'." >&2
    exit 1
fi
timedatectl set-timezone "${TZ}" 2>/dev/null || {
    ln -sf "/usr/share/zoneinfo/${TZ}" /etc/localtime
    echo "${TZ}" > /etc/timezone
}

# 4. Lingering, so user@1000.service runs without a login session and
# /run/user/1000 exists at boot.
loginctl enable-linger "${AGENT_USER}"

# 5. Socket directory for the Signal proxy device. It lives outside /run,
# which is a tmpfs.
install -d -o "${AGENT_UID}" -g "${AGENT_UID}" -m 0750 "$(dirname "${SIGNAL_SOCKET_GUEST}")"

# 6. uv, the venv, corvidae and plugins, all as the agent user.
echo "--- Installing uv ${UV_VERSION}, Python ${PYTHON_VERSION}, corvidae ---"
user_script=$(mktemp)
trap 'rm -f "${user_script}"' EXIT
cat > "${user_script}" <<'USER_EOF'
set -euo pipefail
cd "$HOME"

curl -LsSf "https://astral.sh/uv/${UV_VERSION}/install.sh" | sh
export PATH="$HOME/.local/bin:$PATH"

# The venv lives outside the workspace mount: editable installs record
# container paths, and a venv inside the mount would collide with the host's.
uv venv --python "$PYTHON_VERSION" "$HOME/venv"
export VIRTUAL_ENV="$HOME/venv"

if [ ! -f "$WORKSPACE/$CORVIDAE_SRC/pyproject.toml" ]; then
    echo "ERROR: no pyproject.toml in $WORKSPACE/$CORVIDAE_SRC" >&2
    exit 1
fi
uv pip install -e "$WORKSPACE/$CORVIDAE_SRC[dev]" pytest-timeout

cd "$WORKSPACE"
shopt -s nullglob
# PLUGIN_DIRS is a space-separated list of globs; leave it unquoted so they
# word-split and expand.
# shellcheck disable=SC2086
for dir in $PLUGIN_DIRS; do
    if [ -f "$dir/pyproject.toml" ]; then
        echo "Installing plugin: $dir"
        uv pip install -e "$WORKSPACE/$dir"
    fi
done
USER_EOF
chmod 0755 "${user_script}"
runuser -u "${AGENT_USER}" -- env \
    "HOME=${home}" \
    "WORKSPACE=${WORKSPACE}" \
    "CORVIDAE_SRC=${CORVIDAE_SRC}" \
    "PLUGIN_DIRS=${PLUGIN_DIRS}" \
    "UV_VERSION=${UV_VERSION}" \
    "PYTHON_VERSION=${PYTHON_VERSION}" \
    bash "${user_script}"
rm -f "${user_script}"

# 7. Interactive shells pick up the venv from ~/.envrc, which setup.sh pushes.
if ! grep -q 'envrc' "${home}/.bashrc"; then
    # shellcheck disable=SC2016
    echo '[ -f "$HOME/.envrc" ] && . "$HOME/.envrc"' >> "${home}/.bashrc"
fi

echo "=== Container setup complete ==="
