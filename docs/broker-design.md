# Broker design

A design for `lxc-broker`: a small MCP server that lets agents create and
manage unprivileged containers *without holding LXD credentials*. This
document records the reasoning; the [implementation spec](broker-spec.md)
records the schemas, sequences, error cases, host prerequisites, and tests.

## Status

Design complete, nothing implemented. Several facts below were verified on an
LXD 5.21.7 host with a `dir` storage pool and are marked as such; everything
else is reasoning.

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
MCP: *sandboxes* and *services*, not containers. You can't pass
`security.privileged=true` through a tool that has no config parameter.

Defense in depth still applies. The broker's own LXD cert is a restricted
cert confined to an LXD project with
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
The broker injects the agent's public key at creation time and returns the IP
and the sandbox's SSH host key. SSH beats MCP tool calls here on every axis
that matters — streaming, interactivity, thirty years of hardening, and zero
new tooling for any agent that has a shell. The security boundary is the
unprivileged container, not the protocol used to enter it, and an SSH key for
a non-root user in one disposable container is nearly worthless if stolen.

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
- **TTL-reaped**: no SSH connection for the idle window (default: stop after
  2 hours, delete after 24 — configurable) and the reaper cleans up. The
  failure mode this prevents is real: an agent tries four approaches and
  leaves three half-configured containers behind. A stopped sandbox keeps its
  disk and can be revived with `start_sandbox`; `keep_alive` defers the stop
  for a bounded time.
- **Quota-capped** per agent (default: 10 sandboxes, counting stopped ones).
- Created freely. With pre-baked images, creation takes seconds, so the
  cheapest-safest usage pattern — one sandbox per task, then discard — is also
  the most convenient.

### Services (persistent)

Long-lived network services the agent stands up on the home LAN — one of the
founding use cases of this repo. Persistence is not a creation flag; it's a
**promotion**, a deliberate and auditable act:

```
promote(sandbox, name, purpose, ports) → service
```

Promotion **copies** the sandbox. The sandbox is stopped, `lxc copy` produces
a new container named after the service with its NIC on the LAN bridge and
`boot.autostart=true`, the copy is started, and the original is deleted.
Nothing about the original is mutated, so the only rollback is "delete the
copy", which is idempotent and leaves no half-promoted state to reason about.
Building and testing happen in isolation; *joining the LAN is the promotion*.
This resolves the "bridged LAN IPs are the feature / bridged LAN IPs are the
blast radius" tension: both are true, so the transition is explicit.

**Verified:** the `images:debian/trixie` templates for `/etc/hostname` and
`/etc/hosts` fire on `when: [create, copy]`, so the copy comes up with the
service name as its hostname and the broker never writes those files. `lxc
copy src dst -c boot.autostart=true -d eth0,parent=BRIDGE` took 1.7 s on a
`dir` pool for a fresh image, and the copy had an instance-local `eth0` on
the new parent. On `dir` pools copy time scales with disk usage; on zfs and
btrfs it is a copy-on-write clone.

The copy inherits the sandbox's SSH host key and `authorized_keys`, so the
promoting agent's key and the host key it was given at creation keep working.

Promotion also:

1. **Records the service in a registry**: name, required human-readable
   `purpose`, owning agent, creation date, listening ports. Six months later,
   `lxc-broker services` answers "what is that container on my LAN?" — which
   is the feature the *human* needs most. Agent-created infrastructure that
   has drifted out of everyone's context (including the agent's) is a bigger
   practical risk than any single container escape.
2. **Counts against a separate, smaller quota** (default: 3 services). Ten
   scratch sandboxes and three LAN services are very different risk postures.

Services stay unprivileged, in the restricted project, with resource limits.
Persistence changes lifespan, not trust level. If a service genuinely needs
something the project forbids, a human does that by hand; it is never a broker
parameter.

Container name = service name, so if your router does local DNS from DHCP
leases, `my-service.lan` just works. Because SSH keys persist with the
container, ongoing management (redeploy, restart, read logs) needs nothing
from the broker. Base images include `unattended-upgrades`, because a
container that runs for a year rots in a way a disposable one never does.

### Promotion policy

A config knob, because thresholds for "agent may join things to my network"
vary:

