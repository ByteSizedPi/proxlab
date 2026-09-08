#!/usr/bin/env bash
#
# 3-2-1 backup for pve-prod.
#
#   copy 1  /mnt/safe on pve-prod          the working data (RAID6)
#   copy 2  restic repo on jjserver        second machine, second array
#   copy 3  restic repo on Backblaze B2    offsite
#
# Run by restic-backup.timer. To run by hand:
#     sudo /usr/local/sbin/restic-backup.sh
#
# ── What is and is not backed up ─────────────────────────────────────────
#
# Media is deliberately excluded. /mnt/data is 311 GB of movies and series
# that are re-downloadable, and paying to store them offsite would multiply
# the cost of this by twenty for no benefit. /mnt/safe is the irreplaceable
# half: camera originals, photos, documents, laptop backups, app state.
#
# ── Why the databases need special handling ──────────────────────────────
#
# A live Postgres/Mongo data directory copied file-by-file is not a valid
# backup - the files are mid-write and the restore is a coin flip. They have
# to be dumped through the engine.
#
#   Immich    dumped here. Immich CAN schedule its own dumps, but at the time
#             of writing /mnt/safe/immich/backups held only the .immich
#             marker, and a backup that silently depends on another system's
#             scheduler being enabled is not a backup.
#   Komodo    NOT dumped here. Komodo already writes dated dumps to
#             /mnt/docker-data/komodo/backups, so that directory is simply
#             included below.

set -euo pipefail

RESTIC_PASSWORD_FILE=/etc/restic/password
export RESTIC_PASSWORD_FILE
export RESTIC_REPOSITORY="sftp:jjserver-backup:/mnt/raid5/restic"

B2_ENV=/etc/restic/b2.env          # optional; when present, copy 3 runs
DUMP_DIR=/mnt/safe/documents/db
LOCK=/var/run/restic-backup.lock

log() { printf '\n=== %s ===\n' "$1"; }

# One run at a time. A second run would block on restic's own repo lock
# anyway, but failing fast is clearer than two jobs staring at each other.
exec 9>"$LOCK"
flock -n 9 || { echo "another restic-backup is already running"; exit 0; }

# ── 1. Dump the Immich database ──────────────────────────────────────────
log "Dumping Immich Postgres"
mkdir -p "$DUMP_DIR"
if docker ps --format '{{.Names}}' | grep -qx immich_postgres; then
  PGUSER_=$(docker exec immich_postgres printenv POSTGRES_USER)
  PGDB_=$(docker exec immich_postgres printenv POSTGRES_DB)
  # --clean --if-exists so the dump can be replayed into a non-empty database.
  docker exec immich_postgres pg_dump -U "$PGUSER_" -d "$PGDB_" --clean --if-exists \
    | gzip -c > "$DUMP_DIR/immich.sql.gz.tmp"
  mv -f "$DUMP_DIR/immich.sql.gz.tmp" "$DUMP_DIR/immich.sql.gz"
  echo "wrote $(du -h "$DUMP_DIR/immich.sql.gz" | cut -f1)"
else
  echo "immich_postgres not running - skipping (previous dump is retained)"
fi

# ── 1b. Snapshot the Jellyfin SQLite databases ───────────────────────────
#
# Same problem as Immich Postgres above, different engine. /config/data/data
# holds jellyfin.db and library.db as live SQLite. Copying those file-by-file
# while Jellyfin is writing captures a torn page or a stale main file with the
# real commit still sitting in the -wal, and the restore is a coin flip.
#
# Most of the library is regenerable by rescanning. Watch state, users and
# their per-user home screen choices are NOT - those exist only here.
#
# Measured on 2026-08-31: jellyfin.db was 7.5 MB with a 4.0 MB -wal beside it.
# Over a third of the committed state was outside the main file at that
# moment. A file-by-file copy would have missed it.
#
# The fix is SQLite's online backup API, which walks the pages under a read
# lock and folds the -wal in, without stopping Jellyfin.
#
# ⚠️ It is driven from python3 rather than the sqlite3 CLI on purpose. The
# CLI is present in NEITHER the linuxserver/jellyfin image nor on pve-prod -
# both were checked. python3 is on the host and ships the module in its
# standard library, so this adds no package to install.
#
# The source is opened mode=ro so this can never write to the live database.
# The output lands next to it in the appdata tree, which is already a restic
# source below, so no new path joins the run.
log "Snapshotting Jellyfin SQLite"
JF_DATA=/mnt/docker-data/appdata/jellyfin/data/data
if [ -f "$JF_DATA/jellyfin.db" ]; then
  python3 - "$JF_DATA" <<'PY'
