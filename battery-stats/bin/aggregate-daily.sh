#!/bin/bash
# aggregate-daily.sh — derive discharge_sessions and daily_battery from raw samples
# nightly cron at ~3 AM
set -euo pipefail

DB="$HOME/Documents/battery-stats/battery.duckdb"
DUCKDB="$HOME/.local/bin/duckdb"

# session detection algorithm:
#   - sort battery_samples by ts
#   - a "discharge session" starts when state goes discharging and ends when on_ac becomes true OR last sample
#   - SOT = sum of (sample_interval) where screen_active=true within the session
#   - we approximate sample interval as time-to-next-sample, capped at 10 min (suspended gap detection)

"$DUCKDB" "$DB" <<'SQL'
-- wipe and rebuild derived tables (cheap; battery_samples is small)
DELETE FROM discharge_sessions;
DELETE FROM daily_battery;

-- step 1: tag each sample with session boundaries via on_ac transitions
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
INSERT INTO discharge_sessions
SELECT
    session_id,
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
INSERT INTO daily_battery
SELECT
    DATE_TRUNC('day', (start_ts AT TIME ZONE 'UTC') AT TIME ZONE 'Asia/Kolkata')::DATE AS date,
    CAST(SUM(sot_seconds) / 60 AS INTEGER) AS sot_minutes,
    CAST(SUM(duration_seconds) / 60 AS INTEGER) AS discharge_minutes,
    SUM(energy_used_wh) AS total_discharge_wh,
    CASE WHEN SUM(sot_seconds) > 0
         THEN SUM(energy_used_wh) * 3600.0 / SUM(sot_seconds)
         ELSE NULL END AS avg_drain_w_sot,
    COUNT(*) AS n_sessions,
    NULL AS cycle_count_eod,        -- filled below
    NULL AS energy_full_wh_eod,
    NULL AS health_pct
FROM discharge_sessions
GROUP BY date;

-- backfill end-of-day cycle / energy_full from raw samples
UPDATE daily_battery d
SET
    cycle_count_eod    = s.cycle_count,
    energy_full_wh_eod = s.energy_full_wh,
    health_pct         = s.energy_full_wh / NULLIF(s.energy_full_design_wh, 0) * 100
FROM (
    SELECT
        DATE_TRUNC('day', (ts AT TIME ZONE 'UTC') AT TIME ZONE 'Asia/Kolkata')::DATE AS date,
        FIRST(cycle_count    ORDER BY ts DESC) AS cycle_count,
        FIRST(energy_full_wh ORDER BY ts DESC) AS energy_full_wh,
        FIRST(energy_full_design_wh ORDER BY ts DESC) AS energy_full_design_wh
    FROM battery_samples
    GROUP BY date
) s
WHERE d.date = s.date;

SELECT 'sessions' AS what, COUNT(*) AS n FROM discharge_sessions
UNION ALL
SELECT 'days', COUNT(*) FROM daily_battery;
SQL
