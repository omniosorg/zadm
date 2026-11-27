# zadm user guide

This guide covers zadm 0.15.7. The command reference is the man page
(`zadm man`). Attribute lists for the installed version are printed by
`zadm doc -b <brand>`.

## Contents

- [Overview](#overview)
- [Installation and files](#installation-and-files)
- [Quick start](#quick-start)
- [Editing a configuration](#editing-a-configuration)
- [Common tasks](#common-tasks)
- [Images](#images)
- [Console and VNC](#console-and-vnc)
- [Firewall](#firewall)
- [Snapshots and rollback](#snapshots-and-rollback)
- [Moving a virtual machine disk](#moving-a-virtual-machine-disk)
- [Command summary](#command-summary)
- [Attribute reference](#attribute-reference)
- [Global configuration file](#global-configuration-file)
- [Troubleshooting](#troubleshooting)
- [Known limitations](#known-limitations)

## Overview

`zadm` creates, configures and operates OmniOS zones. The configuration of a
zone is one document, JSON by default, which `zadm` translates to `zonecfg`
settings. ZFS volumes and VNICs named in the document are created on demand.

`zadm` runs in the global zone only. Changing zones requires root or
equivalent privileges.

Brands with their own support in `zadm`:

| Brand | Purpose | Image for `create` |
|---|---|---|
| `bhyve` | Virtual machine | optional |
| `kvm` | Virtual machine (QEMU/KVM) | optional |
| `emu` | Virtual machine emulating another architecture | optional |
| `lx` | Linux userland | required |
| `illumos` | Other illumos distributions, SmartOS images | required |

The other installed brands, for example `ipkg`, `lipkg`, `sparse` and
`pkgsrc`, are handled with the generic attributes.

`zadm brands` lists the available brands and shows which are installed.
`zadm` offers to install a missing brand when a zone of that brand is created.
Without a terminal on standard input it installs the brand without asking.

## Installation and files

On OmniOS, `zadm` is the package `ooce/util/zadm` from the OmniOS extra
repository:

```sh
pkg install ooce/util/zadm
```

Building from source is described in the [README](../README.md).

Paths of the OmniOS package:

- `/etc/opt/ooce/zadm/zadm.conf`: Optional global configuration file.
- `/etc/opt/ooce/zadm/zadm.conf.dist`: Sample configuration file.
- `/var/opt/ooce/zadm/cache`: Downloaded images and image indexes.

The parent directory of a zone path must be the mount point of a ZFS dataset.
The default zone path is `/zones/<zone_name>`. To prepare it:

```sh
zfs create -o mountpoint=/zones rpool/zones
```

### Dataset layout

A uniform layout makes it clear which dataset belongs to which zone and which
ones a backup job has to cover. One possible layout:

| Dataset | Content |
|---|---|
| `<pool>/zones` | Zone paths |
| `<pool>/vm/<zone>/<disk>` | Volumes of virtual machines |
| `<pool>/vm-volatile/<zone>/<disk>` | Volumes excluded from backup |
| `<pool>/appdata/<application>/<zone>` | Application data |
| `<slow pool>/database-backups/<database>/<zone>` | Database dumps |

## Quick start

### A native zone

```sh
zadm create -b lipkg web01      # opens an editor with a default configuration
zadm start web01
zadm console web01              # first boot messages; leave with ~.
zadm login web01
```

### A Linux zone

```sh
zadm list-images -b lx
zadm create -b lx -i <uuid> linux01
zadm start linux01
zadm login linux01
```

### A bhyve virtual machine from an ISO image

```sh
zadm create -b bhyve vm01
```

In the editor, add the installation medium:

```json
"cdrom" : [ "/data/iso/installer.iso" ]
```

Then start the machine and connect with a browser:

```sh
zadm start vm01
zadm webvnc vm01                # http://127.0.0.1:8000
```

Remove the `cdrom` entry with `zadm edit vm01` after the installation.

### Removal

```sh
zadm stop web01
zadm list web01                 # wait for the status "installed"
zadm delete web01               # uninstalls and deletes the zone
```

`stop` returns before the shutdown is complete. `delete` refuses a running zone
and does nothing while the zone is still shutting down.

`delete` passes `-F` on to `zoneadm` and `zonecfg` when `-f` is given. `zadm`
itself does not destroy ZFS volumes of virtual machines or VNICs it created.
Check for leftovers with `zfs list -t volume` and `dladm show-vnic`.

## Editing a configuration

`zadm edit <zone>` opens the configuration in the editor named by `VISUAL`,
then `EDITOR`, then `/usr/bin/vi`.

- A changed file is validated and applied when the editor exits.
- An unchanged file leaves an existing zone as it is. For a new zone, `zadm`
  asks whether to create it with the defaults.
- After an error, `zadm` prints the message and asks whether to retry. Answering
  `n` restores the previous configuration of an existing zone. A new zone may
  be left partly configured; remove it with `zadm delete`.
- An attribute removed from the document is removed from the zone. An attribute
  with a default is set to the default.
- The document must contain `brand`. Without it, `brand` is set to `lipkg`, which
  is an error for a zone of another brand.
- The brand cannot be changed. `zonename`, `zonepath` and `ip-type` are ignored
  once the zone is installed.
- The changes are written to the zone configuration. Boot the zone again to
  make sure that they are in effect.

**ZFS volumes and VNICs are created, and volumes enlarged, during validation.**
They remain if a later check fails or the retry question is answered with `n`.

### Document format

Values are strings. Booleans accept `true`, `false`, `on`, `off`, `yes`, `no`,
`1` and `0` unless stated otherwise.

```json
{
   "zonename" : "vm01",
   "zonepath" : "/zones/vm01",
   "brand" : "bhyve",
   "ip-type" : "exclusive",
   "autoboot" : "true",
   "limitpriv" : "default",
   "ram" : "4G",
   "vcpus" : "2",
   "bootdisk" : {
      "path" : "rpool/vm01/root",
      "size" : "20G",
      "sparse" : "false",
      "blocksize" : "8k"
   },
   "net" : [
      {
         "physical" : "vm010",
         "global-nic" : "igb0"
      }
   ]
}
```

Three kinds of attributes exist:

- A property is a plain value: `"ram" : "4G"`.
- A resource is an object: `"bootdisk" : { ... }`.
- A resource array is a list of objects: `"net" : [ { ... }, { ... } ]`.

YAML and TOML are available through the `format` setting of the
[global configuration file](#global-configuration-file).

### Single values

```sh
zadm set vm01 ram=8G
zadm set vm01 autoboot=true
zadm set vm01 vnc=on,w=1280,h=1024
zadm show vm01 ram,vcpus
```

`set` works for properties and, on bhyve, for `vnc`. On the global zone it
accepts `cpu-shares` only:

```sh
zadm set global cpu-shares=20
```

### Scripts and templates

Without a terminal on standard input, `create` and `edit` read the complete
document from standard input. The document replaces the configuration; it is
not merged. The zone name in the document must match the command line.

```sh
zadm show vm01 > vm01.json
zadm edit vm01 < vm01.json
zadm create -b bhyve vm02 < vm02.json
```

In this mode no confirmation is requested before an image overwrites a boot
disk.

`create -t <file>` uses a template in place of the built-in defaults. Every
occurrence of `__ZONENAME__` is replaced with the zone name. The file uses the
configured document format and is not merged with the defaults, so it has to
contain all required attributes except `zonename` and `brand`, which `zadm` sets.

```sh
zadm create -b bhyve -t /data/templates/small-vm.json vm03
```

## Common tasks

Each task is a change made with `zadm edit <zone>`.

### Additional disk for a virtual machine

```json
"disk" : [
   { "path" : "rpool/vm01/data0", "size" : "50G", "sparse" : "true" },
   { "path" : "rpool/vm01/data1", "size" : "100G" }
]
```

`path` is the dataset name of a ZFS volume, or the absolute path of an existing
file. A missing volume is created with `size` (10G if omitted), `sparse` and
`blocksize`.

The position in the list is the disk number. To remove a disk without
renumbering the disks after it, replace its entry with `null`:

```json
"disk" : [
   null,
   { "path" : "rpool/vm01/data1", "size" : "100G" }
]
```

The volume of a removed disk is kept.

### Larger disk

Raise `size`. The volume is enlarged; the partition and file system inside the
guest have to be grown separately. Shrinking is refused with a warning.
`sparse` and `blocksize` of an existing volume cannot be changed. Use whole
numbers, for example `1536G` (see [Known limitations](#known-limitations)).

### Network interface

```json
"net" : [
   {
      "physical" : "vm010",
      "global-nic" : "igb0",
      "vlan-id" : "20",
      "mac-addr" : "02:08:20:11:22:33"
   }
]
```

- With `global-nic`, `physical` is the name of a VNIC on that link.
- With `"global-nic" : "auto"`, `allowed-address` is required.
- Without `global-nic`, `physical` is an existing link or VNIC. If it does not
  exist, a persistent VNIC is created over the link named in `over`, or over the
  first suitable link.

A VNIC name consists of letters, digits and underscores and ends with a digit.

### Addresses of a Linux zone

```json
"net" : [
   {
      "physical" : "linux010",
      "global-nic" : "igb0",
      "ips" : [ "192.0.2.10/24" ],
      "gateway" : "192.0.2.1",
      "primary" : "true"
   }
],
"resolvers" : [ "192.0.2.53" ],
"dns-domain" : "example.com"
```

`ips` also accepts `dhcp` and `addrconf`.

### Resource limits

```json
"capped-cpu" : { "ncpus" : "1.5" },
"capped-memory" : { "physical" : "4G", "swap" : "6G" },
"cpu-shares" : "10"
```

`zadm memstat` shows memory use and limits of running zones. Virtual machines
use `ram` and `vcpus`. `vcpus` is a number or a topology such as
`sockets=1,cores=2,threads=2`.

### Directory shared from the global zone

```json
"fs" : [
   {
      "dir" : "/export/data",
      "special" : "/tank/data",
      "type" : "lofs",
      "options" : [ "ro", "nodevices" ]
   }
]
```

For a bhyve guest with 9p support:

```json
"virtfs" : [
   { "name" : "share0", "path" : "/tank/share0", "ro" : "true" }
]
```

`zadm` adds a lofs mount for the path unless the zone has a delegated dataset
containing it or an `fs` entry with the path as `dir`. For the automatic mount
the path must exist.

### Database directories on separate pools

A fast pool holds the database, a slow pool the dumps. The example is for an
`lx` zone running PostgreSQL:

```sh
zfs create -p -o recordsize=16k -o atime=off fast/appdata/postgresql/db01
zfs create -p slow/database-backups/postgresql/db01
```

```json
"fs" : [
   {
      "dir" : "/var/lib/postgresql",
      "special" : "/fast/appdata/postgresql/db01",
      "type" : "lofs"
   },
   {
      "dir" : "/database-backups",
      "special" : "/slow/database-backups/postgresql/db01",
      "type" : "lofs"
   }
]
```

`special` is the mount point of the dataset and starts with `/`. `type` is
required.

### Delegated dataset

```json
"dataset" : [ { "name" : "tank/zones/web01" } ]
```

To share a delegated dataset with a bhyve guest through `virtfs`, set
`zoned=on` on the dataset and list it in both places:

```sh
zfs set zoned=on tank/share1
```

```json
"dataset" : [ { "name" : "tank/share1" } ],
"virtfs" : [ { "name" : "share1", "path" : "/tank/share1" } ]
```

### cloud-init for a bhyve or emu guest

```json
"cloud-init" : "on",
"sshkey" : "/root/.ssh/id_rsa.pub",
"password" : "secret",
"resolvers" : [ "192.0.2.53" ],
"dns-domain" : "example.com"
```

A plain-text `password` is stored as a SHA-512 hash. An absolute path is kept
as a path. `cloud-init` also accepts a file path or an HTTP(S) URL.

### Windows guest with VirtIO drivers

Attach the Windows installation medium and the VirtIO driver medium:

```json
"cdrom" : [
   "/data/iso/windows-server.iso",
   "/data/iso/virtio-win.iso"
]
```

With `"diskif" : "virtio"`, the setup program needs the `viostor` driver to find
the disk. In the recovery command prompt, with the driver medium as drive `D:`
and Windows Server 2019:

```
drvload D:\amd64\2k19\viostor.inf
```

The directory name depends on the Windows version.

### Boot order of a bhyve machine

```json
"bootorder" : [ "cdrom0", "bootdisk", "net0=pxe" ]
```

Boot devices are `bootdisk`, `disk<n>`, `cdrom<n>`, `net<n>` (optionally with
`=pxe` or `=http`), `path<n>`, `boot<n>` and `shell`. The legacy values `cd` and
`dc` are accepted.

For the next boot only:

```sh
zadm set vm01 bootnext=cdrom0
zadm start -m vm01              # one-time boot menu
```

The menu requires UEFI boot and a persistent UEFI variable store. `zadm
efireset vm01` deletes the UEFI variables of a stopped machine.

### PCI pass-through for bhyve

```json
"ppt" : [ { "device" : "ppt0", "state" : "on" } ]
```

The device must be listed by `pptadm list -a`. `state` also accepts `slot0` to
`slot7`.

## Images

```sh
zadm list-images                          # all images
zadm list-images -b bhyve --verbose       # one brand, with descriptions
zadm list-images -p smartos --refresh     # one provider, fresh index
zadm pull <uuid>                          # download without creating a zone
zadm vacuum -d 14                         # drop images unused for 14 days
```

Providers are `omnios`, `omnios-us`, `proxmox` and `smartos`. Indexes are
refreshed when older than one day. `kvm` and `bhyve` images are interchangeable.

`create -i` and `install -i` accept:

- Any part of a UUID that identifies exactly one image. `list-images` prints the
  last eight characters.
- The path of a local image file.
- An `http://` or `https://` URL.

Images from a provider are verified against the checksum in the provider index.
Local files and URLs are not verified.

For virtual machines the image is written to the boot disk, after confirmation,
and the volume is then set to the configured `size`. Set `size` to at least the
size of the image. The boot disk must not have snapshots.

`install` sets up a zone that is configured only. `install -f` first uninstalls
an installed zone, which destroys its contents.

## Console and VNC

```sh
zadm console vm01
zadm start -c vm01              # start and attach
```

The default escape sequence is `~.`. It is set with `escape_char` in the global
configuration file or with `-e <char>`.

VNC for `bhyve`, `kvm` and `emu`:

```sh
zadm set vm01 vnc=on            # takes effect at the next boot
zadm vnc vm01                   # VNC client, 127.0.0.1:5900
zadm vnc 5901 vm01
zadm webvnc vm01                # browser, 127.0.0.1:8000
zadm vnc -w 127.0.0.1:8080 vm01
```

The proxy runs until interrupted with Ctrl-C. An address of `*` listens on all
addresses. The proxy adds neither encryption nor authentication, so keep it on
the loopback address and tunnel from a workstation:

```sh
ssh -L 8000:127.0.0.1:8000 root@omnios.example.com
```

A password for bhyve is set with the `password` member of `vnc`. It is stored in
plain text unless it is a file path.

## Firewall

`fw` manages the IP Filter rules of a zone from the global zone. It is available
for all brands except `kvm` and `emu`.

```sh
zadm fw web01                   # show loaded rules
zadm fw -e ipf web01            # edit IPv4 rules, then reload
zadm fw -e ipf6 web01
zadm fw -e ipnat web01
zadm fw -r web01                # reload and enable
zadm fw -d web01                # disable until reload or zone reboot
zadm fw -m web01                # log in real time
zadm fw -t web01                # state table
```

The rules are stored in `ipf.conf`, `ipf6.conf` and `ipnat.conf` in
`<zonepath>/etc`. Without a terminal, `fw -e` reads the file from standard input.
After `-e`, the rules are reloaded if the file changed. Apart from editing, `fw`
does nothing and prints nothing for a zone that is not running.

## Snapshots and rollback

```sh
zadm snapshot vm01              # list
zadm snapshot vm01 before-upgrade
zadm stop vm01
zadm list vm01                  # wait for the status "installed"
zadm rollback vm01 before-upgrade
zadm snapshot -d vm01 before-upgrade
```

- For `bhyve`, `kvm` and `emu`, a snapshot covers the boot disk only. Additional
  disks are not included.
- `rollback` is available for `bhyve`, `kvm`, `emu` and `lx`. For all other brands
  `zadm` prints a warning and does nothing. Zones with boot environments, for
  example `lipkg`, use `beadm` inside the zone.
- `rollback -r` destroys all snapshots newer than the given one. Without it,
  only the latest snapshot can be restored.
- Only snapshots with the configured prefix (`zadm__`) are listed.

## Moving a virtual machine disk

A disk can be copied to a raw image, for example for another hypervisor. Shut the
machine down to get a consistent copy of all disks, then copy each volume from a
snapshot:

```sh
zadm stop vm01
zadm list vm01                  # wait for the status "installed"
zadm snapshot vm01 move
dd if=/dev/zvol/rdsk/rpool/vm01/root@zadm__move of=/data/vm01-root.img bs=4M
zadm snapshot -d vm01 move
```

`zadm snapshot` covers the boot disk only. For additional disks use
`zfs snapshot`.

## Command summary

| Command | Effect |
|---|---|
| `create -b <brand> [-i <image>] [-t <template>] <zone>` | Create and install a zone |
| `edit <zone>` | Edit the configuration |
| `set <zone> <property>=<value>` | Change one property |
| `show [<zone> [<property>,...]]` | Print the configuration |
| `install [-f] [-i <image>] <zone>` | Install a configured zone |
| `uninstall [-f] <zone>` | Uninstall a zone, keep its configuration |
| `delete [-f] <zone>` | Uninstall and delete a zone |
| `list [-H] [-F json\|yaml\|toml] [-b <brand>] [-s <state>] [<zone>]` | List zones |
| `memstat` | Memory use of running zones |
| `start [-c] <zone>`, `boot` | Start; `-m` shows the bhyve boot menu |
| `stop [-c] <zone>`, `shutdown` | Shut down |
| `restart [-c] <zone>`, `reboot` | Shut down and start |
| `poweroff <zone>`, `halt` | Stop without shutdown |
| `reset [-c] <zone>` | Power off and start; hardware reset for virtual machines |
| `login <zone>` | Log in to a running zone (not bhyve, kvm, emu) |
| `console <zone>` | Attach to the console |
| `log <zone>` | Show the boot log |
| `fw <zone>` | Manage the firewall (not kvm, emu) |
| `snapshot [-d] <zone> [<name>]` | List, create or destroy snapshots |
| `rollback [-r] <zone> <name>` | Restore a snapshot |
| `list-images`, `pull`, `vacuum` | Manage images |
| `brands` | List brands |
| `doc [-b <brand>] [-a <attribute>]` | Describe attributes |
| `help [-b <brand>]`, `man`, `version` | Help, man page, version |
| `vnc [-w] [[<addr>:]<port>] <zone>`, `webvnc` | VNC proxy (bhyve, kvm, emu) |
| `nmi <zone>` | Send an NMI (bhyve, kvm, emu) |
| `efireset <zone>` | Delete the UEFI variables (bhyve) |
| `monitor <zone>` | QEMU monitor (kvm, emu) |
| `updateres -i <uuid> <zone>` | Download the image resources again (emu) |

## Attribute reference

"Required" attributes must be present unless a default is listed.

### All brands

| Attribute | Description |
|---|---|
| `zonename` | Zone name. Required |
| `zonepath` | Path of the zone. Required |
| `brand` | Brand. Set to `lipkg` if missing from the document |
| `ip-type` | `exclusive` (default) or `shared` |
| `autoboot` | Start the zone at system boot |
| `bootargs` | Boot arguments |
| `limitpriv` | Privilege limit. Default `default` |
| `pool` | Resource pool |
| `hostid` | Emulated host identifier. Not supported by `lx` |
| `scheduling-class` | Scheduling class |
| `cpu-shares` | Fair Share Scheduler shares |
| `max-lwps`, `max-processes` | Limits on LWPs and processes |
| `max-msg-ids`, `max-sem-ids`, `max-shm-ids`, `max-shm-memory` | System V IPC limits |
| `fs-allowed` | Comma-separated list of additional mountable file systems |
| `dns-domain` | DNS search domain. Not supported by `kvm` |
| `resolvers` | Array of DNS server addresses. Not supported by `kvm` |
| `capped-cpu` | `ncpus` |
| `capped-memory` | `physical`, `swap`, `locked` |
| `dedicated-cpu` | `ncpus`, `importance` |
| `security-flags` | `lower`, `default`, `upper` |
| `net` | Array of network interfaces, see below |
| `fs` | Array of `dir`, `special`, `type` (`lofs` or `zfs`), `raw`, `options` |
| `dataset` | Array of `name` |
| `device` | Array of `match` |
| `attr` | Array of `name`, `type`, `value` |
| `admin` | `user`, `auths` |

`rctl` resources are not supported. Use the property of the same purpose, for
example `max-lwps`, or `zonecfg`.

### Network interface members

| Member | Description |
|---|---|
| `physical` | Interface name. Required |
| `global-nic` | Link in the global zone, or `auto` |
| `over` | Link for a VNIC created by `zadm` |
| `vlan-id` | VLAN, 1 to 4094 |
| `mac-addr` | MAC address |
| `address` | Address in CIDR notation |
| `allowed-address` | Address the zone may use, in CIDR notation |
| `defrouter` | Default router |
| `ips`, `gateway`, `primary` | `lx` only |
| `netif`, `mtu`, `vqsize`, `feature_mask`, `backend` | `bhyve` only |
| `promiscrxonly`, `promiscphys`, `promiscsap`, `promiscmulti` | `bhyve` only |

### lx

| Attribute | Description |
|---|---|
| `kernel-version` | Reported kernel version. Default from the image, else `4.4` |
| `ipv6` | `true` or `false` |

### bhyve, kvm and emu

| Attribute | Description |
|---|---|
| `bootdisk` | Boot disk, see below |
| `disk` | Array of disks, see below |
| `cdrom` | Array of ISO image paths |
| `ram` | Memory, for example `4G`. Default `1G`; new zones are offered `2G` |
| `vcpus` | Processors or topology. Default `1`; new zones are offered `4` |
| `bootorder` | Boot order. bhyve: array of devices. kvm and emu: letters, default `cd` |
| `diskif` | Disk interface. Default `nvme` (bhyve), `virtio` (others) |
| `netif` | Network interface type. Default `virtio` |
| `vnc` | VNC. For `kvm` and `emu`: boolean or `unix=<path>`, default `off`; new zones are offered `on` |
| `console` | Console device |
| `type` | `generic` (default), `windows` or `openbsd` |
| `extra` | Array of additional hypervisor arguments |
| `vga` | `on`, `off` or `io` |
| `cpu` | `kvm`: CPU type and features. `emu`: CPU to emulate, required |
| `arch` | `emu` only: architecture. Required |
| `cloud-init`, `password`, `sshkey`, `rng` | `bhyve` and `emu` only |

### Disk members

| Member | Description |
|---|---|
| `path` | ZFS volume or absolute file path. Required |
| `size` | Whole number with suffix `b`, `k`, `m`, `g`, `t`, `p` or `e` |
| `blocksize` | Power of two from `512` to `128k` |
| `sparse` | Create a sparse volume |
| `serial` | Up to 20 characters: upper-case letters, digits, `-` |

Additional members for `bhyve`:

| Member | Description |
|---|---|
| `diskif` | Interface of this disk |
| `ro` | Read-only |
| `nocache`, `sync`, `direct` | Caching and synchronous writes |
| `nodelete` | Disable TRIM |
| `sectorsize` | Logical or logical/physical size, for example `512/4096` |
| `ser` | Serial number |
| `maxq`, `qsz`, `ioslots`, `sectsz`, `eui64`, `dsm` | NVMe tuning |

### bhyve

| Attribute | Description |
|---|---|
| `acpi` | Generate ACPI tables. Default `on` |
| `bootnext` | Device for the next boot only |
| `bootrom` | Boot ROM. Default `BHYVE` |
| `uefivars` | Persistent UEFI variables. Default `on` |
| `hostbridge` | `i440fx` (default), `q35`, `amd`, `netapp`, `none` or `vendor=<id>,device=<id>` |
| `memreserve` | Keep memory allocated while the zone is down |
| `xhci` | USB tablet. Default `on` |
| `ppt` | Array of `device`, `state` |
| `virtfs` | Array of `name`, `path`, `ro` |
| `vnc` | `enabled`, `wait`, `unix`, `w`, `h`, `password` |

## Global configuration file

`zadm.conf` is a JSON file. All settings are optional.

```json
{
   "CONFIG"   : { "format" : "json" },
   "CONSOLE"  : {
      "auto_connect"    : "off",
      "auto_disconnect" : "on",
      "escape_char"     : "_"
   },
   "SNAPSHOT" : { "prefix" : "zadm__" },
   "VNC"      : { "bind_address" : "127.0.0.1", "auto_connect" : "on" }
}
```

- `CONFIG.format`: Document format: `json`, `toml` or `yaml`.
- `CONSOLE.auto_connect`: Attach to the console when a zone boots.
- `CONSOLE.auto_disconnect`: Detach when the zone shuts down.
- `CONSOLE.escape_char`: Console escape character.
- `SNAPSHOT.prefix`: Prefix of snapshot names.
- `VNC.bind_address`: Listen address for `vnc` and `webvnc`.
- `VNC.novnc_path`: Directory containing noVNC.
- `VNC.auto_connect`: Connect when the noVNC page opens.

An invalid file stops every `zadm` command that manages zones with an error.

Environment variables:

- `VISUAL`: Editor.
- `EDITOR`: Editor if `VISUAL` is not set.
- `PAGER`: Pager for `zadm log`.
- `__ZADMDEBUG`: Print debug messages, including the commands executed, if set.

## Troubleshooting

- `could not find parent dataset for '...'`: The parent directory of `zonepath`
  is not the mount point of a ZFS dataset.
- `link '...' does not exist or is wrong type`: `global-nic` or `over` names an
  unknown link. `dladm show-link` lists the links.
- `file '...' does not exist, did you mean to configure a zvol?`: A disk path
  starting with `/` refers to a file. Use the dataset name for a volume.
- `destination has snapshots`: Destroy the snapshots of the boot disk before
  installing an image.
- `image UUID containing '...' not found`: Refresh with
  `zadm list-images --refresh` and check the brand.
- `malformed JSON string` from an image command: A stored index is damaged. Run
  `zadm list-images --refresh`.
- `brand cannot be changed`: Create a new zone instead.

More detail:

```sh
zadm log web01
__ZADMDEBUG=1 zadm list
```

## Known limitations

These apply to zadm 0.15.7.

- Argument order: `stop`, `restart` and `reset` expect the zone name before any
  extra console arguments (`zadm stop -c vm01 -d`). `start` and `console` expect
  it last (`zadm start -c -d vm01`).
- Fractions in a disk `size` are cut off: `1.5T` becomes `1T`.
- `zadm set` rejects the value `0`. Use `off` or `false` for booleans.
- Dataset names containing a dot are rejected in `dataset`.
- If one image provider cannot be reached, no image index is updated.
- The index and images of the `proxmox` provider are transferred over
  unencrypted HTTP.
