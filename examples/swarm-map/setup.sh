#!/bin/bash
# Create and provision the swarm-map LXD container. Only runs `lxc` commands
# against the container named in swarm-map.conf, plus read-only queries.
#
# Usage: setup.sh [--dry-run] [--update]
#   --dry-run  print what would run; change nothing (safe without the container)
#   --update   check out SWARM_MAP_REF from swarm-map.conf and rebuild
set -euo pipefail

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
CONF="${SWARM_MAP_CONF:-${SCRIPT_DIR}/swarm-map.conf}"

DRY=0 UPDATE=0
for a in "$@"; do
    case "$a" in
        --dry-run) DRY=1 ;;
        --update) UPDATE=1 ;;
        -h|--help) sed -n '5,7p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $a" >&2; exit 2 ;;
    esac
done

readonly F_DRY=$DRY F_UPDATE=$UPDATE
[ -r "$CONF" ] || { echo "ERROR: cannot read ${CONF}" >&2; exit 1; }
# shellcheck source=swarm-map.conf
. "$CONF"
# Flags come from the command line only; nothing in the conf can change them.
DRY=$F_DRY UPDATE=$F_UPDATE

NAME="${NAME-}"
[[ "$NAME" =~ ^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || { echo "ERROR: NAME '${NAME}' in ${CONF} is empty or invalid (must match ^[a-z]([a-z0-9-]{0,61}[a-z0-9])?\$)." >&2; exit 1; }
IMAGE="${IMAGE:-images:debian/trixie}"
STORAGE_POOL="${STORAGE_POOL:-default}"
CPU="${CPU:-4}"
MEMORY="${MEMORY:-8GiB}"
ROOT_SIZE="${ROOT_SIZE:-}"
MIN_HOST_FREE_GIB="${MIN_HOST_FREE_GIB:-25}"
APP_PORT="${APP_PORT:-3000}"

for v in SWARM_MAP_REPO SWARM_MAP_REF NODE_VERSION PNPM_VERSION DOCKER_VERSION DOCKER_APT_KEY_FPR; do
    val="${!v:-}"
    if [ -z "$val" ] || [ "$val" = __SET_ME__ ]; then
        echo "ERROR: ${v} is empty or __SET_ME__ in ${CONF}; set a pinned literal first." >&2
        exit 1
    fi
done
printf '%s' "$SWARM_MAP_REF" | grep -Eq '^[0-9a-f]{40}$' || { echo "ERROR: SWARM_MAP_REF must be a full 40-hex commit id." >&2; exit 1; }

if [ "$DRY" = 1 ]; then
    echo "=== DRY RUN: nothing below is executed except read-only lxc queries ==="
else
    LOG=$(mktemp /tmp/swarm-map-container-setup.XXXXXX.log 2>/dev/null) \
        || LOG=$(mktemp "${HOME:-/tmp}/.swarm-map-container-setup.XXXXXX.log" 2>/dev/null) \
        || { LOG=/dev/null; echo "WARN: no writable log file; logging to terminal only." >&2; }
    exec > >(tee -a "$LOG") 2>&1
    echo "Log file: ${LOG}"
    echo "=== $(date) Starting swarm-map container setup ==="
fi

# run: print in dry-run, execute otherwise.
run() {
    if [ "$DRY" = 1 ]; then echo "DRY-RUN: $*"; else "$@"; fi
}
gx() { lxc exec "$NAME" -- "$@" </dev/null; }

command -v lxc >/dev/null 2>&1 || { echo "ERROR: lxc not found on PATH" >&2; exit 1; }
lxc list -c n --format csv >/dev/null 2>&1 || { echo "ERROR: 'lxc list' failed (is LXD running and are you in the lxd group?)" >&2; exit 1; }
lxc storage show -- "$STORAGE_POOL" >/dev/null 2>&1 || { echo "ERROR: storage pool '${STORAGE_POOL}' does not exist" >&2; exit 1; }

# Fails closed: an unreadable config counts as privileged. LXD truthy values: 1, yes, on, true.
is_privileged() {
    local cfg
    cfg=$(lxc config show "$NAME" --expanded 2>/dev/null) || return 0
    printf '%s\n' "$cfg" | grep -Eiq '^[[:space:]]*security\.privileged:[[:space:]]*"?(1|yes|on|true)"?[[:space:]]*$'
}
EXISTS=0
lxc info "$NAME" >/dev/null 2>&1 && EXISTS=1
if [ "$EXISTS" = 1 ] && [ "$(lxc config get "$NAME" user.swarm-map.managed 2>/dev/null)" != true ]; then
    echo "ERROR: an instance named '${NAME}' already exists but is not marked user.swarm-map.managed=true." >&2
    echo "       Refusing to touch it (nothing was changed). Choose another NAME in the conf." >&2
    exit 1
fi
if [ "$UPDATE" = 1 ] && [ "$EXISTS" = 0 ] && [ "$DRY" = 0 ]; then
    echo "ERROR: --update needs an existing container '${NAME}'." >&2
    exit 1
fi

# Free-space warning (never aborts).
pool_src=$(lxc storage get "$STORAGE_POOL" source 2>/dev/null || true)
if [ -n "$pool_src" ] && avail=$(df -B1 --output=avail "$pool_src" 2>/dev/null | tail -1 | tr -dc '0-9') && [ -n "$avail" ]; then
    gib=$((avail / 1073741824))
    [ "$gib" -lt "$MIN_HOST_FREE_GIB" ] && echo "WARN: ${gib} GiB free on pool '${STORAGE_POOL}' (< ${MIN_HOST_FREE_GIB} GiB); Docker images and volumes need room."
fi

# 1. Create the container.
echo "--- Creating container ---"
NEEDS_RESTART=0
set_cfg() { # key value: set only when different
    local cur
    cur=$(lxc config get "$NAME" "$1" 2>/dev/null || true)
    if [ "$cur" != "$2" ]; then
        echo "Config ${1}: '${cur}' -> '${2}'"
        run lxc config set "$NAME" "$1" "$2"
        case "$1" in security.*) NEEDS_RESTART=1 ;; esac
    fi
}
if [ "$EXISTS" = 1 ]; then
    echo "Container already exists, skipping creation."
    if is_privileged; then
        echo "ERROR: ${NAME} is privileged; refusing to continue." >&2
        exit 1
    fi
    set_cfg security.nesting true
    set_cfg security.syscalls.intercept.mknod true
    set_cfg security.syscalls.intercept.setxattr true
    set_cfg boot.autostart true
    set_cfg limits.cpu "$CPU"
    set_cfg limits.memory "$MEMORY"
else
    run lxc init "$IMAGE" "$NAME" -s "$STORAGE_POOL" \
        --config user.swarm-map.managed=true \
        --config security.nesting=true \
        --config security.syscalls.intercept.mknod=true \
        --config security.syscalls.intercept.setxattr=true \
        --config boot.autostart=true \
        --config "limits.cpu=${CPU}" \
        --config "limits.memory=${MEMORY}"
    [ -n "$ROOT_SIZE" ] && run lxc config device override "$NAME" root "size=${ROOT_SIZE}"
fi
if [ "$DRY" = 0 ] && is_privileged; then
    echo "ERROR: ${NAME} is privileged (possibly via a profile); refusing to continue." >&2
    exit 1
fi
# Repair an interrupted first run: apply what is missing, never overwrite.
if [ "$EXISTS" = 1 ] && [ -n "$ROOT_SIZE" ] && ! lxc config device show "$NAME" 2>/dev/null | grep -q '^root:'; then
    run lxc config device override "$NAME" root "size=${ROOT_SIZE}"
fi
if [ "$EXISTS" = 0 ] && [ "$DRY" = 1 ]; then
    echo "DRY-RUN: lxc config set ${NAME} user.swarm-map.image-fingerprint <volatile.base_image>"
elif [ -z "$(lxc config get "$NAME" user.swarm-map.image-fingerprint 2>/dev/null)" ]; then
    fp=$(lxc config get "$NAME" volatile.base_image 2>/dev/null || true)
    [ -z "$fp" ] || run lxc config set "$NAME" user.swarm-map.image-fingerprint "$fp"
fi

# 2. Start and wait for the guest.
echo "--- Starting container ---"
STATE=$(lxc list "^${NAME}\$" -c s --format csv 2>/dev/null || true)
if [ "$STATE" = RUNNING ] && [ "$NEEDS_RESTART" = 1 ]; then
    echo "Security settings changed; restarting."
    run lxc restart "$NAME"
elif [ "$STATE" != RUNNING ]; then
    run lxc start "$NAME"
fi
if [ "$DRY" = 1 ]; then
    echo "DRY-RUN: wait for systemd, eth0 IPv4 and DNS in ${NAME}"
else
    timeout 180 lxc exec "$NAME" -- systemctl is-system-running --wait </dev/null >/dev/null 2>&1 || true
    ok=0
    for _ in $(seq 1 60); do
        if gx ip -4 -o addr show dev eth0 2>/dev/null | grep -q inet && gx getent hosts deb.debian.org >/dev/null 2>&1; then ok=1; break; fi
        sleep 2
    done
    [ "$ok" = 1 ] || { echo "ERROR: ${NAME} has no IPv4 address or DNS after 120s" >&2; exit 1; }
fi

# 3. Push config and run guest setup.
echo "--- Pushing files ---"
run lxc file push "$CONF" "${NAME}/root/swarm-map.conf" --mode 0644
for f in swarm-map.service swarm-map.env; do
    run lxc file push -p "${SCRIPT_DIR}/${f}" "${NAME}/root/.swarm-map-stage/${f}" --mode 0644
done

echo "--- Running container setup ---"
if [ "$DRY" = 1 ]; then
    echo "DRY-RUN: lxc exec ${NAME} --env SWARM_UPDATE=${UPDATE} -- bash < ${SCRIPT_DIR}/container-setup.sh"
    echo "DRY-RUN: guest steps:"
    sed -n 's/^step "\(.*\)"$/  - \1/p' "${SCRIPT_DIR}/container-setup.sh"
    echo "=== DRY RUN complete ==="
    exit 0
fi
lxc exec "$NAME" --env "SWARM_UPDATE=${UPDATE}" -- bash < "${SCRIPT_DIR}/container-setup.sh" || {
    rc=$?
    echo "ERROR: container setup failed (exit ${rc}); see the messages above. Log: ${LOG}" >&2
    exit "$rc"
}

IP=$(gx ip -4 -o addr show dev eth0 | awk '{print $4}' | cut -d/ -f1 | head -1)
MAC=$(lxc config get "$NAME" volatile.eth0.hwaddr)
echo ""
echo "=== $(date) Setup complete ==="
lxc list "^${NAME}\$"
echo ""
echo "Container MAC (reserve in DHCP): ${MAC}"
echo "Container IP:                    ${IP}"
echo "UI:                              http://${IP}:${APP_PORT}/login"
echo ""
echo "Next:"
echo "  1. Operator token (read it yourself; it is not printed here):"
echo "       lxc exec ${NAME} -- sed -n 's/^HSM_OPERATOR_TOKEN=//p' /etc/swarm-map/swarm-map.env"
echo "  2. Start llama-server on the host with --host 0.0.0.0 --port 8080 --jinja"
echo "  3. ./verify.sh"
