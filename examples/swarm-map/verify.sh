#!/bin/bash
# Verify the swarm-map container. Run on the LXD host as a user who can run
# `lxc`. Read-only against the host and other containers; only touches
# "$NAME" (swarm-map), and only changes it in the opt-in modes.
set -uo pipefail

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
CONF="${SWARM_MAP_CONF:-${SCRIPT_DIR}/swarm-map.conf}"

usage() {
    cat <<'EOF'
Usage: verify.sh [options]

Default: every check runs and all results are reported (FAILs do not stop
the run); --fail-fast stops at the first FAIL. Checks are read-only (plus throwaway docker resources inside
swarm-map, removed on exit). Exit status is non-zero if any check FAILs.
Output: PASS / FAIL / WARN / SKIP / INFO per check.

Opt-in modes (these change the swarm-map container):
  --idempotency     re-run setup.sh as you (lxd group); the instance config, docker info,
                    unit files, build stamp, token hash and package versions must be
                    unchanged and swarm-map.service must not restart
  --reboot          lxc restart swarm-map; assert everything returns unaided
  --agent-smoke     chat via a manually created agent (AGENT_PORT, default
                    8642; AGENT_API_KEY optional; LLAMA_LOG optional path to
                    the llama-server log on this host)
  --deep            MTU checks (docker0 / user-defined network vs eth0)

Other:
  --fail-fast       stop at the first FAIL
  --help            this text

Config: swarm-map.conf next to this script (override with SWARM_MAP_CONF).
EOF
}

OPT_IDEMPOTENCY=0 OPT_REBOOT=0 OPT_AGENT=0 OPT_DEEP=0 FAIL_FAST=0
for a in "$@"; do
    case "$a" in
        --idempotency) OPT_IDEMPOTENCY=1 ;;
        --reboot) OPT_REBOOT=1 ;;
        --agent-smoke) OPT_AGENT=1 ;;
        --deep) OPT_DEEP=1 ;;
        --fail-fast) FAIL_FAST=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $a" >&2; usage >&2; exit 2 ;;
    esac
done

if [ ! -r "$CONF" ]; then
    echo "ERROR: cannot read ${CONF}" >&2
    exit 2
fi
# shellcheck source=swarm-map.conf
. "$CONF"

NAME="${NAME:-swarm-map}"
STORAGE_POOL="${STORAGE_POOL:-default}"
MIN_HOST_FREE_GIB="${MIN_HOST_FREE_GIB:-25}"
APP_PORT="${APP_PORT:-3000}"
LLAMA_URL="${LLAMA_URL:-http://192.168.1.10:8080}"
LLAMA_MODEL="${LLAMA_MODEL:-}"
REQUIRE_APPARMOR="${REQUIRE_APPARMOR:-1}"
CURL_IMG="${VERIFY_CURL_IMAGE:-curlimages/curl:latest}"
HELLO_IMG="${VERIFY_HELLO_IMAGE:-hello-world:latest}"
LOGIN_PATH="${LOGIN_PATH:-/api/auth/login}"

VNET="swarm-map-verify"
TMPDIR_V=$(mktemp -d)

N_PASS=0 N_FAIL=0 N_WARN=0 N_SKIP=0
RUNNING=0
CREATED_THROWAWAY=0

pass() { N_PASS=$((N_PASS + 1)); printf 'PASS  %s\n' "$*"; }
warn() { N_WARN=$((N_WARN + 1)); printf 'WARN  %s\n' "$*"; }
skip() { N_SKIP=$((N_SKIP + 1)); printf 'SKIP  %s\n' "$*"; }
info() { printf 'INFO  %s\n' "$*"; }
fail() {
    N_FAIL=$((N_FAIL + 1)); printf 'FAIL  %s\n' "$*"
    if [ "$FAIL_FAST" = 1 ]; then finish; fi
}
section() { printf '\n== %s\n' "$*"; }