- `promotion: auto` — promotion runs immediately. Full autonomy.
- `promotion: approve` — the request queues and the sandbox is parked,
  exempt from the reaper; a human runs `lxc-broker approve NAME` and the
  server runs the same sequence.

## Tool surface

Eight tools. Deliberately omitted: exec, file transfer (SSH does both), config
of any kind, snapshots, custom images, device attachment, privilege toggles.
Every omission is a policy surface that doesn't exist.

| tool | does |
|---|---|
| `create_sandbox(image?, name_hint?)` | Clones an allowlisted image, injects the caller's SSH key, returns `{id, ip, ssh_user, host_key, ttl_expires}`. |
| `list_sandboxes()` | This agent's sandboxes only. Never shows other agents' containers. |
| `start_sandbox(id)` | Revives a sandbox the reaper stopped. Exists so the stop stage isn't a dead end. |
| `keep_alive(id, hours)` | Defers the reaper's stop stage, clamped to a configured cap (default 12 h). |
| `destroy(id)` | Sandbox or service; owner only. Teardown and the redeploy path (destroy, rebuild, re-promote). |
| `promote(sandbox, name, purpose, ports?)` | The copy described above, or `pending_approval` under `promotion: approve`. |
| `list_services()` / `describe_service(name)` | Registry reads, visible to every agent, so an agent in a fresh conversation can rediscover what exists and how to reach it. |

Every tool takes an id or a name and a handful of validated scalars. `image`
is a key into the broker's allowlist; the agent never sees an LXD alias.

## Identity, quotas, and audit

- **Auth**: bearer token per agent, issued on the host
  (`lxc-broker token create nanobot --pubkey nanobot.pub`). Full MCP OAuth is
  overkill for a homelab; tokens are the pragmatic middle. Token → name
  prefix (`nanobot-...` containers) → ownership checks fall out of the naming.
  Token names are never reused (see decisions).
- **Quotas**: per-agent sandbox and service caps, enforced at create and
  promote. Aggregate CPU/memory caps come from the LXD project.
- **Audit log**: a table recording every lifecycle event — who created,
  promoted, destroyed what, and when. Lifecycle only (see data-plane
  trade-off above).

## Images

The broker owns image choice, so it's the natural home for a base-image bake
step: a script that provisions each allowlisted image from a bootstrap script
(per [container-setup.md](container-setup.md)) and captures it with
`lxc publish`. Sandbox creation drops from minutes of apt-installing to
seconds of clone, and the Debian mirrors stop getting hammered.

Every base image includes: the sandbox user (UID 1000), sshd with the
[hardened config](../examples/claude-code/sshd-hardened.conf),
`unattended-upgrades`, a first-boot unit that regenerates SSH host keys (so
clones don't share one), and whatever the image key promises (`python` → uv,
`node` → Node LTS).

## Networking

Two bridges:

- `sandbox-br` — an isolated, LXD-managed bridge with NAT to the WAN.
  Sandboxes live here. They can reach the internet and each other; the LAN
  can't reach them. The broker listens **only** on the host's address on this
  bridge, and the agent container gets a second NIC on it, which it needs
  anyway to SSH into sandboxes.
- The existing LAN bridge (e.g. `br0`) per [host-setup.md](host-setup.md).
  Services are copied here at promotion and get real DHCP leases.

The host's address on `sandbox-br` is reachable from every sandbox, so LXD
MUST NOT listen there: it binds to the LAN address only, and the operator
installs firewall rules that drop sandbox traffic to the host's other ports
and to the LAN, and drop new connections from outside the sandbox subnet
into it. The broker cannot enforce any of this itself; the spec carries the
reachability matrix and the rules as a required prerequisite.

The LXD project is the second wall for network placement too. **Verified:**
`restricted.networks.access` must list both bridges by name, the unmanaged
LAN bridge included; with only `sandbox-br` listed, attaching a NIC with
`parent=br0` fails with "Network not allowed in project", and a third bridge
not in the list is refused. So even a broker bug can only put a container on
one of the two named bridges. Likewise **verified:**
`restricted.devices.disk=block` permits the root disk and refuses
`source=/` with "Disk devices are forbidden", which is the host-filesystem
hole the project restriction exists to close.

## Implementation sketch

