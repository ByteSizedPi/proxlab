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
service file, creates the config directory, and sets up the key material:

```sh
curl -sSL https://raw.githubusercontent.com/moghtech/komodo/main/scripts/setup-periphery.py | python3
```

Then:

```sh
sudo systemctl enable --now periphery
systemctl status periphery
```

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