# Everything that talks to the guest goes through these; they only ever
# address "$NAME".
gxt() { local t=$1; shift; timeout "$t" lxc exec "$NAME" -- "$@" </dev/null; }
gx() { gxt 60 "$@"; }
gxi() { timeout 60 lxc exec "$NAME" -- "$@"; }

cleanup() {
    if [ "$CREATED_THROWAWAY" = 1 ]; then
        timeout 60 lxc exec "$NAME" -- sh -c \
            "docker network rm ${VNET} >/dev/null 2>&1; true" \
            </dev/null >/dev/null 2>&1
    fi
    rm -rf "$TMPDIR_V"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

finish() {
    printf '\n== Summary: %d PASS, %d FAIL, %d WARN, %d SKIP\n' "$N_PASS" "$N_FAIL" "$N_WARN" "$N_SKIP"
    [ "$N_FAIL" -gt 0 ] && exit 1
    exit 0
}

# Fail a whole section when the instance is not usable.
need_running() {
    if [ "$RUNNING" != 1 ]; then
        fail "$1: instance '${NAME}' is not running"
        return 1
    fi
}

guest_ip4() { gx ip -4 -o addr show dev eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1; }
guest_ip6() { gx ip -6 -o addr show dev eth0 scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1; }

wait_for() { # seconds cmd...
    local n=$1 i; shift
    for ((i = 0; i < n; i += 2)); do
        "$@" >/dev/null 2>&1 && return 0
        sleep 2
    done
    return 1
}

docker_up() { gx docker info; }

# curl from a nested container. DOPTS holds extra `docker run` options.
DOPTS=()
dcurl() { gxt 180 docker run --rm "${DOPTS[@]}" --entrypoint curl "$CURL_IMG" "$@"; }
dcurl_in() { timeout 180 lxc exec "$NAME" -- docker run --rm -i "${DOPTS[@]}" --entrypoint curl "$CURL_IMG" "$@"; }
http_code() { dcurl -sS -o /dev/null -w '%{http_code}' --max-time 15 "$@" 2>/dev/null; }

# ---------------------------------------------------------------- 0 preflight
section "0. Preflight"
if ! command -v lxc >/dev/null 2>&1; then
    fail "lxc not found on PATH"
    finish
fi
if ! timeout 30 lxc list -c n --format csv >/dev/null 2>&1; then
    fail "'lxc list' failed (is LXD running and are you in the lxd group?)"
    finish
fi
pass "lxc usable"
info "config: ${CONF}; instance: ${NAME}; pool: ${STORAGE_POOL}"

# ---------------------------------------------------------------- 1 instance
section "1. Instance"
if ! timeout 30 lxc info "$NAME" >/dev/null 2>&1; then
    fail "instance '${NAME}' does not exist"
else
    STATE=$(timeout 30 lxc list "^${NAME}\$" -c s --format csv 2>/dev/null)
    if [ "$STATE" = "RUNNING" ]; then
        RUNNING=1
        pass "instance RUNNING"
    else
        fail "instance state is '${STATE:-unknown}', expected RUNNING"
    fi
    v=$(timeout 30 lxc config get "$NAME" boot.autostart 2>/dev/null)
    [ "$v" = true ] && pass "boot.autostart=true" || fail "boot.autostart is '${v}', expected true"
    v=$(timeout 30 lxc config get "$NAME" security.nesting 2>/dev/null)
    [ "$v" = true ] && pass "security.nesting=true" || fail "security.nesting is '${v}', expected true"
    for k in security.syscalls.intercept.mknod security.syscalls.intercept.setxattr; do
        v=$(timeout 30 lxc config get "$NAME" "$k" 2>/dev/null)
        [ "$v" = true ] && pass "${k}=true" || fail "${k} is '${v}', expected true"
    done
    if ! cfg=$(timeout 30 lxc config show "$NAME" --expanded 2>/dev/null); then
        fail "cannot read expanded config; cannot confirm not privileged"
    elif printf '%s\n' "$cfg" | grep -Eiq '^[[:space:]]*security\.privileged:[[:space:]]*"?(1|yes|on|true)"?[[:space:]]*$'; then
        fail "security.privileged is truthy (must stay unprivileged)"
    else
        pass "not privileged"
    fi
    v=$(timeout 30 lxc config get "$NAME" limits.memory 2>/dev/null)
    info "limits.memory=${v:-unset} limits.cpu=$(timeout 30 lxc config get "$NAME" limits.cpu 2>/dev/null)"
    v=$(timeout 30 lxc config device get "$NAME" root size 2>/dev/null)
    info "root size setting '${v:-unset}' is advisory on a dir pool and is not asserted"
fi
if [ "$RUNNING" = 1 ]; then
    IP4=$(guest_ip4)
    [ -n "$IP4" ] && pass "eth0 IPv4 ${IP4}" || fail "no IPv4 address on eth0"
else
    IP4=""
fi

# ---------------------------------------------------------------- 2 space
section "2. Space (WARN only)"
pool_src=$(timeout 30 lxc storage get "$STORAGE_POOL" source 2>/dev/null)
avail_gib=""
if [ -z "$pool_src" ]; then
    skip "pool '${STORAGE_POOL}' not found or has no source; cannot check host free space"
else
    avail_b=$(df -B1 --output=avail "$pool_src" 2>/dev/null | tail -1 | tr -dc '0-9')
    if [ -n "$avail_b" ]; then
        avail_gib=$((avail_b / 1073741824))
    else
        # Pool path may be unreadable without root; fall back to LXD's own numbers.
        pinfo=$(timeout 30 lxc storage info "$STORAGE_POOL" 2>/dev/null)
        avail_gib=$(printf '%s\n' "$pinfo" | awk '
            function gib(s,  n, u) { n = s + 0; u = s; gsub(/[0-9.]/, "", u)
                if (u ~ /^T/) return n * 1024; if (u ~ /^M/) return n / 1024
                if (u ~ /^k|^K/) return n / 1048576; return n }
            /space used:/  { used = gib($3) }
            /total space:/ { tot = gib($3) }
            END { if (tot > 0) printf "%d", tot - used }')
    fi
    if [ -z "$avail_gib" ]; then
        skip "cannot determine free space for pool '${STORAGE_POOL}' (${pool_src})"
    elif [ "$avail_gib" -lt "$MIN_HOST_FREE_GIB" ]; then
        warn "host free space ${avail_gib} GiB on pool '${STORAGE_POOL}' < MIN_HOST_FREE_GIB=${MIN_HOST_FREE_GIB}"
    else
        pass "host free space ${avail_gib} GiB >= ${MIN_HOST_FREE_GIB} GiB"
    fi
fi
if [ "$RUNNING" = 1 ]; then
    use=$(gx df --output=pcent / 2>/dev/null | tail -1 | tr -dc '0-9')
    if [ -z "$use" ]; then
        skip "cannot read guest root usage"
    elif [ "$use" -gt 85 ]; then
        warn "guest root usage ${use}% > 85%"
    else
        pass "guest root usage ${use}%"
    fi
else
    skip "guest root usage: instance not running"
fi

# ---------------------------------------------------------------- 3 docker
section "3. Docker engine"
if need_running "docker"; then
    if ! docker_up >/dev/null 2>&1; then
        fail "docker daemon does not answer in ${NAME}"
        DOCKER_OK=0
    else
        DOCKER_OK=1
        pass "docker daemon answers"
        drv=$(gx docker info --format '{{.Driver}}' 2>/dev/null)
        [ "$drv" = overlay2 ] && pass "storage driver overlay2" || fail "storage driver is '${drv}', expected overlay2"
        ds=$(gx docker info --format '{{json .DriverStatus}}' 2>/dev/null)
        if printf '%s' "$ds" | grep -q 'io.containerd.snapshotter'; then
            fail "containerd image store in use (DriverStatus: ${ds})"
        else
            pass "classic graphdriver image store (no io.containerd.snapshotter)"
        fi
        gx test -d /var/lib/docker/overlay2 && pass "/var/lib/docker/overlay2 exists" || fail "/var/lib/docker/overlay2 missing"
        n=$(gx sh -c 'ls -A /var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots 2>/dev/null | wc -l' | tr -dc '0-9')
        [ "${n:-0}" = 0 ] && pass "no image layers under containerd overlayfs snapshotter" \
            || fail "containerd overlayfs snapshotter holds ${n} entries (image store is not the classic graphdriver)"
        so=$(gx docker info --format '{{.SecurityOptions}}' 2>/dev/null)
        for o in seccomp cgroupns; do
            case "$so" in *"name=${o}"*) pass "SecurityOptions has name=${o}" ;; *) fail "SecurityOptions lacks name=${o} (${so})" ;; esac
        done
        case "$so" in
            *name=apparmor*) pass "SecurityOptions has name=apparmor" ;;
            *) if [ "$REQUIRE_APPARMOR" = 1 ]; then fail "SecurityOptions lacks name=apparmor (${so})"
               else skip "apparmor not in SecurityOptions; REQUIRE_APPARMOR=0"; fi ;;
        esac
    fi