Python, FastMCP, pylxd, SQLite (stdlib). One process: the MCP server, the
reaper, and a poller that acts on operator approvals. The CLI is a separate
entry point that only reads and writes the database. All LXD calls go through
one adapter of thirteen operations (launch, copy, start, stop, delete,
list, status, wait-for-IP, file get/put, one fixed-argv exec for the
activity probe, image lookup, pool driver lookup), so an Incus backend is a
contained change. Honest size estimate: 800–1200 lines of Python plus tests. pylxd's
API keeps command injection off the table — the one exec has a constant
argv — and the code that still deserves paranoia is name validation (names
become LXD identifiers and DNS labels), token storage, and the reaper's
delete path.

Unlike the rest of this repo, the broker is security-critical *code*, not a
recipe — it needs tests and shellcheck-grade hygiene from day one.

```
broker/
  lxc_broker/        # server, adapter, db, policy, lifecycle, reaper, cli
  images/            # bake script + per-image bootstrap scripts
  tests/             # fake adapter, unit tests, gated integration tests
  lxc-broker.service
  README.md
```

## Decisions

Each records the reasoning so future disagreement can argue with it rather
than with the conclusion.

### Promotion is a copy, not a mutation

An earlier draft promoted in place: stop, rename, rewrite the hostname,
move the NIC, set autostart, start. Each step could fail, a crash between
any two left a container in a state the registry had to describe, and the
rollback logic grew to read LXD's actual state and reverse whatever it
found. `lxc copy` collapses all of it: the source is untouched until the
copy is running on the LAN, so the only rollback is deleting the copy, and
the only crash-recovery question is "does a running copy exist under the
service name?" The hostname comes for free from the image templates
(verified above), and the copy cost is seconds on `dir` and a CoW clone on
zfs/btrfs. The price is one transient extra container during promotion and
a copy of the disk on `dir` pools, both acceptable for a homelab.
**Verified** while checking this: in a project whose default profile has
no devices, `lxc launch -d` cannot add root or eth0 (it only overrides
profile devices), `--storage` and `--network` can, and the root size is
then set with `device set`, not `device override`. The pylxd create body
takes a full devices dict and is unaffected; only the bake script cares.

### Reaper idle signal: established SSH sockets, read by one fixed exec

"Idle" means no SSH connection to the sandbox. Inbound test traffic (an
agent curling the HTTP server it just wrote) does **not** count, because
counting arbitrary traffic would let any chatty process keep a sandbox alive
forever, and a sandbox whose served traffic matters is a service by
definition. An open connection counts as continuous activity, which is what
an agent running a long build expects.

How to read it was settled by experiment. **Verified:** the LXD files API
cannot read procfs (`lxc file pull c/proc/net/tcp` returns Not Found and
`/proc/1/net/tcp` returns empty), so a files-API probe is dead, not
uncertain. **Verified:** `br_netfilter` is not loaded, so host conntrack
never sees bridged agent-to-sandbox traffic on `sandbox-br`; a conntrack
probe is dead too. **Verified:** `lxc exec c -- cat /proc/net/tcp
/proc/net/tcp6`, filtered for state `01` on local port `0016`, gives the
established SSH count. So the reaper runs that one exec with a constant
argv. The invariant is therefore not "the broker never execs" but "the
broker never passes agent-supplied data to exec", which is the property that
actually matters.

Be clear about what this defends against. Loopback and self-addressed
connections are excluded, but a session from a sibling sandbox counts, so
an agent that *wants* to keep a sandbox alive can, by SSHing into it from
another one. The reaper exists to clean up forgotten sandboxes, not to
defeat an adversarial agent; the sandbox quota and the project's resource
limits are what bound that case.

### A broken activity signal reaps nothing

If the probe fails for a sandbox, the reaper treats it as active. The
alternative, treating "no signal" as "idle", turns a transient exec failure
into the deletion of every running sandbox within a day. Leaving a few
sandboxes running until an operator notices is far cheaper than destroying
live ones.

### Pending approval suspends the reaper

A sandbox with a queued promotion request is exempt from both reaper stages
until the request is approved or rejected. Without this, a human who takes a
long weekend to approve comes back to a deleted sandbox. Rejection resets
the idle clock so the agent gets a fresh window.

### All LXD mutation happens in the server; the CLI writes intent

