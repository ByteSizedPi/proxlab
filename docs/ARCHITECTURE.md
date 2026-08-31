# Homelab architecture

Working plan and the reasoning behind it. Written 2026-07-30.

## Current inventory

Renumbered 2026-08-06 when the TP-Link Archer AX10 replaced the room extender.
See "Addressing plan" below for the scheme and why each host sits where it does.

| Host | Address | Tailnet | Role |
|---|---|---|---|
| `jjserver` | `10.0.0.101` LAN | `100.68.211.32` | Old always-on server. Being retired as a service host → becomes a NAS. |
| AX10 | `10.42.0.1` | — | Router. Gateway and DHCP for `10.42.0.0/24`. |
| `pve` | `10.42.0.10` | `100.65.36.82` | Proxmox host (Dell PowerEdge R720) |
| `pve-prod` | `10.42.0.11` | `100.91.183.47` | VM running Docker + Komodo. The service host. |
| `adguard` | `10.42.0.12` | — | DNS + ad blocking, LXC 100 |
| `pve-tailscale-lxc` | `10.42.0.13` | `100.78.160.15` | Subnet router for `10.42.0.0/24`, exit node, LXC 101 |
| `jj-laptop` | DHCP | `100.107.4.99` | Workstation |

Domain: `jjventer.co.za`, registered at Truehost, DNS not yet configured.

**Two subnets exist and this matters:** the home LAN is `10.0.0.0/24`, the
Proxmox bridge is `10.42.0.0/24`. LAN clients have no route to the bridge.
Reachability there comes only from the Tailscale subnet router.

## Addressing plan

```
10.42.0.1          AX10 - gateway, DHCP server
10.42.0.2  - .9    network gear (spare)
10.42.0.10 - .39   infrastructure, static on the host
10.42.0.40 - .99   future static services
10.42.0.100 - .199 DHCP dynamic pool
10.42.0.200 - .254 DHCP reservations
```

Statics low and contiguous, the dynamic pool high, and no overlap between them.
Before the renumber, `adguard` at `.192` and the tailscale LXC at `.126` both
sat inside the DHCP pool. Nothing had collided yet only because both were
already answering when the router started issuing leases. The next new device
could have been handed either address, and the failure would have looked random.

**Infrastructure gets a host-level static, not a DHCP reservation.** DHCP and
DNS cannot depend on each other. `adguard` serves DNS to the network, so it
cannot wait for a lease to come up, and `pve` must boot without help.
Reservations are for devices whose config you do not control, such as phones,
TVs, and printers.

Addresses live in these places, which is where to look when one is wrong:

| Host | Where its address is set |
|---|---|
| `pve` | `/etc/network/interfaces`, plus the `pve` entry in `/etc/hosts` |
| `pve-prod` | `/etc/netplan/50-cloud-init.yaml` |
| `adguard`, `tailscale` LXCs | `pct config <id>`, on pve. Never inside the container. |

`pve-prod` also carries `/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg`.
Without it, cloud-init rewrites the netplan file back to DHCP on every boot and
the static address silently disappears.

## Getting in when the LAN is broken

`pve` and `pve-prod` both run Tailscale directly, not only through the subnet
router LXC. Reach them by `ssh pve-ts` and `ssh pve-prod-ts`, which resolve over
MagicDNS and do not depend on any LAN address.

This is what makes a re-addressing safe to attempt. Install it *before* changing
anything, not after.

Neither host uses `--accept-routes`. Both sit on `10.42.0.0/24`, which LXC 101
advertises, so accepting that route would send their own LAN neighbours through
the tailnet by way of a container running on themselves.

## Constraints that shape everything

- **`pve-prod` is not always on.** The PowerEdge is loud, lives in a bedroom,
  and gets shut down nightly. A permanent home is still some way off.
  The laptop tether is gone as of 2026-08-06: the AX10 is the gateway now,
  and the laptop is an ordinary DHCP client with no infrastructure role.
