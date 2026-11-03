#!/bin/bash
# Live Jellyfin UI development. Run on jj-laptop from anywhere:
#
#   stacks/media/jellyfin/ui/dev.sh          watch: sync to pve-prod on every save
#   stacks/media/jellyfin/ui/dev.sh build    only rebuild manifest.json (before a commit)
#
# Each save rebuilds manifest.json and rsyncs this folder to the dev mount
# on pve-prod (/web/ui-dev/). A browser in dev mode (?uidev=1) polls the
# manifest: CSS changes swap in place, JS changes reload the page.
# Production (/web/ui/) only changes on a git push. See README.md.
set -euo pipefail
cd "$(dirname "$0")"

DEST=/mnt/docker-data/appdata/jellyfin-ui-dev/
SOCK="${XDG_RUNTIME_DIR:-/tmp}/ui-dev-ssh-%r@%h"
SSH="ssh -o ControlMaster=auto -o ControlPath=$SOCK -o ControlPersist=30m"

build_manifest() {
  python3 -I - <<'PY'
import hashlib, json, pathlib
def h(p): return hashlib.sha1(p.read_bytes()).hexdigest()[:10]
m = {kind: {str(p): h(p) for p in sorted(pathlib.Path(kind).glob(f"*.{kind}"))} for kind in ("css", "js")}
pathlib.Path("manifest.json").write_text(json.dumps(m, indent=2) + "\n")
PY
}

if [ "${1:-}" = build ]; then build_manifest; cat manifest.json; exit 0; fi

HOST=${UI_HOST:-}
if [ -z "$HOST" ]; then
  for h in pve-prod pve-prod-ts; do  # LAN first, tailnet when away
    if $SSH -o ConnectTimeout=4 -o BatchMode=yes "$h" true 2>/dev/null; then HOST=$h; break; fi
  done
fi
[ -n "$HOST" ] || { echo "pve-prod is not reachable on the LAN or the tailnet" >&2; exit 1; }

sync() {
  build_manifest
  rsync -a --delete -e "$SSH" --exclude dev.sh --exclude README.md ./ "$HOST:$DEST"
}

sync
echo "ui-dev: synced to $HOST. Open Jellyfin with ?uidev=1. Ctrl-C to stop."
while inotifywait -qq -r -e close_write,create,delete,move --exclude 'manifest\.json$' .; do
  sync && echo "$(date +%T) synced"
done
