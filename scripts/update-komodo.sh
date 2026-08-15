#!/usr/bin/env bash
#
# Update the Komodo control plane — Core and Periphery together.
#
# These two MUST run the same version or Core marks the server yellow with a
# version mismatch. They are installed by different mechanisms (Core by
# compose, Periphery by an installer script), so nothing keeps them aligned on
# its own. Doing both here, back to back, is what makes drift impossible
# rather than merely something that gets corrected eventually.
#
# Deliberately NOT managed by Komodo. Letting Komodo update Komodo was tried
# and removed: it required the Core stack to run in `files_on_host` mode, which
# reads a clone nothing refreshes, which needed a Repo resource to refresh it,
# which then failed anyway on `detected dubious ownership` because Periphery
# runs as root against a jj-owned clone. Three layers of machinery to update
# one container. This script replaces all of it.
#
# Run by komodo-update.timer, or by hand:
#     sudo /home/jj/proxlab/scripts/update-komodo.sh
#
set -euo pipefail

REPO_DIR="${REPO_DIR:-/home/jj/proxlab}"
KOMODO_DIR="$REPO_DIR/komodo"
INSTALLER_URL="https://raw.githubusercontent.com/moghtech/komodo/main/scripts/setup-periphery.py"

# Periphery's installer writes to /usr/local/bin and /etc/systemd/system, and
# compose needs the docker socket. Re-exec rather than failing halfway.
if [[ $EUID -ne 0 ]]; then
  exec sudo -- "$0" "$@"
fi

log() { printf '\n=== %s ===\n' "$1"; }

log "Updating repo at $REPO_DIR"
# git refuses to operate on a repo owned by another user. Rather than adding a
# global safe.directory exception for root, drop to the owner for this one
# command — the same failure that killed the Komodo-managed version of this.
owner="$(stat -c %U "$REPO_DIR")"
runuser -u "$owner" -- git -C "$REPO_DIR" pull --ff-only

log "Pulling Core images"
cd "$KOMODO_DIR"
# The .env symlink -> compose.env is what supplies ${KOMODO_DATABASE_USERNAME}
# etc. to compose itself. Without it every compose command here fails with
# "invalid spec: :/backups: empty section between colons".
if [[ ! -e .env ]]; then
  echo "ERROR: $KOMODO_DIR/.env is missing. Run: ln -s compose.env .env" >&2
  exit 1
fi
docker compose pull

log "Updating Periphery"
# ⚠️ Download, then run. Piping curl into python3 makes stdin the pipe, so the
# privilege prompt cannot read the terminal and it dies with a misleading
# "Failed to download binary... Did you provide a valid tag?".
#
# ⚠️ The installer REWRITES /etc/komodo/periphery.config.toml with its own
# defaults. That silently reverts the hardening applied 2026-08-15:
#
#     bind_ip     = "172.17.0.1"       listen on the docker bridge only, so
#                                      the LAN cannot reach 8120 at all
#     allowed_ips = ["172.19.0.0/16"]  only Komodo's own network may call it
#     connect_as  = "pve-prod"         must match the Komodo Server resource
#
# Periphery is UNAUTHENTICATED by default — no passkeys, no allowed_ips — and
# it drives Docker as root. Letting the installer reset those three lines
# re-opens the host to anything on the LAN, and nothing would report it.
#
# So: keep our file, let the installer write its own, then put ours back and
# show the diff. The diff is what surfaces genuinely new upstream defaults
# instead of hiding them.
PERIPHERY_CONF=/etc/komodo/periphery.config.toml
cp -a "$PERIPHERY_CONF" "$PERIPHERY_CONF.pre-update"

curl -fsSL -o /tmp/setup-periphery.py "$INSTALLER_URL"
python3 /tmp/setup-periphery.py
rm -f /tmp/setup-periphery.py

if ! cmp -s "$PERIPHERY_CONF" "$PERIPHERY_CONF.pre-update"; then
  log "Installer changed periphery.config.toml — restoring ours"
  echo "--- what the installer would have set (ours vs theirs) ---"
  diff -u "$PERIPHERY_CONF.pre-update" "$PERIPHERY_CONF" || true
  echo "---------------------------------------------------------"
  cp -a "$PERIPHERY_CONF.pre-update" "$PERIPHERY_CONF"
  echo "Restored. Review the diff above for new upstream settings worth adopting."
fi

# Fail loudly rather than start an unauthenticated agent on every interface.
for key in 'bind_ip = "172.17.0.1"' 'allowed_ips = \["172.19.0.0/16"\]'; do
  if ! grep -qE "^${key}$" "$PERIPHERY_CONF"; then
    echo "ERROR: hardening line missing from $PERIPHERY_CONF: $key" >&2
    echo "Refusing to restart periphery. Fix the config first." >&2
    exit 1
  fi
done

systemctl restart periphery

log "Restarting Core"
# Last, so Periphery is already on the new version when Core comes back and
# compares them. Safe to restart Core from here precisely because this script
# is NOT running inside Komodo — nothing is killed mid-operation.
docker compose up -d

log "Versions"
sleep 5
printf 'core:      %s\n' "$(curl -fsS http://localhost:9120/version || echo '(not up yet)')"
printf 'periphery: %s\n' "$(/usr/local/bin/periphery --version)"
echo
echo "These two must match. If they don't, check 'docker compose ps' in $KOMODO_DIR."