else
    DOCKER_OK=0
fi

# ---------------------------------------------------------------- 4/5 runs
section "4. Container runs"
IMAGES_OK=0
if need_running "nested containers" && [ "$DOCKER_OK" = 1 ]; then
    CREATED_THROWAWAY=1
    gx docker network rm "$VNET" >/dev/null 2>&1
    if gxt 300 docker run --rm "$HELLO_IMG" >/dev/null 2>&1; then pass "docker run hello-world"; else fail "docker run ${HELLO_IMG} failed (registry egress or runtime problem)"; fi
    if gxt 300 docker pull -q "$CURL_IMG" >/dev/null 2>&1; then
        IMAGES_OK=1
        pass "pulled ${CURL_IMG}"
    else
        fail "cannot pull ${CURL_IMG}; nested-container checks below are skipped"
    fi
    if [ "$IMAGES_OK" = 1 ]; then
        out=$(gxt 120 docker run --rm --read-only --tmpfs /run:exec --tmpfs /tmp --cap-drop ALL \
            --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add SETUID --cap-add SETGID --cap-add NET_BIND_SERVICE \
            --memory 256m --cpus 1 --entrypoint sh "$CURL_IMG" \
            -c 'echo "TAG_OK=$(echo ok > /tmp/x && cat /tmp/x)"; echo "TAG_MEM=$(cat /sys/fs/cgroup/memory.max)"; echo "TAG_CPU=$(cat /sys/fs/cgroup/cpu.max)"' 2>"$TMPDIR_V/hardened.err")
        if [ "$(printf '%s\n' "$out" | sed -n 's/^TAG_OK=//p')" = ok ]; then
            pass "hardened run (read-only, cap-drop ALL, tmpfs)"
            mem=$(printf '%s\n' "$out" | sed -n 's/^TAG_MEM=//p')
            cpu=$(printf '%s\n' "$out" | sed -n 's/^TAG_CPU=//p')
            if [ "$mem" = 268435456 ]; then pass "memory limit enforced (memory.max ${mem})"
            else fail "memory limit not enforced (memory.max '${mem}', expected 268435456)"; fi
            if [ "$cpu" = "100000 100000" ]; then pass "cpu limit enforced (cpu.max ${cpu})"
            else fail "cpu limit not enforced (cpu.max '${cpu}', expected '100000 100000')"; fi
        else
            fail "hardened run failed: $(tail -2 "$TMPDIR_V/hardened.err" | tr '\n' ' ')$(printf '%s' "$out" | tail -2 | tr '\n' ' ')"
        fi
    fi
