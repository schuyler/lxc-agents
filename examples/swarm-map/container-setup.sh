#!/bin/bash
# Runs inside the swarm-map container as root, fed by setup.sh:
#   lxc exec swarm-map -- bash < container-setup.sh
# Idempotent. Each step is announced with a `step "..."` line; setup.sh
# --dry-run lists them from this file.
set -euo pipefail

CONF=/root/swarm-map.conf
STAGE=/root/.swarm-map-stage
readonly F_UPDATE="${SWARM_UPDATE:-0}"

[ -r "$CONF" ] || { echo "ERROR: ${CONF} missing (setup.sh pushes it)" >&2; exit 1; }
# shellcheck source=swarm-map.conf
. "$CONF"
SWARM_UPDATE=$F_UPDATE   # the conf cannot override the flag

APP_PORT="${APP_PORT:-3000}"
REQUIRE_APPARMOR="${REQUIRE_APPARMOR:-1}"
HELLO_IMG="${VERIFY_HELLO_IMAGE:-hello-world:latest}"
APP_ROOT=/opt/swarm-map
APP_DIR=${APP_ROOT}/app
STAMP=${APP_ROOT}/.build-stamp
ENV_DIR=/etc/swarm-map
ENV_FILE=${ENV_DIR}/swarm-map.env
UNIT=/etc/systemd/system/swarm-map.service
DATA_DIR=/home/swarm/.hermes-swarm-map

export DEBIAN_FRONTEND=noninteractive
cd /opt

