# Broker implementation spec

The implementation specification for `lxc-broker`. The
[design document](broker-design.md) says *why*; this document says *what*,
precisely enough that an implementer makes no design decisions of their own
on anything security-relevant. Where the two disagree, this one wins and the
disagreement is a bug to report.

## 1. Scope and invariants

Covers the server, its CLI, the image bake tooling, the LXD host
prerequisites, and the test suite. **MUST** and **MUST NOT** are hard
requirements; **SHOULD** may be deviated from only with a comment saying why.

The implementation MUST preserve these across crashes and restarts:

1. **Every container on the LAN bridge has a live or deleted service row.**
   Promotion (§11) writes the row before touching LXD; rollback marks it
   `deleted` rather than removing it; only the pruner removes rows, once
   the container is gone.
2. **The broker never passes agent-supplied data to exec.** The reaper's
   activity probe (§12) is the only exec; its argv is a constant.
3. **Agents never see other agents' sandboxes.** A sandbox owned by another
   agent is `not_found`, never `not_owner`.
4. **Names are validated in `policy.py` before they reach the database or
   LXD.** A lookup argument reaches the adapter only after resolving to a
   row.
5. **No config key reaches LXD except the fixed sets in §8.** The adapter
   has no generic config-setting method.
6. **Policy lives outside the adapter**, which translates and never
   decides; that is what makes the fake adapter (§17) a faithful double.
7. **Only the server mutates LXD.** The CLI writes intent under a
   precondition check; the server acts on it, one actor per container (§6).

## 2. Repository layout

`broker/lxc_broker/`: `server.py` (FastMCP app, tools, auth, approval
poller), `adapter.py` (the only module importing pylxd), `db.py`,
`policy.py` (validation, ownership, quotas, transitions), `lifecycle.py`
(create / promote / destroy / reconcile, locks), `reaper.py`, `cli.py`,
`config.py`, `audit.py`. `broker/images/`: `bake.sh`, `manifest.toml`,
`common.sh`, per-image scripts, `ssh-host-keys.service`. `broker/tests/`:
`fake_adapter.py`, `test_*.py`, `integration/`. Plus `lxc-broker.service`,
`pyproject.toml`, `README.md`.

Python 3.11+. Dependencies: `fastmcp`, `pylxd==2.3.5` (the current release
at time of writing; re-check PyPI when implementing), `httpx`, `uvicorn`.
Tests: `pytest`, `pytest-asyncio`. Environment: `uv`. `adapter.py` is the
only module that imports `pylxd`.

## 3. Configuration

`/etc/lxc-broker/config.toml`; `--config PATH` is a global option before
any subcommand. Unknown keys are a startup error. The file and the 0750
directory MUST be readable by the `lxc-broker` group, which the CLI runs as.

| key | type | default | meaning |
|---|---|---|---|
| `listen_address` | string | **required** | The host's address on `sandbox_bridge`. `load()` rejects `0.0.0.0`, `::`, and empty; startup binds it before touching LXD (§16) and exits if it is not assigned to the host. |
| `listen_port` | int | `8765` | |
| `lxd_endpoint` | string | **required** | e.g. `https://192.168.1.10:8443`, the host's LAN address (§9). |
| `lxd_cert`, `lxd_key` | path | `/etc/lxc-broker/client.{crt,key}` | Restricted client cert; key mode 0600. |
| `lxd_server_cert` | path | `/etc/lxc-broker/lxd-server.crt` | Copy of the server cert (§9), passed as a CA-bundle path. Verification MUST NOT be disabled. |
| `lxd_project` | string | `agents` | |
| `storage_pool` | string | `default` | |
| `sandbox_bridge` | string | `sandbox-br` | LXD-managed isolated bridge. |
| `lan_bridge` | string | `br0` | Host bridge to the LAN. |
| `images` | table | see example | image key → LXD alias in `lxd_project`. Every alias MUST exist at startup. |
| `default_image` | string | `debian` | MUST be a key of `images`. |
| `sandbox_quota` | int | `10` | Per agent, counting every live sandbox row. |
| `service_quota` | int | `3` | Per agent: live services plus sandboxes `pending_promotion`. |
| `idle_stop_hours`, `idle_delete_hours` | float | `2`, `24` | Both measured from the start of the idle period; delete MUST exceed stop. |
| `max_keep_alive_hours` | float | `12` | |
| `reaper_interval_seconds`, `approval_poll_seconds` | int | `300`, `5` | Reaper tick; how often the server looks for approved promotions. |
| `promotion` | `"auto"` \| `"approve"` | `"approve"` | |
| `notify_url` | string | absent | §14. |
| `state_dir` | path | `/var/lib/lxc-broker` | Database. MUST match the unit's `StateDirectory` (§16). |
| `sandbox_user` | string | `sandbox` | MUST match the user baked into the images. |
| `limits.cpu`, `limits.memory` | int, string | `2`, `"2GiB"` | Per-container. |
| `limits.disk` | string | unset | Root disk size; unset means no `size` on the root device. Startup warns when set and the pool driver is `dir` (§9). |
| `wait_for_ip_seconds` | int | `60` | |
| `row_retention_days` | int | `30` | How long `deleted` rows are kept once their container is gone. Does not apply to the audit table. |

```toml
listen_address = "10.77.0.1"
lxd_endpoint = "https://192.168.1.10:8443"
promotion = "approve"
notify_url = "https://ntfy.sh/my-broker-topic"
[images]
debian = "broker/debian"
python = "broker/python"
[limits]
cpu = 2
memory = "2GiB"
```

`config.load(path) -> Config` (frozen dataclass) raises `ConfigError` naming
the key: `default_image not in images`, `idle_delete_hours <=
idle_stop_hours`, a bad `listen_address`, a missing path.

## 4. Identity

**Tokens.** 32 bytes from `secrets.token_bytes`, base64url without padding.
Shown once at creation, stored only as `sha256` hex, compared with
`hmac.compare_digest`. **Agent names:** `^[a-z0-9][a-z0-9-]{0,19}$`, not
ending in `-`; the name prefixes every container the agent creates.

**Authentication.** Every MCP request carries `Authorization: Bearer
<token>`. Missing, malformed, unknown, or revoked → HTTP 401 with an
identical body. On match the agent name goes on the request context; tools
never take it as a parameter. Failures are logged with the source address,
never the token. Each request queries `agents`, so CLI changes apply at once.

**CLI** (database only; see §16 for the write discipline):

| command | effect |
|---|---|
| `token create NAME --pubkey FILE` | Validates NAME; reads one `ssh-ed25519` or `ssh-rsa` key from FILE; inserts the row; prints the token once. **Fails if any row for NAME exists, revoked or not**, and if NAME equals or is a `-`-prefix of any live service name. |
| `token revoke NAME` | Sets `revoked`. Nothing is destroyed; the agent's containers appear in `lxc-broker orphans` and are removed with `lxc-broker destroy`. |
| `token list` | Name, created, revoked, live sandbox and service counts. Never hashes. |

## 5. Naming and argument validation

