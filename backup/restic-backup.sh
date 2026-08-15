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
