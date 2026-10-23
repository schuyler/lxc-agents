# corvidae LXC Agent Example

This example runs [corvidae](https://github.com/schuyler/corvidae) -- a Python LLM
agent daemon -- in its own Debian LXC container, with the workspace mounted from
the host and, optionally, a unix socket proxied in from a host-side
[signal-cli](https://github.com/AsamK/signal-cli) daemon.

Unlike the [nanobot](../nanobot/) example, the container gets no LXD credentials
and no sudo by default. The agent can't create sibling containers; see
[Security notes](#security-notes) if you want that.

## Synopsis

Everything is configured through environment variables:

    WORKSPACE_HOST_PATH=/home/me/agent-workspace \
    CONTAINER=myagent AGENT_USER=myagent SERVICE=myagent \
    PLUGIN_DIRS="plugins/*" \
    sudo -E ./setup.sh

The workspace must already contain a corvidae checkout (at `corvidae/` by
default). `setup.sh` installs it, and anything matching `PLUGIN_DIRS`, editable.
Afterwards, put an `agent.yaml` in the workspace and start the service:

    lxc exec myagent -- systemctl start myagent
    lxc exec myagent -- journalctl -u myagent -f

## Prerequisites

- LXD on a bridged LAN, per [host-setup.md](../../docs/host-setup.md).
- Host uid/gid 1000 delegated to LXD, for `raw.idmap`. Add `root:1000:1` to both
  `/etc/subuid` and `/etc/subgid`, then restart LXD (`sudo snap restart lxd`).
- A workspace directory on the host, containing a corvidae checkout.
- The agent's uid is fixed at 1000 (the unit template refers to
  `/run/user/1000`). Your workspace files should belong to host uid 1000.

## What it does

1. Refuses to continue if the container already exists. It never deletes anything.
2. Launches `images:debian/trixie` with `raw.idmap=both 1000 1000`,
   `boot.autostart=true`, and any limits you set.
3. Mounts the workspace.
4. Runs `container-setup.sh` in the container: creates the user, installs
   packages and [uv](https://docs.astral.sh/uv/), builds `~/venv` on Python 3.14,
   installs corvidae and your plugins editable, sets the timezone, and enables
   lingering for the agent user.
5. If `SIGNAL_SOCKET_HOST` is set, adds a proxy device for it.
6. Installs the systemd unit (and your drop-in, if any).
7. Runs `POST_SETUP_HOOK`, if any.
8. Runs `daemon-reload` and `enable`. It doesn't start the service.

If anything fails after the container is launched, the script exits (`set -e`)
and leaves a half-provisioned container, which step 1 then refuses to touch.
To recover, read `/tmp/$CONTAINER-setup.log` on the host to see what failed,
fix it, delete the container, and rerun:

    lxc delete --force myagent
    sudo -E ./setup.sh

## Variables

Only `WORKSPACE_HOST_PATH` is required.

| Variable | Default | Purpose |
|---|---|---|
| `CONTAINER` | `corvidae` | LXD container name. |
| `AGENT_USER` | `corvidae` | User inside the container (uid/gid 1000). |
| `SERVICE` | `corvidae` | systemd unit name. Installed as `/etc/systemd/system/$SERVICE.service`. |
| `WORKSPACE_HOST_PATH` | (required) | Host directory to mount. |
| `WORKSPACE_GUEST_PATH` | `/home/$AGENT_USER/workspace` | Absolute; letters, digits and `_ . / -` only. Where it appears in the container. The unit runs from here and reads `agent.yaml` from here. |
| `CORVIDAE_SRC` | `corvidae` | Path to the corvidae checkout, relative to the workspace. |
| `PLUGIN_DIRS` | (none) | Space-separated globs relative to the workspace, e.g. `plugins/*`. Each match with a `pyproject.toml` is installed editable. |
| `UNIT_DROPIN` | (none) | Host path to a systemd drop-in, installed as `$SERVICE.service.d/<basename>`. A relative path is relative to your cwd. |
| `POST_SETUP_HOOK` | (none) | Shell command run in the container as `$AGENT_USER`, in the workspace, after install and before `enable`. If it fails, the container is left provisioned but the service isn't enabled. |
| `SIGNAL_SOCKET_HOST` | (none) | Host path of a signal-cli JSON-RPC unix socket. If set, it's proxied into the container. |
| `SIGNAL_SOCKET_GUEST` | `/var/lib/signal-proxy/signal.sock` | Where the socket appears in the container. |
| `SIGNAL_SOCKET_HOST_UID` | `1000` | Host uid (and gid) that owns the host socket. LXD's host-side dialer drops to it. |
| `TZ` | `UTC` | Container timezone, a name under `/usr/share/zoneinfo` (checked on the host before anything is created). Inherited from your environment if set there, so set it explicitly. |
| `LIMITS_CPU`, `LIMITS_MEMORY` | (unlimited) | `limits.cpu` and `limits.memory`, e.g. `4` and `8GiB`. |
| `ROOT_SIZE` | (profile default) | Root disk size, e.g. `40GiB`. |
| `SUDO` | `0` | `1` installs sudo with passwordless access for `$AGENT_USER`. |

`corvidae.service` is a template. `setup.sh` fills in `@AGENT_USER@`,
`@WORKSPACE@` and `@SERVICE@`.

## Files

| File | Purpose |
|---|---|
| `setup.sh` | Host-side orchestrator. |
| `container-setup.sh` | Runs inside the container as root. Receives the variables above via `lxc exec --env`. |
| `corvidae.service` | Unit template. |
| `envrc` | Installed as `~/.envrc`. Puts `~/venv` on `PATH`; sourced from `.bashrc`. |

## Notes

**Venv location.** The venv is `/home/$AGENT_USER/venv`, outside the workspace
mount. Editable installs record container paths, and a venv inside the mount
would collide with whatever `.venv` the host has. Rebuilding the container
rebuilds the venv, since `setup.sh` reinstalls everything.

**The unit runs as the agent user.** corvidae can SIGTERM itself, and so can its
shell children (`kill $PPID`), because they're direct children of the daemon.
`Restart=always` brings it back, and no sudo is involved. `NoNewPrivileges`
blocks sudo inside the service even with `SUDO=1`. The unit also sets
`XDG_RUNTIME_DIR` and `DBUS_SESSION_BUS_ADDRESS` so the agent's shell children
can reach its user manager and use `systemd-run --user`.

**Unverified.** `PrivateTmp` inside an unprivileged LXD container, and
`systemd-run --user` from a system service in one, haven't been confirmed. If
the unit fails with a namespace error, delete `PrivateTmp` from the template. A
drop-in with `PrivateTmp=no` also works.

**No `cli:` channels in `agent.yaml`.** The unit's stdin is `/dev/null`, and
corvidae's CLI plugin sends the process SIGINT on stdin EOF, so the service
would shut itself down at every start. Also don't run `corvidae cli` against the
live workspace: it starts a second daemon on the same database and Signal socket.

**Unit overrides.** To replace `ExecStart` (say, with a wrapper that records why
the process exited), use a drop-in. It must first clear the inherited value:

    [Service]
    ExecStart=
    ExecStart=/home/myagent/venv/bin/python /home/myagent/workspace/bin/wrapper

Check the result with `lxc exec myagent -- systemctl cat myagent`.

## Signal

With `SIGNAL_SOCKET_HOST` set, `setup.sh` runs the equivalent of:

    lxc config device add myagent signal proxy \
      connect=unix:$SIGNAL_SOCKET_HOST \
      listen=unix:$SIGNAL_SOCKET_GUEST \
      bind=container uid=1000 gid=1000 mode=0660 \
      security.uid=$SIGNAL_SOCKET_HOST_UID security.gid=$SIGNAL_SOCKET_HOST_UID

`bind=container` means LXD listens inside the container and dials the host
socket once per connection, so a signal-cli restart that recreates the host
socket doesn't break the proxy. Existing connections get EOF, though, and the
client has to reconnect. While signal-cli is down, connecting to the container
socket probably succeeds and is then closed at once, which makes for noisy but
harmless reconnect logs. None of this has been verified against a specific LXD
release; test it before relying on it.

The default listen path is deliberately outside `/run`, which is a tmpfs inside
the container: a socket created there could be hidden by the mount or vanish on
reboot. `container-setup.sh` creates the parent directory because it's unknown
whether LXD will.

Only the JSON-RPC socket crosses over. The container never sees signal-cli's key
store, which is the part you don't want to leak. Run signal-cli with
`--receive-mode=on-connection` and don't expose it over TCP.

## Security notes

This example does not set up LXD TLS trust, so the agent has no way to manage
the host's containers. If you want that, see
[broker-design.md](../../docs/broker-design.md) for a design that keeps
credentials out of the agent, or issue it a
restricted certificate yourself (the broker design explains what that does and
doesn't buy you).

The workspace is writable from inside the container, and an agent that can edit
its own workspace can edit its own plugins and prompts. Keep it in git, and
review what it changes.
