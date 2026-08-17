# Authentication

How Authentik fronts the estate, and how to make it disappear on your own
devices.

## The goal, restated

Never see a login screen on a device you own. Always see one on a device you
do not. Do that without paying for Enterprise.

That is achievable. The mechanism is not what it first looks like.

## What Enterprise actually gates

Checked against the Enterprise features list, 2026-08-17:

| Enterprise only | Free |
|---|---|
| Enhanced audit logging, event maps/charts, CSV export | **WebAuthn / passkeys** |
| Google Workspace and Entra ID sync | **Passwordless flows** |
| Source Stage (embedding external OAuth/SAML) | **MFA, all stages, all policies** |
| **Chrome Enterprise Device Trust connector** | **Proxy / forward-auth provider** |
| Shared Signals Framework | **OIDC / OAuth2 providers** |
| Password Uniqueness Policy | Session and network binding |
| **Mutual TLS (client certificates)** | |

So true device-certificate trust, the thing closest to "SSH knows my key", is
paid. Everything needed for the actual goal is not.

## ⚠️ The passkey plan does not work on this laptop

An earlier version of this document argued that a platform passkey is the
device identity, so a passkey-only flow gives owned-versus-borrowed asymmetry
for free, and that no password should be a valid first factor.

That reasoning is sound on macOS, Windows and Android. **It does not hold on
Linux with Firefox**, which is the primary workstation here.

Verified 2026-08-17:

- Firefox on Linux supports WebAuthn **only with USB hardware tokens**. There
  is no platform-authenticator support, and no QR / phone hybrid transport.
- Chrome and Chromium on Linux do better, but Linux generally still pushes
  users toward an external security key.
- `libwebauthn` and `credentialsd` (an XDG portal plus a patched Firefox
  build, presented at FOSDEM 2026) are the projects fixing this. They are not
  something to depend on yet.

### PAM fingerprint is not browser WebAuthn

This is the part most worth being clear about, because the two look like the
same feature and are unrelated.

Swapping `libfprint` for a third-party build gives fingerprint unlock to
**PAM** — the display manager, `sudo`, `polkit`. PAM and the browser's
WebAuthn stack share nothing. No browser on Linux can present that fingerprint
reader as a platform authenticator, so a working fingerprint login to the
desktop produces exactly zero improvement to a web login.

### What follows

**The password fallback is permanent.** Not a temporary safety measure until a
second admin exists, but the actual login mechanism on the Linux workstation.

So seamlessness cannot come from passwordless here. It comes from **not being
asked**: a 30-day session, a 60-day remember-me, MFA suppressed for 24 hours,
and one cookie shared across every subdomain. The realistic outcome is a
login roughly once a month, not never.

The passwordless flow is still built and still linked from the login page. It
is worth keeping because it works on the phone, works in Chrome, and would
work immediately with a USB security key. It is an option, not the mechanism.

### Keeping the borrowed-device property anyway

Losing "no password to save" costs the clean asymmetry. Two things preserve
most of it:

- **MFA is still required.** A saved password alone is not enough to log in,
  because the second factor lives on the phone. A borrowed device can save
  the half that does not work on its own.
- **Network binding** terminates a session whose cookie appears from a
  different network, and `*.admin.jjventer.co.za` only resolves and routes on
  the LAN and tailnet in the first place.

A USB security key is the one purchase that would restore the original plan
in full, on Firefox and Linux included.

## Making it seamless

Five settings, all free. Together these mean a login roughly once a month, and
one touch when it happens.

### 1. Passwordless flow

Authentication flow, in order:

- **Identification stage** — enable **Passkey autofill**. Requires
  discoverable credentials (resident keys), which is what you enrolled.
- **Authenticator Validation stage** — set **Device classes** to `webauthn`
  only. Set **WebAuthn hints** to client device / hybrid.
- **User Login stage** — settings below.

### 2. Long sessions

On the **User Login stage**. Format is authentik's timedelta syntax
(`hours=`, `days=`, `weeks=`):

| Field | Suggested | Effect |
|---|---|---|
| `Session duration` | `days=30` | how long a login lasts |
| `Remember me offset` | `days=60` | shows "stay signed in", extends to this |

`seconds=0` in `Session duration` means "until the browser closes".
`seconds=0` in `Remember me offset` hides the checkbox entirely.

### 3. One session for every service

**This is the setting that makes SSO actually feel like SSO.** On each Proxy
Provider, set **Cookie domain** to `admin.jjventer.co.za` — the parent domain,
not the per-service hostname.

Get this wrong and every subdomain prompts separately, which feels worse than
having no SSO at all because it looks like it should be working.

### 4. Stop re-asking for MFA

On the **Authenticator Validation stage**, set **Last validation threshold**
to something like `hours=24`. It skips validation when a compatible device was
used successfully inside that window.

### 5. Kill sessions that leave the network

On the **User Login stage**, set **Network binding** to bind ASN and network,
and optionally **GeoIP binding**. If a session cookie is replayed from a
different network, authentik terminates it and logs the binding change.

