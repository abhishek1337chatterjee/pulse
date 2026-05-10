#!/bin/bash
# cleanup-old.sh — 90-day retention on raw samples
# Daily aggregates (daily_battery) and discharge_sessions are kept indefinitely
# since they're tiny (~1-10 rows/day) and useful for long-term trends.
set -euo pipefail

DB="$HOME/Documents/battery-stats/battery.duckdb"
DUCKDB="$HOME/.local/bin/duckdb"

RETENTION_DAYS="${BATTERY_STATS_RETENTION_DAYS:-90}"

"$DUCKDB" "$DB" <<SQL
-- before
SELECT 'before' AS phase, COUNT(*) AS battery_samples, (SELECT COUNT(*) FROM upower_rate) AS upower_rate, (SELECT COUNT(*) FROM upower_charge) AS upower_charge FROM battery_samples;

DELETE FROM battery_samples WHERE ts < CURRENT_DATE - INTERVAL $RETENTION_DAYS DAY;
DELETE FROM upower_rate     WHERE ts < CURRENT_DATE - INTERVAL $RETENTION_DAYS DAY;
DELETE FROM upower_charge   WHERE ts < CURRENT_DATE - INTERVAL $RETENTION_DAYS DAY;
DELETE FROM powertop_runs   WHERE captured_at < CURRENT_DATE - INTERVAL $RETENTION_DAYS DAY;
-- powertop_top_processes cleaned via cascade-style FK-less manual delete
DELETE FROM powertop_top_processes
WHERE run_id NOT IN (SELECT run_id FROM powertop_runs);
VACUUM;

-- after
SELECT 'after' AS phase, COUNT(*) AS battery_samples, (SELECT COUNT(*) FROM upower_rate) AS upower_rate, (SELECT COUNT(*) FROM upower_charge) AS upower_charge FROM battery_samples;
SQL