- **The ISP won't do inbound.** No port forwarding, so public services need an
  external ingress regardless.
- **Hardware is aging.** jjserver's drives are in variable condition; it stays
  in service until the *arr stack and other migrations land on `pve-prod`.

The uptime constraint is the big one. It rules out promising anything to other
people, and it changes the deploy mechanism (see "Komodo" below).

## Naming scheme

Revised 2026-08-27. Three zones, split on **how a client reaches the host**
rather than on how much the service is trusted.

```
*.admin.jjventer.co.za    -> 100.91.183.47   pve-prod's TAILNET address
                          infrastructure. proxmox, adguard, komodo, *arr.
                          Any device on the tailnet, from anywhere.
                          Never in public DNS.

*.home.jjventer.co.za     -> 10.42.0.11      pve-prod's LAN address
                          things a device WITHOUT Tailscale must reach.
                          The TV, a console, a guest laptop.
                          Only reachable from the AX10 SSID.

*.jjventer.co.za          -> the VPS
                          public services. Still deferred, see below.
```

Splitting on the label rather than per-service keeps the boundary structural:
a name either carries `admin.` or `home.` or neither, and there is no
per-service decision to get wrong later.

### Why the admin zone points at a tailnet address

`pve-prod` runs Tailscale in its own right. Until 2026-08-27 the admin names
still resolved to `10.42.0.11`, its LAN address, which forced every client to
carry the `10.42.0.0/24` subnet route. That route then collided with the
physical path on `jj-laptop` (see the `--accept-routes` section below), and
the workaround was to toggle a flag per SSID.

Addressing a Tailscale host by its tailnet address removes the collision. The
rule this encodes: **a host that runs Tailscale is addressed by its tailnet
address. The subnet router exists only for devices that cannot run Tailscale.**

The `100.x` address is an identity, not a detour. Two peers on the same LAN
connect directly over that LAN. Confirm with `tailscale ping pve-prod`, which
reports `direct` at home and `DERP` only when a network blocks direct UDP.

### Why Jellyfin and Seerr have a name in both zones

These two are the exception. The test is the same for both: **someone other
than JJ uses the service, and that person is not on the tailnet.**

Jellyfin needs the `home` name because the TV cannot run Tailscale, and the
`admin` name for watching from outside the house. A high-bitrate remux on the
LAN should also not pay WireGuard's encryption cost and 1280-byte MTU to cross
a single hop.

Seerr (added 2026-08-31) needs the `home` name because household members
request titles from phones and laptops that are not tailnet members, and the
`admin` name for requesting from mobile data.

Do not copy this pattern by default. The *arr apps, Tdarr, Netdata, Traefik,
Komodo, AdGuard, Proxmox and Immich are single-operator and belong in the
admin zone only. A second router costs nothing to add and everything to
reason about later, so add one only when a real non-tailnet person needs it.

## DNS: correcting a wrong assumption

The worry was that AdGuard's rewrites (`*.home.jjventer.co.za` →
`10.42.0.11`) mean AdGuard can't also be the LAN ad blocker, because that
would "expose admin services".

**DNS is not access control.** Resolving a name to `10.42.0.10` grants
nothing to a client with no route to `10.42.0.0/24`, which is every client
outside the house. What leaks is *information* (internal hostnames and
private IPs), not access.

⚠️ An earlier version of this paragraph said LAN clients sit on
`10.0.0.0/24` and therefore have no route either. That is wrong. Measured
2026-08-31: the AX10 hands out `10.42.0.0/24` and `jj-laptop` holds
`10.42.0.145`. LAN clients are on the same subnet as the services and can
reach them directly. The argument above survives the correction, because it
only ever depended on clients *outside* the house.

And if the network were flat, removing the rewrites would protect nothing
anyway — anyone could port-scan the subnet. The control is the network
boundary and Tailscale ACLs, never the absence of a DNS record.

So: keep AdGuard as the LAN ad blocker, keep the rewrites. AdGuard rewrites
are global rather than per-client, so genuinely hiding the names would need a
second resolver — not worth it for an information leak of this size.