step() { echo "--- $* ---"; }
as_swarm() { runuser -u swarm -- env HOME=/home/swarm CI=true NEXT_TELEMETRY_DISABLED=1 "$@" </dev/null; }
apt_get() { apt-get -y -qq -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@" >/dev/null </dev/null; }

# install_if_changed SRC DST MODE: sets CHANGED=1 when DST was (re)written.
CHANGED=0
install_if_changed() {
    if [ -f "$2" ] && cmp -s "$1" "$2"; then
        CHANGED=0
    else
        install -m "$3" -o root -g root "$1" "$2"
        CHANGED=1
    fi
    chmod "$3" "$2"
}

echo "=== Setting up swarm-map container ($(date)) ==="

gate_fail() {
    {
        echo ""
        echo "ERROR: Docker gate failed at: $1"
        echo "  docker driver line: $(timeout 20 docker info 2>&1 | grep -iE 'storage driver' | head -1 || true)"
        echo "  docker info --format driver: $(timeout 20 docker info --format '{{.Driver}}' 2>&1 | head -1 || true)"
        echo "  SecurityOptions: $(timeout 20 docker info --format '{{.SecurityOptions}}' 2>&1 | head -1 || true)"
        if [ -n "${GATE_STDERR:-}" ]; then
            echo "  docker run stderr:"
            printf '%s\n' "$GATE_STDERR" | tail -15 | sed 's/^/    /'
            if printf '%s' "$GATE_STDERR" | grep -Eiq 'open sysctl|reopen fd|permission denied|apparmor'; then
                cat <<'HINT'
  Hint: this symptom matches the known runc/AppArmor incompatibility with
  Docker-in-LXC (late-2025 runc 1.2.8 / 1.3.3 era). Options: pin an older
  containerd.io (and with it runc), update LXD, or, as a last resort and only
  if you decide so, drop AppArmor confinement in the guest (apt purge apparmor
  and set REQUIRE_APPARMOR=0 in swarm-map.conf, which makes verify.sh accept it).
HINT
            fi
        fi
        echo "  last lines of journalctl -u docker:"
        journalctl -u docker --no-pager -n 40 2>&1 | sed 's/^/    /' || true
        cat <<'MSG'

Nothing was changed to work around this (no storage-driver fallback). Options,
to be chosen manually:
  (a) fuse-overlayfs: install the fuse-overlayfs package, give the instance a
      /dev/fuse device, and set "storage-driver":"fuse-overlayfs" in
      /etc/docker/daemon.json
  (b) vfs: works, but is very slow and uses a lot of disk
  (c) a different kernel / LXD setting that allows overlayfs in the container
swarm-map.service has not been started by this run.
MSG
    } >&2
    exit 30
}

# policy-begin
# Temporary /usr/sbin/policy-rc.d stub (exit 101) so package scripts do not
# start/restart daemons while apt runs. An existing file is backed up (verified
# byte-identical) before the restore trap is armed or the stub is written. A
# leftover stub from a killed run is recognised by its exact content and removed.
POLICY=${POLICY:-/usr/sbin/policy-rc.d}
POLICY_STUB=$'#!/bin/sh\nexit 101\n'
POLICY_BAK=""
POLICY_OWN=0
policy_restore() {
    if [ -n "$POLICY_BAK" ]; then
        mv -f "$POLICY_BAK" "$POLICY" 2>/dev/null || cp -p "$POLICY_BAK" "$POLICY"
        POLICY_BAK=""
    elif [ "$POLICY_OWN" = 1 ]; then
        rm -f "$POLICY"
    fi
    POLICY_OWN=0
}
policy_block() {
    local bak
    POLICY_BAK="" POLICY_OWN=0
    if [ -e "$POLICY" ]; then
        if [ "$(cat "$POLICY"; printf x)" = "${POLICY_STUB}x" ]; then
            rm -f "$POLICY" || return 1
        else
            bak=$(mktemp "${POLICY}.bak.XXXXXX") || return 1
            if ! cp -p "$POLICY" "$bak" || [ ! -s "$bak" ] || ! cmp -s "$POLICY" "$bak"; then
                rm -f "$bak"
                return 1
            fi
            POLICY_BAK=$bak
        fi
    fi
    trap policy_restore EXIT
    POLICY_OWN=1
    printf '%s' "$POLICY_STUB" > "$POLICY" || return 1
    chmod 0755 "$POLICY" || return 1
}
# policy-end

# ------------------------------------------------------------------ packages
step "Installing base packages"
PKGS=(ca-certificates curl git gnupg openssl iptables nftables iproute2 procps jq build-essential python3 xz-utils unzip tzdata)
[ "$REQUIRE_APPARMOR" = 1 ] && PKGS+=(apparmor)
MISSING=()
for p in "${PKGS[@]}"; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q '^install ok installed$' || MISSING+=("$p")
done
if [ "${#MISSING[@]}" -gt 0 ]; then
    apt_get update
    apt_get install "${MISSING[@]}"
else
    echo "Base packages already installed, skipping."
fi

# ------------------------------------------------------------ docker config
step "Writing /etc/docker/daemon.json"
# Written before docker-ce is installed so the first daemon start already uses
# overlay2 and the classic image store.
TMPF=$(mktemp)
MTU=$(cat /sys/class/net/eth0/mtu 2>/dev/null || echo 1500)
mkdir -p /etc/docker
jq -n --argjson mtu "$MTU" '{
  "storage-driver": "overlay2",
  "features": {"containerd-snapshotter": false},
  "log-driver": "json-file",
  "log-opts": {"max-size": "10m", "max-file": "3"},
  "mtu": $mtu,
  "live-restore": true
}' > "$TMPF"
install_if_changed "$TMPF" /etc/docker/daemon.json 0644
DAEMON_CHANGED=$CHANGED
rm -f "$TMPF"
[ "$DAEMON_CHANGED" = 1 ] && echo "daemon.json written." || echo "daemon.json unchanged."

# ------------------------------------------------------------ docker engine
step "Installing Docker Engine"
mkdir -p /etc/apt/keyrings
[ -f /etc/apt/keyrings/docker.asc ] || curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
KEY_COLONS=$(gpg --show-keys --with-colons /etc/apt/keyrings/docker.asc 2>/dev/null || true)
KEY_FPR=$(printf '%s\n' "$KEY_COLONS" | awk -F: '/^fpr:/{print $10; exit}')
if [ "$(printf '%s\n' "$KEY_COLONS" | grep -c '^pub:')" != 1 ] || [ "$KEY_FPR" != "$DOCKER_APT_KEY_FPR" ]; then
    echo "ERROR: Docker apt key fingerprint is '${KEY_FPR}', expected '${DOCKER_APT_KEY_FPR}'. Removing the key; not installing." >&2
    rm -f /etc/apt/keyrings/docker.asc
    exit 1