else
    [ "$RUNNING" = 1 ] && fail "nested containers: docker not usable"
fi

# ---------------------------------------------------------------- 6 service
check_service() {
    local st en
    st=$(gx systemctl is-active swarm-map 2>/dev/null)
    en=$(gx systemctl is-enabled swarm-map 2>/dev/null)
    [ "$st" = active ] && pass "swarm-map.service active" || fail "swarm-map.service is '${st}'"
    [ "$en" = enabled ] && pass "swarm-map.service enabled" || fail "swarm-map.service is '${en}', expected enabled"
    gx ss -ltn "sport = :${APP_PORT}" 2>/dev/null | grep -q "0.0.0.0:${APP_PORT}" \
        && pass "0.0.0.0:${APP_PORT} listening" || fail "nothing listening on 0.0.0.0:${APP_PORT}"
}
section "5. Swarm Map service"
if need_running "service"; then
    check_service
    v=$(gx runuser -u swarm -- docker version --format '{{.Server.Version}}' 2>&1)
    [ $? -eq 0 ] && [ -n "$v" ] && pass "user swarm can run docker (server ${v})" || fail "user swarm cannot run docker: ${v}"
    gx runuser -u swarm -- sh -c 'cd /opt/swarm-map/app && node -e "require(\"better-sqlite3\")(\":memory:\").prepare(\"select 1\").get()"' >/dev/null 2>&1 \
        && pass "better-sqlite3 loads under swarm" || fail "better-sqlite3 does not load under swarm"
