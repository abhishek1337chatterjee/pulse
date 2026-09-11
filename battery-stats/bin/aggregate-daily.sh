#!/bin/bash
# aggregate-daily.sh — derive discharge_sessions and daily_battery from raw samples
# runs nightly (systemd timer) AND after every poll (poll.sh, via flock)
set -euo pipefail

DB="$HOME/Documents/battery-stats/battery.duckdb"
DUCKDB="$HOME/.local/bin/duckdb"

# session detection algorithm:
#   - sort battery_samples by ts
#   - a "discharge session" starts when state goes discharging and ends when on_ac becomes true OR last sample
#   - SOT = sum of (sample_interval) where screen_active=true within the session
#   - we approximate sample interval as time-to-next-sample, capped at 10 min (suspended gap detection)
#
# STORAGE NOTE (2026-09-11): this used to be an unconditional DELETE + INSERT rebuild.
# DuckDB never reclaims the row group a DELETE empties, so every run (288/day once
# poll.sh started calling this) leaked one 256 KB block per derived table — the DB file
# reached 4.9 GB for ~15 MB of live data. Now the derivation lands in TEMP tables first and
# the persistent tables are rewritten ONLY when the result actually differs (the DELETE /
# INSERT carry a `WHERE changed` guard, so an unchanged run is a pure read). compact-db.sh
# (nightly) reclaims whatever still accumulates on days with real changes.

