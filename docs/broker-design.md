# Broker design

A design proposal for `lxc-broker`: a small MCP server that lets agents create
and manage unprivileged containers *without holding LXD credentials*. This
document is the design to argue with before any code exists.

## Status

Proposal. Nothing here is implemented yet.

## Why a broker

The current recipes hand the agent a TLS client certificate trusted by the
host's LXD daemon. That works, but the cert is a skeleton key: an agent holding
an unrestricted LXD cert can launch a privileged container, or attach a disk
device with `source=/`, and either one is root on the host. LXD's restricted
certificates and projects narrow this considerably (and the recipes should use
them regardless), but even a restricted cert exposes the full LXD API surface —
dozens of config keys, each a potential policy hole.

The broker inverts the trust model. It runs on the LXD host, holds the only
LXD credential, and exposes a deliberately narrow vocabulary to agents over
MCP: *sandboxes* and *services*, not containers. The agent never learns that
LXD exists. You can't pass `security.privileged=true` through a tool that has
no config parameter.

Defense in depth still applies. The broker's own LXD cert should be a
restricted cert confined to an LXD project with
`restricted.containers.privilege=unprivileged`, so a bug in the broker doesn't
escalate to full LXD. Broker policy is the first wall; project restrictions
are the second.

This does not replace the [LXC skill](../skills/lxc/SKILL.md). The skill
remains the low-ceremony option when you trust your agent with a (restricted)
cert. The broker is the next rung on the containment ladder.

## What the broker is not

The containment claim is "the agent can't touch the host, and joins your LAN
only deliberately" — not "the agent is safe." Code running inside a sandbox is
still arbitrary code with internet access. The
[lethal trifecta](https://simonwillison.net/2025/Jun/16/the-lethal-trifecta/)
caveat from the README applies in full.

## Architecture: control plane vs. data plane

The design splits along a line that fell out of asking "why not just hand the
agent an SSH connection?" — because for most of the job, you should.

**Control plane (the broker, MCP over Streamable HTTP).** Creating and
destroying containers requires a privileged credential, so it goes through the
broker. This is also where policy lives: image allowlist, quotas, TTL reaping,
ownership, the service registry, and the audit log. The tool surface is small —
lifecycle only.

**Data plane (SSH, direct).** Running commands, transferring files, tailing
logs, using REPLs: the agent SSHes straight into the sandbox it was handed.
The broker injects the agent's public key at creation time and returns the IP.
SSH beats MCP tool calls here on every axis that matters — streaming,
interactivity, thirty years of hardening, and zero new tooling for any agent
that has a shell. The security boundary is the unprivileged container, not the
protocol used to enter it, and an SSH key for a non-root user in one
disposable container is nearly worthless if stolen.

```
agent machine                     LXD host
┌─────────────┐   MCP (HTTP)    ┌──────────────────────────┐
│    agent     ├────────────────►│ lxc-broker               │
│              │  create/destroy │   policy, quotas, TTL,   │
│  (no LXD     │                 │   registry, audit log    │
│   cert, no   │                 │      │ restricted cert   │
│   root)      │                 │      ▼                   │
│              │                 │  LXD (project: agents)   │
│              │      SSH        │      │                   │
│              ├────────────────►│  ┌───┴────┐  ┌────────┐  │
└─────────────┘  exec, files,   │  │sandbox │  │service │  │
                 logs, REPLs    │  └────────┘  └────────┘  │
                                 └──────────────────────────┘
```

What this trades away: per-command auditability. The broker sees "sandbox
created, sandbox destroyed," not what ran inside. If you need keystroke-level
audit, log at sshd inside the base image; the containment story never depended
on it.

One consequence: v1 targets shell-capable agents (Claude Code, nanobot,
anything with a bash tool). An MCP-only client like Claude Desktop can't SSH
anywhere; serving those would mean adding exec/file tools to the broker, which
can be bolted on later without breaking this design.

## Two tiers: sandboxes and services

A single TTL knob is the wrong model. Agents create two kinds of container
with opposite lifecycles, and the broker models them explicitly.

### Sandboxes (ephemeral)

Where the agent experiments, builds, and breaks things.

- Attached to an **isolated bridge**: internet and sibling access, but not
  exposed to the LAN.
- **TTL-reaped**: no SSH activity for the idle window (default: stop after 2
  hours, delete after 24 — configurable) and the reaper cleans up. The failure
  mode this prevents is real: an agent tries four approaches and leaves three
  half-configured containers behind. A stopped sandbox keeps its disk and can
  be revived with `start_sandbox`.
- **Quota-capped** per agent (default: 10 live sandboxes).
- Created freely. With pre-baked images, creation takes seconds, so the
  cheapest-safest usage pattern — one sandbox per task, then discard — is also
  the most convenient.

### Services (persistent)

Long-lived network services the agent stands up on the home LAN — one of the
founding use cases of this repo. Persistence is not a creation flag; it's a
**promotion**, a deliberate and auditable act:

```
promote(sandbox, name, purpose) → service
```

Promotion does four things:

1. **Exempts the container from the reaper** and sets `boot.autostart=true`.
2. **Moves the NIC from the isolated bridge to the LAN bridge** (and restarts
   the container). Building and testing happen in isolation; *joining the LAN
   is the promotion*. This is the resolution of the "bridged LAN IPs are the
   feature / bridged LAN IPs are the blast radius" tension: both are true, so
   the transition is explicit.
3. **Records the service in a registry**: name, required human-readable
   `purpose`, owning agent, creation date, listening ports. Six months later,
   `lxc-broker services` answers "what is that container on my LAN?" — which
   is the feature the *human* needs most. Agent-created infrastructure that
   has drifted out of everyone's context (including the agent's) is a bigger
   practical risk than any single container escape.
