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

```
*.admin.jjventer.co.za    infrastructure, tailnet only, never in public DNS
                          proxmox, adguard, komodo, *arr, anything only I use

*.jjventer.co.za          public services, resolves to the VPS
                          jellyfin, and whatever else gets shared
```

Splitting on the `admin.` label rather than per-service means the boundary is
structural: a name either has it or it doesn't, and there's no per-service
decision to get wrong later.

## DNS: correcting a wrong assumption

The worry was that AdGuard's rewrites (`proxmox.admin...` → `10.42.0.10`)
mean AdGuard can't also be the LAN ad blocker, because that would "expose
admin services".

**DNS is not access control.** Resolving a name to `10.42.0.10` grants
nothing to a client with no route to `10.42.0.0/24` — and LAN clients on
`10.0.0.0/24` have no such route. What leaks is *information* (internal
hostnames and private IPs), not access.

And if the network were flat, removing the rewrites would protect nothing
anyway — anyone could port-scan the subnet. The control is the network
boundary and Tailscale ACLs, never the absence of a DNS record.

So: keep AdGuard as the LAN ad blocker, keep the rewrites. Optionally add
Tailscale split-DNS (`admin.jjventer.co.za` → AdGuard) so tailnet clients
resolve admin names wherever they are. AdGuard rewrites are global rather
than per-client, so genuinely hiding the names would need a second resolver —
not worth it for an information leak of this size.

### `--accept-routes` — on for remote devices, OFF for the laptop

`tailscale status` warns that peers advertise routes while `--accept-routes`
is false. Enable it on the **phone and any remote device** — that's how they
reach `10.42.0.0/24`.

⚠️ **Do not enable it on `jj-laptop` while it is at home.** The laptop is
directly on `10.42.0.0/24` — now as an ordinary WiFi DHCP client
(`wlp0s20f3`, currently `10.42.0.145`) rather than as the gateway. Accepting
the route installs `10.42.0.0/24 dev tailscale0` into Tailscale's policy table
52, and rule `5270: lookup 52` is consulted before `32766: lookup main`, so the
physical route is never used.

Rule: **any machine physically on a subnet must not accept a tailnet route for
that subnet.**

```sh
tailscale debug prefs | grep RouteAll        # must be false at home
ip route get 10.42.0.11                      # must show dev wlp0s20f3
```

**When the laptop is away, it mostly does not need the route anyway.** `pve`
and `pve-prod` are tailnet nodes in their own right since 2026-08-06, so
`ssh pve-ts` and `ssh pve-prod-ts` reach them from anywhere with
`--accept-routes` still off. Only LAN-only devices — `adguard`, the router
itself — need the subnet route, and that is the one case worth turning it on
for, then off again on returning home.

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
