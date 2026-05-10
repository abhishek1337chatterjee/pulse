#!/bin/bash
# powertop-capture.sh — manually run powertop and ingest top energy consumers
# usage: battery-stats powertop [duration_sec] [notes...]
set -euo pipefail

DB="$HOME/Documents/battery-stats/battery.duckdb"
DUCKDB="$HOME/.local/bin/duckdb"
ASKPASS="${SUDO_ASKPASS:-$HOME/.local/bin/sudo-askpass}"

DURATION="${1:-30}"
shift || true
NOTES="${*:-}"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
CSV="$WORK/powertop.csv"

echo "running powertop for ${DURATION}s (sudo askpass)..."
SUDO_ASKPASS="$ASKPASS" sudo -A powertop --csv="$CSV" --time="$DURATION" >/dev/null 2>&1

if [ ! -s "$CSV" ]; then
    echo "powertop produced no output" >&2
    exit 1
fi

# extract on_ac state at capture time
on_ac=$(cat /sys/class/power_supply/AC/online 2>/dev/null || echo 0)
on_ac_bool="false"; [ "$on_ac" = "1" ] && on_ac_bool="true"

ts=$(date -u +"%Y-%m-%d %H:%M:%S")

# parse the "Top 10 Power Consumers" section from powertop CSV.
# powertop CSV is messy: section headers are "______; ; ;" rows.
# we grep the section between the consumer header and the next blank/section.
python3 - "$CSV" "$WORK/parsed.csv" <<'PYEOF'
import csv, sys, re
src, dst = sys.argv[1], sys.argv[2]
rows = []
with open(src, newline='', encoding='utf-8', errors='replace') as f:
    in_section = False
    rank = 0
    for line in f:
        stripped = line.strip().strip(';').strip()
        if 'Top 10 Power Consumers' in line or 'Overview of Software Power Consumers' in line:
            in_section = True
            rank = 0
            continue
        if in_section:
            if not stripped or stripped.startswith('___') or stripped.startswith('* * *'):
                if rank > 0:
                    in_section = False
                continue
            parts = [p.strip() for p in line.split(';')]
            # heuristic: rows have at least 3 fields and the first two are usage values
            if len(parts) >= 3 and any(parts):
                # description is usually the longest text field
                desc = max(parts, key=len)
                # try to pull a wattage estimate from a field containing 'W'
                pw = None
                for p in parts:
                    m = re.match(r'^([\d.]+)\s*W$', p)
                    if m:
                        try:
                            pw = float(m.group(1))
                            break
                        except ValueError:
                            pass
                # try to pull wakeups/sec
                wk = None
                for p in parts:
                    m = re.match(r'^([\d.]+)$', p)
                    if m and float(m.group(1)) < 10000:
                        try:
                            wk = float(m.group(1))
                            break
                        except ValueError:
                            pass
                rank += 1
                rows.append((rank, desc[:200], parts[0][:100], wk, pw, 'process'))
                if rank >= 20:
                    in_section = False

with open(dst, 'w', newline='') as f:
    w = csv.writer(f)
    for r in rows:
        w.writerow(r)
PYEOF

n=$(wc -l < "$WORK/parsed.csv")
echo "parsed $n entries from powertop"

"$DUCKDB" "$DB" <<SQL
-- get next run_id
INSERT INTO powertop_runs (run_id, captured_at, duration_seconds, on_ac, notes)
SELECT
    COALESCE((SELECT MAX(run_id) FROM powertop_runs), 0) + 1,
    '$ts'::TIMESTAMP, $DURATION, $on_ac_bool,
    NULLIF('$NOTES', '');

CREATE TEMP TABLE staging (
    rank INTEGER, description VARCHAR, usage VARCHAR,
    wakeups_per_sec DOUBLE, pw_estimate_w DOUBLE, category VARCHAR
);
COPY staging FROM '$WORK/parsed.csv' (HEADER FALSE);

INSERT INTO powertop_top_processes
SELECT
    (SELECT MAX(run_id) FROM powertop_runs) AS run_id,
    rank, description, usage, wakeups_per_sec, pw_estimate_w, category
FROM staging
ON CONFLICT (run_id, rank, description) DO NOTHING;

SELECT * FROM powertop_top_processes
WHERE run_id = (SELECT MAX(run_id) FROM powertop_runs)
ORDER BY rank
LIMIT 10;
SQL
