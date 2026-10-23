# Swarm Map LXC Example

This example runs [Swarm Map](https://github.com/cyborg-garden/swarm-map) -- a Next.js admin dashboard for AI agents -- in an unprivileged LXD container with Docker Engine nested inside it.

Swarm Map runs each Hermes agent as a Docker container by shelling out to the `docker` CLI (compose, exec, stats, volume rm, and so on), so it needs a working local Docker engine. Hence nested Docker, and hence `security.nesting=true` (lets Docker create its own namespaces and cgroups) plus `security.syscalls.intercept.mknod` and `security.syscalls.intercept.setxattr`, which are LXD's documented recommendations for running Docker. The container stays unprivileged: setup refuses to continue if it finds `security.privileged=true`, including via a profile.

WARNING: None of this has been run against a real container yet: not `setup.sh`, not `verify.sh`, not the Discord or llama-server steps. This README describes what the scripts do according to the code, and marks the statements that are inference rather than script behaviour. Expect to fix things, and fix them in the scripts rather than by hand; a hand-patched container is not what the next person will get.

## Usage

On the LXD host, as a user in the `lxd` group:

    ./setup.sh --dry-run        # print what would happen; changes nothing
    ./setup.sh                  # slow: apt, Docker, Node, a full pnpm build
    ./verify.sh
    ./verify.sh --idempotency
    ./verify.sh --reboot        # optional

`setup.sh` ends by printing the container's MAC, IP, UI URL, and the command to read the operator token. Reserve the address in DHCP (see [Network](#network)), then open `http://<container-ip>:3000/login` and paste the token.

If setup exits 30, the overlay2 gate failed. Read the driver line and journal excerpt it printed and pick one of the manual options in [The overlay2 gate](#the-overlay2-gate). The script won't choose for you.

Known first-run risks:

- Disk space. Setup alone needs roughly 4-6 GiB before any Hermes images, and on a `dir` pool nothing caps what Docker uses afterwards (see Prerequisites). Free some space, or set `STORAGE_POOL` to another pool, before running.
- runc/AppArmor. Docker in an LXD container can hit an incompatibility between runc and AppArmor. The symptom would be exit 30 at the `hello-world` run, with `open sysctl` or `reopen fd` errors in the journal. Anticipated, not seen.
- Nested overlay2 on a `dir` pool is untested. If it doesn't work, setup fails closed rather than falling back.

## Prerequisites

- LXD with the usual bridged LAN profile, per [host-setup.md](../../docs/host-setup.md), and your user in the `lxd` group (both scripts check that `lxc list` works).
- `curl` on the host (`verify.sh` uses it to probe the UI).
- Internet access from the container: Debian and Docker apt repos, nodejs.org, GitHub, the npm registry, ghcr.io, Docker Hub.
- Disk space. The container's root lives on the LXD storage pool named by `STORAGE_POOL` (default `default`). If that's a `dir` pool on the host's `/`, there is no quota: Docker images, layers and volumes inside the container consume host disk directly, and nothing stops them filling it. `setup.sh` and `verify.sh` only WARN when the pool's filesystem has less than `MIN_HOST_FREE_GIB` free. Plan on 10-20 GiB for the Hermes image and a few agents. If you have a spare disk, a separate LXD pool on it, named in `STORAGE_POOL` before the first run, is the only way the scripts offer to keep Docker data off `/`. Also untested.
- A llama-server reachable from the container, if you want local models (see [below](#using-a-local-llama-server)).

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

`--dry-run` still runs read-only `lxc` queries (`lxc list`, `lxc info`, `lxc storage show`, `lxc storage get`, `lxc config get`, `lxc config show --expanded`, `lxc config device show`). It prints every mutating command prefixed with `DRY-RUN:` and lists the steps `container-setup.sh` would announce. Flags come from the command line only; the conf can't set them.

`SWARM_MAP_CONF=/path/to/file` points the script at a different conf. If your LXD is the snap, its `lxc` has a private `/tmp`, so for a real run (which pushes the conf with `lxc file push`) the conf must not live under `/tmp`. The default path next to the script is fine. Each run's log goes to a `mktemp` file under `/tmp`, falling back to `$HOME`, then to the terminal only.

A real run:

1. Validates the conf (see below), checks that `lxc` works and the storage pool exists, and WARNs if the pool's filesystem is short on space.
2. `lxc init`s the container with the nesting and syscall-interception keys, `boot.autostart=true`, and CPU/memory limits. If it already exists, it sets whichever of those keys differ, and restarts the container if a `security.*` key changed. Records the base image fingerprint in `user.swarm-map.image-fingerprint`.
3. Starts it and waits up to 180 seconds for `systemctl is-system-running --wait`, then up to 120 seconds for an IPv4 address on `eth0` and working DNS.
4. Pushes the conf, unit file and env template, then pipes `container-setup.sh` into the container.
5. Prints the MAC, IP and UI URL.

`container-setup.sh` then:

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

Before doing anything, `setup.sh` checks whether an instance called `NAME` exists. If it does and doesn't carry `user.swarm-map.managed=true`, it exits with an error and changes nothing. New containers get that key at `lxc init`. So pointing `NAME` at, say, your `claude-code` container is refused rather than quietly reconfigured. `NAME` must match `^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$`; empty or invalid values abort. The script runs no mutating `lxc` commands against anything but `NAME`.

It also refuses to start if any of `SWARM_MAP_REPO`, `SWARM_MAP_REF`, `NODE_VERSION`, `PNPM_VERSION`, `DOCKER_VERSION`, `DOCKER_APT_KEY_FPR` is empty or `__SET_ME__`, if `SWARM_MAP_REF` isn't a full 40-hex commit id, or if a real (not `--dry-run`) `--update` is given with no existing container.

### Exit codes

| Code | From | Meaning |
|---|---|---|
| 0 | both | success |
| 1 | `setup.sh` | bad or missing conf/NAME/pins, `lxc` not found or unusable, a real `--update` with no existing container, pool missing, instance not managed, privileged instance, no IP/DNS after 120s |
| 2 | `setup.sh` | unknown option |
| 1 | `container-setup.sh` | `/root/swarm-map.conf` missing, Docker apt key fingerprint mismatch, Node SHA256 mismatch or unsupported arch/`NODE_VERSION`, checkout not at the pinned ref, pinned ref differs from the checkout without `--update`, `systemctl enable` failed, service not listening |
| 30 | `container-setup.sh` | Docker gate failed (see next section) |
| 31 | `container-setup.sh` | `apt` could not install the pinned `docker-ce` (not a storage-driver problem) |
| 32 | `container-setup.sh` | could not safely install the temporary `policy-rc.d` stub that keeps apt from starting Docker before the gate |
| 40 | `container-setup.sh` | `pnpm install` or `pnpm build` failed |

These are only the codes the scripts choose deliberately. Both run under `set -e`, so any other failing command (`curl`, `git clone`/`fetch`, `npm`, `useradd`, ...) exits with its own code (22, 128, and so on). `setup.sh` passes the guest script's exit code through unchanged.

### The overlay2 gate

Docker's `overlay2` driver inside an unprivileged LXD container depends on the host kernel and LXD cooperating. After installing Docker, `container-setup.sh` requires that `docker.service` starts and the daemon answers, `docker info` reports the `overlay2` driver, the containerd image store (`io.containerd.snapshotter`) is not in use, and `docker run hello-world` works. If any of that fails it exits 30, dumps the driver line, Docker's security options and the last 40 lines of the Docker journal (plus a runc/AppArmor hint if the `docker run` errors match), and stops. It doesn't fall back to another storage driver and doesn't start `swarm-map.service`. The manual options it lists are `fuse-overlayfs` (needs the package, a `/dev/fuse` device, and a `daemon.json` edit), `vfs` (works, slow, disk-hungry), or a different kernel/LXD setting.

## swarm-map.conf

| Variable | Default | Meaning |
|---|---|---|
| `NAME` | `swarm-map` | Container name. Validated; see above. |
| `IMAGE` | `images:debian/trixie` | Base image. Only used when creating. The Docker repo and apt key steps assume Debian. |
| `STORAGE_POOL` | `default` | LXD pool for the container root. Must already exist. Only used when creating. |
| `CPU` | `4` | `limits.cpu`. Applied on re-run too. |
| `MEMORY` | `8GiB` | `limits.memory`. Applied on re-run too. |
| `ROOT_SIZE` | empty | If set, `lxc config device override <name> root size=...`. On a `dir` pool it's enforced only if the backing filesystem has project quotas (ext4 doesn't by default, so assume no cap); on btrfs/zfs/lvm it's a hard cap. Leave empty unless you mean it. |
| `MIN_HOST_FREE_GIB` | `25` | Free-space threshold for the WARN. Never aborts anything. |
| `SWARM_MAP_REPO` | `https://github.com/cyborg-garden/swarm-map.git` | Where to clone from. |
| `SWARM_MAP_REF` | pinned 40-hex commit | What gets built. See [Updating](#updating). |
| `NODE_VERSION` | `24.21.0` | Changing it also means updating the SHA256 values in `container-setup.sh`; the script refuses any other version otherwise. |
| `PNPM_VERSION` | `10.34.6` | Installed via `npm install -g`. |
| `DOCKER_VERSION` | `5:29.9.0-1~debian.13~trixie` | Exact `docker-ce` / `docker-ce-cli` package version. `containerd.io`, buildx and compose plugins are not version-pinned; they're whatever the repo serves at first install, and `containerd.io` is held afterwards. |
| `DOCKER_APT_KEY_FPR` | Docker's key fingerprint | The downloaded apt key must match or nothing is installed. |
| `APP_PORT` | `3000` | Port for the UI. Written into the env file as `PORT` and used for `next start --port`. |
| `LLAMA_URL` | `http://192.168.1.10:8080` | Used by `verify.sh` only. |
| `LLAMA_MODEL` | empty | Used by `verify.sh` only. Empty means the first id from `/v1/models`. |
| `ENABLE_LETTA` | `0` | Not read by any script in this directory. Letta is something you turn on from the Swarm Map UI; see [Security](#security-and-limitations). |
| `REQUIRE_APPARMOR` | `1` | If 1, installs `apparmor` and `verify.sh` requires `name=apparmor` in Docker's security options. |
| `VERIFY_CURL_IMAGE` | `curlimages/curl:8.5.0` | Throwaway image `verify.sh` pulls inside the container. |
| `VERIFY_HELLO_IMAGE` | `hello-world:latest` | Used by the overlay2 gate and by `verify.sh`. A floating tag; hello-world publishes no pinned one. |
| `LOGIN_PATH` | `/api/auth/login` | Endpoint `verify.sh` POSTs the operator token to. |

The conf is pushed into the container as `/root/swarm-map.conf` on each run.

## Where state lives

All inside the container, on its root volume in `STORAGE_POOL`:

- `/opt/swarm-map/app`: the git checkout and build. Disposable.
- `/etc/swarm-map/swarm-map.env`: root-owned, mode 0600. Holds `NODE_ENV`, `PORT`, `HOME`, `DATA_DIR`, `NEXT_TELEMETRY_DISABLED`, and `HSM_OPERATOR_TOKEN`. The token is generated once with `openssl rand -hex 32` and kept on re-runs. Setup never prints it.
- `DATA_DIR` = `/home/swarm/.hermes-swarm-map`: Swarm Map's own data, including generated compose files and `.key`.
- `/home/swarm/.hermes-<agent>/`: one directory per agent, hard-coded by Swarm Map under the `swarm` user's `$HOME`, not under `DATA_DIR`. Agent `.env` and config live here.
- Docker volumes: `hermes-state-<agent-name>` per agent (the generated compose file pins the volume's `name:`, so no project prefix is added), and `letta-pgdata` if Letta is enabled. The Letta compose file doesn't name that volume, so Compose prefixes it with the project name; `docker volume ls` in the container shows the real name. Images and layers are in `/var/lib/docker`.

To read the operator token without it passing through a script's output or your shell history, run this and copy it from your terminal:

    lxc exec swarm-map -- sed -n 's/^HSM_OPERATOR_TOKEN=//p' /etc/swarm-map/swarm-map.env

Don't paste it into chat windows, tickets, or agents. `verify.sh` logs in with it inside the container and only reports the HTTP status code.

## Updating

`SWARM_MAP_REF` is pinned to a commit on purpose. Re-running `setup.sh` against a checkout at a different commit stops with an error instead of pulling. To move to a newer commit:

1. In a clone of the upstream repo, review the diff between your current ref and the new one, especially `package.json` and `pnpm-lock.yaml`. The build runs lockfile-pinned third-party code with network access and the `docker` group.
2. Put the new full 40-hex commit id in `swarm-map.conf`.
3. `./setup.sh --update`.

`--update` stops the service, fetches, checks out the new ref, rebuilds, and restarts. If the build fails (exit 40), the service stays stopped and the message says so. `pnpm build` overwrites `.next` in place, so the previous build may or may not still work; you can try it with `lxc exec swarm-map -- systemctl start swarm-map`, or fix the problem and re-run `--update`.

`git fetch origin` only brings in commits reachable from a ref the remote advertises, so a commit on an unfetched branch, or an unreachable one, will fail the checkout.

To rotate the operator token, delete the `HSM_OPERATOR_TOKEN=` line (or the whole file) in `/etc/swarm-map/swarm-map.env` and re-run `setup.sh`. It generates a new token when it finds no valid one, and restarts the service because the env file changed. Existing sessions stop working.

Without `--update`, re-running `setup.sh` is safe and should change nothing (`verify.sh --idempotency` checks this).

## Network

The container gets a LAN address from the bridge profile, like the other examples. Reserve it in your DHCP server using the MAC `setup.sh` prints (also `lxc config get swarm-map volatile.eth0.hwaddr`). Agents, Caddy and your browser all assume the address stays put.

### Caddy

Not configured here. Proxy to `<container-ip>:3000` and pass `X-Forwarded-Proto: https` through. Swarm Map sets its `hsm_session` cookie with the `Secure` flag only when the request is HTTPS or carries that header, so plain-HTTP login on the LAN works, and so does login behind Caddy as long as the header is set. Until you put Caddy in front, the token travels in clear text on the LAN.

## Using a local llama-server

llama-server runs on the LXD host (or anywhere on the LAN) and must listen on a non-loopback address, or the container can't reach it:

    llama-server --host 0.0.0.0 --port 8080 --jinja ...

See [local-models.md](../../docs/local-models.md) for the host side. In Swarm Map's model cascade editor, pick provider `custom` and set the Base URL to `http://192.168.1.10:8080/v1`, using your host's actual address (`LLAMA_URL` in the conf only feeds `verify.sh`). Swarm Map writes it into the agent's `config.yaml` as an unquoted YAML scalar, so keep it plain: no `: ` or ` #` inside.

Two things to know:

- `host.docker.internal`, as seen by the agents, resolves to the docker0 address of the engine inside this container, not to the LXD host. It's how agents call back to Swarm Map. Anything an agent needs from "the host" must run inside this container, or be addressed by its LAN IP as above.
- Choosing `ollama` or `custom` in the deploy wizard writes `OLLAMA_BASE_URL=http://host.docker.internal:11434/v1` into the agent's `.env` (the bundled-ollama variant writes `http://ollama-<name>:11434/v1` instead). Whether Hermes prefers that or `model.base_url` from `config.yaml` is decided in the hermes-agent-mt repo, which hasn't been read for this example, so it's an open question. `verify.sh --agent-smoke` is meant to answer it: run it once with `OLLAMA_BASE_URL` at the wizard default and once pointing at the llama-server, and whichever run adds lines to the llama-server log tells you which setting Hermes honours. Changing `OLLAMA_BASE_URL` means editing `/home/swarm/.hermes-<agent>/.env` in the container and restarting the agent.

## Discord

Hermes agents talk to Discord over an outbound websocket from the agent container, so no inbound port or public URL is needed, only outbound HTTPS/WSS from the container (`verify.sh` checks this).

These Developer Portal steps are inferred from reading the Swarm Map source (upstream's platform docs have no Discord section), and the intent requirements haven't been tried:

1. In the Discord Developer Portal, create an application, add a Bot, and reset its token. That's `DISCORD_BOT_TOKEN`.
2. Enable the Message Content intent, and probably the Server Members intent.
3. Generate an OAuth2 invite URL with the `bot` scope and permissions to view channels, send messages (and in threads), read history, embed links, attach files, add reactions. Invite the bot to your server.
4. In Swarm Map, open the agent's Surfaces tab, connect Discord, paste the token, and set the allowlists (users, channels, roles). Developer Mode in Discord lets you copy the IDs.

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

It exits 1 if anything FAILed, 2 for a bad option or unreadable conf. It only addresses the `NAME` container, where it creates one throwaway Docker network (`swarm-map-verify`) plus `--rm` containers, cleaned up on exit. The pulled `curl` and `hello-world` images stay. Default checks:

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

`--idempotency` needs no sudo, just `lxd` group access. Besides what the usage text lists, it compares the service's start time before and after. `--reboot` waits for Docker, the service and the UI to return. `--agent-smoke` needs an agent you've already created in the UI, and is configured by environment variables, not flags:

    LLAMA_LOG=/path/to/llama-server.log AGENT_PORT=8642 ./verify.sh --agent-smoke

It sends a chat to `http://127.0.0.1:<AGENT_PORT>/v1/chat/completions` from inside the container and passes if the response has `choices[0]`. `AGENT_API_KEY`, if set, is sent as a Bearer token (passed to curl on stdin, not on the command line). `LLAMA_LOG` is a path on the LXD host; that check passes if the file grew by at least one line during the chat. llama-server logs to stdout by default, so start it with `--log-file` or redirect its output, or the check is skipped.

## Security and limitations

- **Published ports are LAN-exposed, by decision.** Agent API ports (8642 and up, ten apart), the Google OAuth port if used, and Letta's 8283 if you enable it are published on all interfaces of the container. They may also be reachable over the container's global IPv6 address, since Docker's proxy listens on `[::]` (inferred, untested). There is no firewall in this setup, in the container or on the host. The LAN is assumed trusted. If yours isn't, this isn't the right example.
- **One shared secret.** The UI is gated by a single operator token; there are no per-user accounts.
- **UI access is root-in-the-container.** The `swarm` user is in the `docker` group, and Swarm Map deploys containers with user-supplied configuration. Anyone logged into the UI can effectively do anything inside this container. LXD's unprivileged mapping is what stands between that and the host.
- **Plain HTTP** until you set up Caddy. The token and session cookie cross the LAN unencrypted.
- **No disk cap** on a `dir` pool. An image pull or a runaway agent can fill the host disk. The free-space check only warns.
- **Nested overlay2 can fail**, and setup then stops (exit 30) rather than working around it.
- **Supply chain.** The build runs pinned-lockfile npm packages, and the Hermes image is pulled from ghcr.io as `:latest`, which is not pinned.
- **Secrets in plaintext.** Provider keys stored in Swarm Map's registry are encrypted at rest (AES-256-GCM, key in `DATA_DIR/.key`), but when a key is assigned to an agent, Swarm Map writes it into that agent's `.env` in plaintext (`upsertEnvVar`). Keys entered in the deploy wizard and Discord tokens land there too.
- **Letta**, if you enable it from the UI, is an upstream image that its own compose file flags as not actively maintained.

### Backups

None are provided. If you want any, these are the pieces:

- `DATA_DIR/.key` (`/home/swarm/.hermes-swarm-map/.key`): the AES master key. If it goes missing, Swarm Map silently generates a new one and every stored provider key becomes unreadable. Back this up first.
- `/home/swarm/.hermes-<agent>/`: agent config, `.env` with plaintext tokens, data. Treat backups as secrets.
- Docker volumes `hermes-state-<agent-name>` and the Letta volume (see `docker volume ls`).
- `/etc/swarm-map/swarm-map.env`. If it's lost, `swarm-map.service` fails to start (it's the unit's `EnvironmentFile`) until you re-run `setup.sh`, which writes a new file with a new operator token.

`lxc snapshot` on a `dir` pool is a full copy of the container, so it works but costs the whole footprint in host disk.

## Not covered

VPN and Signal agent variants (they need `NET_ADMIN`, `/dev/net/tun`, or a docker.sock proxy, and the nesting settings here don't grant that), TLS, backups, and anything about the Hermes images themselves.