**Lookup arguments** (`id`, `sandbox`, `name` on every tool, and every
NAME on the CLI): `^[a-z0-9][a-z0-9-]{0,62}$`, not ending in `-`, checked in
`policy.py` before any database query; failure → `invalid_argument`.

**Sandbox ids.** `{agent}-{slug}-{hex4}`. `slug` from `name_hint`: lowercase;
runs of characters outside `[a-z0-9]` → one `-`; strip `-` from both ends;
truncate to 20 and strip again; empty or absent → `sandbox`. `hex4` from
`secrets.token_hex(2)`, regenerated on collision with any container name or
sandbox row (any state), 8 tries then `backend_error`. Maximum length 46.

**Service names**, checked in order; 1–3 give `invalid_name`, 4–5
`name_taken`:

1. `^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$` (RFC 1123 label, 1–40).
2. Does not begin with `{agent}-` for any agent row, revoked or not.
3. Not in `{lxc-broker, default, localhost, <sandbox_user>}`.
4. Not a live service row.
5. Not in `adapter.list_instances()`.

**Image keys.** Must be a key of `config.images` → else `invalid_image`.

**Scalar arguments** → `invalid_argument` naming the parameter:

| parameter | rule |
|---|---|
| `name_hint` | string, ≤ 200 chars |
| `purpose` | string; after strip, 1–500 chars; every char printable and none of `U+0000`–`U+001F`, `U+007F`, `U+0080`–`U+009F`, `U+061C`, `U+200E`, `U+200F`, `U+202A`–`U+202E`, `U+2066`–`U+2069` |
| `ports` | list of ints 1–65535, ≤ 64 entries; stored deduplicated and sorted; advisory only, no firewall effect |
| `hours` | finite number `> 0`; above `max_keep_alive_hours` is clamped, not rejected |

The CLI escapes any agent-originated string (`repr`-style for non-printable
ASCII) before printing.

## 6. Data model

### Database

`state_dir/broker.db`, stdlib `sqlite3`, `journal_mode=WAL`,
`busy_timeout=5000`, writes under `BEGIN IMMEDIATE`. `db.py` chmods
`broker.db`, `-wal`, and `-shm` to 0660 after creation; the directory is
2770 `lxc-broker:lxc-broker` (setgid), and `cli.py` sets `os.umask(0o007)`
at startup, so a database first created by `token create` is still usable
by the server. The database holds only token hashes.

**No adapter call is ever made inside a transaction.** Every sequence is:
read in one transaction; adapter work with none open; then a write
transaction that re-reads the row and proceeds only if it is still in the
expected state — **otherwise it logs, audits the event named in that
sequence, writes nothing, and takes that sequence's failure path**.

```sql
CREATE TABLE agents (name TEXT PRIMARY KEY, token_sha256 TEXT NOT NULL UNIQUE,
  ssh_public_key TEXT NOT NULL, created TEXT NOT NULL, revoked TEXT);

CREATE TABLE sandboxes (
  id INTEGER PRIMARY KEY, sandbox_id TEXT NOT NULL,
  agent TEXT, image TEXT,                     -- both NULL only for operator-destroyed orphans
  status TEXT NOT NULL, created TEXT NOT NULL, last_active TEXT NOT NULL,
  keep_alive_until TEXT, stopped_at TEXT, deleted_at TEXT,
  host_key TEXT, ip TEXT, signal TEXT);       -- signal: reaper's last result
CREATE UNIQUE INDEX sandboxes_live ON sandboxes(sandbox_id) WHERE deleted_at IS NULL;

CREATE TABLE services (
  id INTEGER PRIMARY KEY, name TEXT NOT NULL, agent TEXT NOT NULL,
  purpose TEXT NOT NULL, ports TEXT NOT NULL,  -- JSON array
  status TEXT NOT NULL, created TEXT NOT NULL,
  promoted_from TEXT NOT NULL, image TEXT NOT NULL,
  host_key TEXT, ip TEXT, deleted_at TEXT);
CREATE UNIQUE INDEX services_live_name ON services(name) WHERE deleted_at IS NULL;

CREATE TABLE promotions (id INTEGER PRIMARY KEY, sandbox TEXT NOT NULL,
  name TEXT NOT NULL, purpose TEXT NOT NULL, ports TEXT NOT NULL, requested TEXT NOT NULL,
  approved TEXT, rejected TEXT, failed TEXT, completed TEXT, reason TEXT);
CREATE UNIQUE INDEX promotions_open_sandbox ON promotions(sandbox)
  WHERE rejected IS NULL AND failed IS NULL AND completed IS NULL;
CREATE UNIQUE INDEX promotions_open_name ON promotions(name)
  WHERE rejected IS NULL AND failed IS NULL AND completed IS NULL;

CREATE TABLE containers_seen (name TEXT PRIMARY KEY, status TEXT NOT NULL,
  seen TEXT NOT NULL);                        -- server's last list_instances()
CREATE TABLE audit (id INTEGER PRIMARY KEY, ts TEXT NOT NULL, agent TEXT NOT NULL,
  event TEXT NOT NULL, target TEXT NOT NULL, detail TEXT NOT NULL);  -- JSON
```

A **live** row has `deleted_at IS NULL`; `status = deleted` and `deleted_at`
are always written together. Every lookup by `sandbox_id` or `name` here
resolves on the live index, so destroy-then-re-promote under one name
inserts a second row while the first awaits pruning. Timestamps are ISO
8601 UTC `Z`, compared as datetimes. `db.py` creates the schema if absent.

### Locks

`lifecycle.py` keeps `dict[str, asyncio.Lock]` keyed by container name,
held for the whole of `create_sandbox` (from after the id is committed),
`start_sandbox`, `keep_alive`, `destroy`, `promote` and the poller (§11),
and each reaper action. **Any operation touching two containers acquires
both locks in sorted-name order** before any work; `asyncio.Lock` is not
reentrant, so inner sequences never acquire (§11). Locks are taken outside
any transaction and never across a whole reaper pass; an entry is pruned
with its row, and only while unlocked. **Container locks are taken before
the adapter's internal lock, never the other way**, and the adapter
releases its lock inside each call: container → adapter → release.

### States

Sandbox: `creating → running ↔ stopped → deleted`; `running →
pending_promotion → running` (reject) or `→ promoting`; `running →
promoting` (auto); `promoting → deleted` (completed) or `→ running` /
`→ stopped` (failed, §11); any live state `→ deleted` via `destroy` except
`promoting` and `creating` (`invalid_state`). Service: `promoting → active
→ deleted`; `promoting → deleted` (failed or reconciled). Services have no
stopped state: `active` stays `active` whatever the container is doing, and
`container_status` is reported separately (§7, §16).

The reaper evaluates `running` for stop, `stopped` for delete, `creating`
for a stuck-creation timeout, `deleted` for retry-delete and pruning, and
skips `pending_promotion` (no timeout, by design: it waits for a human) and
`promoting`. `stopped` counts toward `sandbox_quota`; `deleted` does not.
`keep_alive`/`promote` are valid only in `running`, `start_sandbox` in `stopped`.