import sqlite3, sys, os, glob
data = sys.argv[1]
for src in sorted(glob.glob(os.path.join(data, "*.db"))):
    dst = src + ".bak"
    con = sqlite3.connect("file:%s?mode=ro" % src, uri=True)
    out = sqlite3.connect(dst + ".tmp")
    with out:
        con.backup(out)
    out.close(); con.close()
    os.replace(dst + ".tmp", dst)
    print("wrote %s (%.1f MB)" % (os.path.basename(dst), os.path.getsize(dst) / 1e6))
PY
else
  echo "no Jellyfin database at $JF_DATA - skipping"
fi

# ── 1c. Snapshot the FreshRSS SQLite database ────────────────────────────
#
# Same reason as Jellyfin above, same method. FreshRSS keeps one SQLite
# database per user under data/users/<user>/, and the cron inside the
# container refreshes feeds twice an hour, so a file-by-file copy can land
# mid-write.
#
# The glob is deliberate: it takes every user directory and every .sqlite file
# in it, so adding a second FreshRSS user needs no change here.
#
# Read state is the part that cannot be regenerated. The subscription list can
# be rebuilt from stacks/apps/freshrss/feeds.opml, but which of 500 articles
# you have already read exists only in this file.
log "Snapshotting FreshRSS SQLite"
FRSS_USERS=/mnt/docker-data/appdata/freshrss/data/users
if [ -d "$FRSS_USERS" ]; then
  python3 - "$FRSS_USERS" <<'PY'
import sqlite3, sys, os, glob
users = sys.argv[1]
found = False
for src in sorted(glob.glob(os.path.join(users, "*", "*.sqlite"))):
    found = True
    dst = src + ".bak"
    con = sqlite3.connect("file:%s?mode=ro" % src, uri=True)
    out = sqlite3.connect(dst + ".tmp")
    with out:
        con.backup(out)
    out.close(); con.close()
    os.replace(dst + ".tmp", dst)
    print("wrote %s (%.1f MB)" % (dst, os.path.getsize(dst) / 1e6))
if not found:
    print("no FreshRSS database under %s - skipping" % users)
PY
else
  echo "no FreshRSS user directory at $FRSS_USERS - skipping"
fi

# ── 2. Back up to jjserver ───────────────────────────────────────────────
log "Backup -> jjserver"
SOURCES=(/mnt/safe /mnt/docker-data/appdata)
[ -d /mnt/docker-data/komodo/backups ] && SOURCES+=(/mnt/docker-data/komodo/backups)

restic backup \
  --verbose \
  --tag pve-prod \
  --exclude /mnt/safe/immich/thumbs \
  --exclude /mnt/safe/immich/encoded-video \
  --exclude '**/lost+found' \
  "${SOURCES[@]}"

# thumbs/ and encoded-video/ are excluded because Immich regenerates both from
# the originals. They were 4.5 GB on jjserver for this library - real money on
# B2, and zero value, since a restore rebuilds them.

# ── 3. Retention ─────────────────────────────────────────────────────────
log "Retention on jjserver"
restic forget --tag pve-prod \
  --keep-daily 7 --keep-weekly 4 --keep-monthly 6 \
  --prune

# ── 4. Copy to B2 ────────────────────────────────────────────────────────
if [ -f "$B2_ENV" ]; then
  log "Copy -> Backblaze B2"
  # shellcheck disable=SC1090
  set -a; . "$B2_ENV"; set +a
  # RESTIC_REPOSITORY2 / RESTIC_FROM_* is restic's copy convention: FROM is the
  # source repo, the plain vars are the destination.
  export RESTIC_FROM_REPOSITORY="$RESTIC_REPOSITORY"
  export RESTIC_FROM_PASSWORD_FILE="$RESTIC_PASSWORD_FILE"
  export RESTIC_REPOSITORY="$B2_REPOSITORY"
  restic copy --from-repo "$RESTIC_FROM_REPOSITORY"
  restic forget --tag pve-prod \
    --keep-daily 7 --keep-weekly 4 --keep-monthly 6 \
    --prune
else
  log "B2 not configured ($B2_ENV absent) - skipping copy 3"
fi

log "Done"
