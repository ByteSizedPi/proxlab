# Homelab architecture

Working plan and the reasoning behind it. Written 2026-07-30.

## Current inventory

| Host | Address | Role |
|---|---|---|
| `jjserver` | `10.0.0.101` LAN, `100.68.211.32` tailnet | Old always-on server. Being retired as a service host → becomes a NAS. |
| `pve` | `10.42.0.50` | Proxmox host (Dell PowerEdge) |
| `pve-prod` | `10.42.0.205` | VM running Docker + Komodo. The new service host. |
| `adguard` | `10.42.0.192` | DNS + ad blocking |
| `pve-tailscale-lxc` | `100.78.160.15` | Subnet router for `10.42.0.0/24`, exit node |
| `jj-laptop` | `100.107.4.99` | Workstation |

Domain: `jjventer.co.za`, registered at Truehost, DNS not yet configured.

**Two subnets already exist and this matters:** the home LAN is `10.0.0.0/24`,
the Proxmox bridge is `10.42.0.0/24`. LAN clients have no route to the bridge.
Reachability there comes only from the Tailscale subnet router.

## Constraints that shape everything

- **`pve-prod` is not always on.** The PowerEdge is loud, lives in a bedroom,
  is tethered to the laptop over ethernet, and gets shut down nightly. A
  permanent home and a new router are months away, blocked on money.
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

The worry was that AdGuard's rewrites (`proxmox.admin...` → `10.42.0.50`)
mean AdGuard can't also be the LAN ad blocker, because that would "expose
admin services".

**DNS is not access control.** Resolving a name to `10.42.0.50` grants
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

⚠️ **Never enable it on `jj-laptop`.** The laptop is physically attached to
`10.42.0.0/24` via `enp0s31f6` and is `10.42.0.1`, the subnet's gateway.
Accepting the route installs `10.42.0.0/24 dev tailscale0` into Tailscale's
policy table 52, and rule `5270: lookup 52` is consulted before
`32766: lookup main` — so the physical route is never used.

The symptom is confusing: the Proxmox box keeps LAN connectivity but loses
all internet. Outbound works (VM → laptop → masquerade → wifi), but the
laptop returns replies via `tailscale0` instead of `enp0s31f6`, so the NAT
return path is silently dropped. AdGuard then appears broken too — it
answers local rewrites instantly but times out on anything needing upstream,
because its queries leave and the answers never come back.

Rule: **any machine physically on a subnet must not accept a tailnet route
for that subnet.** Since the PowerEdge is tethered to the laptop, there is
no case where the laptop is away yet still needs to reach `10.42.0.x`.

```sh
sudo tailscale set --accept-routes=false     # on jj-laptop
ip route get 10.42.0.205                     # must show dev enp0s31f6
```

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