4. **Counts against a separate, smaller quota** (default: 3 services). Ten
   scratch sandboxes and three LAN services are very different risk postures.

Services stay unprivileged, in the restricted project, with resource limits.
Persistence changes lifespan, not trust level. If a service genuinely needs
something the project forbids, a human does that by hand; it is never a broker
parameter.

Container name = service name, so if your router does local DNS from DHCP
leases, `my-service.lan` just works.

Because SSH keys persist with the container, ongoing management (redeploy,
restart, read logs) needs nothing from the broker. Base images should include
`unattended-upgrades`, because a container that runs for a year rots in a way
a disposable one never does.

### Promotion policy

A config knob, because thresholds for "agent may join things to my network"
vary:

- `promotion: auto` — promotion succeeds immediately. Full autonomy.
- `promotion: approve` — promotion requests queue; a human confirms with
  `lxc-broker approve NAME` before the container touches the LAN.

## Tool surface (v1)

Seven tools. Deliberately omitted: exec, file transfer (SSH does both), config
of any kind, snapshots, custom images, device attachment, privilege toggles.
Every omission is a policy surface that doesn't exist.

### `create_sandbox`

| param | type | notes |
|---|---|---|
| `image` | string, optional | key into the broker's image allowlist (`debian`, `python`, `node`, …); default `debian` |
| `name_hint` | string, optional | prettified into the container name |

Returns `{id, ip, ssh_user, status}`. The broker injects the calling agent's
registered public key for `ssh_user` (UID 1000, passwordless sudo *inside the
sandbox only*). Fails if the sandbox quota is reached.

### `list_sandboxes`

No params. Returns this agent's sandboxes: `{id, ip, status, created,
last_active, ttl_expires}`. Never shows other agents' containers.

### `start_sandbox`

| param | type | notes |
|---|---|---|
| `id` | string | must be owned by the calling agent |

Restarts a sandbox the reaper has stopped (disk state intact, processes
gone). This tool exists solely so the reaper's stop stage isn't a dead end —
without it, a stopped sandbox would be unrecoverable by the agent, since
there is no other path back in.

### `destroy`

| param | type | notes |
|---|---|---|
| `id` | string | must be owned by the calling agent |

Works on both sandboxes and services. Destroying a service also removes its
registry entry. This is the teardown *and* redeploy path: replacing a service
is destroy-and-repromote (see "Demotion" below).

### `promote`

| param | type | notes |
|---|---|---|
| `sandbox` | string | must be owned by the calling agent |
| `name` | string | becomes the container/DNS name; must be unique |
| `purpose` | string | required; stored in the registry for humans |
| `ports` | int[], optional | listening ports, for the registry |

Returns the service record, or `{status: "pending_approval"}` under
`promotion: approve`.

### `list_services` / `describe_service`

Registry reads, so an agent in a *fresh* conversation can rediscover what
exists, what it's for, and how to reach it. `describe_service` returns the
full record including IP and ports.

## Identity, quotas, and audit

- **Auth**: bearer token per agent, issued on the host
  (`lxc-broker token create nanobot`). Full MCP OAuth is overkill for a
  homelab; tokens are the pragmatic middle. Token → name prefix
  (`nanobot-...` containers) → ownership checks fall out of the naming.
- **Quotas**: per-agent live-sandbox and service caps, enforced at create and
  promote. Aggregate CPU/memory caps come free from the LXD project
  (`limits.cpu`, `limits.memory` on the project).
- **Audit log**: append-only record of every lifecycle event — who created,
  promoted, destroyed what, and when. Lifecycle only (see data-plane
  trade-off above).

## Images

The broker owns image choice, so it's the natural home for a base-image bake
step: a script that provisions each allowlisted image from a bootstrap script
(per [container-setup.md](container-setup.md)) and captures it with
`lxc publish`. Sandbox creation drops from minutes of apt-installing to ~2
seconds of copy-on-write clone, and the Debian mirrors stop getting hammered.

Every base image includes: the sandbox user (UID 1000), sshd with the
[hardened config](../examples/claude-code/sshd-hardened.conf),
`unattended-upgrades`, and whatever the image key promises (`python` → uv,
`node` → Node LTS).

## Networking

Two LXD networks:

- `sandbox-br` — an isolated bridge (LXD-managed, NAT to WAN). Sandboxes live
  here. They can reach the internet and each other; the LAN can't reach them.
  The agent must be able to reach this bridge to SSH in — trivially true if
  the agent runs on the host or in a container on the same bridge; a static
  route or firewall rule if the agent is elsewhere on the LAN.
- The existing LAN bridge (e.g. `br0`) per [host-setup.md](host-setup.md).
  Services move here at promotion and get real DHCP leases.

## Implementation sketch

Python, FastMCP, pylxd. One file for the server, plus a small CLI for token
and approval management, a systemd unit, and the image-bake script. Rough
estimate: 300–500 lines of server. pylxd's exec-free API keeps command
injection off the table (the broker never shells out on behalf of the agent);
the code that still deserves paranoia is name validation (names become LXD
identifiers and DNS labels), token storage, and the reaper's delete path.

Unlike the rest of this repo, the broker is security-critical *code*, not a
recipe — it needs tests and shellcheck-grade hygiene from day one.

Proposed layout:

```
broker/
  lxc_broker/        # server + CLI
  images/            # bake script + per-image bootstrap scripts
  lxc-broker.service
  README.md
