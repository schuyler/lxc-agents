# Nanobot LXC Agent Example

This example runs [nanobot](https://pypi.org/project/nanobot-ai/) -- a Python-based
AI agent framework -- inside an LXC container, with the agent able to manage sibling
containers on the host via LXD.

## What it does

1. Creates a Debian LXC container
2. Installs nanobot and its dependencies inside the container
3. Mounts the nanobot workspace from the host
4. Sets up TLS certificates so the agent can talk to the host's LXD
5. Installs the LXC skill so the agent knows how to manage containers
6. Configures a systemd service to run `nanobot gateway` on boot

## Prerequisites

- Host set up per [host-setup.md](../../docs/host-setup.md) (LXD installed, bridge configured)
- A nanobot workspace directory on the host with `config.json` and any custom
  channel packages

## Files

| File | Purpose |
|---|---|
| `setup.sh` | Host-side orchestrator. Creates the container, mounts the workspace, generates TLS certs, and registers the host as an LXD remote. |
| `container-setup.sh` | Runs inside the container. Creates the `nanobot` user, installs packages, sets up a venv, and installs nanobot. |
| `nanobot.service` | Systemd unit that runs `nanobot gateway` as the nanobot user. |
| `envrc` | direnv-style environment file for interactive use inside the container. |
| `nanobot-wiring.md` | Wiring details: config.json fields, workspace mounts, LXC skill, day-to-day operations. |

## Usage

1. Edit the workspace path in `setup.sh` if needed.
2. Run `setup.sh` as root on the host.
3. Follow the wiring instructions in [nanobot-wiring.md](nanobot-wiring.md)
   to finish configuring `config.json` and the LXC skill.
4. Start the service:

       lxc exec nanobot -- systemctl start nanobot

5. Watch logs:

       lxc exec nanobot -- journalctl -u nanobot -f

## Wiring details

See [nanobot-wiring.md](nanobot-wiring.md) for the full explanation of
workspace mounts, config.json fields, the LXC skill, and day-to-day operations.
