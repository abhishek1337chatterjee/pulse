-- battery-stats schema
-- mirrors the claude-stats pattern: raw samples + derived rollups, 365-day retention

-- raw poller samples: every ~5 min from systemd user timer
CREATE TABLE IF NOT EXISTS battery_samples (
    ts                  TIMESTAMP NOT NULL,
    energy_now_wh       DOUBLE NOT NULL,
    energy_full_wh      DOUBLE NOT NULL,
    energy_full_design_wh DOUBLE NOT NULL,
    power_now_w         DOUBLE NOT NULL,        -- positive = drain or charge magnitude
    voltage_v           DOUBLE NOT NULL,
    capacity_pct        INTEGER NOT NULL,
    cycle_count         INTEGER,
    state               VARCHAR NOT NULL,       -- charging | discharging | full | not-charging | unknown
    on_ac               BOOLEAN NOT NULL,
    screen_active       BOOLEAN NOT NULL,       -- IdleHint=no AND ScreenSaver inactive
    idle_hint           BOOLEAN NOT NULL,       -- raw IdleHint
    screensaver_active  BOOLEAN NOT NULL,
    brightness_pct      INTEGER,
    PRIMARY KEY (ts)
);
CREATE INDEX IF NOT EXISTS idx_samples_state ON battery_samples(state);
CREATE INDEX IF NOT EXISTS idx_samples_ts ON battery_samples(ts);

-- raw upower rate history (bulk-imported from /var/lib/upower/history-rate-*.dat)
CREATE TABLE IF NOT EXISTS upower_rate (
    ts      TIMESTAMP NOT NULL,
    watts   DOUBLE NOT NULL,
    state   VARCHAR NOT NULL,
    PRIMARY KEY (ts, state)
);

-- raw upower charge percentage history
CREATE TABLE IF NOT EXISTS upower_charge (
    ts          TIMESTAMP NOT NULL,
    percentage  DOUBLE NOT NULL,
    state       VARCHAR NOT NULL,
    PRIMARY KEY (ts, state)
);

-- discharge sessions (derived nightly): one row per "from unplug to plug-in or shutdown"
CREATE TABLE IF NOT EXISTS discharge_sessions (
    session_id          INTEGER PRIMARY KEY,
    start_ts            TIMESTAMP NOT NULL,
    end_ts              TIMESTAMP NOT NULL,
    duration_seconds    BIGINT NOT NULL,
    start_pct           INTEGER NOT NULL,
    end_pct             INTEGER NOT NULL,
    energy_used_wh      DOUBLE NOT NULL,
    sot_seconds         BIGINT NOT NULL,            -- screen-on-time during this session
    screen_off_seconds  BIGINT NOT NULL,
    avg_drain_w         DOUBLE,                     -- across whole session (incl screen off)
    avg_drain_w_sot     DOUBLE,                     -- only when screen was on (the honest number)
    projected_full_runtime_hours DOUBLE             -- extrapolated: full_design / avg_drain_w_sot
);
CREATE INDEX IF NOT EXISTS idx_sessions_start ON discharge_sessions(start_ts);

-- daily roll-up: one row per calendar day
CREATE TABLE IF NOT EXISTS daily_battery (
    date                DATE PRIMARY KEY,
    sot_minutes         INTEGER NOT NULL,
    discharge_minutes   INTEGER NOT NULL,           -- total time on battery
    total_discharge_wh  DOUBLE NOT NULL,
    avg_drain_w_sot     DOUBLE,
    n_sessions          INTEGER NOT NULL,
    cycle_count_eod     INTEGER,                    -- end-of-day reading
    energy_full_wh_eod  DOUBLE,                     -- end-of-day full capacity (for decay tracking)
    health_pct          DOUBLE                      -- energy_full / energy_full_design * 100
);

-- powertop snapshots: manual `battery-stats powertop` runs
CREATE TABLE IF NOT EXISTS powertop_runs (
    run_id              INTEGER PRIMARY KEY,
    captured_at         TIMESTAMP NOT NULL,
    duration_seconds    INTEGER NOT NULL,
    on_ac               BOOLEAN NOT NULL,
    notes               VARCHAR
);

CREATE TABLE IF NOT EXISTS powertop_top_processes (
    run_id              INTEGER NOT NULL,
    rank                INTEGER NOT NULL,
    description         VARCHAR NOT NULL,
    usage               VARCHAR,            -- raw text e.g. "12.3 ms/s"
    wakeups_per_sec     DOUBLE,
    pw_estimate_w       DOUBLE,
    category            VARCHAR,            -- 'process' | 'device' | 'tunable' | etc
    PRIMARY KEY (run_id, rank, description)
);
