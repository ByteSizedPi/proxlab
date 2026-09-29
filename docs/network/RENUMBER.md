# Renumber the room LAN: 10.42.0.0/24 to 10.77.0.0/24

Written 2026-09-29. **Not done yet.** Delete this line when the cutover is
complete.

## Why

`10.42.0.0/24` is NetworkManager's default subnet for `ipv4.method=shared`
and for the Wi-Fi hotspot. Any Linux machine that shares a connection makes
itself `10.42.0.1`, which is the AX10's address. This collision happened twice:

- 2026-08-16: `pe-share` on jj-laptop started on cable carrier.
- 2026-09-29: Noctalia started `pe-share` by hand. jjlink lost all internet
  on the laptop, because traffic to `10.42.0.1` and `10.42.0.12` went to an
  unplugged port.

`pe-share` is deleted (see `~/dotfiles/SYSTEM.md`). The subnet move makes the
collision impossible on every device, not only this laptop.

`10.77.0.0/24` avoids every default in this setup:

| Range | Used by |
|---|---|
| `10.0.0.0/24` | upstream router (`17 Mozart`, `10.0.0.254`), jjserver |
| `10.42.x.x` | NetworkManager shared mode and hotspot |
| `172.17.0.0/16` to `172.29.0.0/16` | Docker bridges on pve-prod (checked 2026-09-29) |
| `192.168.0.x`, `192.168.1.x` | most consumer routers |
| `100.64.0.0/10` | Tailscale |

Only the third octet changes. The host numbers stay the same, so the
addressing plan in `docs/ARCHITECTURE.md` keeps its shape.

| Host | Before | After | Where the address is set |
|---|---|---|---|
| AX10 | `10.42.0.1` | `10.77.0.1` | AX10 web UI |
| `pve` | `10.42.0.10` | `10.77.0.10` | `/etc/network/interfaces`, `/etc/hosts` |
| `pve-prod` | `10.42.0.11` | `10.77.0.11` | `/etc/netplan/50-cloud-init.yaml` |
| `adguard` (LXC 100) | `10.42.0.12` | `10.77.0.12` | `pct config 100` on pve |
| `pve-tailscale-lxc` (LXC 101) | `10.42.0.13` | `10.77.0.13` | `pct config 101` on pve |

Tailnet addresses do not change. Everything in the `admin` zone keeps working
through the move, as long as each host has internet.

## What else refers to the old subnet

Checked 2026-09-29.

- **Repo:** 17 files and 101 lines. Two lines are live config:
  `stacks/platform/traefik/dynamic/proxmox.yml` (`url: https://10.42.0.10:8006`)
  and `stacks/platform/traefik/dynamic/adguard.yml` (`url: http://10.42.0.12:80`).
  `tailscale/policy.hujson` names the route in `autoApprovers`. The other
  lines are comments and docs.
- **Jellyfin:** `/mnt/docker-data/appdata/jellyfin/network.xml` holds
  `LocalNetworkSubnets`. This file is the only app config under `CONFIG_ROOT`
  that has a `10.42.0.x` address.
- **AdGuard:** one rewrite, `*.home.jjventer.co.za -> 10.42.0.11`. The admin
  wildcard points at a tailnet address and does not change.
- **LXC 101:** advertises `10.42.0.0/24`, `0.0.0.0/0` and `::/0`.
- **jj-laptop:** `~/.ssh/config`, the `pve` and `pve-prod` aliases. This file
  is not in dotfiles.
- **Komodo:** Core reaches Periphery at `host.docker.internal`. No change.
- **jjserver:** no `10.42` in `/etc/exports`, `/etc/hosts` or `/etc/fstab`.
  Backups go to `10.0.0.101` through the AX10 NAT, which does not change.
- **Not checked:** DHCP reservations on the AX10 (TV, phones), and the iDRAC
  address. Write them down in step 1.

## The problem with the order

The hosts use `10.42.0.1` as their gateway. The moment the AX10 moves, the
hosts lose internet, so Tailscale on them loses its connections and the
`-ts` SSH aliases stop working. If you move the hosts first, the same thing
happens in the other direction.

The bridge: the AX10 is one layer-2 network. A laptop on jjlink can hold a
second, temporary address on the old subnet and reach the hosts directly,
with no router involved. The `ip addr add` in step 3 is runtime only. It does
not change any file and a reboot or a Wi-Fi reconnect removes it.

If that path fails, the fallback for every host is the Proxmox web UI console
on `https://10.77.0.10:8006` (after step 6) or a monitor and keyboard on the
R720.

## Cutover

Do this in daytime with pve and pve-prod on, and with nobody watching
Jellyfin. The household loses DNS for about one minute at step 5.

### 1. Record the current state

1. In the AX10 UI (`http://10.42.0.1`), write down every DHCP reservation and
   the iDRAC address, if the iDRAC has one.
2. Save the LXC 101 prefs:
   `ssh pve 'pct exec 101 -- tailscale debug prefs' > ~/lxc101-prefs.json`

### 2. Move the AX10

1. In the AX10 UI, set the LAN IP to `10.77.0.1`, mask `255.255.255.0`.
2. Set the DHCP pool to `10.77.0.100` to `10.77.0.199`.
3. Set the DHCP DNS servers to `10.77.0.12` and `10.77.0.1`. Keep both. See
   `docs/ARCHITECTURE.md`, "Rejected fix".
4. Save. The AX10 restarts.

### 3. Build the bridge from jj-laptop

1. Connect to jjlink. Confirm an address in `10.77.0.0/24`:
   `ip -4 addr show wlp0s20f3`
