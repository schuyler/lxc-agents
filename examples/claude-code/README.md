# Claude Code LXC Example

Run [Claude Code](https://docs.anthropic.com/en/docs/claude-code) inside an LXC container. Two ways to use it:

- **Local**: `lxc exec claude-code -- su - claude -c 'claude'` from the host terminal.
- **Remote**: SSH in from another machine, run Claude in tmux so it persists across disconnects. A systemd service can start it automatically on boot.

## What it does

1. Creates a Debian LXC container
2. Installs Node.js, Claude Code, and developer tools
3. Sets up SSH for remote access
4. Installs tmux for persistent remote sessions
5. Optionally mounts a workspace from the host

## Prerequisites

- Host set up per [host-setup.md](../../docs/host-setup.md) (LXD installed, bridge configured)
- An SSH public key at `~/.ssh/id_ed25519.pub` (for remote access)
- An Anthropic API key

## Files

| File | Purpose |
|---|---|
| `setup.sh` | Host-side orchestrator. Creates the container, pushes config files, enables the systemd service. |
| `container-setup.sh` | Runs inside the container. Creates the `claude` user, installs packages, Node.js, Claude Code, starts SSH. |
| `claude-code.service` | Systemd unit that starts Claude Code in a tmux session on boot. |
| `claude-code.env` | API key and optional custom endpoint. Edit before starting the service. |
| `sshd-hardened.conf` | SSH drop-in: key auth only, no root login, no passwords. |
| `envrc` | direnv file for `~/code`. Adds `~/.local/bin` (uv) to PATH. |
| `profile.sh` | Appended to `.bashrc`. Sets up direnv and sources `claude-code.env`. |
| `lxc-claude.sh` | Convenience wrapper. Runs Claude Code in the container with `lxc exec --user 1000`. |

## Setup

1. Edit `claude-code.env` to set your API key.
2. Run `setup.sh` as root on the host.

The env file is pushed into the container during setup. To change the key later:

    lxc exec claude-code -- nano /home/claude/.config/claude-code.env

---

## Local: from the host terminal

`lxc exec` allocates a PTY and connects your terminal directly to the container. No SSH needed.

### Run Claude Code

    lxc exec claude-code --user 1000 --group 1000 --cwd /home/claude/code -- claude

### Run in a specific project directory

    lxc exec claude-code --user 1000 --group 1000 --cwd /home/claude/code/workspace/my-project -- claude

### Get a shell

    lxc exec claude-code --user 1000 --group 1000 -- bash

---

## Remote: SSH + tmux

If you're connecting from another machine on the network (or want Claude Code to survive terminal disconnects), use SSH and tmux.

The container runs an SSH server with key-based authentication. Password auth is disabled. Find the container's IP:

    lxc list claude-code

### SSH config

Add an entry to `~/.ssh/config` on your local machine:

    Host claude-code
        HostName <CONTAINER_IP>
        User claude
        ForwardAgent yes

Then connect with `ssh claude-code`.

`ForwardAgent yes` lets Claude Code use your host SSH agent (e.g., to push to GitHub). This gives it access to all keys on your agent. If that's too broad, omit `ForwardAgent` and configure a deploy key or token inside the container instead.

If the container's IP changes after a reboot, update the HostName. To pin it, set a static IP inside the container:

    lxc exec claude-code -- bash -c 'cat > /etc/network/interfaces.d/static.cfg <<EOF
    auto eth0
    iface eth0 inet static
        address 10.0.0.50/24
        gateway 10.0.0.1
    EOF'

Or use your DHCP server's static binding feature.

### tmux

Claude Code runs inside a tmux session named `claude`. SSH disconnects don't affect it -- reattach from any machine.

Start a session:

    tmux new -s claude

Attach:

    tmux attach -t claude

Detach: `Ctrl-b` then `d`.

Quick reconnect (requires the SSH config above):

    ssh claude-code -t 'tmux attach -t claude'
    ssh claude-code -t 'tmux new -A -s claude'

List sessions:

    tmux ls

Kill a session:

    tmux kill-session -t claude

### Auto-start on boot

The systemd service creates a detached tmux session running Claude Code when the container starts. It reads `claude-code.env` for environment variables. If the session already exists (e.g., after a restart), the start command is a no-op.

The service is enabled but not started during setup -- start it manually after setting the API key:

    lxc exec claude-code -- systemctl start claude-code

After that it starts automatically on every boot. Restart it after changing the API key or updating Claude Code:

    lxc exec claude-code -- systemctl restart claude-code

Watch service logs:

    lxc exec claude-code -- journalctl -u claude-code -f

---

## Environment

### ANTHROPIC_API_KEY

Claude Code requires an Anthropic API key. Set it in `claude-code.env` before starting the service, or edit it inside the container:

    nano ~/.config/claude-code.env

This file is loaded by both the systemd service and `.bashrc` (for interactive sessions).

### Local LLM endpoint

To point Claude Code at a local model instead of Anthropic's API, add to `claude-code.env`:

    ANTHROPIC_BASE_URL=http://<HOST_IP>:8080/v1

Replace `<HOST_IP>` with the bridge IP of the host running llama.cpp. See [local-models.md](../../docs/local-models.md) for host-side setup.

## Workspace mount

To give Claude Code access to a host-side codebase, add an LXC disk device. Edit `setup.sh` to include:

    lxc config device add claude-code workspace disk \
        source=/path/on/host path=/home/claude/code/workspace

The `raw.idmap=both 1000 1000` set during container creation maps host UID 1000 to guest UID 1000, so the `claude` user sees correct file ownership. If your host user has a different UID, adjust the mapping.

## Day-to-day operations

### Update Claude Code

    lxc exec claude-code -- su - claude -c 'npm update -g @anthropic-ai/claude-code'

If using the systemd service:

    lxc exec claude-code -- systemctl restart claude-code

### Stop / start the container

    lxc stop claude-code
    lxc start claude-code

### Check container status

    lxc list claude-code

### Get a root shell

    lxc exec claude-code -- bash