fi

# ---------------------------------------------------------------- 7 UI
check_ui() {
    local ip c b
    ip=$(guest_ip4)
    [ -n "$ip" ] || { fail "UI: no guest IPv4"; return; }
    c=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "http://${ip}:${APP_PORT}/login" 2>/dev/null)
    [ "$c" = 200 ] && pass "UI /login 200 from LXD host (${ip})" || fail "UI /login returned '${c}' from LXD host"
    b=$(curl -sS -w '\n%{http_code}' --max-time 10 "http://${ip}:${APP_PORT}/api/health/docker" 2>/dev/null)
    c=$(printf '%s' "$b" | tail -1)
    if [ "$c" = 200 ] && printf '%s' "$b" | grep -Eq '"available"[[:space:]]*:[[:space:]]*true'; then
        pass "/api/health/docker 200 with available:true"
    else
        fail "/api/health/docker returned '${c}' / body without available:true: $(printf '%s' "$b" | head -c 160)"
    fi
    c=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "http://${ip}:${APP_PORT}/api/harnesses" 2>/dev/null)
    [ "$c" = 401 ] && pass "/api/harnesses unauthenticated 401" || fail "/api/harnesses unauthenticated returned '${c}', expected 401"
}
check_login() {
    # Token is read and sent inside the guest (stdin body); only the status code leaves it.
    # setup.sh must write HSM_OPERATOR_TOKEN unquoted and hex-only: it is embedded in JSON unescaped.
    local c
    c=$(gx sh -c '
        t=$(sed -n "s/^HSM_OPERATOR_TOKEN=//p" /etc/swarm-map/swarm-map.env)
        [ -n "$t" ] || { echo notoken; exit 0; }
        printf "{\"token\":\"%s\"}" "$t" | curl -sS -o /dev/null -w "%{http_code}" --max-time 10 \
            -H "Content-Type: application/json" --data @- "http://127.0.0.1:'"${APP_PORT}"'$1"' sh "$LOGIN_PATH" 2>/dev/null)
    case "$c" in
        200) pass "token login ${LOGIN_PATH} 200" ;;
        notoken) fail "HSM_OPERATOR_TOKEN missing in /etc/swarm-map/swarm-map.env" ;;
        *) fail "token login ${LOGIN_PATH} returned '${c}'" ;;
    esac
}
section "6. UI from the LXD host"
if need_running "UI"; then check_ui; check_login; fi

