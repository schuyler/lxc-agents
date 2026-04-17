# Container setup

Two ways to provision a container: bootstrap scripts or cloud-init.

## Bootstrap scripts

Launch a plain image, push a script in, run it. Simple and debuggable.

```bash
lxc launch images:debian/trixie mycontainer
sleep 10  # wait for DHCP
lxc exec mycontainer -- bash < bootstrap.sh
```

The script runs as root inside the container. A typical bootstrap:

```bash
#!/bin/bash
set -euo pipefail

# Create a user
useradd -m -u 1000 -s /bin/bash agent
echo "agent ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/agent

# Install packages
apt update -qq
apt install -y -qq curl git build-essential > /dev/null

# Install uv (fast Python package manager)
su - agent -c 'curl -LsSf https://astral.sh/uv/install.sh | sh'

# Set up a venv and install your agent
su - agent -c '
    export PATH="$HOME/.local/bin:$PATH"
    cd ~/code
    uv venv .venv
    uv pip install nanobot-ai
'
```

This is the approach used in the [nanobot example](../examples/nanobot/).

## Cloud-init

Use a `/cloud` image variant and pass user-data at launch time:

```bash
lxc launch images:debian/trixie/cloud mycontainer \
    < cloud-init.yaml
```

Or via a config key:

```bash
lxc config set mycontainer cloud-init.user-data - < cloud-init.yaml
```

Example `cloud-init.yaml`:

```yaml
#cloud-config
hostname: agent

users:
  - name: agent
    uid: 1000
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL

packages:
  - curl
  - git
  - build-essential

runcmd:
  - su - agent -c 'curl -LsSf https://astral.sh/uv/install.sh | sh'
  - su - agent -c 'export PATH="$HOME/.local/bin:$PATH" && cd ~/code && uv venv .venv && uv pip install nanobot-ai'
```

## Which to use

Bootstrap scripts are easier to debug — you see every command's output in your terminal. Cloud-init silently swallows failures and writes them to `/var/log/cloud-init-output.log`, which you have to go fish out of the container after the fact.

Cloud-init is the better choice when you're launching many containers with the same configuration, or integrating with tools that speak the cloud-init format. For one-off setups or when iterating on provisioning, bootstrap scripts are less frustrating.