```

## Open questions, resolved

These were open in the first draft. Each now has a decision; the rationale is
recorded so future disagreement can argue with the reasoning, not just the
conclusion.

### Reaper idle signal: SSH activity only

**Decision:** "Idle" means no SSH connection to the sandbox. Inbound test
traffic (an agent curling the HTTP server it just wrote) does **not** count.

SSH is the agent's only management channel, so an agent still working on a
sandbox will reconnect soon, and the first reaper stage only stops the
container — disk intact, recoverable via `start_sandbox`. Counting arbitrary
network traffic as activity would let any container with a chatty process
keep itself alive forever, which defeats the reaper. And the deeper rule
already covers the edge case: a sandbox whose *served traffic* matters is a
service by definition, and should be promoted. The 2h-stop / 24h-delete
defaults stand until real usage argues otherwise; both are config values.

### Approval UX: CLI plus an optional webhook

**Decision:** `lxc-broker approve` on the host is the approval mechanism. The
only notification support is an optional `notify_url` — a bare HTTP POST fired
on pending promotions (and reaper deletions). No Matrix, email, or other
integrations.

A generic webhook costs one config key and a few lines, and covers
[ntfy](https://ntfy.sh), Slack-compatible endpoints, and home-automation hooks
without the broker growing opinions about any of them. Anything richer is
disproportionate for a security-critical component whose main virtue is being
small enough to audit.

### Sandbox-to-sandbox reachability: shared bridge, documented trust boundary

**Decision:** v1 uses one shared isolated bridge. All agents on the same
broker mutually trust each other, and the docs say so plainly.

Multi-container experiments — an agent wiring a web container to a database
container — are this repo's founding use case, so sibling reachability is a
feature, not a leak. The homelab deployment this targets nearly always runs
one agent (or several agents owned by the same person), so cross-agent
snooping is a theoretical concern being weighed against real network sprawl:
per-agent bridges mean per-agent subnets, routes, and firewall rules. If real
multi-tenancy ever matters, LXD network ACLs on the shared bridge are the
escape hatch that doesn't require re-plumbing — but it is explicitly out of
scope for v1.

### Incus: adapter seam now, second backend later

**Decision:** v1 targets LXD via pylxd, matching the platform the rest of the
repo is tested on. All LXD calls go through one thin adapter module —
roughly ten operations (launch, stop, delete, device set, list, publish,
project ops) — so an Incus backend is a contained change rather than a
rewrite.

The REST APIs are still near-identical, but the auth and
projects/restricted-cert surfaces are drifting, and tracking both from day
one doubles the test burden on the security-critical component before there
is a single user of either. The adapter seam is cheap insurance; writing the
second backend before someone needs it is not.

### Demotion: no — destroy and re-promote

**Decision:** There is no `demote(service)`. Taking a service off the LAN is
`destroy(id)`; replacing one is destroy, rebuild in a sandbox, re-promote.

Demotion has ambiguous semantics that promotion doesn't: LAN clients may hold
the DNS name and IP, the container keeps state accumulated while exposed, and
a "demoted" container is neither a fresh sandbox nor a registered service —
a third lifecycle state whose reaper and quota treatment would need defining.
Destroy-and-recreate is unambiguous, and cheap base images make rebuild the
easy path anyway. The one-way ratchet also preserves a useful invariant: every
container on your LAN got there through a promotion that is still in the
registry and the audit log.
