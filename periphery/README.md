# Periphery — the agent, deliberately outside the Core stack

Periphery is the component that actually runs `docker compose` on `pve-prod`.
Komodo Core connects to it over a Noise-authenticated channel on port 8120.

## Why it isn't a container in `../komodo/compose.yaml`

Upstream's `mongo.compose.yaml` bundles Periphery alongside Core. That is fine
until you ask Komodo to manage its own Core stack — at which point redeploying
Core also restarts Periphery, killing the agent halfway through the deploy it
is performing. The deploy dies, and Komodo reports a failure it cannot recover
from because the thing reporting is the thing that died.

Running Periphery as a **systemd unit on the host** breaks that cycle. Core can
be stopped, rebuilt and restarted freely; Periphery is untouched and simply
reconnects. This is the arrangement Komodo's maintainer uses.

## Install

Use the official installer rather than hand-rolling a unit — it generates the
service file, creates the config directory, and sets up the key material.

⚠️ **Download it first; do not pipe curl into python3.** The installer
escalates privileges, and when stdin is the pipe the password prompt can't read
the terminal. It then fails with `Failed to download binary… Did you provide a
valid tag?` — an error that describes nothing like the actual problem and sends
you hunting for a network or version fault.

```sh
curl -fsSL -o /tmp/setup-periphery.py \
  https://raw.githubusercontent.com/moghtech/komodo/main/scripts/setup-periphery.py
sudo python3 /tmp/setup-periphery.py
```

Then replace the unit the installer wrote with the one in this directory, and
enable it:

```sh
sudo install -m 0644 periphery.service /etc/systemd/system/periphery.service
sudo systemctl daemon-reload
sudo systemctl enable --now periphery
systemctl status periphery
```

The installer's own unit boots dead. See "The boot race" below.

## Staying in step with Core

Core and Periphery must run the same version or Core marks the server yellow
with a version mismatch. They install by different mechanisms — Core by
compose, Periphery by this script — so nothing aligns them on its own.

Both track the floating `2` tag, and **one** thing updates both:
`../scripts/update-komodo.sh`, run weekly by `komodo-update.timer`. Doing them
in a single pass is what makes drift impossible rather than something that
gets corrected eventually. Install per `BOOTSTRAP.md` step 13.

Run it by hand any time:

```sh
sudo /home/jj/proxlab/scripts/update-komodo.sh
```

It prints both versions at the end. They must match.

### Two mistakes worth not repeating

Both were made here on 2026-08-01 and are fixed in the unit file:

- `KeyError: 'HOME'` — systemd gives services a near-empty environment, and
  `setup-periphery.py` reads `os.environ['HOME']` before deciding whether it
  even needs it. Fixed by `Environment=HOME=/root`.
- `Restart=on-failure` on a `Type=oneshot` unit is an endless retry loop, not
  a safety net. It sat in `activating (auto-restart)` re-running every five
  minutes against an error that was never going to clear. The timer is the
  retry mechanism; `Persistent=true` covers runs missed while the box was off.

When reading the journal, scope it to the current boot — `journalctl -u
komodo-update.service -b --since "10 min ago"`. A bare `-n 30` shows the tail
of the *previous* run alongside the current one, and an old traceback sitting
above a successful run reads exactly like a fresh failure.

## The boot race

`periphery.service` in this directory differs from the one the installer
writes, in two places, for one reason.

`periphery.config.toml` sets `bind_ip = "172.17.0.1"`. That is the docker0
bridge address, chosen so the agent listens on the bridge only and is not
reachable from the LAN or the tailnet. The address does not exist until
dockerd creates the bridge.

The installer's unit declares no ordering against Docker, so at boot systemd
starts Periphery first and the bind fails:

```
ERROR CONNECTION ERROR: Failed to start https server: Cannot assign requested address (os error 99)
```

Periphery then **exits 0**. systemd logs `Deactivated successfully`, and the
installer's `Restart=on-failure` never fires, because by its own exit code
nothing failed. The agent stays dead until someone starts it by hand.

That happened on the 7 and 8 September 2026 boots. pve-prod is powered down
overnight, so every boot is a fresh roll of this dice. The visible symptom is
not "Periphery is down" — it is the gitops procedure failing with:

```
Failed to get Swarm or Server for Stack <name> | Cannot send command when Server is unreachable or disabled
```

which reads like a problem with the stack being deployed. It is not. Check
`systemctl is-active periphery` first, before reading a single line of the
stack that appears in the message.

The fix is `After=docker.service` plus `Wants=docker.service`, and
`Restart=always` rather than `Restart=on-failure`.

## The one setting that matters

`periphery.config.toml` contains a **root directory** (default `/etc/komodo`).
Every repo Periphery clones and every stack it runs must live beneath it.

If you later switch Periphery to a container, this path must be identical
inside and outside the container or Docker resolves bind mounts against the
wrong filesystem — see [discussion #180](https://github.com/moghtech/komodo/discussions/180).
As a systemd unit there's no such constraint, which is one more reason to
prefer it.

## Housekeeping

Installing this creates a **system-level systemd unit**. The unit file lives
here, in `periphery.service`, and is copied to `/etc/systemd/system/`. It does
NOT go in `~/dotfiles/SYSTEM.md`: that rule covers jj-laptop. Everything that
belongs to pve-prod belongs in this repo.
