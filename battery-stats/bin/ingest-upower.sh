#!/bin/bash
# ingest-upower.sh — bulk-import UPower's existing battery history into DuckDB
# safe to run repeatedly (ON CONFLICT DO NOTHING)
set -euo pipefail

DB="$HOME/Documents/battery-stats/battery.duckdb"
DUCKDB="$HOME/.local/bin/duckdb"
HIST_DIR="/var/lib/upower"

# Auto-detect the laptop battery's UPower history files.
# UPower names them history-{rate,charge}-{MODEL}-{SERIAL}.dat. We read the
# kernel-reported model from sysfs and glob for matching files. Override with
# BATTERY_MODEL env var if your battery's UPower filename uses a different tag.
BATTERY_MODEL="${BATTERY_MODEL:-$(cat /sys/class/power_supply/BAT0/model_name 2>/dev/null | tr -d '[:space:]')}"

if [ -z "$BATTERY_MODEL" ]; then
    echo "could not detect battery model from /sys/class/power_supply/BAT0/model_name" >&2
    echo "set BATTERY_MODEL=<tag> to override (look in $HIST_DIR for history-rate-*.dat)" >&2
    exit 1
fi

RATE_FILE=$(ls "$HIST_DIR"/history-rate-"$BATTERY_MODEL"-*.dat 2>/dev/null | head -1 || true)
CHARGE_FILE=$(ls "$HIST_DIR"/history-charge-"$BATTERY_MODEL"-*.dat 2>/dev/null | head -1 || true)

if [ -z "$RATE_FILE" ] || [ -z "$CHARGE_FILE" ]; then
    echo "could not find UPower history files in $HIST_DIR" >&2
    exit 1
fi

# need read perms on /var/lib/upower; if not readable, advise sudo workaround
if [ ! -r "$RATE_FILE" ]; then
    echo "cannot read $RATE_FILE — need to grant read access:" >&2
    echo "  sudo setfacl -m u:$USER:r $HIST_DIR/history-*.dat" >&2
    echo "  sudo setfacl -m u:$USER:rx $HIST_DIR" >&2
    exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# convert TSV "epoch  value  state" into a CSV that DuckDB can COPY
awk -F'\t' '$1 ~ /^[0-9]+$/ {
    cmd = "date -u -d @" $1 " +\"%Y-%m-%d %H:%M:%S\""
    cmd | getline ts
    close(cmd)
    printf "\"%s\",%s,\"%s\"\n", ts, $2, $3
}' "$RATE_FILE" > "$WORK/rate.csv"

awk -F'\t' '$1 ~ /^[0-9]+$/ {
    cmd = "date -u -d @" $1 " +\"%Y-%m-%d %H:%M:%S\""
    cmd | getline ts
    close(cmd)
    printf "\"%s\",%s,\"%s\"\n", ts, $2, $3
}' "$CHARGE_FILE" > "$WORK/charge.csv"

n_rate=$(wc -l < "$WORK/rate.csv")
n_charge=$(wc -l < "$WORK/charge.csv")
echo "ingesting $n_rate rate samples, $n_charge charge samples"

"$DUCKDB" "$DB" <<SQL
CREATE TEMP TABLE staging_rate (ts TIMESTAMP, watts DOUBLE, state VARCHAR);
COPY staging_rate FROM '$WORK/rate.csv' (HEADER FALSE);
INSERT INTO upower_rate
SELECT ts, watts, state FROM staging_rate
ON CONFLICT (ts, state) DO NOTHING;

CREATE TEMP TABLE staging_charge (ts TIMESTAMP, percentage DOUBLE, state VARCHAR);
COPY staging_charge FROM '$WORK/charge.csv' (HEADER FALSE);
INSERT INTO upower_charge
SELECT ts, percentage, state FROM staging_charge
ON CONFLICT (ts, state) DO NOTHING;

SELECT
  (SELECT COUNT(*) FROM upower_rate)   AS rate_rows,
  (SELECT COUNT(*) FROM upower_charge) AS charge_rows,
  (SELECT MIN(ts)  FROM upower_rate)   AS earliest,
  (SELECT MAX(ts)  FROM upower_rate)   AS latest;
SQL