### ⚠️ The AX10 hands out two DNS servers, and the home zone needs one

Found 2026-08-31 while testing `seerr.home.jjventer.co.za`.

DHCP on the AX10 advertises **both** resolvers:

```
Link 3 (wlp0s20f3): 10.42.0.12 10.42.0.1
```

`10.42.0.12` is AdGuard and answers the home zone. `10.42.0.1` is the AX10
itself and returns an empty answer for every `*.home.jjventer.co.za` name.
systemd-resolved picks one server per link and stays with it, so the outcome
is a coin flip made at association time. On `jj-laptop` it picked the router:

```
$ dig +short @10.42.0.12 seerr.home.jjventer.co.za
10.42.0.11
$ dig +short @10.42.0.1  seerr.home.jjventer.co.za
            (empty)
$ getent hosts seerr.home.jjventer.co.za
            NXDOMAIN
```

The admin zone hides the fault. Tailscale installs a routing domain
(`~admin.jjventer.co.za`) on `tailscale0`, which forces admin lookups to
AdGuard's tailnet address no matter what the wifi link does. The home zone has
no such override on purpose — it must resolve on the LAN — so it takes the
full weight of the wrong choice.

**Fix, on the AX10 admin UI at `http://10.42.0.1`:** set the DHCP DNS server
list to `10.42.0.12` **only**. Remove the router's own address.

This is the same change that makes ad blocking work for the whole house. Any
client that picks `10.42.0.1` today bypasses AdGuard entirely, so the filter
lists are being applied to an unknown subset of devices.

Keep a second entry out of the list rather than adding a public resolver as a
fallback. A fallback resolver reintroduces exactly this failure: it answers
fast, it answers wrong for both private zones, and it silently disables
filtering. If AdGuard is down the correct symptom is "no DNS", which is
diagnosable, not "half the names resolve".

### AdGuard must be a tailnet node, not just a LAN address

Tailscale split DNS sends `admin.jjventer.co.za` to AdGuard. Until 2026-08-27
it named `10.42.0.12`, a LAN address, so a client could only resolve admin
names if it also carried the `10.42.0.0/24` route. The resolver had exactly
the problem the services had.

LXC 100 now runs Tailscale, and split DNS names its tailnet address instead.
AdGuard already binds `0.0.0.0:53`, so it serves on `tailscale0` with no
AdGuard-side change.

The container is unprivileged, so it needs `/dev/net/tun` bound in. The two
lines are the same ones LXC 101 has carried since it was built:

```
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
```

Userspace networking mode is not an option here. It does not serve UDP at the
tailnet address, and DNS is UDP.

### `--accept-routes` — OFF everywhere, as of 2026-08-27

`tailscale status` warns that peers advertise routes while `--accept-routes`
is false. Ignore the warning. Leave the flag off on every device.

Once the admin zone resolves to `100.91.183.47` and split DNS points at
AdGuard's tailnet address, no client needs the `10.42.0.0/24` route to reach
a service. The route stays advertised for the handful of boxes that cannot
run Tailscale and have no name in either zone: the AX10 web UI at
`10.42.0.1`, TVs, printers. Turn the flag on for that rare case, then off
again.

The rest of this section records why the flag was a problem, because the same
collision returns the moment a name points at a LAN address again.

#### The old rule, kept for the reasoning

⚠️ **Do not enable it on `jj-laptop` while it is on the AX10 network.** There
the laptop is directly on `10.42.0.0/24` as an ordinary WiFi DHCP client
(`wlp0s20f3`) rather than as the gateway. Accepting the route installs
`10.42.0.0/24 dev tailscale0` into Tailscale's policy table 52, and rule
`5270: lookup 52` is consulted before `32766: lookup main`, so the physical
route is never used.