fi
CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
TMPF=$(mktemp)
cat > "$TMPF" <<SRC
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: ${CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
SRC
install_if_changed "$TMPF" /etc/apt/sources.list.d/docker.sources 0644
rm -f "$TMPF"

DOCKER_PKG_CHANGED=0
CONTAINERD_CHANGED=0
HAVE_CONTAINERD=$(dpkg-query -W -f='${Version}' containerd.io 2>/dev/null || true)
HAVE_DOCKER=$(dpkg-query -W -f='${Version}' docker-ce 2>/dev/null || true)
if [ "$HAVE_DOCKER" != "$DOCKER_VERSION" ]; then
    apt_get update
    apt-mark unhold docker-ce docker-ce-cli containerd.io >/dev/null 2>&1 || true
    # Keep the package scripts from starting the daemon: the gate below starts
    # it, so a start failure gets the gate's message instead of dying in apt.
    policy_block || { echo "ERROR: could not safely install the temporary ${POLICY} stub; the original was not touched." >&2; exit 32; }
    apt_get install --allow-downgrades --allow-change-held-packages \
        "docker-ce=${DOCKER_VERSION}" "docker-ce-cli=${DOCKER_VERSION}" \
        containerd.io docker-buildx-plugin docker-compose-plugin \
        || { echo "ERROR: apt could not install docker-ce ${DOCKER_VERSION} (see apt output above); not a storage-driver problem." >&2; exit 31; }
    DOCKER_PKG_CHANGED=1
    [ "$(dpkg-query -W -f='${Version}' containerd.io 2>/dev/null || true)" = "$HAVE_CONTAINERD" ] || CONTAINERD_CHANGED=1
    policy_restore
    trap - EXIT
else
    echo "docker-ce ${DOCKER_VERSION} already installed, skipping."
fi
apt-mark hold docker-ce docker-ce-cli containerd.io >/dev/null
# NOTE: containerd.io, docker-buildx-plugin and docker-compose-plugin are not
# version-pinned (only docker-ce / docker-ce-cli are); first-install versions
# are whatever the Docker apt repo serves. containerd.io is held after install.

# --------------------------------------------------------------- docker gate
step "Starting Docker and checking the overlay2 gate"
# policy-rc.d suppressed the package scripts' restart, so restart here when
# either the config or the installed version changed.
if { [ "$DAEMON_CHANGED" = 1 ] || [ "$DOCKER_PKG_CHANGED" = 1 ]; } && systemctl is-active --quiet docker; then
    [ "$CONTAINERD_CHANGED" = 1 ] && { systemctl restart containerd || gate_fail "restarting containerd.service"; }
    systemctl restart docker || gate_fail "restarting docker.service after daemon.json or version change"
fi
systemctl enable --now docker || gate_fail "starting docker.service"
for _ in $(seq 1 30); do
    docker info >/dev/null 2>&1 && break
    sleep 2
done
docker info >/dev/null 2>&1 || gate_fail "daemon not answering after start"
[ "$(docker info --format '{{.Driver}}' 2>/dev/null)" = overlay2 ] || gate_fail "storage driver is not overlay2"
if docker info --format '{{json .DriverStatus}}' 2>/dev/null | grep -q 'io.containerd.snapshotter'; then
    gate_fail "containerd image store in use instead of the overlay2 graphdriver"
fi
if ! GATE_STDERR=$(timeout 300 docker run --rm "$HELLO_IMG" 2>&1 >/dev/null); then
    gate_fail "docker run ${HELLO_IMG}"
fi
echo "Docker OK: overlay2, hello-world ran."

# -------------------------------------------------------------------- sysctl
step "Enabling IPv4 forwarding"
TMPF=$(mktemp)
echo "net.ipv4.ip_forward=1" > "$TMPF"
install_if_changed "$TMPF" /etc/sysctl.d/90-swarm-map.conf 0644
rm -f "$TMPF"
sysctl -q -w net.ipv4.ip_forward=1 || true

# ---------------------------------------------------------------------- node
step "Installing Node.js"
# SHA256 values from https://nodejs.org/dist/v24.21.0/SHASUMS256.txt. Update
# both together with NODE_VERSION in swarm-map.conf.
NODE_SHA_X64=fd8e59d5a511510f6a298afb548f18c7d2b1be404d8b4a27d94fbe49f56cb2d6
NODE_SHA_ARM64=6ad1325edbdb5649c379b75a237147a666c95d4f9ae8d340fef2d1575d289ad2
if [ "$(node --version 2>/dev/null || true)" = "v${NODE_VERSION}" ]; then
    echo "node v${NODE_VERSION} already installed, skipping."
else
    if [ "$NODE_VERSION" != 24.21.0 ]; then
        echo "ERROR: NODE_VERSION=${NODE_VERSION} but the SHA256 literals in container-setup.sh are for 24.21.0; update them from nodejs.org SHASUMS256.txt." >&2
        exit 1
    fi
    case "$(uname -m)" in
        x86_64) NARCH=x64; NSHA=$NODE_SHA_X64 ;;
        aarch64) NARCH=arm64; NSHA=$NODE_SHA_ARM64 ;;
        *) echo "ERROR: unsupported architecture $(uname -m)" >&2; exit 1 ;;
    esac
    NTAR=node-v${NODE_VERSION}-linux-${NARCH}.tar.xz
    NTMP=$(mktemp -d)
    trap 'rm -rf "$NTMP"' EXIT
    curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/${NTAR}" -o "${NTMP}/${NTAR}"
    echo "${NSHA}  ${NTMP}/${NTAR}" | sha256sum -c - >/dev/null || { echo "ERROR: Node tarball SHA256 mismatch" >&2; rm -rf "$NTMP"; exit 1; }
    tar --no-same-owner -xJf "${NTMP}/${NTAR}" -C /opt
    rm -rf "$NTMP"
    trap - EXIT
    for b in node npm npx corepack; do
        ln -sfn "/opt/node-v${NODE_VERSION}-linux-${NARCH}/bin/${b}" "/usr/local/bin/${b}"
    done
