#!/bin/bash
# compact-db.sh — rebuild battery.duckdb into a fresh file to reclaim dead blocks
# nightly (systemd timer, after cleanup-old.sh); also `battery-stats compact`
#
# WHY: DuckDB never shrinks a database file. Row groups emptied by DELETE stay allocated
# (observed 2026-09-11: 4.9 GB file, ~15 MB live data, 9075 dead row groups per derived
# table). `VACUUM` is a no-op for space. The only reclaim path is copying every table into
# a new file (`COPY FROM DATABASE`, keeps schema + indexes) and swapping it in.
#
# SAFETY: takes the same lock poll.sh / aggregate-daily.sh use, so no writer touches the
# DB mid-copy; verifies per-table row counts before the swap; swap is two renames.
set -euo pipefail

DB="$HOME/Documents/battery-stats/battery.duckdb"
DUCKDB="$HOME/.local/bin/duckdb"
LOCK="/tmp/battery-stats-aggregate.lock"
THRESHOLD_MB="${BATTERY_STATS_COMPACT_MB:-100}"   # skip when file is already small
FORCE="${1:-}"                                    # `--force` ignores the threshold

size_before=$(stat -c%s "$DB")
if [ "$FORCE" != "--force" ] && [ "$size_before" -lt $((THRESHOLD_MB * 1024 * 1024)) ]; then
    echo "compact: $DB is $((size_before / 1024 / 1024)) MB (< ${THRESHOLD_MB} MB) — skipped"
    exit 0
fi

exec 9>"$LOCK"
flock -w 120 9 || { echo "compact: could not acquire $LOCK" >&2; exit 1; }

NEW="$DB.compact"
rm -f "$NEW" "$NEW.wal"

"$DUCKDB" "$DB" "ATTACH '$NEW' AS newdb; COPY FROM DATABASE battery TO newdb; DETACH newdb;"

# verify: every table's row count must match
mismatch=0
while IFS= read -r t; do
    a=$("$DUCKDB" "$DB"  -readonly -csv -noheader "SELECT COUNT(*) FROM $t")
    b=$("$DUCKDB" "$NEW" -readonly -csv -noheader "SELECT COUNT(*) FROM $t")
    if [ "$a" != "$b" ]; then
        echo "compact: row count mismatch in $t (old=$a new=$b) — aborting" >&2
        mismatch=1
    fi
done < <("$DUCKDB" "$DB" -readonly -csv -noheader "SELECT table_name FROM duckdb_tables() WHERE NOT internal")
if [ "$mismatch" -ne 0 ]; then
    rm -f "$NEW" "$NEW.wal"
    exit 1
fi

mv "$DB" "$DB.pre-compact"
mv "$NEW" "$DB"
rm -f "$DB.pre-compact" "$DB.wal"

size_after=$(stat -c%s "$DB")
echo "compact: $((size_before / 1024 / 1024)) MB -> $((size_after / 1024 / 1024)) MB"