# ---------------------------------------------------------------- 8/9 host.docker.internal
section "7. host.docker.internal:${APP_PORT} from nested containers"
if need_running "host.docker.internal" && [ "$IMAGES_OK" = 1 ]; then
    DOPTS=(--add-host host.docker.internal:host-gateway)
    c=$(http_code "http://host.docker.internal:${APP_PORT}/api/health/docker")
    [ "$c" = 200 ] && pass "default bridge -> host.docker.internal:${APP_PORT} 200" || fail "default bridge -> host.docker.internal:${APP_PORT} returned '${c}'"
    if gx docker network create "$VNET" >/dev/null 2>&1; then
        DOPTS=(--network "$VNET" --add-host host.docker.internal:host-gateway)
        c=$(http_code "http://host.docker.internal:${APP_PORT}/api/health/docker")
        [ "$c" = 200 ] && pass "user-defined network -> host.docker.internal:${APP_PORT} 200" || fail "user-defined network -> host.docker.internal:${APP_PORT} returned '${c}'"
    else
        fail "cannot create throwaway network ${VNET}"
    fi
else
    [ "$RUNNING" = 1 ] && skip "host.docker.internal: nested images unavailable"
fi

# ---------------------------------------------------------------- 10 egress
section "8. Egress from a nested container"
if need_running "egress" && [ "$IMAGES_OK" = 1 ]; then
    DOPTS=()
    body=$(dcurl -sS --max-time 20 https://discord.com/api/v10/gateway 2>&1)
    if printf '%s' "$body" | grep -q '"url"'; then pass "discord.com/api/v10/gateway returned url"
    else fail "discord.com/api/v10/gateway: $(printf '%s' "$body" | head -c 160)"; fi
    if dcurl -sS -o /dev/null --max-time 20 https://gateway.discord.gg >/dev/null 2>&1; then pass "gateway.discord.gg TLS completes"
    else fail "gateway.discord.gg TLS failed"; fi
else
    [ "$RUNNING" = 1 ] && skip "egress: nested images unavailable"
fi

# ---------------------------------------------------------------- 11 llama
section "9. llama-server (${LLAMA_URL})"
if need_running "llama-server" && [ "$IMAGES_OK" = 1 ]; then
    DOPTS=()
    dcurl -s -o /dev/null --max-time 5 "${LLAMA_URL}/" >/dev/null 2>&1
    rc=$?
    if [ "$rc" = 125 ] || [ "$rc" = 124 ] || [ "$rc" = 126 ] || [ "$rc" = 127 ]; then
        fail "llama-server probe: docker run itself failed or timed out (rc ${rc}); port state unknown"
    elif [ "$rc" = 7 ] || [ "$rc" = 28 ] || [ "$rc" = 6 ]; then
        warn "llama-server port closed or unreachable (curl rc ${rc}); not running or not bound to a non-loopback address (--host 0.0.0.0)"
    else
        c=$(http_code "${LLAMA_URL}/health")
        [ "$c" = 200 ] && pass "llama-server /health 200" || fail "llama-server port open but /health returned '${c}'"
        models=$(dcurl -sS --max-time 15 "${LLAMA_URL}/v1/models" 2>/dev/null)
        mid="$LLAMA_MODEL"
        [ -n "$mid" ] || mid=$(printf '%s' "$models" | gxi jq -r '.data[0].id // empty' 2>/dev/null)
        if [ -n "$models" ] && printf '%s' "$models" | gxi jq -e '.data' >/dev/null 2>&1; then
            pass "llama-server /v1/models (model: ${mid:-none})"
        else
            fail "llama-server port open but /v1/models failed"
        fi
        req=$(gx jq -n --arg m "$mid" '{model:$m,messages:[{role:"user",content:"Say OK."}],max_tokens:8}' 2>/dev/null)
        [ -n "$req" ] || req=$(printf '{"model":"%s","messages":[{"role":"user","content":"Say OK."}],"max_tokens":8}' "$(printf '%s' "$mid" | tr -cd 'A-Za-z0-9._:/-')")
        resp=$(printf '%s' "$req" | dcurl_in -sS --max-time 120 -H 'Content-Type: application/json' --data @- "${LLAMA_URL}/v1/chat/completions" 2>&1)
        if printf '%s' "$resp" | gxi jq -e '.choices[0]' >/dev/null 2>&1; then
            pass "POST /v1/chat/completions returned choices[0]"
        else
            fail "port open but POST /v1/chat/completions failed: $(printf '%s' "$resp" | head -c 200)"
        fi
    fi
else
    [ "$RUNNING" = 1 ] && skip "llama-server: nested images unavailable"
fi

# ---------------------------------------------------------------- 13 host netfilter
section "10. Host netfilter"
if grep -q '^br_netfilter ' /proc/modules 2>/dev/null; then
    pol=$(iptables -S FORWARD 2>/dev/null | head -1)
    case "$pol" in
        *"-P FORWARD DROP"*) warn "br_netfilter loaded on host and FORWARD policy is DROP: br0 traffic to containers may break" ;;
        "") warn "br_netfilter loaded on host; cannot read FORWARD policy without root" ;;
        *) pass "br_netfilter loaded, FORWARD policy not DROP" ;;
    esac
