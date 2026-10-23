# Swarm Map LXD Example

Provisions an unprivileged LXD container running [Swarm Map](https://github.com/cyborg-garden/swarm-map) -- a Next.js admin dashboard for AI agents -- with Docker Engine nested inside it.

Swarm Map runs each Hermes agent as a Docker container (it shells out to the `docker` CLI: compose, exec, stats, volume rm, and so on), so the container it lives in needs a working local Docker engine. That is why this is nested Docker in LXD, and why the container gets `security.nesting=true` (lets Docker create its own namespaces and cgroups inside the container), plus `security.syscalls.intercept.mknod` and `security.syscalls.intercept.setxattr` (LXD's documented recommendations for running Docker in LXD). The container stays unprivileged; setup refuses to continue if it finds `security.privileged=true`, including via a profile.

## Status

This README was written before the first provisioning run. Nothing here has been exercised against a real container yet: not `setup.sh`, not `verify.sh`, not the Discord or llama-server steps. Everything below describes what the scripts do according to the code, not what has been observed to work. Expect to fix things. Statements that come from inference rather than from the scripts are marked as such.

## First run

Failures on this first run are expected. Report or fix the cause in the scripts rather than working around it by hand; a hand-patched container is not what the next person will get.

1. `./setup.sh --dry-run` and read the output.
2. `./setup.sh`. It takes a while (apt, Docker, Node, a full `pnpm build`).
3. Note the MAC and IP it prints; reserve the address in DHCP.
4. `./verify.sh`
5. `./verify.sh --idempotency`
6. Optionally `./verify.sh --reboot`.

Known first-run risks:

- Free space. The host `/` was about 94% used with roughly 27 GiB free when this was written, and setup alone needs roughly 4-6 GiB before any Hermes images. Free some space, or set `STORAGE_POOL` to another pool, before running.
- runc/AppArmor. Docker in an LXD container can hit an incompatibility between runc and AppArmor. The symptom would be exit 30 at the `hello-world` run, with `open sysctl` or `reopen fd` errors in the journal. This has not been seen here, only anticipated.
- Nested overlay2 on a `dir` pool is untested on this host. If it does not work, setup fails closed rather than falling back.

If setup exits 30, the overlay2 gate failed. Read the driver line and journal excerpt it printed, and pick one of the manual options in "The overlay2 gate" below. The script will not choose for you.

## Quickstart

On the LXD host, as a user in the `lxd` group:

    ./setup.sh --dry-run    # print what would happen; changes nothing
    ./setup.sh
    ./verify.sh

`setup.sh` ends by printing the container's MAC, IP, UI URL, and the command to read the operator token. Open `http://<container-ip>:3000/login` and paste the token.

## Prerequisites

- LXD on the host with the usual bridged LAN profile, set up per [host-setup.md](../../docs/host-setup.md), and your user in the `lxd` group (both scripts check that `lxc list` works).
- `curl` on the host (`verify.sh` uses it to probe the UI).
- Internet access from the container: Debian and Docker apt repos, nodejs.org, GitHub, the npm registry, ghcr.io, Docker Hub.
- Free disk space. This is advisory only. The container's root lives on the LXD storage pool named by `STORAGE_POOL` (default `default`). On this host that is a `dir` pool on the host's `/`, which means there is no quota and no cap: Docker images, layers and volumes inside the container consume host disk directly, and nothing stops them filling it. `setup.sh` and `verify.sh` only WARN when the filesystem backing the pool has less than `MIN_HOST_FREE_GIB` free. Plan on 10-20 GiB for the Hermes image and a few agents.
- Optional: if you have a spare disk, create a separate LXD storage pool on it and set `STORAGE_POOL` to its name before the first run. That is the only way the scripts offer to keep Docker data off `/`, and it is not tested.
- A llama-server somewhere reachable from the container, if you want local models (see below).

## Files

| File | Purpose |
|---|---|
| `setup.sh` | Host-side. Validates the conf, creates and configures the container, pushes files, runs `container-setup.sh` inside it, prints MAC/IP/URL. |
| `container-setup.sh` | Runs inside the container as root, fed on stdin by `setup.sh`. Installs packages, Docker, Node, pnpm, the `swarm` user, builds Swarm Map, installs the service. Idempotent. |
| `verify.sh` | Host-side checks against the running container. |
| `swarm-map.conf` | All tunables. Sourced by bash, so literals only. |
| `swarm-map.service` | systemd unit pushed to the container. |
| `swarm-map.env` | Template for `/etc/swarm-map/swarm-map.env`. |

## setup.sh

    Usage: setup.sh [--dry-run] [--update]
      --dry-run  print what would run; change nothing (safe without the container)
      --update   check out SWARM_MAP_REF from swarm-map.conf and rebuild

`--dry-run` still runs read-only `lxc` queries (`lxc list`, `lxc info`, `lxc storage show`, `lxc storage get`, `lxc config get`, `lxc config show --expanded`, `lxc config device show`), prints every mutating command prefixed with `DRY-RUN:`, and lists the steps `container-setup.sh` would announce. Flags come from the command line only; the conf cannot set them. `SWARM_MAP_CONF=/path/to/file` points the script at a different conf. If your LXD is the snap, its `lxc` has a private `/tmp`, so for a real run (which pushes the conf with `lxc file push`) the conf must not live under `/tmp`; the default path next to the script is fine. A log of the run is written to a `mktemp` file under `/tmp` (falling back to `$HOME`, then to the terminal only).

What a real run does, in order:

1. Validates the conf (see below), checks `lxc` works and the storage pool exists, and WARNs if the pool's filesystem is short on space.
2. `lxc init` the container with the nesting and syscall-interception keys, `boot.autostart=true`, and CPU/memory limits. If it already exists, it sets any of those keys that differ and restarts the container if a `security.*` key changed. Records the base image fingerprint in `user.swarm-map.image-fingerprint`.
3. Starts it, waits (up to 180 seconds) for `systemctl is-system-running --wait`, then up to 120 seconds for an IPv4 address on `eth0` and working DNS.
4. Pushes the conf, unit file and env template, then pipes `container-setup.sh` into the container.
5. Prints the MAC, IP and UI URL.

The guest side (`container-setup.sh`) then:

- installs base packages (including `apparmor` unless `REQUIRE_APPARMOR=0`);
- writes `/etc/docker/daemon.json` (overlay2, classic image store, json-file log rotation, MTU copied from `eth0`, `live-restore`);
- installs the pinned `docker-ce` from Docker's apt repo after checking the signing key's fingerprint against `DOCKER_APT_KEY_FPR`, and holds `docker-ce`, `docker-ce-cli` and `containerd.io`;
- starts Docker and runs the overlay2 gate (below);
- enables IPv4 forwarding via `/etc/sysctl.d/90-swarm-map.conf`;
- installs Node from the nodejs.org tarball, checked against a SHA256 hard-coded in the script (only the 24.21.0 hashes are there), and pnpm via npm;
- creates the `swarm` user (in the `docker` group), clones the repo to `/opt/swarm-map/app`, and checks out `SWARM_MAP_REF` detached;
- writes `/etc/swarm-map/swarm-map.env`, generating the operator token once;
- runs `pnpm install --frozen-lockfile` and `pnpm build` (heap capped at 3 GiB), skipped if a stamp of ref + lockfile hash + node and pnpm versions is unchanged;
- installs, enables and starts `swarm-map.service`, then waits for it to listen on `0.0.0.0:<APP_PORT>`.

Swarm Map's `pnpm seed` step is not run.

### It only touches the container it made

Before doing anything, `setup.sh` checks whether an instance called `NAME` exists. If it does and does not carry `user.swarm-map.managed=true`, it exits with an error and changes nothing. New containers get that key at `lxc init`. So pointing `NAME` at, say, your `claude-code` container is refused rather than quietly reconfigured. `NAME` must match `^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$`; empty or invalid values abort. The script only runs `lxc` commands against `NAME` (plus read-only queries).

Other pre-flight refusals: any of `SWARM_MAP_REPO`, `SWARM_MAP_REF`, `NODE_VERSION`, `PNPM_VERSION`, `DOCKER_VERSION`, `DOCKER_APT_KEY_FPR` empty or `__SET_ME__`; `SWARM_MAP_REF` not a full 40-hex commit id; `--update` with no existing container.

### Exit codes

| Code | From | Meaning |
|---|---|---|
| 0 | both | success |
| 1 | `setup.sh` | bad or missing conf/NAME/pins, `lxc` not found or unusable, `--update` with no existing container, pool missing, instance not managed, privileged instance, no IP/DNS after 120s |
| 2 | `setup.sh` | unknown option |
| 1 | `container-setup.sh` | `/root/swarm-map.conf` missing, Docker apt key fingerprint mismatch, Node SHA256 mismatch or unsupported arch/`NODE_VERSION`, checkout not at the pinned ref, pinned ref differs from the checkout without `--update`, `systemctl enable` failed, service not listening |
| 30 | `container-setup.sh` | Docker gate failed (see next section) |
| 31 | `container-setup.sh` | `apt` could not install the pinned `docker-ce` (not a storage-driver problem) |
| 32 | `container-setup.sh` | could not safely install the temporary `policy-rc.d` stub that keeps apt from starting Docker before the gate |
| 40 | `container-setup.sh` | `pnpm install` or `pnpm build` failed |

The table lists only the codes the scripts choose deliberately. Both scripts run under `set -e`, so any other failing command (`curl`, `git clone`/`fetch`, `npm`, `useradd`, ...) exits with its own code (22, 128, and so on). `setup.sh` passes the guest script's exit code through, so 30, 31, 32, 40 and those come out of `setup.sh` unchanged.

### The overlay2 gate

Docker's `overlay2` driver inside an unprivileged LXD container depends on the host kernel and LXD cooperating. After installing Docker, `container-setup.sh` requires: the daemon answers, `docker info` reports the `overlay2` driver, the containerd image store (`io.containerd.snapshotter`) is not in use, and `docker run hello-world` works. If any of that fails it exits 30, dumps the driver line and the last 40 lines of the Docker journal, and stops. It does not fall back to another storage driver and does not start `swarm-map.service`. The message lists the manual options: `fuse-overlayfs` (needs the package, a `/dev/fuse` device, and a `daemon.json` edit), `vfs` (works, slow, disk-hungry), or a different kernel/LXD setting.

## swarm-map.conf

| Variable | Default | Meaning |
|---|---|---|
| `NAME` | `swarm-map` | Container name. Validated; see above. |
| `IMAGE` | `images:debian/trixie` | Base image. Only used when creating. The Docker repo and apt key steps assume Debian. |
| `STORAGE_POOL` | `default` | LXD pool for the container root. Must already exist. Only used when creating. |
| `CPU` | `4` | `limits.cpu`. Applied on re-run too. |
| `MEMORY` | `8GiB` | `limits.memory`. Applied on re-run too. |
| `ROOT_SIZE` | empty | If set, `lxc config device override <name> root size=...`. On a `dir` pool it is enforced only if the backing filesystem has project quotas (ext4 here does not by default, so assume no cap); a hard cap on btrfs/zfs/lvm. Leave empty unless you mean it. |
| `MIN_HOST_FREE_GIB` | `25` | Free-space threshold for the WARN. Never aborts anything. |
| `SWARM_MAP_REPO` | `https://github.com/cyborg-garden/swarm-map.git` | Where to clone from. |
| `SWARM_MAP_REF` | pinned 40-hex commit | What gets built. See Updating. |
| `NODE_VERSION` | `24.21.0` | Changing it also requires updating the SHA256 values in `container-setup.sh`; the script refuses any other version otherwise. |
| `PNPM_VERSION` | `10.34.6` | Installed via `npm install -g`. |
| `DOCKER_VERSION` | `5:29.9.0-1~debian.13~trixie` | Exact `docker-ce` / `docker-ce-cli` package version. `containerd.io`, buildx and compose plugins are not version-pinned; they are whatever the repo serves at first install, and `containerd.io` is held afterwards. |
| `DOCKER_APT_KEY_FPR` | Docker's key fingerprint | The downloaded apt key must match or nothing is installed. |
| `APP_PORT` | `3000` | Port for the UI. Written into the env file as `PORT` and used for `next start --port`. |
| `LLAMA_URL` | `http://192.168.1.10:8080` | Used by `verify.sh` only. |
| `LLAMA_MODEL` | empty | Used by `verify.sh` only. Empty means the first id from `/v1/models`. |
| `ENABLE_LETTA` | `0` | Not read by any script in this directory. Letta is something you turn on from the Swarm Map UI; see Security. |
| `REQUIRE_APPARMOR` | `1` | If 1, installs `apparmor` and `verify.sh` requires `name=apparmor` in Docker's security options. |
| `VERIFY_CURL_IMAGE` | `curlimages/curl:8.5.0` | Throwaway image `verify.sh` pulls inside the container. |
| `VERIFY_HELLO_IMAGE` | `hello-world:latest` | Used by the overlay2 gate and by `verify.sh`. A floating tag; hello-world publishes no pinned one. |
| `LOGIN_PATH` | `/api/auth/login` | Endpoint `verify.sh` POSTs the operator token to. |

The conf is pushed into the container as `/root/swarm-map.conf` on each run.

## Where state lives

Everything below is inside the container, on the pool root, i.e. host `/` on a default setup.

- `/opt/swarm-map/app`: the git checkout and build. Disposable.
- `/etc/swarm-map/swarm-map.env`: root-owned, mode 0600. Holds `NODE_ENV`, `PORT`, `HOME`, `DATA_DIR`, `NEXT_TELEMETRY_DISABLED`, and `HSM_OPERATOR_TOKEN`. The token is generated once with `openssl rand -hex 32` and kept on re-runs. Setup never prints it.
- `DATA_DIR` = `/home/swarm/.hermes-swarm-map`: Swarm Map's own data, including generated compose files and `.key`.
- `/home/swarm/.hermes-<agent>/`: one directory per agent, hard-coded under the `swarm` user's `$HOME` by Swarm Map, not under `DATA_DIR`. Agent `.env` and config live here.
- Docker volumes: `hermes-state-<agent-name>` per agent (the generated compose file pins the volume's `name:` to exactly that, so the project prefix is not added), and `letta-pgdata` if Letta is enabled. The Letta compose file does not name that volume, so Compose prefixes it with the project name; run `docker volume ls` in the container to find the real name. Images and layers in `/var/lib/docker`.

To read the operator token without it passing through a script's output or your shell history's arguments, run this in your terminal and copy it from there:

    lxc exec swarm-map -- sed -n 's/^HSM_OPERATOR_TOKEN=//p' /etc/swarm-map/swarm-map.env

Don't paste it into chat windows, tickets, or agents. `verify.sh` logs in with it inside the container and only reports the HTTP status code.

## Updating

`SWARM_MAP_REF` is pinned to a commit on purpose. Re-running `setup.sh` against a checkout at a different commit stops with an error instead of pulling.

To move to a newer commit:

1. In a clone of the upstream repo, review the diff between your current ref and the new one, especially `package.json` and `pnpm-lock.yaml`. The build runs lockfile-pinned third-party code with network access and the `docker` group.
2. Put the new full 40-hex commit id in `swarm-map.conf`.
3. `./setup.sh --update`.

A real `--update` refuses to run unless the container already exists.

`--update` stops the service, fetches, checks out the new ref, rebuilds, and restarts. If the build fails (exit 40), the service stays stopped; the message says so. `pnpm build` overwrites `.next` in place, so the previous build may or may not still work. Fix the problem and re-run `--update`.

`git fetch origin` only brings in commits reachable from a ref the remote advertises, so a ref on an unfetched branch or an unreachable commit will fail the checkout.

To rotate the operator token, delete the `HSM_OPERATOR_TOKEN=` line (or the whole file) in `/etc/swarm-map/swarm-map.env` and re-run `setup.sh`: it generates a new token when none valid is found, and restarts the service because the env file changed. Existing sessions stop working.

Without `--update`, re-running `setup.sh` is safe and should change nothing (`verify.sh --idempotency` checks this).

## Network

The container gets a LAN address from the bridge profile, like the other examples. Reserve it in your DHCP server using the MAC `setup.sh` prints (also `lxc config get swarm-map volatile.eth0.hwaddr`). Agents, Caddy and your browser all assume the address stays put.

### Caddy

Not configured here; that part is left to you. Proxy to `<container-ip>:3000` and make sure `X-Forwarded-Proto: https` is passed through. Swarm Map sets its `hsm_session` cookie with the `Secure` flag only when the request is HTTPS or carries that header, so plain-HTTP login on the LAN works and login behind Caddy works as long as the header is set. Until you put Caddy in front, the token travels in clear text on the LAN.

## Using the local llama-server

llama-server runs on the LXD host (or anywhere on the LAN) and must listen on a non-loopback address, or the container cannot reach it:

    llama-server --host 0.0.0.0 --port 8080 --jinja ...

See [local-models.md](../../docs/local-models.md) for the host side. In Swarm Map's model cascade editor, pick provider `custom` and set the Base URL to `http://192.168.1.10:8080/v1` (use your host's actual address; `LLAMA_URL` in the conf only feeds `verify.sh`). Swarm Map writes it into the agent's `config.yaml` as an unquoted YAML scalar, so keep it plain: no `: ` or ` #` inside.

Two things to know:

- `host.docker.internal`, as seen by the agents, resolves to the docker0 address of the engine inside this container, not to the LXD host. It is how agents call back to Swarm Map. Anything an agent needs from "the host" must run inside this container, or be addressed by its LAN IP as above.
- Choosing `ollama` or `custom` in the deploy wizard writes `OLLAMA_BASE_URL=http://host.docker.internal:11434/v1` into the agent's `.env`. Whether Hermes prefers that variable or `model.base_url` from `config.yaml` is decided in the hermes-agent-mt repo, which has not been read for this example. Open question. `verify.sh --agent-smoke` is meant to answer it: it sends a chat to an agent and checks the llama-server log grew. Run it once with `OLLAMA_BASE_URL` at the wizard default and once with it pointing at the llama-server; whichever run produces log lines tells you which setting Hermes honours. Changing `OLLAMA_BASE_URL` means editing `/home/swarm/.hermes-<agent>/.env` in the container and restarting the agent. (The bundled-ollama variant of the wizard writes `OLLAMA_BASE_URL=http://ollama-<name>:11434/v1` instead.)

## Discord

Hermes agents talk to Discord over an outbound websocket from the agent container, so no inbound port or public URL is needed, only outbound HTTPS/WSS from the container (`verify.sh` checks this).

The Developer Portal steps are inferred from reading the Swarm Map source, not from upstream documentation (upstream's platform docs have no Discord section), and the intent requirements have not been tried:

1. In the Discord Developer Portal, create an application, add a Bot, and reset its token. That is `DISCORD_BOT_TOKEN`.
2. Enable the Message Content intent, and likely the Server Members intent.
3. Generate an OAuth2 invite URL with the `bot` scope and permissions to view channels, send messages (and in threads), read history, embed links, attach files, add reactions. Invite the bot to your server.
4. In Swarm Map: the agent's Surfaces tab, connect Discord, paste the token, and set the allowlists (users, channels, roles). Developer Mode in Discord lets you copy the IDs.

The token is stored in plaintext in the agent's `/home/swarm/.hermes-<agent>/.env`. Swarm Map's dashboard process also calls the Discord REST API with it to resolve usernames.

## verify.sh

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

Default run reports PASS / FAIL / WARN / SKIP / INFO per check and exits 1 if anything FAILed (2 for a bad option or unreadable conf). It only addresses the `NAME` container and creates one throwaway Docker network (`swarm-map-verify`) plus `--rm` containers inside it, cleaned up on exit. The pulled `curl` and `hello-world` images stay in the container. Default checks:

- instance running; `boot.autostart`, `security.nesting` and both syscall-intercept keys set; not privileged; an `eth0` IPv4 address;
- host free space against `MIN_HOST_FREE_GIB` and guest root over 85% (WARN only);
- Docker answers, `overlay2`, no containerd image store, seccomp and cgroupns (and apparmor if required) in the security options;
- `hello-world` runs; a hardened nested container (read-only, `--cap-drop ALL`, tmpfs) runs and its memory and CPU limits are actually enforced;
- `swarm-map.service` active, enabled and listening; user `swarm` can use Docker; `better-sqlite3` loads;
- from the LXD host: `/login` returns 200, `/api/health/docker` reports `available:true`, and `/api/harnesses` returns 401 unauthenticated; then, inside the container, the operator token logs in at `LOGIN_PATH` (only the status code leaves the container);
- nested containers on the default bridge and on a user-defined network reach `host.docker.internal:<APP_PORT>`;
- nested containers reach `discord.com/api/v10/gateway` and `gateway.discord.gg`;
- llama-server: WARN if the port is closed (not running, or loopback-only), otherwise `/health`, `/v1/models` and a one-token chat completion;
- WARN if `br_netfilter` is loaded on the host with a DROP forward policy.

Opt-in modes change the container. `--idempotency` needs no sudo; it runs `setup.sh` as you (so you still need `lxd` group access). It fingerprints the instance config, Docker info, unit files, build stamp, token hash, package versions and service start time, re-runs `setup.sh`, and compares. `--reboot` restarts the container and waits for Docker, the service and the UI to return. `--deep` compares docker0 and user-defined network MTUs against `eth0`. `--agent-smoke` needs an agent you have already created in the UI. It is configured by environment variables, not flags:

    LLAMA_LOG=/path/to/llama-server.log AGENT_PORT=8642 ./verify.sh --agent-smoke

`AGENT_PORT` defaults to 8642. `AGENT_API_KEY` is optional; if set it is sent as a Bearer token (passed to curl on stdin, not on the command line). `LLAMA_LOG` is optional: it is a path on the LXD host, and the check passes if the file grew by at least one line during the chat. llama-server logs to stdout by default, so start it with `--log-file` or redirect its output to a file, or that check is skipped. The request goes to `http://127.0.0.1:<AGENT_PORT>/v1/chat/completions` from inside the container, and passes if the response has `choices[0]`.

## Security and limitations

Plainly:

- **Published ports are LAN-exposed, by decision.** Agent API ports (8642 and up, ten apart), the Google OAuth port if used, and Letta's 8283 if you enable it are published on all interfaces of the container. They may also be reachable over the container's global IPv6 address, since Docker's proxy listens on `[::]` (inferred, untested). There is no firewall in this setup, in the container or on the host. The LAN is assumed trusted. If yours isn't, this isn't the right example.
- **One shared secret.** The UI is gated by a single operator token; there are no per-user accounts.
- **UI access is root-in-the-container.** The `swarm` user is in the `docker` group, and Swarm Map deploys containers with user-supplied configuration. Anyone logged into the UI can effectively do anything inside this container. LXD's unprivileged mapping is what stands between that and the host.
- **Plain HTTP** until you set up Caddy. The token and session cookie cross the LAN unencrypted.
- **No disk cap.** Docker data lives on host `/`; an image pull or a runaway agent can fill it. The free-space check only warns.
- **Nested overlay2 can fail**, and setup then stops (exit 30) rather than working around it. See above.
- **Supply chain.** The build runs pinned-lockfile npm packages, and the Hermes image is pulled from ghcr.io as `:latest`, which is not pinned.
- **Secrets in plaintext.** Provider keys stored in Swarm Map's registry are encrypted at rest (AES-256-GCM, key in `DATA_DIR/.key`), but when a key is assigned to an agent, Swarm Map writes it into that agent's `.env` in plaintext (`upsertEnvVar`). Keys entered in the deploy wizard and Discord tokens land there too.
- **Letta**, if you enable it from the UI, is an upstream image that its own compose file flags as not actively maintained.

### Backups

None are provided. If you want any, these are the pieces:

- `DATA_DIR/.key` (`/home/swarm/.hermes-swarm-map/.key`): the AES master key. If it goes missing, Swarm Map silently generates a new one and every stored provider key becomes unreadable. Back this up first.
- `/home/swarm/.hermes-<agent>/`: agent config, `.env` with plaintext tokens, data. Treat backups as secrets.
- Docker volumes `hermes-state-<agent-name>` and the Letta volume (see `docker volume ls`).
- `/etc/swarm-map/swarm-map.env`. If it is lost, `swarm-map.service` fails to start (it is the unit's `EnvironmentFile`) until you re-run `setup.sh`, which writes a new file with a new operator token.

`lxc snapshot` on a `dir` pool is a full copy of the container, so it works but costs the whole footprint in host disk.

## Not covered

VPN and Signal agent variants (they need `NET_ADMIN`, `/dev/net/tun`, or a docker.sock proxy, and the nesting settings here don't grant that), TLS, backups, and anything about the Hermes images themselves.
