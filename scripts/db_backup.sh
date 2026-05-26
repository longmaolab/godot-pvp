#!/usr/bin/env bash
# Daily backup of the godot-pvp SQLite DB. Designed to run as a cron job
# on the VPS. WAL mode is safe to copy with sqlite3 .backup since it
# acquires a shared lock — DS can keep running while we backup.
#
# Install on VPS (one-time):
#   sudo cp scripts/db_backup.sh /etc/cron.daily/godot-pvp-db-backup
#   sudo chmod +x /etc/cron.daily/godot-pvp-db-backup
# (cron.daily fires at ~6:25 UTC by default, see /etc/crontab)
#
# Retention: keeps 14 most recent .db.gz files; older purged.

set -eu

DB="/var/lib/godot-pvp/godot-pvp.db"
BACKUP_DIR="/var/backups/godot-pvp"
TS="$(date +%Y-%m-%d)"
DEST="$BACKUP_DIR/godot-pvp-$TS.db"

mkdir -p "$BACKUP_DIR"

# sqlite3's `.backup` is online-safe (uses shared lock, copies pages
# without blocking writers). Falls back to plain cp if sqlite3 CLI
# isn't installed (the godot-sqlite gdextension bundles its own libsqlite3
# but doesn't expose the CLI).
if command -v sqlite3 >/dev/null 2>&1; then
  sqlite3 "$DB" ".backup '$DEST'"
else
  # Fallback: copy + WAL checkpoint via straight file copy. Slight risk
  # of inconsistent state if DS is mid-transaction; sqlite3 CLI is much
  # safer. Recommended to `apt install sqlite3` on the VPS.
  cp "$DB" "$DEST"
fi

gzip -f "$DEST"

# Retention: keep last 14 days
find "$BACKUP_DIR" -name "godot-pvp-*.db.gz" -mtime +14 -delete

echo "[$(date '+%Y-%m-%d %H:%M:%S')] backed up to $DEST.gz"