## 7. Tool surface

Eight tools. Policy failures return `{"error": CODE, "message": "..."}` as
the result; they do not raise. Unexpected exceptions are caught at the tool
boundary, logged with a traceback, and returned as `backend_error` with a
message that MUST NOT include exception text or LXD detail.

| code | meaning |
|---|---|
| `quota_exceeded` | per-agent cap reached |
| `not_found` | no such sandbox or service visible to this agent |
| `not_owner` | the service exists but belongs to another agent |
| `invalid_name`, `name_taken`, `invalid_image`, `invalid_argument` | §5 |
| `invalid_state` | not valid in the target's current state |
| `backend_error` | LXD or internal failure |

Tool descriptions given to FastMCP MUST say that SSH is the way in, that
idle sandboxes are stopped then deleted, and that promotion copies to the LAN.

`ttl_expires`: for `running`, `max(last_active, keep_alive_until or
last_active) + idle_stop_hours`; for `stopped`, `stopped_at +
(idle_delete_hours - idle_stop_hours)`; otherwise null.

**`create_sandbox(image?, name_hint?)`** → §10. Returns
`{id, ip, ssh_user, host_key, status, ttl_expires}`. Errors:
`invalid_image`, `invalid_argument`, `quota_exceeded`, `backend_error`.

**`list_sandboxes()`** → `{"sandboxes": [{id, ip, status, created,
last_active, ttl_expires, pending_promotion}]}` for this agent's live
sandboxes. `pending_promotion` is the requested service name in
`pending_promotion` or `promoting`, else null.

**`start_sandbox(id)`**, this agent's sandbox in `stopped`, under the lock:

1. `start(id)`. Failure: nothing changed; `backend_error`.
2. `ip = wait_for_ip(id)`.
3. `put_file` the agent's registered key to `authorized_keys` (mode 0o600,
   uid/gid 1000).
4. Transaction: re-read (still `stopped`, else log and return
   `backend_error` with no audit row); `status = running`, `ip`,
   `last_active = now`, `stopped_at = null`. Audit `sandbox_started`.

Failure at 2 or 3: the container is running, so commit `running`,
`stopped_at = null`, `last_active = now`, `ip` if obtained, then return
`backend_error` naming the step (else the delete stage would remove a live
container). Returns the `create_sandbox` shape. Errors: `not_found`,
`invalid_argument`, `invalid_state`, `backend_error`.

**`keep_alive(id, hours)`**, this agent's sandbox in `running`:
`keep_alive_until = now + min(hours, max_keep_alive_hours)`, so the
effective ceiling on the stop time is `now + max_keep_alive_hours +
idle_stop_hours`. Audits `keep_alive`. Returns `{id, keep_alive_until,
ttl_expires}`. Errors: `not_found`, `invalid_argument`, `invalid_state`.

**`destroy(id)`**. Resolution: this agent's live sandboxes, then live
services. Another agent's sandbox → `not_found`; another agent's service →
`not_owner`; `promoting` or `creating` → `invalid_state`. Under the lock: a
transaction re-reads (no longer destroyable → `invalid_state`, no audit
row) and marks the row `deleted` (a `pending_promotion` sandbox also gets
its promotions row `rejected`, reason `destroyed`, audited
`promotion_rejected` by the acting agent); then `adapter.delete`
(`not_found` counts as success); audit `sandbox_destroyed` or
`service_destroyed`, and notify the latter. An adapter failure leaves the
row `deleted`, returns `backend_error`, and the reaper retries. Returns
`{id, kind: "sandbox" | "service", status: "deleted"}`. Errors: `not_found`,
`not_owner`, `invalid_argument`, `invalid_state`, `backend_error`.

**`promote(sandbox, name, purpose, ports?)`** → §11. Under `approve`
returns `{"status": "pending_approval", "name", "sandbox"}`; under `auto`
the `describe_service` record. Errors: `not_found`, `invalid_state`,
`invalid_name`, `name_taken`, `invalid_argument`, `quota_exceeded`,
`backend_error`.

**`list_services()`** → `{"services": [{name, agent, purpose, ports,
status, created, ip}]}` for every live service, all agents.

**`describe_service(name)`** → the `list_services` entry plus `ssh_user`,
`host_key`, `promoted_from`, and `container_status` from a live
`get_status`: `running`, `stopped`, `transitional`, `error`; `missing` on
`not_found`; `unknown` on any other `AdapterError`. The registry read never
fails on a transient LXD problem. This is one LXD call per invocation from
any agent, an accepted consequence of the shared-trust boundary. The SSH
key that works is the promoting agent's, inherited by the copy. Errors:
`not_found`, `invalid_argument`.

## 8. The adapter

`LXDAdapter(config)` holds one `pylxd.Client(endpoint, cert=(crt, key),
verify=server_cert, project=lxd_project, timeout=30)`; `verify` is a PEM
CA-bundle path (the self-signed server cert is its own CA). pylxd is not
safe for concurrent use (one `requests.Session`), so every public method
holds a `threading.Lock`, deliberately and boundedly: for exactly one LXD
call, never across a sequence (`wait_for_ip` releases between polls). The
adapter is synchronous; server code calls it via `asyncio.to_thread` through
one helper in `lifecycle.py`. Every method raises `AdapterError(not_found:
bool)` on failure; `wait=True` everywhere. Thirteen methods and nothing else:

| method | pylxd | notes |
|---|---|---|
| `launch(name, image_alias)` | `instances.create(LAUNCH, wait=True)`; `start(wait=True)` | |
| `copy(src, dst)` | `instances.create(COPY, wait=True)` | `src` must be stopped |
| `start(name)`, `stop(name)` | `instance.start/stop(wait=True)` | no-op if already so; `stop` forces after 30s |
| `delete(name)` | stop if running, `instance.delete(wait=True)` | `not_found=True` if absent |
| `list_instances() -> dict[str, str]` | `instances.all()`, `.name` → mapped `.status` | project-scoped; one call |
| `get_status(name) -> str` | `instance.status` mapped | `Running`→`running`, `Stopped`→`stopped`, `Starting/Stopping/Freezing/Thawing/Aborting`→`transitional`, else (`Frozen`, `Error`, unknown)→`error`. `Frozen` is deliberately `error`: the broker never freezes, so a frozen container is someone else's doing. |
| `wait_for_ip(name, timeout) -> str` | poll `state().network["eth0"]["addresses"]` 1s | first `inet` `global`; `AdapterError` on timeout |
| `put_file(name, path, content: bytes, mode: int, uid: int, gid: int)` | `files.put(...)` | `mode` is an int such as `0o600`; parent dir must exist; running only |
| `get_file(name, path) -> bytes` | `files.get(path)` | running only |
| `read_tcp_table(name) -> str` | `instance.execute(["cat", "/proc/net/tcp", "/proc/net/tcp6"]).stdout` | the only exec; argv is this constant; non-zero exit → `AdapterError` |
| `image_exists(alias) -> bool` | `images.get_by_alias`, `except NotFound` | |
| `pool_driver(name) -> str` | `storage_pools.get(name).driver` | startup's `dir` warning only |