fi

# ---------------------------------------------------------------------- pnpm
step "Installing pnpm"
if [ "$(pnpm --version 2>/dev/null || true)" = "$PNPM_VERSION" ]; then
    echo "pnpm ${PNPM_VERSION} already installed, skipping."
else
    npm install -g "pnpm@${PNPM_VERSION}" >/dev/null
    ln -sfn "$(npm prefix -g)/bin/pnpm" /usr/local/bin/pnpm
fi

# ---------------------------------------------------------------------- user
step "Creating the swarm user"
if ! id swarm >/dev/null 2>&1; then
    useradd -m -s /bin/bash swarm
fi
id -nG swarm | tr ' ' '\n' | grep -qx docker || usermod -aG docker swarm
mkdir -p "$APP_ROOT" "$DATA_DIR"
chown swarm:swarm "$APP_ROOT" "$DATA_DIR"

# ------------------------------------------------------------------ checkout
step "Checking out Swarm Map"
SERVICE_STOPPED=0
stop_service() {
    if systemctl is-active --quiet swarm-map 2>/dev/null; then
        systemctl stop swarm-map
        SERVICE_STOPPED=1
    fi
}
if [ ! -d "${APP_DIR}/.git" ]; then
    as_swarm git clone --quiet "$SWARM_MAP_REPO" "$APP_DIR"
    as_swarm git -C "$APP_DIR" checkout --quiet --detach "$SWARM_MAP_REF"
else
    HEAD_NOW=$(as_swarm git -C "$APP_DIR" rev-parse HEAD)
    if [ "$HEAD_NOW" != "$SWARM_MAP_REF" ]; then
        if [ "$SWARM_UPDATE" != 1 ]; then
            echo "ERROR: ${APP_DIR} is at ${HEAD_NOW}, swarm-map.conf pins ${SWARM_MAP_REF}." >&2
            echo "       Review the upstream diff (package.json, pnpm-lock.yaml), then run: setup.sh --update" >&2
            exit 1
        fi
        stop_service
        as_swarm git -C "$APP_DIR" fetch --quiet origin
        as_swarm git -C "$APP_DIR" checkout --quiet --detach "$SWARM_MAP_REF"
    fi
fi
[ "$(as_swarm git -C "$APP_DIR" rev-parse HEAD)" = "$SWARM_MAP_REF" ] || { echo "ERROR: checkout is not at ${SWARM_MAP_REF}" >&2; exit 1; }