else
    pass "br_netfilter not loaded on host"
fi

# ---------------------------------------------------------------- 14 deep
if [ "$OPT_DEEP" = 1 ]; then
    section "11. MTU (--deep)"
    if need_running "mtu" && [ "$IMAGES_OK" = 1 ]; then
        emtu=$(gx cat /sys/class/net/eth0/mtu | tr -dc '0-9')
        dmtu=$(gx cat /sys/class/net/docker0/mtu 2>/dev/null | tr -dc '0-9')
        info "eth0 mtu ${emtu}, docker0 mtu ${dmtu:-n/a}"
        [ -n "$dmtu" ] && [ "$dmtu" -le "$emtu" ] && pass "docker0 MTU <= eth0 MTU" || fail "docker0 MTU '${dmtu}' vs eth0 '${emtu}'"
        gx docker network create "$VNET" >/dev/null 2>&1
        umtu=$(gxt 120 docker run --rm --network "$VNET" --entrypoint cat "$CURL_IMG" /sys/class/net/eth0/mtu 2>/dev/null | tr -dc '0-9')
        [ -n "$umtu" ] && [ "$umtu" -le "$emtu" ] && pass "user-defined network MTU ${umtu} <= eth0 ${emtu}" \
            || fail "user-defined network MTU '${umtu}' vs eth0 '${emtu}' (set com.docker.network.driver.mtu in generated compose?)"
    else
        [ "$RUNNING" = 1 ] && skip "mtu: nested images unavailable"
    fi
fi

# ---------------------------------------------------------------- 15 idempotency
fingerprint() { # outdir
    local d=$1
    mkdir -p "$d"
    timeout 30 lxc config show "$NAME" 2>/dev/null | grep -v 'volatile\.' > "$d/instance-config"
    gx docker info --format '{{.Driver}} {{.ServerVersion}} {{.SecurityOptions}}' > "$d/docker-info" 2>&1
    gx sh -c 'sha256sum /etc/systemd/system/swarm-map.service /etc/docker/daemon.json /etc/sysctl.d/90-swarm-map.conf 2>&1' > "$d/units"
    gx cat /opt/swarm-map/.build-stamp > "$d/build-stamp" 2>&1
    gx sh -c 'sed -n "s/^HSM_OPERATOR_TOKEN=//p" /etc/swarm-map/swarm-map.env | sha256sum' > "$d/token-hash" 2>&1
    gx sh -c "dpkg-query -W -f '\${Package} \${Version}\n' | sort" > "$d/packages" 2>&1
    gx systemctl show -p ActiveEnterTimestamp --value swarm-map > "$d/swarm-map-active-enter" 2>&1
}
if [ "$OPT_IDEMPOTENCY" = 1 ]; then
    section "12. Idempotency (--idempotency)"
    if need_running "idempotency"; then
        # setup.sh runs as the invoking user (lxd group is enough).
        fingerprint "$TMPDIR_V/before"
        if "${SCRIPT_DIR}/setup.sh" > "$TMPDIR_V/setup.log" 2>&1; then
            pass "setup.sh re-run exited 0"
        else
            fail "setup.sh re-run failed: $(tail -3 "$TMPDIR_V/setup.log" | tr '\n' ' ')"
        fi
        fingerprint "$TMPDIR_V/after"
        for f in $(ls "$TMPDIR_V/before"); do
            if cmp -s "$TMPDIR_V/before/$f" "$TMPDIR_V/after/$f"; then pass "unchanged: ${f}$([ "$f" = swarm-map-active-enter ] && printf ' (swarm-map.service not restarted)')"
            else fail "changed by re-run: ${f}"; diff "$TMPDIR_V/before/$f" "$TMPDIR_V/after/$f" | head -5 | sed 's/^/        /'; fi
        done
    fi
