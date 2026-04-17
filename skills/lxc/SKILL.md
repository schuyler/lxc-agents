---
name: lxc
description: Manage sibling LXC containers from inside a container. Provides create, exec, file transfer, start, stop, and delete operations via the host LXD remote.
---

# LXC Container Skill

Instructions for an LLM agent that has exec access inside an LXC container
and needs to manage sibling containers. The LXD remote name is configured
during container provisioning — replace `<remote>` in the commands below
with the appropriate remote prefix.

## Creating a container

lxc launch images:debian/trixie <remote>:NAME

Wait for it to boot and get a DHCP lease:

lxc list <remote>:

## Running commands inside a container

lxc exec <remote>:NAME -- COMMAND

Examples:

lxc exec <remote>:web -- apt update
lxc exec <remote>:web -- apt install -y nginx

## Pushing files into a container

lxc file push /path/in/workspace <remote>:NAME/path/inside/container

## Pulling files from a container

lxc file pull <remote>:NAME/path/inside/container /path/in/workspace

## Listing containers

lxc list <remote>:

## Stopping a container (keeps disk)

lxc stop <remote>:NAME

## Starting a stopped container

lxc start <remote>:NAME

## Deleting a container

lxc delete <remote>:NAME --force

## Conventions

- Containers are cheap — create freely, delete when done
- Network reachability depends on the host's LXD profile setup
- Default to Debian 13 unless there is a reason to use something else