**The laptop roams between two SSIDs, and this is easy to misread as a
fault.** On the AX10 SSID it gets a `10.42.0.x` address and reaches everything
over the LAN. On the upstream house SSID `17 Mozart` it gets `10.0.0.x` (seen
at `10.0.0.110`, gateway `10.0.0.254`) and has **no route to `10.42.0.0/24`
at all** — `ip route show | grep 10.42` returns nothing. Every LAN alias
(`ssh pve`, `ssh pve-prod`) then hangs, and only `pve-ts` / `pve-prod-ts`
work.

Observed live on 2026-08-16: `ssh pve-prod` succeeded, then began hanging
mid-session after a roam, while the host was healthy the whole time (uptime
10:56). **Check the SSID before diagnosing anything as a server fault.**

Rule: **any machine physically on a subnet must not accept a tailnet route for
that subnet.**

#### The phantom `10.42.0.0/24` on jj-laptop

Found on 2026-08-27, and it made the failure above much harder to read. The
NetworkManager profile `pe-share` on `enp0s31f6` was still **activated** in
`ipv4.method: shared` mode with no cable attached. Shared mode defaults to
`10.42.0.1/24`, so the laptop held the AX10's gateway address and kept a
`linkdown` route for the whole subnet in the main table.

Packets for `10.42.0.x` left a dead interface. DNS queries hung indefinitely
instead of failing. Fixed with `nmcli connection down pe-share`;
`connection.autoconnect` was already `no`. The profile is kept, not deleted,
because it is the tether recovery path if the AX10 fails.

Check for it with `ip route show table main | grep linkdown`.

```sh
tailscale debug prefs | grep RouteAll        # false, everywhere, always
ip route show table main | grep linkdown     # must return nothing
```

**Nothing the laptop uses daily needs the route.** `pve`, `pve-prod`,
`jjserver` and `adguard` are all tailnet nodes in their own right, so
`ssh pve-ts`, `ssh pve-prod-ts` and every `*.admin` name work from anywhere
with `--accept-routes` off. The AX10 web UI at `10.42.0.1` is the only
remaining reason to turn it on, and it is worth turning off again after.

### Historical: why this rule was originally written

Until 2026-08-06 the laptop was the subnet's gateway at `10.42.0.1`, NATing for
the PowerEdge over `enp0s31f6`. Accepting the route then produced a confusing
failure: the Proxmox box kept LAN connectivity but lost all internet. Outbound
worked (VM → laptop → masquerade → wifi), but the laptop returned replies via
`tailscale0` instead of `enp0s31f6`, so the NAT return path was silently
dropped. AdGuard appeared broken too, answering local rewrites instantly while
timing out on anything needing upstream.

That specific failure mode is gone — the laptop no longer NATs for anything.
The rule survives it, for the simpler reason stated above.

## Public ingress: VPS as the single front door

```
        Internet
           │
           ▼
    ┌──────────────┐   public IP, Truehost
    │  VPS         │   Traefik: TLS + auth
    │  + tailscale │   joins the tailnet as a node
    └──────┬───────┘
           │  over the tailnet, not the internet
           ▼
    ┌──────────────┐
    │  pve-prod    │   Traefik → services
    └──────────────┘
```

Public DNS: `*.jjventer.co.za` → VPS public IP. Nothing at home is exposed;
no port forwards; the ISP's stance stops mattering.

This is what replaces "a Cloudflare tunnel per service" — one ingress, one
wildcard cert, one auth layer, N services behind it.

⚠️ **The VPS is the untrusted box.** It's the only thing facing the internet,
so a compromise there must not become full tailnet access. Use Tailscale ACLs
to restrict that node to exactly the hosts and ports it proxies — for example
`pve-prod:443` and nothing else. A tailnet node with default ACLs can reach
everything, which would make the VPS the weakest link and the widest one.

`*.admin.jjventer.co.za` is never in public DNS and never proxied by the VPS.

### Not a Proxmox cluster member

A cloud VPS can't usefully join the Proxmox cluster — clustering wants low
latency and quorum, and a WAN link gives neither. Manage it the same way as
everything else instead: install Komodo Periphery on it and add it as a
second Server in Komodo. Same workflow, same repo, no new tooling.

