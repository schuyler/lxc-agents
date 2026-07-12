# lxc-agents

Run autonomous LLM agents inside LXC containers where they can create and manage other containers on the same host. This gives your agents the ability to create, launch, and manage network services -- or indeed anything that will run on your host OS kernel -- all in a self-contained environment that minimizes the blast radius.

The idea: an agent lives in its own container, talks to the host's LXD daemon over TLS, and can spin up worker containers on demand. Everything gets real LAN IPs from DHCP — no NAT, no port forwarding.

```
host (LXD on br0)
  └─ LXD (:8443)
       ├─ agent (Debian trixie, UID-mapped)
       │    workspace mounted from host
       │    HTTP → host LXD
       │    HTTP(S) → LLM endpoint
       │
       ├─ worker-1  ← created by agent
       └─ worker-2  ← created by agent
```

## What's here

[**Host setup**](docs/host-setup.md) — install LXD, bridge your LAN, expose the daemon, trust a client cert. These are the instructions specific to your hardware and network.

[**LXC skill**](skills/lxc/SKILL.md) — a `SKILL.md` you can drop into any agent that supports the [opencode skill format](https://opencode.ai/docs/skills/) (or anything that reads markdown instructions). Teaches the agent how to create, exec into, and destroy containers via the `lxc` CLI.

[**Example: nanobot**](examples/nanobot/) — a complete worked example using [nanobot](https://pypi.org/project/nanobot-ai/), an agent framework that runs in a container and manages siblings on demand.

[**Example: Claude Code**](examples/claude-code/) — a worked example running [Claude Code](https://docs.anthropic.com/en/docs/claude-code) in its own container, accessible via SSH with tmux for persistent sessions.

## CAVEAT HAX0R

* The code and directions in this repo are less plug-and-play and more like a set of recipes that you or an agent can adapt to your purposes.
* The examples have been tested and work for me, but they might not work for you for ... any number of reasons. Please send patches if you find anything grossly erroneous or foolish.
* "Locks keep honest people honest." LXC containment can reduce your vulnerability to your bots making stupid mistakes, but a determined attacker can find ways to escape a container. Containers aren't a cure-all for [the lethal trifecta](https://simonwillison.net/2025/Jun/16/the-lethal-trifecta/)!

## Why LXC and not Docker

Three reasons Docker was a bad fit for this:

1. **Security.** Docker's daemon runs as root. Anyone who can talk to the Docker socket can run `--privileged` and get root on the host. There's no practical way to let an agent create containers without also giving it a path to full host access. LXD uses unprivileged containers by default, per-container UID mapping, and TLS client certs with scoped trust.

2. **UID mapping.** Rootless Docker remaps all container UIDs through user namespaces (`/etc/subuid`). If you want container UID 1000 to match host UID 1000 for workspace sharing, you're fighting the namespace mapping. With LXC you just set `raw.idmap="both 1000 1000"`.

3. **Networking.** Docker's default is NAT. To get containers on the LAN with real IPs you have to configure macvlan or custom bridge networks. LXC containers on a bridged profile just get DHCP leases like any other machine on the network.

If your agent needs to run Docker containers or Docker Compose, you can install Docker inside an LXC container. You get the isolation benefits of LXC with Docker's ecosystem when you need it. The main caveat is that Docker's default `overlay2` storage driver doesn't work inside LXC — you need to configure `fuse-overlayfs` instead. See [this guide](https://rose-stl-lab.github.io/guide/docker.html) for the specifics.

## Other docs

- [Local models](docs/local-models.md) — running llama.cpp on the host and pointing containers at it
- [Container setup](docs/container-setup.md) — provisioning containers with bootstrap scripts or cloud-init
- [Broker design](docs/broker-design.md) — proposal for an MCP broker that manages container lifecycle so agents never hold LXD credentials

## You'll need

- A Linux host with LXD or [Incus](https://linuxcontainers.org/incus/) (tested on Ubuntu 22.04 with LXD via snap)
- A bridge interface connected to your LAN
- An LLM endpoint reachable from the container network

## See also

- [packnplay](https://github.com/obra/packnplay) — one of the inspirations for this approach