`approve`, `reject`, and operator `destroy` write a row; the server polls
for approvals every few seconds and runs the sequence, and the reaper
removes anything marked `deleted`. This keeps exactly one holder of the LXD
credential, one place where container locks exist, and no admin socket or
second privileged process. The cost is a few seconds of latency on
operator commands, which nobody will notice.

### Approval UX: CLI plus an optional webhook

`lxc-broker approve` on the host is the approval mechanism. The only
notification support is an optional `notify_url` — a bare HTTP POST fired
on pending promotions, reaper deletions, and service destruction. A generic
webhook costs one config key and covers [ntfy](https://ntfy.sh),
Slack-compatible endpoints, and home-automation hooks without the broker
growing opinions about any of them. Anything richer is disproportionate for
a security-critical component whose main virtue is being small enough to
audit.

### Host keys are regenerated at first boot and returned by the tools

Clones of one image would otherwise share a host key. Separately, a small
isolated subnet reuses addresses, so the agent's `known_hosts` would produce
mismatch errors on most new sandboxes, and the agent's natural response is
to disable host key checking. Handing it the key up front removes the
incentive. The service copy keeps the sandbox's key, so `describe_service`
returns the same value.

### The broker listens only on the sandbox bridge

Restricting the listener to the isolated bridge means the bearer token never
crosses the LAN, which is what makes plain HTTP acceptable. The consequence
worth stating plainly: the agent container, which holds the broker token and
the LLM API key, is reachable from every sandbox. That is the same exposure
it had on the LAN, but it belongs in the trust-boundary discussion. The same
reasoning is why LXD is bound to the LAN address only and the firewall rules
are required, not advisory.

### Sandbox-to-sandbox reachability: shared bridge, documented trust boundary

All agents on one broker mutually trust each other, and the docs say so
plainly. Multi-container experiments are this repo's founding use case, so
sibling reachability is a feature, not a leak. The homelab deployment this
targets nearly always runs one agent (or several owned by one person), so
cross-agent snooping is a theoretical concern weighed against real network
sprawl. If real multi-tenancy ever matters, LXD network ACLs on the shared
bridge are the escape hatch that doesn't require re-plumbing.

### Quotas count every non-deleted sandbox

Stopped sandboxes count. Disk is the scarce resource, and a stopped sandbox
holds its disk for up to 22 hours. Counting only running sandboxes would let
an agent accumulate ten running plus an unbounded tail of stopped ones. An
agent frees a slot with `destroy`.

### `list_services` is cross-agent

Every agent can list and describe every service; only the owner can destroy
one. Services are on the shared LAN and the shared-trust decision already
puts all agents in one trust domain. Rediscovery is the point of the
registry, and an agent in a fresh conversation may not be the one that built
the service it needs.

### `keep_alive` is the eighth tool

The 2-hour stop kills "start a job, come back in three hours." The
alternative was "promote it," which would train agents to join the LAN for
reasons unrelated to serving traffic. A capped extension costs nothing in
policy surface: it takes no configuration and cannot exceed the operator's
ceiling. The cap keeps the *tool* from expressing "forever"; as the reaper
decision notes, a determined agent has other ways, and quotas bound those.

### Token names are never reused

`token create` refuses any name that has ever had a token, revoked or not,
and any name that collides with an existing service's name prefix. Since
ownership falls out of the name prefix, re-issuing a revoked name would
silently transfer every container it still owns to whoever holds the new
token. A revoked agent's containers are listed as orphans and removed by the
operator.

### Demotion: no — destroy and re-promote

There is no `demote(service)`. Taking a service off the LAN is `destroy`;
replacing one is destroy, rebuild in a sandbox, re-promote. Demotion has
ambiguous semantics that promotion doesn't: LAN clients may hold the DNS
name and IP, the container keeps state accumulated while exposed, and a
"demoted" container is neither a fresh sandbox nor a registered service.
Cheap base images make rebuild the easy path anyway, and the one-way ratchet
preserves a useful invariant: every container on your LAN got there through
a promotion that is still in the registry and the audit log.

### Incus: adapter seam now, second backend later

v1 targets LXD via pylxd, matching the platform the rest of the repo is
tested on. All LXD calls go through one thin adapter so an Incus backend is
a contained change. The REST APIs are near-identical, but the auth and
projects surfaces are drifting, and tracking both from day one doubles the
test burden on the security-critical component before there is a single
user of either.