This is what enforces "external devices do not keep access". Note the blast
radius is already small: `*.admin.jjventer.co.za` resolves and routes only on
the LAN and the tailnet, so a device off the network cannot reach these
services at all, with or without a cookie.

## Which mechanism per service

Two mechanisms, and picking the wrong one wastes an afternoon.

**OIDC** — the app redirects to authentik, gets a signed token, and knows who
you are. Real per-user accounts. Configure an OAuth2/OpenID Provider.

**Forward auth** — Traefik asks authentik "is this person logged in?" before
passing the request on. The app learns nothing about you and keeps its own
accounts. Configure a Proxy Provider in forward-auth mode.

| Service | Mechanism | Note |
|---|---|---|
| `komodo` | **OIDC** | verified: `KOMODO_OIDC_*`, callback `/auth/oidc/callback`, names authentik explicitly |
| `immich` | **OIDC** | native. Forward auth would break the mobile app |
| `seerr` | **OIDC** | check its settings; Overseerr-lineage supports OIDC |
| `sonarr` `radarr` `prowlarr` `bazarr` | forward auth | no OIDC support |
| `qbittorrent` | forward auth | safe, see below |
| `tdarr` `maintainerr` | forward auth | no OIDC support |
| `homepage` | forward auth | has no auth of its own at all |
| `netdata` | forward auth | local agent has no OIDC, that is Netdata Cloud |
| `traefik` dashboard | forward auth | replaces the basicauth label and its `$`-doubling trap |
| `adguard` | forward auth | has its own login; gate it or do not, but not both |
| **`ntfy`** | **NEITHER** | see below |
| **`jellyfin`** | **NEITHER** | see below |
| **`plex`** | **NEITHER** | see below |
| **`auth`** (authentik) | **NEVER** | guarding it with itself is a redirect loop that locks you out of the login page |

### Why three services must not be gated

- **`ntfy`** — its publishers are machines. Netdata, Komodo and Proxmox POST
  with a token and cannot complete an interactive SSO redirect. ntfy's own
  `deny-all` plus per-topic ACLs are the access control there.
- **`jellyfin`** — TVs and native apps cannot follow an SSO redirect. The same
  hostname serves both the web UI and the client API, so gating the router
  breaks every client. Use Jellyfin's own SSO plugin if you want this.
- **`plex`** — authenticates against plex.tv accounts. Same client problem.

### Why qBittorrent is safe and Immich is not

Both are talked to by other services, but over different paths.

Sonarr and Radarr reach qBittorrent **east-west**, by container name over the
`media` network. That never touches Traefik, so a forward-auth middleware on
qBittorrent's Traefik router cannot see it, let alone block it. The
`ingress` / `media` split in this repo is what makes that true.

Immich's mobile app reaches Immich **north-south**, through Traefik on the
same hostname you use in a browser. A forward-auth middleware sits directly in
its path and the app cannot answer the challenge. Hence OIDC, which Immich
speaks natively.

**The rule: forward auth is safe when every non-browser client is east-west.**

### Komodo webhooks are not at risk

Worth stating because it looks dangerous. cloudflared targets
`http://host.docker.internal:9120` directly and never traverses Traefik, so
gating `komodo.admin.jjventer.co.za` cannot break GitHub webhook delivery.
Verified 2026-08-17 against the tunnel config.

## Order of work

⚠️ **An unresolvable middleware fails the whole chain and takes down every
route on the entrypoint, not just the one that names it.**

1. Build the passwordless flow and set it as the Brand's authentication flow.
2. Create one Proxy Provider (forward auth, single application) per gated
   service, each with **Cookie domain** `admin.jjventer.co.za`. Create the
   matching Application. Add every one to the **authentik Embedded Outpost**.
3. Uncomment the `authentik` middleware in
   `stacks/platform/traefik/dynamic/middlewares.yml`.
4. **Deploy the traefik stack by hand.** Editing `dynamic/*.yml` does not
   refresh Traefik's clone, so the middleware stays invisible otherwise. See
   the note at the top of `dynamic/komodo.yml`.
5. Add `middlewares=authentik@file` to one service's router, and a second
   router on that host matching `PathPrefix(/outpost.goauthentik.io/)` at a
   higher priority, pointing at `authentik-server:9000`. Without that second
   router the auth callback hits the app instead of authentik and the login
   never completes.
6. Verify that one service, then do the rest.

Do one service first. `homepage` is the right choice: it has no login of its
own to conflict with, nothing else calls it, and breaking it costs nothing.

### The *arr apps need one more change

They keep their own login on top of forward auth, so you would authenticate
twice. Per app, Settings → General → Security:

```
Authentication:          External / Forms
Authentication Required: Disabled for Local Addresses
```

jjserver's Sonarr already runs exactly that pair.

## Honest limits

- A session still expires. `days=30` plus remember-me is close to invisible,
  but it is not literally never.
- Network binding cannot tell your laptop from a borrowed laptop on the same
  network. Only the passkey does that, which is why the flow must not accept
  a password.
- Cross-device passkey sign-in needs Bluetooth for the QR handshake. It is the
  borrowed-device path, so it is rare, but it is not frictionless by design.
