# Periphery — the agent, deliberately outside the Core stack

Periphery is the component that actually runs `docker compose` on `app-prod`.
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

Then:

```sh
sudo systemctl enable --now periphery
systemctl status periphery
```

## Staying in step with Core

Core and Periphery must run the same version, or Core marks the server yellow
with a version mismatch. Because they're installed by different mechanisms —
Core by compose, Periphery by this script — nothing keeps them aligned on its
own. Both therefore track the **floating major tag `2`**, which is also
upstream's default, and each has its own updater:

| Component | Updated by | Cadence |
|---|---|---|
| Core | Komodo itself — `auto_update` + `poll_for_updates` on the `komodo-core` stack | within `KOMODO_RESOURCE_POLL_INTERVAL` of a release |
| Periphery | `komodo-periphery-update.timer` in `systemd/` | daily, catching up after boot |

Core auto-updating itself is only safe *because* Periphery is out here in
systemd: Core can be torn down and replaced while the agent performing that
work keeps running. This is the same separation described above, now doing a
second job.

Install the timer on `app-prod`:

```sh
sudo cp periphery/systemd/komodo-periphery-update.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now komodo-periphery-update.timer
systemctl list-timers komodo-periphery-update.timer
```

Test the unit once by hand rather than waiting for the timer:

```sh
sudo systemctl start komodo-periphery-update.service
journalctl -u komodo-periphery-update.service -n 30 --no-pager
```

Two failures found the first time this ran on `app-prod`, both now fixed in
the unit but worth recognising if it's ever rewritten:

- `KeyError: 'HOME'` — systemd gives services a near-empty environment, and
  the installer reads `os.environ['HOME']` before deciding whether it even
  needs it. Fixed by `Environment=HOME=/root`.
- `Restart=on-failure` on a `Type=oneshot` unit is an endless retry loop, not
  a safety net. It sat in `activating (auto-restart)` re-running every five
  minutes against a permanent error. The timer is the retry mechanism.

**Known limitation:** the two updaters are independent, so after a release Core
may be newer than Periphery until the timer next runs — up to a day. That shows
as a yellow server in the UI. It is a warning, not an outage. If it ever
matters more than that, the alternative is to move Periphery back into Core's
compose file, where both read one `${COMPOSE_KOMODO_IMAGE_TAG}` and cannot
drift — at the cost of Core no longer being able to manage its own stack.

## The one setting that matters

`periphery.config.toml` contains a **root directory** (default `/etc/komodo`).
Every repo Periphery clones and every stack it runs must live beneath it.

If you later switch Periphery to a container, this path must be identical
inside and outside the container or Docker resolves bind mounts against the
wrong filesystem — see [discussion #180](https://github.com/moghtech/komodo/discussions/180).
As a systemd unit there's no such constraint, which is one more reason to
prefer it.

## Housekeeping

Installing this creates a **system-level systemd unit**, which is a change
outside the dotfiles stow tree. Record the unit file and the reason in
`~/dotfiles/SYSTEM.md`.
