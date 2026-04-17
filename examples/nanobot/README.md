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
- A nanobot workspace directory on the host with `config.json`

## Files

| File | Purpose |
|---|---|
| `setup.sh` | Host-side orchestrator. Creates the container, mounts the workspace, generates TLS certs, and registers the host as an LXD remote. |
| `container-setup.sh` | Runs inside the container. Creates the `nanobot` user, installs packages, sets up a venv, and installs nanobot. |
| `nanobot.service` | Systemd unit that runs `nanobot gateway` as the nanobot user. |
| `envrc` | direnv-style environment file for interactive use inside the container. |

## Usage

1. Edit the workspace path in `setup.sh` if needed.
2. Run `setup.sh` as root on the host.
3. Edit `config.json` per the [config.json](#configjson) section below.
4. Create the config symlink (see [The config.json symlink issue](#the-configjson-symlink-issue)).
5. Start the service:

       lxc exec nanobot -- systemctl start nanobot

6. Watch logs:

       lxc exec nanobot -- journalctl -u nanobot -f

## Workspace mount

The setup script mounts the host-side nanobot workspace into the container
using an LXC disk device. File ownership works because `setup.sh` configures
`raw.idmap` on the container:

    raw.idmap=both 1000 1000

This maps UID and GID 1000 identically between host and guest. The host-side
user (UID 1000) and the container's `nanobot` user (UID 1000) see the same
file ownership. Without this mapping, the mounted files would be owned by
nobody/root and nanobot could not write to its own workspace.

## config.json

The nanobot workspace's `config.json` lives at `/home/nanobot/code/nanobot/config.json`
inside the container (the guest-side mount of your host workspace). You can edit it
from the host since it's a shared mount:

    nano /home/YOUR_USER/code/llm/nanobot/config.json

Or pull it out, edit, and push it back:

    lxc file pull nanobot/home/nanobot/code/nanobot/config.json /tmp/config.json
    nano /tmp/config.json
    lxc file push /tmp/config.json nanobot/home/nanobot/code/nanobot/config.json

Two things need to match the container environment:

1. **Workspace path.** If your config sets a workspace path, it must be the
   guest-side path (`/home/nanobot/code/nanobot`), not the host-side path.
2. **LLM provider URL.** The provider endpoint must be reachable from inside
   the container. Use the host's bridge IP (e.g. `http://10.0.0.1:8080/v1`),
   not `localhost`.

See the [nanobot docs](https://pypi.org/project/nanobot-ai/) for the full
config schema.

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
- `nanobot gateway` starts a persistent process that serves incoming requests
  and dispatches them to agents. This is what the systemd service runs.

The service file runs `nanobot gateway` because the typical use case is a
long-running agent that responds to incoming requests.

## Connecting to WhatsApp

Nanobot has WhatsApp support built in — no extra Python packages needed. It
uses a local Node.js bridge that acts as a WhatsApp Web client, linking to your
existing phone number. No WhatsApp Business API or third-party service required.

The bridge needs Node.js >= 18. Debian Trixie ships Node.js 20.x, so you can
install it directly:

    lxc exec nanobot -- apt install -y nodejs

### Pair and run the bridge

`nanobot channels login whatsapp` does two things: on first run it pairs with
your phone (displaying a QR code), and on every run it starts the bridge
process that stays connected to WhatsApp. This process must remain running for
the gateway to send and receive messages.

Pair your device by running:

    lxc exec nanobot -- su - nanobot -c 'cd code && nanobot channels login whatsapp'

Scan the QR code via WhatsApp > Settings > Linked Devices on your phone.

The bridge stays connected as long as that process is alive. To keep it
running in the background, use a persistent session. For example, in a
separate terminal:

    lxc exec nanobot -- su - nanobot -c 'screen -dmS whatsapp bash -c "cd code && nanobot channels login whatsapp"'

Then start the gateway:

    lxc exec nanobot -- systemctl start nanobot

### Configure config.json

Add a `channels` key to your `config.json`:

```json
{
  "channels": {
    "whatsapp": {
      "enabled": true,
      "allowFrom": ["+1234567890"]
    }
  }
}
```

`allowFrom` is a list of phone numbers (with country code) the agent will
respond to. Use `["*"]` to allow all contacts — but note that anyone you allow
can send messages to an agent that can execute arbitrary commands inside the
container.

### After upgrading nanobot

Rebuild the bridge:

    lxc exec nanobot -- su - nanobot -c 'rm -rf ~/.nanobot/bridge && cd code && nanobot channels login whatsapp'

## systemd service setup

The setup script pushes `nanobot.service` into the container and enables
it. It does **not** start it -- you start it manually after verifying the
config:

    lxc exec nanobot -- systemctl start nanobot

The service runs as the `nanobot` user, using the venv's nanobot binary directly.
It restarts automatically on failure with a 10-second delay.

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