## Certificates: move DNS to Cloudflare

Admin services are never publicly reachable, so HTTP-01 can never validate
them. That forces DNS-01, which needs an API the ACME client supports.
Truehost is unlikely to offer one.

**Keep the domain registered at Truehost, change the nameservers to
Cloudflare** (free). Traefik then issues wildcard certs for both
`*.jjventer.co.za` and `*.admin.jjventer.co.za` over DNS-01, including for
services that are only ever reachable on the tailnet.

## Komodo: poll, don't webhook — for now

Earlier plan was GitHub webhooks for push-to-deploy. **The uptime constraint
inverts that.**

A webhook fires once. If `pve-prod` is powered off, GitHub retries briefly,
gives up, and that push is missed permanently — nothing reconciles it later.
Polling has no such failure mode: whenever the box boots, it pulls whatever
the current state of `main` is and converges.

So while the box is nightly-off, `KOMODO_RESOURCE_POLL_INTERVAL` is both
simpler and strictly more reliable. Revisit webhooks once it's always-on and
behind the VPS.

## Sequencing

Deliberately ordered to avoid paying for infrastructure ahead of need.

1. **Now** — Komodo on `pve-prod`, tailnet only. Fix `--accept-routes`.
2. **Next** — Cloudflare nameservers, Traefik on `pve-prod`, wildcard cert
   via DNS-01, admin services behind `*.admin.jjventer.co.za`.
3. **Then** — migrate the wanted services off `jjserver`. *arr stack,
   Jellyfin. Everything internal, everything on the tailnet.
4. **Later** — wipe `jjserver`, rebuild as a NAS.
5. **When `pve-prod` is permanently on** — buy the VPS, add public ingress,
   Tailscale ACLs, auth layer. Only then does anything become public.

**Don't buy the VPS yet.** It would be a monthly bill for an ingress to
services that don't exist, fronting a box that's off half the time. The work
in steps 1–3 is unaffected by whether the VPS exists, so it costs nothing to
defer and it keeps the money for hardware.

## Backups: 3-2-1, and what is deliberately not in it

```
copy 1   /mnt/safe on pve-prod        working data, RAID6
copy 2   restic repo on jjserver      second machine, second array (md0)
copy 3   restic repo on Backblaze B2  offsite, EU Central
```

Implementation is `backup/restic-backup.sh`, run by `restic-backup.timer`.

**Media is excluded on purpose.** `/mnt/data` is ~311 GB of movies and series
that are re-downloadable. `/mnt/safe` is the irreplaceable half: camera
originals, photos, documents, laptop backups, app state. Backing up the media
would multiply the offsite bill by twenty for no benefit. See
`jjserver-media-stays-put` for the related decision that jjserver's own 920 GB
library is never migrated either.

**Live databases are dumped, not copied.** A Postgres or Mongo data directory
copied file-by-file is mid-write and restores are a coin flip. Immich is
dumped by the script. Komodo already writes dated dumps to
`/mnt/docker-data/komodo/backups`, so that path is simply included.

**`thumbs/` and `encoded-video/` are excluded.** Immich regenerates both from
the originals. They were 4.5 GB for this library, which is real money on B2
and zero value on restore.

**`Persistent=true` on the timer is load-bearing.** pve-prod's uptime is
irregular, so a plain `OnCalendar=daily` firing at 00:00 would usually be
missed silently. Same reasoning as choosing polling over webhooks above: on a
box with irregular uptime, reconcile-on-wake beats fire-at-an-appointed-time.

**The repository password is the single point of failure.** It lives in
`/etc/restic/password` on pve-prod — the same machine being backed up. A copy
belongs in a password manager. Encrypted backups with no key are not backups.

B2 region is fixed at account creation and cannot be changed. EU Central
(Amsterdam) is the right choice from South Africa: same price as US West,
roughly half the latency.
