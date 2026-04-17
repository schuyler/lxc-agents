# Nanobot Wiring Guide

This document covers how to wire nanobot into an LXC container so it can
manage sibling containers on the host.

## Workspace mount

The setup script mounts the host-side nanobot workspace into the container
using an LXC disk device. File ownership works because `setup.sh` configures
`raw.idmap` on the container:

    raw.idmap=both 1000 1000

This maps UID and GID 1000 identically between host and guest. The host-side
user (UID 1000) and the container's `nanobot` user (UID 1000) see the same
file ownership. Without this mapping, the mounted files would be owned by
nobody/root and nanobot could not write to its own workspace.

## config.json changes

After running `setup.sh`, edit the nanobot workspace's `config.json`
to match the container environment. The fields that need updating:

| Field | Value | Why |
|---|---|---|
| `agents.defaults.workspace` | `/home/nanobot/code/nanobot` | The guest-side mount path |
| `providers.custom.apiBase` | `http://<HOST_IP>:8080/v1` | LLM provider reachable from container |
| `tools.mcpServers` | `{}` | Clear any host-side MCP server configs |
| `tools.exec.pathAppend` | `/home/nanobot/code/.venv/bin` | Adds the venv to the agent's PATH |
| `tools.exec.allowedEnvKeys` | `["XDG_RUNTIME_DIR", "VIRTUAL_ENV"]` | Environment keys the agent may pass through |

Example Python snippet to apply these programmatically from the host:

```python
import json

WORKSPACE_HOST = "/home/YOUR_USER/code/llm/nanobot"  # your host workspace path
WORKSPACE_GUEST = "/home/nanobot/code/nanobot"
HOST_IP = "10.0.0.1"  # your bridge IP

with open(f"{WORKSPACE_HOST}/config.json") as f:
    c = json.load(f)

c["agents"]["defaults"]["workspace"] = WORKSPACE_GUEST
c["providers"]["custom"]["apiBase"] = f"http://{HOST_IP}:8080/v1"
c["tools"]["mcpServers"] = {}
c["tools"]["exec"]["allowedEnvKeys"] = ["XDG_RUNTIME_DIR", "VIRTUAL_ENV"]
c["tools"]["exec"]["pathAppend"] = "/home/nanobot/code/.venv/bin"

with open(f"{WORKSPACE_HOST}/config.json", "w") as f:
    json.dump(c, f, indent=2)
    f.write("\n")
```

## The config.json symlink issue

Nanobot reads `config.json` from the current working directory. The systemd
service sets `WorkingDirectory=/home/nanobot/code`, but the actual config
lives at `/home/nanobot/code/nanobot/config.json` (inside the mounted
workspace). You have two options:

1. Symlink: `ln -s nanobot/config.json /home/nanobot/code/config.json`
2. Change `WorkingDirectory` in the service file to
   `/home/nanobot/code/nanobot`.

Option 1 keeps the working directory as a parent of the workspace, which is
useful if the agent needs to write files alongside it.

Run this after setup.sh completes and before starting the service:

    lxc exec nanobot -- su - nanobot -c 'ln -sf nanobot/config.json ~/code/config.json'

## nanobot-channel-irc

If the nanobot workspace includes `nanobot-channel-irc` (an IRC adapter),
`container-setup.sh` installs it as an editable package. This is conditional --
if the directory does not exist inside the mounted workspace, the step is
skipped. To include it, clone it into the workspace before running setup:

    git clone <repo-url> /path/to/nanobot/nanobot-channel-irc

## LXC skill

The setup script copies `skills/lxc/` from this repository into the
nanobot workspace's `skills/` directory. Nanobot loads skill files at startup
and makes them available to the agent as instructions.

The skill teaches the agent the `lxc` CLI commands for creating, listing,
executing in, and destroying containers, using the `host:` remote prefix that
was registered during setup.

If you re-run setup, the skill directory is replaced. If you customize the
skill, keep your changes outside the `skills/lxc/` path or they will be
overwritten.

## nanobot agent vs nanobot gateway

Nanobot has two relevant commands:

- `nanobot agent` runs a single agent session interactively. Useful for
  debugging or one-off tasks.
- `nanobot gateway` starts the persistent gateway process that connects to
  configured channels (IRC, etc.) and dispatches incoming messages to agents.
  This is what the systemd service runs.

The service file runs `nanobot gateway` because the typical use case is a
long-running agent that responds to messages on a channel.

## systemd service setup

The setup script pushes `nanobot.service` into the container and enables
it. It does **not** start it -- you start it manually after verifying the
config:

    lxc exec nanobot -- systemctl start nanobot

The service runs as the `nanobot` user with the venv on PATH. It restarts
automatically on failure with a 10-second delay.

## Day-to-day operations

### Start the service

    lxc exec nanobot -- systemctl start nanobot

### Stop the service

    lxc exec nanobot -- systemctl stop nanobot

### Watch logs

    lxc exec nanobot -- journalctl -u nanobot -f

### Get a shell in the container

    lxc exec nanobot -- su - nanobot

The `su -` gives you a login shell. The venv is on PATH if you source `.envrc` manually or install [direnv](https://direnv.net/) and add the hook to `.bashrc`.

### Run a one-off agent command

    lxc exec nanobot -- su - nanobot -c 'cd code && nanobot agent'

### Restart after config changes

    lxc exec nanobot -- systemctl restart nanobot

### Check container status

    lxc list nanobot
