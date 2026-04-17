# Host setup

Tested on Ubuntu 22.04 with LXD installed via snap. The instructions should work on any Linux distro with LXD or [Incus](https://linuxcontainers.org/incus/) (the community fork), but package names and paths may differ.

Set up the host so LXC containers get real LAN IPs and the agent container can manage siblings through the LXD daemon.

## 1. Install LXD

```bash
# Ubuntu (snap — recommended)
sudo snap install lxd

# Debian 13 (trixie) and later
sudo apt install lxd lxd-client

# Debian 12 (bookworm) — use Incus from Zabbly instead:
#   https://github.com/zabbly/incus
# (LXD is Ubuntu-focused; Incus is the community fork with native Debian packages.)

# Arch
sudo pacman -S lxd
```

If using Incus instead of LXD, the CLI commands are the same but the binary is `incus` instead of `lxc`. The rest of this guide uses `lxc` — substitute `incus` as needed.

Initialize with defaults first — we will override networking in step 3:

```bash
sudo lxd init --auto
```

Add your user to the `lxd` group so you can run `lxc` without `sudo`:

```bash
sudo usermod -aG lxd $USER
# Log out and back in for the group change to take effect.
```

## 2. Create a host bridge

The bridge connects containers to the LAN so they get real IPs from your DHCP server. These instructions use NetworkManager. Adjust for your network manager (netplan, systemd-networkd, or raw ip/bridge commands).

Replace the placeholders:

- `YOUR_PHYSICAL_INTERFACE` — e.g. `eno1`, `enp3s0`
- `YOUR_BRIDGE_NAME` — e.g. `br0`

```bash
# Create the bridge
sudo nmcli connection add type bridge ifname YOUR_BRIDGE_NAME con-name YOUR_BRIDGE_NAME \
    ipv4.method auto ipv6.method auto

# Enslave the physical interface
sudo nmcli connection add type bridge-slave ifname YOUR_PHYSICAL_INTERFACE master YOUR_BRIDGE_NAME

# Bring up the bridge
sudo nmcli connection up YOUR_BRIDGE_NAME
```

Verify:

```bash
ip addr show YOUR_BRIDGE_NAME
# should show an IP from your DHCP server
```

For other network managers, see:
- netplan: <https://netplan.io/examples/#bridging>
- systemd-networkd: <https://wiki.archlinux.org/title/Network_bridge#systemd-networkd>

## 3. Configure the LXD default profile

Point LXD at your bridge so containers get LAN IPs.

```bash
lxc profile device set default eth0 parent YOUR_BRIDGE_NAME
```

Confirm:

```bash
lxc profile show default
# eth0 should have parent: YOUR_BRIDGE_NAME
```

## 4. Expose LXD on the network

LXD only listens on the local unix socket by default. Containers need TCP to add the host as a remote.

```bash
lxc config set core.https_address YOUR_HOST_IP:8443
```

Find your bridge IP:

```bash
ip -4 addr show YOUR_BRIDGE_NAME | grep inet
```

## 5. Firewall

LXD on port 8443 gives full container management access. Restrict it to the LAN only.

```bash
# ufw example — adjust the subnet to match your LAN
sudo ufw allow from 192.168.1.0/24 to any port 8443
sudo ufw deny 8443
sudo ufw reload
```

## 6. UID mapping

If you plan to mount a host directory into the container (e.g. a workspace), you need UID mapping. Without it, container UID 1000 maps to host UID 1001000 and mounted files appear owned by `nobody`.

Set `raw.idmap` **before** starting the container for the first time (or stop/start after setting it):

```bash
lxc launch images:debian/trixie mycontainer \
    --config raw.idmap="both 1000 1000"
```

Or on an existing container:

```bash
lxc config set mycontainer raw.idmap "both 1000 1000"
lxc restart mycontainer
```

This maps container UID/GID 1000 to host UID/GID 1000.

## 7. Resize the root disk (if needed)

The default root disk is small. The root device is inherited from the default profile, so you must use `override`, not `set`:

```bash
lxc config device override mycontainer root size=40GiB
```

`lxc config device set` will fail with "Cannot be modified for individual instance." After the initial override, subsequent resizes can use `device set`.

## 8. Give the container access to LXD

The container needs a TLS client certificate to talk to the host's LXD daemon. The `lxc remote add` command in older `lxd-client` versions (5.0.x and earlier) doesn't support `--cert`/`--key` flags, so you use a trust password workflow:

```bash
# Generate a client cert inside the container
lxc exec mycontainer -- openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout /root/.config/lxc/client.key \
    -out /root/.config/lxc/client.crt \
    -subj "/CN=mycontainer"

# Trust the cert on the host
lxc file pull mycontainer/root/.config/lxc/client.crt /tmp/client.crt
lxc config trust add-certificate /tmp/client.crt --name mycontainer
rm /tmp/client.crt

# Register the host remote via trust password
lxc config set core.trust_password TEMPORARY_PASSWORD

lxc exec mycontainer -- lxc remote add host https://YOUR_HOST_IP:8443 \
    --accept-certificate --password=TEMPORARY_PASSWORD

lxc config unset core.trust_password
```

Verify from inside the container:

```bash
lxc exec mycontainer -- lxc list host:
```

## 9. Test networking

Create a test container and confirm it gets a LAN IP:

```bash
lxc launch images:debian/trixie test-container
sleep 10
lxc list test-container
# should show a real LAN IP, not 10.x.x.x LXD default
lxc exec test-container -- ping -c 3 YOUR_HOST_IP
lxc delete test-container --force
```

## Next

- [Container setup](container-setup.md) — provisioning with bootstrap scripts or cloud-init
- [Local models](local-models.md) — running llama.cpp on the host