# ------------------------------------------------------------- env and token
step "Writing /etc/swarm-map/swarm-map.env"
mkdir -p "$ENV_DIR"
TOKEN=$(sed -n 's/^HSM_OPERATOR_TOKEN=//p' "$ENV_FILE" 2>/dev/null | head -1 || true)
if ! printf '%s' "$TOKEN" | grep -Eq '^[0-9a-f]{64}$'; then
    TOKEN=$(openssl rand -hex 32)
    echo "Generated a new operator token (not printed)."
fi
ENVFLAG=$(mktemp)
(
    umask 077
    TMPF=$(mktemp)
    sed "s/@APP_PORT@/${APP_PORT}/" "${STAGE}/swarm-map.env" > "$TMPF"
    printf 'HSM_OPERATOR_TOKEN=%s\n' "$TOKEN" >> "$TMPF"
    install_if_changed "$TMPF" "$ENV_FILE" 0600
    rm -f "$TMPF"
    echo "$CHANGED" > "$ENVFLAG"
)
ENV_CHANGED=$(cat "$ENVFLAG"); rm -f "$ENVFLAG"
unset TOKEN
[ "$ENV_CHANGED" = 1 ] && echo "env file written." || echo "env file unchanged."

# --------------------------------------------------------------------- build
step "Installing dependencies and building"
LOCK_HASH=$(sha256sum "${APP_DIR}/pnpm-lock.yaml" | cut -d' ' -f1)
WANT_STAMP=$(printf '%s\n%s\n%s\n%s\n' "$SWARM_MAP_REF" "$LOCK_HASH" "$(node --version)" "$(pnpm --version)" | sha256sum | cut -d' ' -f1)
HAVE_STAMP=$(cat "$STAMP" 2>/dev/null || true)
build_fail() {
    {
        echo ""
        echo "ERROR: $1 failed."
        if [ "$SERVICE_STOPPED" = 1 ]; then
            echo "swarm-map service is STOPPED. The previous build may still be on disk (best effort:"
            echo "pnpm build overwrites .next). To recover, either:"
            echo "  - fix the error and re-run: setup.sh --update"
            echo "  - or try the previous build: lxc exec ${NAME} -- systemctl start swarm-map"
        else
            echo "swarm-map service was not started. Fix the error and re-run setup.sh."
        fi
    } >&2
    exit 40
}
if [ "$WANT_STAMP" = "$HAVE_STAMP" ] && [ -d "${APP_DIR}/.next" ] && [ -d "${APP_DIR}/node_modules" ]; then
    echo "Build stamp unchanged, skipping install/build."
else
    stop_service
    rm -f "$STAMP"
    as_swarm pnpm --dir "$APP_DIR" install --frozen-lockfile || build_fail "pnpm install"
    as_swarm NODE_OPTIONS=--max-old-space-size=3072 pnpm --dir "$APP_DIR" build || build_fail "pnpm build"
    echo "$WANT_STAMP" > "$STAMP"
fi

# ------------------------------------------------------------------- service
step "Installing and starting swarm-map.service"
install_if_changed "${STAGE}/swarm-map.service" "$UNIT" 0644
UNIT_CHANGED=$CHANGED
[ "$UNIT_CHANGED" = 1 ] && systemctl daemon-reload
systemctl enable swarm-map >/dev/null 2>&1 || { echo "ERROR: systemctl enable swarm-map failed" >&2; exit 1; }
if [ "$UNIT_CHANGED" = 1 ] || [ "$ENV_CHANGED" = 1 ]; then
    systemctl restart swarm-map
elif ! systemctl is-active --quiet swarm-map; then
    systemctl start swarm-map
fi
for _ in $(seq 1 30); do
    ss -ltn "sport = :${APP_PORT}" 2>/dev/null | grep -q "0.0.0.0:${APP_PORT}" && break
    sleep 2
done
if ! ss -ltn "sport = :${APP_PORT}" 2>/dev/null | grep -q "0.0.0.0:${APP_PORT}"; then
    echo "ERROR: nothing listening on 0.0.0.0:${APP_PORT} after start. Last journal lines:" >&2
    journalctl -u swarm-map --no-pager -n 40 >&2 || true
    exit 1
fi
echo "swarm-map listening on 0.0.0.0:${APP_PORT}."

echo "=== Container setup complete ==="