"$DUCKDB" "$DB" <<'SQL'
-- step 1: tag each sample with session boundaries via on_ac transitions
CREATE TEMP TABLE new_sessions AS
WITH ordered AS (
    SELECT
        ts, energy_now_wh, energy_full_wh, energy_full_design_wh,
        capacity_pct, cycle_count, state, on_ac, screen_active,
        LAG(on_ac) OVER (ORDER BY ts) AS prev_on_ac,
        LAG(ts)    OVER (ORDER BY ts) AS prev_ts
    FROM battery_samples
),
boundaries AS (
    SELECT
        *,
        -- new session whenever AC goes from true→false, or first row that is on battery
        CASE
            WHEN on_ac = false AND (prev_on_ac IS NULL OR prev_on_ac = true) THEN 1
            ELSE 0
        END AS new_session,
        -- gap to next sample, used for SOT integration; cap at 600s to handle suspends/missed polls
        LEAST(
            COALESCE(EXTRACT(EPOCH FROM (LEAD(ts) OVER (ORDER BY ts) - ts)), 300),
            600
        ) AS interval_seconds
    FROM ordered
),
tagged AS (
    SELECT
        *,
        SUM(new_session) OVER (ORDER BY ts ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS session_id
    FROM boundaries
    WHERE on_ac = false  -- only battery samples belong to sessions
)
SELECT
    CAST(session_id AS INTEGER) AS session_id,
    MIN(ts) AS start_ts,
    MAX(ts) AS end_ts,
    CAST(SUM(interval_seconds) AS BIGINT) AS duration_seconds,
    MAX(capacity_pct) AS start_pct,
    MIN(capacity_pct) AS end_pct,
    GREATEST(MAX(energy_now_wh) - MIN(energy_now_wh), 0) AS energy_used_wh,
    CAST(SUM(CASE WHEN screen_active THEN interval_seconds ELSE 0 END) AS BIGINT) AS sot_seconds,
    CAST(SUM(CASE WHEN NOT screen_active THEN interval_seconds ELSE 0 END) AS BIGINT) AS screen_off_seconds,
    CASE WHEN SUM(interval_seconds) > 0
         THEN GREATEST(MAX(energy_now_wh) - MIN(energy_now_wh), 0) * 3600.0 / SUM(interval_seconds)
         ELSE NULL END AS avg_drain_w,
    CASE WHEN SUM(CASE WHEN screen_active THEN interval_seconds ELSE 0 END) > 0
         THEN GREATEST(MAX(energy_now_wh) - MIN(energy_now_wh), 0) * 3600.0
              / SUM(CASE WHEN screen_active THEN interval_seconds ELSE 0 END)
         ELSE NULL END AS avg_drain_w_sot,
    CASE WHEN SUM(CASE WHEN screen_active THEN interval_seconds ELSE 0 END) > 0
              AND GREATEST(MAX(energy_now_wh) - MIN(energy_now_wh), 0) > 0
         THEN MAX(energy_full_design_wh) /
              (GREATEST(MAX(energy_now_wh) - MIN(energy_now_wh), 0) * 3600.0
               / SUM(CASE WHEN screen_active THEN interval_seconds ELSE 0 END))
         ELSE NULL END AS projected_full_runtime_hours
FROM tagged
GROUP BY session_id
HAVING duration_seconds > 60
   AND (MAX(energy_now_wh) - MIN(energy_now_wh)) > 0.05;  -- skip phantom sessions with no real drain

-- step 2: daily roll-up (group by IST date so a 23:00 IST session belongs to today, not tomorrow UTC)
--         + end-of-day cycle / energy_full backfill from raw samples
CREATE TEMP TABLE new_daily AS
WITH days AS (
    SELECT
        DATE_TRUNC('day', (start_ts AT TIME ZONE 'UTC') AT TIME ZONE 'Asia/Kolkata')::DATE AS date,
        CAST(SUM(sot_seconds) / 60 AS INTEGER) AS sot_minutes,
        CAST(SUM(duration_seconds) / 60 AS INTEGER) AS discharge_minutes,
        -- ROUND: DuckDB's parallel SUM over doubles is order-nondeterministic in the last
        -- ulp (38.1 vs 38.10000000000001 across runs); rounding keeps the change check
        -- below stable so unchanged days never trigger a rewrite.
        ROUND(SUM(energy_used_wh), 6) AS total_discharge_wh,
        CASE WHEN SUM(sot_seconds) > 0
             THEN ROUND(SUM(energy_used_wh) * 3600.0 / SUM(sot_seconds), 6)
             ELSE NULL END AS avg_drain_w_sot,
        CAST(COUNT(*) AS INTEGER) AS n_sessions
    FROM new_sessions
    GROUP BY date
),
eod AS (
    SELECT
        DATE_TRUNC('day', (ts AT TIME ZONE 'UTC') AT TIME ZONE 'Asia/Kolkata')::DATE AS date,
        FIRST(cycle_count    ORDER BY ts DESC) AS cycle_count,
        FIRST(energy_full_wh ORDER BY ts DESC) AS energy_full_wh,
        FIRST(energy_full_design_wh ORDER BY ts DESC) AS energy_full_design_wh
    FROM battery_samples
    GROUP BY date
)
SELECT
    d.date, d.sot_minutes, d.discharge_minutes, d.total_discharge_wh, d.avg_drain_w_sot, d.n_sessions,
    e.cycle_count                                              AS cycle_count_eod,
    e.energy_full_wh                                           AS energy_full_wh_eod,
    e.energy_full_wh / NULLIF(e.energy_full_design_wh, 0) * 100 AS health_pct
FROM days d
LEFT JOIN eod e USING (date);

-- step 3: did anything change? (symmetric difference; EXCEPT treats NULLs as equal)
CREATE TEMP TABLE chg AS
SELECT (
    (SELECT COUNT(*) FROM (SELECT * FROM new_sessions EXCEPT SELECT * FROM discharge_sessions))
  + (SELECT COUNT(*) FROM (SELECT * FROM discharge_sessions EXCEPT SELECT * FROM new_sessions))
  + (SELECT COUNT(*) FROM (SELECT * FROM new_daily EXCEPT SELECT * FROM daily_battery))
  + (SELECT COUNT(*) FROM (SELECT * FROM daily_battery EXCEPT SELECT * FROM new_daily))
) > 0 AS changed;

-- step 4: rewrite persistent tables only when changed (0-row DELETE/INSERT touch no storage)
DELETE FROM discharge_sessions WHERE (SELECT changed FROM chg);
INSERT INTO discharge_sessions SELECT * FROM new_sessions WHERE (SELECT changed FROM chg);
DELETE FROM daily_battery      WHERE (SELECT changed FROM chg);
INSERT INTO daily_battery      SELECT * FROM new_daily    WHERE (SELECT changed FROM chg);

SELECT 'changed' AS what, CAST(changed AS BIGINT) AS n FROM chg
UNION ALL
SELECT 'sessions', COUNT(*) FROM discharge_sessions
UNION ALL
SELECT 'days', COUNT(*) FROM daily_battery;
SQL
