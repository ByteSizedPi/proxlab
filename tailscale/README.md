# Tailnet policy

`policy.hujson` is the reviewed copy of the tailnet ACL policy for
`tail2d486a.ts.net`. Nothing applies it automatically. Paste it into
[the admin console](https://login.tailscale.com/admin/acls), or wire up the
GitHub Action at the bottom of this file.

## What the tailnet looks like today

| Node | Tailnet IP | LAN | Role | Tag |
|---|---|---|---|---|
| `pve` | `100.65.36.82` | `10.42.0.10` | Proxmox host | `tag:infra` |
| `pve-prod` | `100.91.183.47` | `10.42.0.11` | Docker service host | `tag:services` |
| `pve-tailscale-lxc` | `100.78.160.15` | `10.42.0.13` | subnet router, exit node | `tag:router` |
| `jjserver` | `100.68.211.32` | `10.0.0.101` | old service host, NAS | `tag:infra` |
| `jj-laptop` | `100.107.4.99` | roams | personal | none, stays user-owned |
| `johans-s25-fe` | `100.103.148.59` | roams | personal | none, stays user-owned |

Already configured and **not** changed by this policy:

- MagicDNS is on tailnet-wide, suffix `tail2d486a.ts.net`.
- Split DNS already routes `admin.jjventer.co.za` to AdGuard at `10.42.0.12`,
  and `jj.home` to jjserver. Note the AdGuard entry points at a LAN address,
  so a device only resolves admin names if it also accepts the
  `10.42.0.0/24` route.
- LXC 101 advertises `10.42.0.0/24`, `0.0.0.0/0` and `::/0`.

## Why three Tailscale nodes and not one

It looks like sprawl and it is not. The rule is: install Tailscale directly
on hosts you administer, and use a subnet router only for things that cannot
run it themselves (the AdGuard LXC, the AX10, TVs, printers).

Each node has a job the others cannot do:

- `pve` is the recovery path. If LXC 101 dies, you still need a way in to fix
  it. Reaching the hypervisor through a container running on the hypervisor
  is a loop.
- `pve-prod` needs its own identity so policy can name it, and so it survives
  LXC 101 being down.
- LXC 101 carries everything that cannot run Tailscale itself.

This was load-bearing on 2026-08-16: `jj-laptop` roamed onto the upstream
`17 Mozart` network, lost every route to `10.42.0.0/24`, and `ssh pve-prod-ts`
kept working because `pve-prod` is a tailnet node in its own right. Collapsing
to a single subnet router would have meant no access at all.

## Rollout order

⚠️ **Order matters, and getting it wrong locks you out.** The policy denies by
default. Applying grants that reference tags *before* the nodes carry those
tags leaves nodes that match no grant.

Phase 1 and 2 below are safe because grant 1 (`autogroup:member` → `*`) does
not depend on any tag. Your own devices keep full access throughout.

### Phase 1 — publish the policy

Paste `policy.hujson` into the admin console and save. Nothing changes yet:
no node carries a tag, so `tagOwners` and `autoApprovers` are inert, and the
grants still let your devices reach everything.

### Phase 2 — tag the nodes

Tagging changes a node's identity, so Tailscale requires re-authentication.
The node briefly drops off the tailnet. These are headless hosts, so use an
auth key rather than a browser login.

Generate one reusable, pre-approved auth key per tag in
**Settings → Keys → Generate auth key**, with the matching tag selected.

⚠️ `tailscale up` resets any flag you do not repeat. LXC 101 advertises
routes and an exit node; omitting those flags silently withdraws them.

Read the current settings first, on every node, and keep the output:

```sh
tailscale debug prefs
```

Then, **in this order**:

```sh
# 1. LXC 101, from pve. Safe to do first: if it drops, pve is still reachable
#    over its own tailnet address and over 10.42.0.10 on the LAN.
pct exec 101 -- tailscale up \
  --authkey=tskey-auth-... \
  --advertise-tags=tag:router \
  --advertise-routes=10.42.0.0/24 \
  --advertise-exit-node \
  --accept-routes=false

# 2. pve-prod. Reachable from pve at 10.42.0.11 if the tailnet path drops,
#    because both sit on 10.42.0.0/24.
tailscale up --authkey=tskey-auth-... --advertise-tags=tag:services --accept-routes=false

# 3. jjserver.
tailscale up --authkey=tskey-auth-... --advertise-tags=tag:infra --accept-routes=false

# 4. pve last. Do this one from the Proxmox web console, not over SSH — it is
#    the recovery path for everything above, so it is the one node you do not
#    want to be inside an SSH session on when it re-authenticates.
tailscale up --authkey=tskey-auth-... --advertise-tags=tag:infra --accept-routes=false
```

Do **not** tag `jj-laptop` or the phone. A tagged device leaves your user
account, and grant 1 is written for `autogroup:member` — tagging your laptop
removes it from that group and from its own access.

### Phase 3 — verify before trusting it

```sh
# every server carries the tag you expect, and no personal device does
tailscale status --json | jq -r '.Peer[] | "\(.HostName)\t\(.Tags // ["-"] | join(","))"'

# routes survived the re-auth
tailscale status --json | jq -r '.Peer[] | select(.PrimaryRoutes) | "\(.HostName)\t\(.PrimaryRoutes|join(","))"'

# the laptop still reaches things by both paths
ssh pve-prod-ts hostname
ssh pve-ts hostname
```

Check the exit node still works from the phone, since `autogroup:internet` is
the grant most easily forgotten.

## Rollback

Policy changes take effect immediately and the console keeps previous
versions. If access breaks, revert to the previous policy version in the
console — that restores the old allow-all rule without touching any node.

Tags are removed the same way they were added, with `tailscale up
--advertise-tags=` and an empty value.

## Optional: apply this file from CI

Tailscale publishes a GitHub Action that syncs a policy file on push, which
would make this directory behave like the rest of the repo. It needs an OAuth
client with the `policy_file` scope stored as repository secrets.

Left as a deliberate next step rather than done here, because a CI job that
can rewrite the tailnet policy is itself a credential worth thinking about
before creating — a leaked OAuth client could open the whole tailnet.