Reconciliation and the reaper skip `transitional` containers and skip
`error` ones after logging once per container per process.

```python
LAUNCH = {
    "name": name, "type": "container",
    "source": {"type": "image", "alias": image_alias},
    "config": {"security.privileged": "false", "security.nesting": "false",
               "boot.autostart": "false",
               "limits.cpu": str(limits.cpu), "limits.memory": limits.memory},
    "devices": {"root": {"type": "disk", "path": "/", "pool": storage_pool,
                         "size": limits.disk},          # key omitted if unset
                "eth0": {"type": "nic", "network": sandbox_bridge, "name": "eth0"}},
    "profiles": ["default"],
}
COPY = {
    "name": dst, "type": "container",
    "source": {"type": "copy", "source": src},
    "config": {"security.privileged": "false", "security.nesting": "false",
               "boot.autostart": "true",
               "limits.cpu": str(limits.cpu), "limits.memory": limits.memory},
    "devices": {"root": {"type": "disk", "path": "/", "pool": storage_pool,
                         "size": limits.disk},          # key omitted if unset
                "eth0": {"type": "nic", "nictype": "bridged", "parent": lan_bridge, "name": "eth0"}},
    "profiles": ["default"],
}
```

`sandbox_bridge` is LXD-managed (§9) and uses the `network` form;
`lan_bridge` uses `parent`. The project's default profile has no devices,
so these are the only ones. No `exec` beyond `read_tcp_table`, no
`set_config`, no device or snapshot methods; adding one is a design change.

**`FakeAdapter`** (`tests/fake_adapter.py`) implements the same interface
over an in-memory dict `{name: {status, config, devices, files, tcp_table}}`
with `fail_on` (raise once on the named method), `crash_after` (raise
`SimulatedCrash` after it takes effect), a `calls` log, and fixed addresses.

## 9. LXD host prerequisites

Run once by the operator with full LXD access. `br0` MUST exist per
[host-setup.md](host-setup.md) §2 and `lxd init` MUST have run. Facts
marked *verified* were checked on LXD 5.21.7 with a `dir` pool.

**Storage.** If `limits.disk` is set, `storage_pool` MUST enforce
per-instance size (`zfs`, `btrfs`, `lvm`, or `dir` on ext4/xfs with
`prjquota`); plain `dir` silently ignores `size`, and startup warns.
Promotion copies the sandbox: on `dir` time scales with disk usage
(*verified*: 1.7 s for a fresh image), on zfs/btrfs it is a CoW clone.

```bash
# 1. Isolated bridge. Subnet must not overlap the LAN.
lxc network create sandbox-br ipv4.address=10.77.0.1/24 ipv4.nat=true \
    ipv6.address=none dns.mode=managed

# 2. Restricted project. Project limits cap the SUM of instance limits:
#    n_agents x (sandbox_quota + service_quota + 1 for a bake or an in-flight
#    promotion) x per-container limits; one agent, defaults: 14 / 28 CPU / 28 GiB.
#    restricted.networks.access MUST list BOTH bridges (verified: with only
#    sandbox-br, parent=br0 fails "Network not allowed in project"; a third
#    bridge is refused either way).
lxc project create agents \
    -c features.images=true -c features.profiles=true \
    -c features.networks=false -c features.storage.volumes=true \
    -c restricted=true \
    -c restricted.containers.privilege=unprivileged \
    -c restricted.containers.nesting=block \
    -c restricted.containers.lowlevel=block \
    -c restricted.containers.interception=block \
    -c restricted.devices.disk=block -c restricted.devices.nic=allow \
    -c restricted.devices.proxy=block -c restricted.devices.unix-char=block \
    -c restricted.devices.unix-block=block -c restricted.devices.unix-hotplug=block \
    -c restricted.devices.usb=block -c restricted.devices.gpu=block \
    -c restricted.devices.infiniband=block -c restricted.devices.pci=block \
    -c restricted.networks.access=sandbox-br,br0 \
    -c limits.virtual-machines=0 -c limits.containers=14 \
    -c limits.cpu=28 -c limits.memory=28GiB

# 3. Empty default profile in the project; the broker sets root and eth0.
lxc profile device remove default root --project agents 2>/dev/null || true
lxc profile device remove default eth0 --project agents 2>/dev/null || true

# 4. Broker user, state directory (setgid so CLI-created files stay in the
#    group before the first `serve`), and restricted certificate.
sudo useradd --system --shell /usr/sbin/nologin --home /var/lib/lxc-broker lxc-broker
sudo install -d -o lxc-broker -g lxc-broker -m 2770 /var/lib/lxc-broker
sudo install -d -o lxc-broker -g lxc-broker -m 0750 /etc/lxc-broker
sudo openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -days 3650 -subj "/CN=lxc-broker" \
    -keyout /etc/lxc-broker/client.key -out /etc/lxc-broker/client.crt
sudo chown lxc-broker:lxc-broker /etc/lxc-broker/client.*
sudo chmod 0600 /etc/lxc-broker/client.key
lxc config trust add-certificate /etc/lxc-broker/client.crt \
    --name lxc-broker --projects agents --restricted

# 5. Server certificate copy (the snap path is unreadable by other users;
#    re-copy if LXD regenerates it). Its SAN MUST contain the LAN address or
#    a hostname usable in lxd_endpoint; if not, use such a hostname, or
#    regenerate the server cert (delete server.crt/.key, restart LXD) and re-copy.
sudo install -o lxc-broker -g lxc-broker -m 0644 \
    /var/snap/lxd/common/lxd/server.crt /etc/lxc-broker/lxd-server.crt
openssl x509 -in /etc/lxc-broker/lxd-server.crt -noout -ext subjectAltName

# 6. LXD listens on the LAN address ONLY. Never "[::]" or "0.0.0.0", which
#    would expose the LXD API to every sandbox via the sandbox-br gateway.
lxc config set core.https_address 192.168.1.10:8443

# 7. The agent container gets a leg on sandbox-br (in its own project).
lxc config device add nanobot eth1 nic network=sandbox-br name=eth1
#    Inside it: printf 'auto eth1\niface eth1 inet dhcp\n' > /etc/network/interfaces.d/eth1
```

Notes the README MUST carry. *Verified:* `restricted.devices.disk=block`
permits the root disk (via `--storage` or an explicit root device) and
refuses `source=/` with "Disk devices are forbidden".
`restricted.networks.access=sandbox-br,br0` is the second wall for NIC
placement: only the two named bridges are attachable at all.
`restricted.containers.lowlevel=block` forbids every `raw.*` key.

### Reachability matrix

Rows marked *operator* are enforced only by the firewall rules below, which
are REQUIRED.