fi

# ---------------------------------------------------------------- 16 reboot
if [ "$OPT_REBOOT" = 1 ]; then
    section "13. Reboot (--reboot)"
    if need_running "reboot"; then
        timeout 180 lxc restart "$NAME" >/dev/null 2>&1 && pass "lxc restart issued" || fail "lxc restart failed"
        if wait_for 180 docker_up; then
            pass "docker back after reboot"
            wait_for 120 gx systemctl is-active swarm-map
            wait_for 60 sh -c "curl -s -o /dev/null --max-time 5 http://\$(lxc exec ${NAME} -- ip -4 -o addr show dev eth0 </dev/null | awk '{print \$4}' | cut -d/ -f1 | head -1):${APP_PORT}/login"
            check_service
            check_ui
        else
            fail "docker did not come back within 180s of reboot"
        fi
    fi
fi

# ---------------------------------------------------------------- 17 agent smoke
if [ "$OPT_AGENT" = 1 ]; then
    section "14. Agent smoke (--agent-smoke)"
    if need_running "agent-smoke"; then
        AGENT_PORT="${AGENT_PORT:-8642}"
        lines_before=""
        if [ -n "${LLAMA_LOG:-}" ] && [ -r "$LLAMA_LOG" ]; then lines_before=$(wc -l < "$LLAMA_LOG"); fi
        body='{"model":"agent","messages":[{"role":"user","content":"Say OK."}],"max_tokens":16}'
        url="http://127.0.0.1:${AGENT_PORT}/v1/chat/completions"
        if [ -n "${AGENT_API_KEY:-}" ]; then
            # key goes over stdin as a curl config, never argv
            resp=$(printf 'header = "Authorization: Bearer %s"\n' "$AGENT_API_KEY" | timeout 180 lxc exec "$NAME" -- \
                curl -sS --max-time 150 -K - -H 'Content-Type: application/json' -d "$body" "$url" 2>&1)
        else
            resp=$(gxt 180 curl -sS --max-time 150 -H 'Content-Type: application/json' -d "$body" "$url" 2>&1)
        fi
        if printf '%s' "$resp" | gxi jq -e '.choices[0]' >/dev/null 2>&1; then pass "agent :${AGENT_PORT} chat completion returned choices[0]"
        else fail "agent :${AGENT_PORT} chat failed: $(printf '%s' "$resp" | head -c 200)"; fi
        if [ -n "$lines_before" ]; then
            lines_after=$(wc -l < "$LLAMA_LOG")
            [ "$lines_after" -gt "$lines_before" ] && pass "llama-server log grew ($((lines_after - lines_before)) lines)" \
                || fail "llama-server log did not grow; agent may not be calling ${LLAMA_URL}"
        else
            skip "llama-server log check: LLAMA_LOG unset or unreadable"
        fi
        info "run twice: with OLLAMA_BASE_URL=http://host.docker.internal:11434/v1 (wizard default) and with it set to ${LLAMA_URL}/v1, to see which variable Hermes honours"
    fi
fi

finish