2. Add a temporary address on the old subnet:
   `sudo ip addr add 10.42.0.250/24 dev wlp0s20f3`
3. Confirm the hosts answer: `ping -c1 10.42.0.10` and `ping -c1 10.42.0.11`.

If the pings fail, the AX10 isolates Wi-Fi clients. Plug a cable into an AX10
LAN port and add the same address on `enp0s31f6` instead.

### 4. Move pve-prod

1. `ssh jj@10.42.0.11`
2. Edit `/etc/netplan/50-cloud-init.yaml`. Change three values:
   `10.42.0.11/24` to `10.77.0.11/24`, `via: 10.42.0.1` to `via: 10.77.0.1`,
   and `[10.42.0.12]` to `[10.77.0.12]`.
3. Run `sudo netplan apply`. The SSH session drops.
4. From the laptop, run `ssh jj@10.77.0.11 'ip -4 route; ping -c1 1.1.1.1'`.
   Expect `default via 10.77.0.1` and a reply.

Do not use `netplan try`. It rolls back unless you confirm in the same
session, and the session dies when the address changes.

### 5. Move the two LXCs

On pve (`ssh root@10.42.0.10`). The MAC addresses are copied from
`pct config` on 2026-09-29. Keep them, or the AX10 sees new devices.

```sh
pct set 101 --net0 name=eth0,bridge=vmbr0,gw=10.77.0.1,hwaddr=BC:24:11:0A:C8:A9,ip=10.77.0.13/24,type=veth
pct set 100 --net0 name=eth0,bridge=vmbr0,gw=10.77.0.1,hwaddr=BC:24:11:5E:1D:23,ip=10.77.0.12/24,type=veth
pct exec 100 -- ip -4 addr show eth0
pct exec 101 -- ip -4 addr show eth0
```

If an LXC still shows `10.42.0.x`, run `pct reboot <id>`.

Then check DNS from the laptop:
`dig +short @10.77.0.12 jellyfin.home.jjventer.co.za` must return
`10.42.0.11`. The rewrite changes in step 8.

### 6. Move pve

1. Still on pve. In `/etc/network/interfaces`, change `address 10.42.0.10/24`
   to `address 10.77.0.10/24` and `gateway 10.42.0.1` to `gateway 10.77.0.1`.
2. In `/etc/hosts`, change `10.42.0.10 pve.home pve` to
   `10.77.0.10 pve.home pve`.
3. Run `reboot`. A reboot proves the config survives a boot, and pve-cluster
   reads `/etc/hosts` at start. The reboot also restarts pve-prod and both
   LXCs, which proves their new config too.
4. When it is back, run `ssh root@10.77.0.10 'ip -4 route; pct list; qm list'`.

### 7. Remove the bridge

1. `sudo ip addr del 10.42.0.250/24 dev wlp0s20f3`
2. In `~/.ssh/config`, change `HostName 10.42.0.11` to `10.77.0.11` for
   `pve-prod`, and `10.42.0.10` to `10.77.0.10` for `pve`.
3. Check both paths: `ssh pve hostname`, `ssh pve-ts hostname`,
   `ssh pve-prod hostname`, `ssh pve-prod-ts hostname`.

### 8. Move the names and routes

1. **AdGuard:** change the `*.home.jjventer.co.za` rewrite to `10.77.0.11`.
2. **Cloudflare:** add `A *.home 10.77.0.11`, DNS only. This is the fix from
   `docs/ARCHITECTURE.md`, with the new address.
3. **LXC 101:** change the advertised route. Name the exit node explicitly
   so that it cannot be dropped:
   ```sh
   pct exec 101 -- tailscale set --advertise-routes=10.77.0.0/24 --advertise-exit-node
   pct exec 101 -- tailscale debug prefs | grep -A4 AdvertiseRoutes
   ```
   Expect `0.0.0.0/0`, `::/0` and `10.77.0.0/24`. Compare with
   `~/lxc101-prefs.json` from step 1.
4. **Tailscale console:** approve `10.77.0.0/24` on `pve-tailscale-lxc`. The
   console is the source of truth until `tailscale/policy.hujson` is applied.
5. **Jellyfin:** Dashboard, Networking, LAN networks. Replace `10.42.0.0/24`
   with `10.77.0.0/24`. Keep `10.0.0.0/24`.
6. **AX10:** create the DHCP reservations from step 1 again.

### 9. Merge the repo change

Merge the `renumber-10.77` branch into `main`. Komodo pulls it within 15
minutes, and Traefik's file provider reloads `proxmox.yml` and `adguard.yml`.

⚠️ Do not merge before step 6. Traefik would then send Proxmox and AdGuard
traffic to addresses that do not exist yet.

### 10. Verify

```sh
dig +short @10.77.0.1  jellyfin.home.jjventer.co.za    # 10.77.0.11 (Cloudflare)
dig +short @10.77.0.12 jellyfin.home.jjventer.co.za    # 10.77.0.11 (AdGuard)
curl -so /dev/null -w '%{http_code}\n' https://proxmox.admin.jjventer.co.za/   # 200
curl -so /dev/null -w '%{http_code}\n' https://adguard.admin.jjventer.co.za/   # 200 or 302
curl -so /dev/null -w '%{http_code}\n' https://jellyfin.home.jjventer.co.za/   # 302
ssh pve-prod 'tailscale ping -c1 pve'                  # direct
```

Then play something on the TV, and use the exit node once from the phone.

## Rollback

Each step reverses with the same edit and the old values. The AX10 is the
pivot. If you move the AX10 back to `10.42.0.1`, use the same bridge in
reverse: `sudo ip addr add 10.77.0.250/24 dev wlp0s20f3`.