| path | v1 | enforced by |
|---|---|---|
| sandbox ↔ sandbox | allowed | shared bridge (documented trust boundary) |
| sandbox → internet | allowed | LXD NAT |
| sandbox → broker (`listen_address:listen_port`), sandbox → agent container (`eth1`) | allowed | required; the agent had the same exposure on the LAN |
| sandbox → host DHCP/DNS (udp/tcp 53, udp 67) | allowed | LXD's dnsmasq |
| sandbox → LXD API (host:8443), any other host port | **blocked** | *operator*: LXD bound to the LAN address **and** the input rule |
| sandbox → LAN, including services | **blocked** | *operator*: forward rule. An agent tests a promoted service from the agent container. A per-service `accept` above the drop is the hand-added exception. |
| LAN → sandbox, service → sandbox | **blocked** | no route from LAN hosts **and** the inbound forward rule, so an added route does not help |
| LAN → service, service → LAN, service → internet | allowed | a service is a LAN host |

Both rulesets use `LISTEN_PORT`, `LAN_CIDR`, and `SANDBOX_CIDR`; substitute
with `sed -e s/LISTEN_PORT/8765/ -e s#LAN_CIDR#192.168.1.0/24# -e
s#SANDBOX_CIDR#10.77.0.0/24#` before loading.

```
table inet lxc_broker {
    chain input {
        type filter hook input priority filter; policy accept;
        iifname "sandbox-br" udp dport { 53, 67 } accept
        iifname "sandbox-br" tcp dport { 53, LISTEN_PORT } accept
        iifname "sandbox-br" icmp type echo-request accept
        iifname "sandbox-br" ct state established,related accept
        iifname "sandbox-br" drop
    }
    chain forward {
        type filter hook forward priority filter; policy accept;
        iifname "sandbox-br" ip daddr LAN_CIDR drop
        oifname "sandbox-br" ip saddr != SANDBOX_CIDR ct state new drop
    }
}
```

LXD's own accept rules live in another table; a `drop` here is final, so
DHCP and DNS are accepted explicitly. NAT return traffic is `established`,
so the inbound rule only stops new connections. Load with `nft -f`.

**Agent elsewhere on the LAN.** With no `sandbox-br` leg the agent needs a
route to `SANDBOX_CIDR` via the LXD host, a static LAN address, and two
`accept` rules above the drops: `iifname "sandbox-br" ip daddr <agent>` and
`oifname "sandbox-br" ip saddr <agent>`. The token then crosses the LAN in
plain HTTP; such an operator SHOULD front the broker with TLS (out of scope).

**ufw equivalent** (substitute the placeholders by hand). Requires
`DEFAULT_FORWARD_POLICY="ACCEPT"` in `/etc/default/ufw` (LXD's NAT needs
forwarding). ufw's built-in rules accept
`RELATED,ESTABLISHED` forward traffic first, so `deny out` only stops new
inbound connections:

```bash
sudo ufw route deny in  on sandbox-br to LAN_CIDR
sudo ufw route deny out on sandbox-br
sudo ufw allow in on sandbox-br to any port LISTEN_PORT proto tcp
sudo ufw allow in on sandbox-br to any port 53
sudo ufw allow in on sandbox-br to any port 67 proto udp
sudo ufw deny  in on sandbox-br
sudo ufw reload
```

The remote-agent exceptions are `ufw route insert 1 allow in|out on
sandbox-br to|from <agent>`. Verify with a `curl` from a sandbox and a
`ping` toward one from a LAN host.

## 10. Sandbox creation

`lifecycle.create_sandbox(agent, image_key, name_hint)`:

1. Validate → `invalid_image`, `invalid_argument`. `seen = list_instances()`.
2. Transaction: count the agent's live sandboxes → `quota_exceeded` if ≥
   quota; generate the id against `seen` and all sandbox rows; insert
   `creating` with `created = last_active = now`; commit. Then acquire the
   lock for the id and hold it to the end.
3. `launch(id, images[image_key])`.
4. `ip = wait_for_ip(id)`.
5. `put_file` the agent's key to `/home/{sandbox_user}/.ssh/authorized_keys`,
   mode 0o600, uid/gid 1000 (the image guarantees the directory).
6. Poll `get_file(id, "/etc/ssh/ssh_host_ed25519_key.pub")` 1 s × 30; parse
   to `type key`.
7. Transaction: re-read (still `creating`, else log, audit
   `sandbox_create_failed` reason `state_changed`, and take the failure
   path); `status = running`, `ip`, `host_key`. Audit `sandbox_created`.

Failure at 3–7 (3 included, since `launch` is create-then-start):
`delete(id)` best effort, behind a defensive assertion that `id` was absent
from `seen`; row → `deleted`; audit `sandbox_create_failed` with the step;
return `backend_error`.

## 11. Promotion

Promotion is a **copy**: stop the sandbox, copy it to a container named
after the service with its NIC on `lan_bridge` and autostart on, start the
copy, delete the original. The image templates for `/etc/hostname` and
`/etc/hosts` fire on copy, so the broker writes no files. The copy inherits
the sandbox's SSH host key and `authorized_keys`, so both keep working.

**Lock ownership.** `promote` (both modes) and the approval poller acquire
**both** container locks, `sandbox_id` and `name`, in sorted order before
any work and hold them to the end. Execute and Rollback acquire nothing;
they are called with both held. The names can never be equal (§5 rule 2
forbids a service name starting with any `{agent}-`, and every sandbox id
does), so sorted acquisition never takes one lock twice.

### Request

`lifecycle.promote(agent, sandbox_id, name, purpose, ports)`, both locks
held:

1. Resolve: this agent's live sandbox, `running` → else `not_found` /
   `invalid_state`. Validate `name`, `purpose`, `ports`. `seen =
   list_instances()`.
2. Transaction: re-read; quota (§3 `service_quota`); collision checks (§5
   rules 4–5 against live rows and `seen`). Insert a `promotions` row with
   `requested = now`; an `IntegrityError` from either partial unique index
   is returned as `name_taken`. Under `approve`: `approved = null`, sandbox
   → `pending_promotion`; audit `promotion_requested`; notify
   `promotion_pending`; return `pending_approval`. Under `auto`: `approved
   = now`, sandbox → `promoting`, insert the service row (`promoting`,
   `name`, `purpose`, `ports`, `created = requested`, `promoted_from`,
   `image` and `host_key` from the sandbox, `ip = null`); audit
   `promotion_requested`; no notification, since there is nothing for an
   operator to act on and the audit row records it; fall through to
   *Execute*.

### Approval

`lxc-broker approve NAME` sets `approved = now`; `reject NAME [--reason
TEXT]` sets `rejected = now` and `reason`, sandbox → `running` with
`last_active = now`, and writes `promotion_rejected` as `operator`, in one
transaction. Both are guarded writes (§16); `reject` refuses once
`approved` is set (approval wins; the operator uses `destroy` afterwards).

The server polls every `approval_poll_seconds` for approved-and-open rows
whose sandbox is `pending_promotion`. For each, with both locks acquired
as above: `seen = list_instances()`; transaction: re-read the promotions row
and abort unless still approved-and-open with the sandbox still
`pending_promotion`; re-run §5 rules 4–5 (name taken meanwhile: `failed =
now`, reason `name_taken`, sandbox → `running`, audit `promotion_failed`);
else insert the service row exactly as in Request step 2, sandbox →
`promoting`, audit `promotion_approved`; Execute. The agent learns of
rejection or failure by the sandbox reappearing in `list_sandboxes` without
`pending_promotion`.

### Execute

Called with both locks held. Precondition: the sandbox row is `promoting`
and its service row exists. Let `stopped_by_us = (get_status(sandbox_id)
== "running")`.

1. `stop(sandbox_id)`.
2. `copy(sandbox_id, name)`.
3. `start(name)`.
4. `ip = wait_for_ip(name)`.
5. Transaction: re-read both rows; if either has changed, log, audit
   `promotion_failed` reason `state_changed`, write nothing, and run
   *rollback*. Else service → `active` with `ip`; sandbox → `deleted`,
   `deleted_at = now`; promotions `completed = now`. Audit
   `promotion_completed`.
6. `delete(sandbox_id)` best effort. A failure is logged; the reaper's
   retry-delete of `deleted` rows with a container (§12) finishes it.

**Rollback** (failure at 1–4, or the step-5 guard; both locks held):
`delete(name)` if `name` is in `list_instances()` or that call itself
fails (treat as "may exist"), ignoring the delete's outcome; if
`stopped_by_us`, `start(sandbox_id)` then `wait_for_ip`; then **always**
the transaction: service → `deleted` (never removed; the reaper finishes a
failed delete), promotions `failed = now` with the step as `reason`,
sandbox → `running` with `last_active = now` and `ip` (null on a
`wait_for_ip` timeout, as §7), or → `stopped`, `stopped_at = now`, only if
`start` itself failed. Audit `promotion_failed`. Return `backend_error`
naming the sandbox id. Idempotent by construction.

### Reconciliation at startup

Before serving, `lifecycle.reconcile()` takes one read transaction to
snapshot every row, then `seen = list_instances()`, replacing
`containers_seen` in one transaction. **`seen` holds every instance LXD
returned with its mapped status**; containers whose status is
`transitional` or `error` are logged and excluded from candidate selection
only, so their rows are left untouched (never treated as missing). Rows
are handled in order, first match wins, each committed in its own short
transaction that re-reads the row. Reconciliation takes no container
locks; it runs before the server accepts requests or starts the reaper.

| # | row | action |
|---|---|---|
| 1 | sandbox `creating` | `delete` if in `seen`; row → `deleted`; audit `sandbox_create_failed` reason `reconciled`. |
| 2a | service `promoting`, neither `name` nor `promoted_from` in `seen` | service and sandbox → `deleted`; promotions `failed`; audit `reconcile_missing`. |
| 2b | service `promoting`, `name` in `seen` and `running`, and `wait_for_ip(name)` succeeds | service → `active` with `ip`; sandbox → `deleted`; promotions `completed = now`; `delete(promoted_from)` best effort; audit `promotion_completed`. |
| 2c | service `promoting`, otherwise | `delete(name)` if in `seen`; service → `deleted`; promotions `failed`, reason `reconciled`; audit `promotion_failed`. Sandbox: if `promoted_from` not in `seen` → `deleted`, audit `reconcile_missing`; else `start` it if `stopped`, → `running` (`stopped` if the start failed). A `wait_for_ip` timeout in 2b lands here deliberately: the sandbox is intact, so rolling back loses nothing. |
| 2d | sandbox `promoting` with no live `promoting` service row | as 2c, using the sandbox's open promotions row for `name`. |
| 3 | sandbox `pending_promotion`, not in `seen` | promotions `rejected = now`, reason `container missing`; sandbox → `deleted`; audit `reconcile_missing`. |
| 4 | sandbox `running`/`stopped` | Not in `seen` → `deleted`, audit `reconcile_missing`. If `seen` status is `running` or `stopped`, sync `status` to it (`stopped_at` or `last_active` set to now; audit `reconcile_stopped`/`reconcile_started`); `transitional`/`error` → untouched. Start nothing. |
| 5 | service `active`, not in `seen` | → `deleted`; audit `reconcile_missing`. Services are never status-synced. |
| 6 | any row `deleted`, name in `seen` with status `running`/`stopped` | `delete`; audit `reconcile_deleted`. |
| 7 | name in `seen` with no row | Log once at warning; visible in `lxc-broker orphans`. |

If `list_instances()` fails, the server exits non-zero.

## 12. Reaper

An asyncio task started after reconciliation, running every
`reaper_interval_seconds` with an injectable `clock`.

**Activity signal.** For a `running` sandbox, `read_tcp_table(id)` (§8)
returns `/proc/net/tcp` and `/proc/net/tcp6` concatenated. Skip headers;
split on whitespace; fields 1 and 2 are `local_address` and `rem_address`
as `HEXIP:HEXPORT`; field 3 is `st`. Decode each `HEXIP` to an `ipaddress`
object (the kernel writes each 32-bit word little-endian: reverse the bytes
of every 4-byte word, one for `tcp`, four for `tcp6`) and normalise
v4-mapped v6 to v4. A row counts if `st == "01"`, local port is 22, and the
remote is not `is_loopback` and not `IPv4Address(row.ip)` (null `ip`:
loopback only). A sandbox SSHing to itself is not activity.
Any counted row → `active`, none → `idle`. An `AdapterError` (exec failed,
or not running when sampled) → `unavailable`, treated as `active` for this
pass and logged once per sandbox per process: a broken signal reaps
nothing. A sibling sandbox's session does count; the design document says
why that is accepted.

**Pass.** One read transaction snapshots every sandbox and service row;
`seen = list_instances()` replaces `containers_seen` (DELETE then INSERT,
one transaction); each `running` sandbox is sampled with no lock or
transaction held, and every sampled result is written to `signal` in the
act phase. For each candidate below the reaper takes the container lock,
opens a transaction, re-reads the row, and **skips** it if `status`,
`last_active`, or `keep_alive_until` differ from the snapshot (a lifecycle
operation intervened). Adapter calls happen between that re-read and a
second identical check before the write. Any `AdapterError` skips the
candidate without changing the row; absence is established only by `seen`.

Like §11, `seen` holds every instance with its status; a row whose
container is `transitional` or `error` matches no candidate below and is
left untouched. Candidates are first-match-wins per row:

| candidate | condition | action |
|---|---|---|
| `running`/`stopped` sandbox or `active` service | name not in `seen` | → `deleted`; audit `reconcile_missing` |
| `running`, `active` | | `last_active = now` |
| `running`, `idle` | `now - max(last_active, keep_alive_until or last_active) > idle_stop_hours` | `stop`; `status = stopped`, `stopped_at = now`, `keep_alive_until = null`; audit `sandbox_stopped` |
| `stopped` | `now - stopped_at > idle_delete_hours - idle_stop_hours` | `delete`; → `deleted`; audit `sandbox_deleted`; notify `sandbox_deleted` |
| `creating` | `now - created > wait_for_ip_seconds + 120 s` | `delete` if in `seen`; → `deleted`; audit `sandbox_create_failed` reason `timeout` |
| `deleted` (either table) | name in `seen` | `delete`; audit `reconcile_deleted` (retry path for `destroy`, operator destroy, rollback, and promotion step 6) |
| `deleted` (either table) | name not in `seen`, `now - deleted_at > row_retention_days` | delete the row and, if unlocked, its lock entry |

## 13. Audit

One row per lifecycle event in the `audit` table (§6), `detail` as JSON
with `purpose` and `error` truncated to 256 characters; `agent` is the
actor, `operator` for the CLI, `broker` for reaper and reconciliation. Never
pruned.

| event | target | detail |
|---|---|---|
| `sandbox_created` / `sandbox_create_failed` | id | `image`, `ip` / `step` or `reason`, `error` |
| `sandbox_started` / `sandbox_stopped` / `sandbox_deleted` / `sandbox_destroyed` | id | `ip` / `idle_hours` / `stopped_hours` / — |
| `keep_alive` | id | `hours`, `keep_alive_until` |
| `promotion_requested` / `promotion_approved` / `promotion_rejected` | name | `sandbox`, `purpose`, `ports`, `mode` / `sandbox` / `sandbox`, `reason` |
| `promotion_completed` / `promotion_failed` | name | `sandbox`, `ip` / `sandbox`, `step` or `reason`, `error` |
| `service_destroyed` | name | `purpose`, `ip`, `by` (`agent` or `operator`) |
| `token_created` / `token_revoked` | agent | — |
| `reconcile_stopped` / `reconcile_started` / `reconcile_missing` / `reconcile_deleted` | id or name | `kind` |
| `orphan_destroyed` | container name | — |

`lxc-broker audit [--since T] [--agent A]` prints rows.

## 14. Notifications

With `notify_url` set, the server POSTs JSON (5 s total timeout, no
retries, failures logged at warning) as a background task nobody awaits.
Body: `{"event", "ts", "agent", "target", "detail"}`, the audit-row shape.
Events: `promotion_pending` (`sandbox`, `purpose`, `ports`),
`sandbox_deleted` (`stopped_hours`), `service_destroyed` (`purpose`, `ip`, `by`).

## 15. Images

**Bake.** `images/bake.sh` runs on the host as the operator with full LXD
access; it is the one place besides the reaper probe that uses `lxc exec`,
before any agent can reach the image. `lxc-broker bake [KEY...]` wraps it,
passing `PROJECT`, `SANDBOX_USER`, `STORAGE_POOL`, `SANDBOX_BRIDGE`,
`LIMITS_CPU`, `LIMITS_MEMORY`, `LIMITS_DISK` in the environment.
`images/manifest.toml` names the base image (`images:debian/trixie`) and
the ordered scripts per key, relative to `SCRIPT_DIR=$(dirname "$(readlink
-f "$0")")`. *Verified on LXD 5.21:* `lxc launch -d` only overrides
profile devices, so with an empty profile root and eth0 MUST come from
`--storage` and `--network` (which writes `network=`), and the root size
via `device set` (`override` fails "The device already exists"). The pylxd
create body is unaffected. For each key:

```bash
args=(--project "$PROJECT" --storage "$STORAGE_POOL" --network "$SANDBOX_BRIDGE"
      -c security.privileged=false -c security.nesting=false
      -c "limits.cpu=$LIMITS_CPU" -c "limits.memory=$LIMITS_MEMORY")
lxc launch "$BASE" "bake-$KEY" "${args[@]}"
if [[ -n "${LIMITS_DISK:-}" ]]; then
    lxc config device set "bake-$KEY" root size="$LIMITS_DISK" --project "$PROJECT"
fi
# wait for an address, then for each script:
lxc exec "bake-$KEY" --project "$PROJECT" --env "SANDBOX_USER=$SANDBOX_USER" -- bash < "$SCRIPT_DIR/$script"
lxc exec "bake-$KEY" --project "$PROJECT" -- sh -c 'rm -f /etc/ssh/ssh_host_* && apt-get clean'
lxc stop "bake-$KEY" --project "$PROJECT"
lxc publish "bake-$KEY" --project "$PROJECT" --alias "broker/$KEY" --reuse
lxc delete "bake-$KEY" --project "$PROJECT"
```

A non-zero exit from any script aborts and deletes the container.

**Every image guarantees** (`common.sh`, `$SANDBOX_USER` defaulting to
`sandbox`): the user at UID/GID 1000 with passwordless sudo via
`/etc/sudoers.d/$SANDBOX_USER`; `/home/$SANDBOX_USER/.ssh` mode 0700 owned
1000:1000 and empty; `openssh-server` with the repo's
[hardened drop-in](../examples/claude-code/sshd-hardened.conf) plus
`AllowUsers $SANDBOX_USER`; `unattended-upgrades`; `curl git build-essential
ca-certificates`; locale `C.UTF-8`; and this unit enabled so every clone
generates its own host key on first boot (Debian 13 uses `ssh.socket`):

```ini
[Unit]
Description=Generate SSH host keys on first boot
Before=ssh.service ssh.socket
ConditionPathExists=!/etc/ssh/ssh_host_ed25519_key
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/ssh-keygen -A
[Install]
WantedBy=multi-user.target
```

Per-image: `debian` adds nothing; `python` adds `uv` for `$SANDBOX_USER`
with `~/.local/bin` on PATH, plus `python3` and `python3-venv`; `node` adds
Node 20 from Debian trixie (`nodejs`, `npm`). Images are never updated in
place; re-bake to update.

## 16. Server and CLI

**Startup.** Load config → `bind()` `listen_address:listen_port` (exit
non-zero if the address is not assigned to the host; no `listen()` yet) →
construct the adapter, verify `list_instances()` and every image alias,
warn if `limits.disk` is set and `pool_driver(storage_pool) == "dir"`
(exit non-zero on any failure) → open the database → reconcile (§11) →
start the reaper and the approval poller → `listen()` and serve FastMCP
over Streamable HTTP with uvicorn on that socket, path `/mcp`, behind the
auth middleware. Tools are thin wrappers over `lifecycle`/`policy`; none
touches the adapter. Logs go to stderr, one line each: every tool call at
info with agent, tool, outcome; problems at warning or above; never a token.

**CLI.** `lxc-broker [--config PATH] SUBCOMMAND`, run by operators in the
`lxc-broker` group; everything but `serve` and `bake` talks only to the
database. **Every write opens `BEGIN IMMEDIATE`, re-reads, acts only if its
precondition holds, and prints a refusal otherwise.**

| subcommand | effect |
|---|---|
| `serve` | run the server in the foreground |
| `token create\|revoke\|list` | §4 |
| `pending` | open promotions: name, agent, sandbox, purpose, ports, requested |
| `approve NAME` | precondition: an open promotions row for NAME (`approved`, `rejected`, `failed`, `completed` all null) whose sandbox is `pending_promotion`; sets `approved = now`. The server acts within `approval_poll_seconds`. |
| `reject NAME [--reason TEXT]` | same precondition, and refuses if `approved` is already set; §11. |
| `services` | name, agent, status, ip, ports, created, purpose; `container_status` and `seen` from `containers_seen`; `revoked` when the owner is; `pending_delete` when the row is `deleted` and the name is still in `containers_seen` |
| `sandboxes` | id, agent, status, ip, last_active, ttl_expires, signal, `pending_delete` as above |
| `orphans` | names in `containers_seen` with no sandbox or service row at all (printed as name, `-`, container status), plus rows whose owning agent is revoked (name, owner, row status); prints `seen` so a stale list is obvious |
| `destroy NAME` | precondition: a live row for NAME not in `promoting` or `creating` (else "in progress, retry"), or a name in `containers_seen` with no row at all (an orphan: inserts a sandbox row with `sandbox_id = NAME`, `agent = image = null`, `created = last_active = deleted_at = now`, `status = deleted`). A row already `deleted` with the name still in `containers_seen` prints "already marked for deletion"; anything else prints "no such container or row". Marks the row `deleted`, bypassing ownership; a `pending_promotion` sandbox also gets its promotions row `rejected = now`, reason `destroyed`, audited `promotion_rejected` as `operator`, in the same transaction; audits `service_destroyed` with `by: operator`, `sandbox_destroyed`, or `orphan_destroyed`. The reaper removes the container on its next pass. |
| `audit [--since T] [--agent A]` | §13 |
| `bake [KEY...]` | §15 |

**systemd unit.**

```ini
[Unit]
Description=lxc-broker MCP server
After=network-online.target snap.lxd.daemon.service
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=simple
User=lxc-broker
Group=lxc-broker
UMask=0007
ExecStart=/opt/lxc-broker/.venv/bin/lxc-broker serve
Restart=on-failure
RestartSec=5
StateDirectory=lxc-broker
StateDirectoryMode=2770
ReadWritePaths=/var/lib/lxc-broker
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
NoNewPrivileges=true
ProtectKernelTunables=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6

[Install]
WantedBy=multi-user.target
```

`state_dir` MUST equal `/var/lib/lxc-broker` unless both `StateDirectory`
and `ReadWritePaths` are edited. The `lxc-broker` user is **not** in the
`lxd` group: it uses its restricted certificate over HTTPS, and the `lxd`
group is root-equivalent. Adjust `After=` for a non-snap install.

## 17. Testing

`pytest` from `broker/`; the default run uses `FakeAdapter` and an
in-memory SQLite database and MUST pass with no LXD present. Because the
adapter holds no policy, the fake exercises everything security-relevant.
Required coverage, each as separate tests:

- **Names and arguments.** Every §5 rule, pass and fail, including the
  lookup rule on every tool and CLI command; the slug table (`"My Web
  Test!"` → `my-web-test`, 30-char hint → 20 then stripped, empty →
  `sandbox`); hex collision retry and exhaustion; every `invalid_argument`
  rule (`purpose` with a control or bidi char; `hours` NaN, inf, 0, clamped).
- **Tokens.** `create` rejects an existing name revoked or not, and a name
  equal to or a `-`-prefix of a live service; revoked token → 401 with the
  same body as unknown.
- **Ownership, quotas, transitions.** Another agent's sandbox →
  `not_found` on every tool; another agent's service → `not_owner` on
  destroy; quotas count exactly the states §3 says; every edge in §6 and
  every `invalid_state` case; destroy-then-re-promote under the same name
  inserts a second service row while the first awaits pruning.
- **Creation.** Failure injected at each of steps 3–7, including the
  step-7 guard; a container present before launch is never deleted.
- **Promotion.** `auto`; `approve` with the poller; reject, and reject
  refused after approve; name taken between request and approval (row
  check and `IntegrityError`); failure injected at each of Execute steps
  1–5 including the step-5 guard, asserting the copy gone, the sandbox
  `running` on `sandbox_bridge`, the promotions row `failed`, the service
  row `deleted` never removed; a failed `delete(name)` or `list_instances`
  in rollback still reaches the transaction and the reaper cleans up;
  `crash_after` `copy` and `start` then reconciliation asserting 2b or 2c;
  rollback twice is a no-op; step 6 failure cleaned by the reaper;
  `destroy` on `promoting`/`creating` refused by tool and CLI; the poller
  aborts if the row was rejected or the sandbox destroyed after approval;
  Execute and Rollback take no locks (asserted on a lock log).
- **Reconciliation.** Each row of the §11 table, 2a–2d separately;
  first match wins; `transitional` and `error` containers untouched; an
  `active` service with a stopped container stays `active`.
- **Reaper.** With a fake clock: every candidate in the §12 table; a
  `running` sandbox whose container vanishes reaches `deleted` on the next
  pass; `unavailable` never stops or deletes and is written to `signal`;
  tcp-table parsing in both formats with loopback, v4-mapped loopback, and
  self-ip remotes excluded and a null `ip` handled; `transitional`/`error`
  containers leave rows untouched; pruning only once the container is gone
  and only while unlocked; `containers_seen` replaced each pass; the
  `pool_driver` warning fires for `dir`.
- **Concurrency.** A `keep_alive` or `start_sandbox` between snapshot and
  act makes the reaper skip; `destroy` racing a reaper stop ends `deleted`;
  two `promote` calls for one name yield one open promotions row;
  two-container operations lock in sorted order (asserted on a lock log).
- **CLI guards, start, errors.** Each §16 precondition, pass and refused;
  destroy of an unknown name inserts nothing; CLI destroy of a
  `pending_promotion` sandbox closes its promotions row and frees the name;
  `start_sandbox` failing at
  step 2 or 3 leaves the row `running` and survives the next reaper pass;
  an unexpected adapter exception reaches the agent as `backend_error`
  with no exception text.

**Integration** (`@pytest.mark.lxd`, skipped unless
`LXC_BROKER_TEST_LXD=1`, against project `LXC_BROKER_TEST_PROJECT`, default
`agents-test`, with a baked `broker/debian` image): every adapter method;
`copy` yielding the new hostname in both files and an instance-local `eth0`
with a LAN lease; `read_tcp_table` parseable with an SSH session open;
`instance.config` and `devices` after `launch` and `copy` containing nothing
beyond §8 apart from `volatile.*`. A fixture deletes leftover `itest-*`.

**Hygiene.** `ruff`; `mypy --strict` on `lxc_broker/`; `shellcheck` on
`images/*.sh`; CI runs unit tests, lint, type check, and shellcheck on every
push, integration on demand.

## 18. Out of scope for v1

Exec or file-transfer tools; demotion; per-agent bridges or network ACLs;
an Incus backend (the adapter seam exists for it); OAuth; snapshots, agent
images, or device attachment; automatic image rebuilds; token rotation;
audit pruning; IPv6 on `sandbox_bridge`; defending the reaper against an
agent that keeps a sandbox alive from a sibling (quotas bound it).
