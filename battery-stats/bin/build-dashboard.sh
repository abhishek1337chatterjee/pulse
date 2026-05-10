#!/bin/bash
# build-dashboard.sh — generate self-contained HTML dashboard from DuckDB
# usage: build-dashboard.sh [days=14] [output_path]
set -euo pipefail

DB="$HOME/Documents/battery-stats/battery.duckdb"
DUCKDB="$HOME/.local/bin/duckdb"
DAYS="${1:-14}"
OUT="${2:-/tmp/battery-stats-dashboard.html}"

if [ ! -f "$DB" ]; then
    echo "battery-stats: db not found at $DB" >&2
    exit 1
fi

q() { "$DUCKDB" -readonly -json "$DB" "$1"; }

# All ts columns are stored as UTC. Convert to IST for display in every query.
# Pattern: STRFTIME((ts AT TIME ZONE 'UTC') AT TIME ZONE 'Asia/Kolkata', '%Y-%m-%d %H:%M:%S')
# Plotly receives IST strings without TZ marker, so it displays them verbatim — which is what we want.

# --- gather data ---
STATS=$(q "
    WITH latest AS (
        SELECT * FROM battery_samples ORDER BY ts DESC LIMIT 1
    )
    SELECT
        capacity_pct,
        ROUND(power_now_w, 2) AS power_now_w,
        cycle_count,
        ROUND(energy_full_wh / energy_full_design_wh * 100, 1) AS health_pct,
        ROUND(energy_now_wh, 2) AS energy_now_wh,
        ROUND(energy_full_wh, 2) AS energy_full_wh,
        state,
        on_ac,
        screen_active,
        STRFTIME((ts AT TIME ZONE 'UTC') AT TIME ZONE 'Asia/Kolkata', '%Y-%m-%d %H:%M:%S IST') AS last_sample_ts
    FROM latest;
")

# charge % over time — split into charging vs discharging traces for color coding
CHARGE_DATA=$(q "
    -- one continuous line of % over time (Android-style), with state tag for color/hover
    SELECT
        STRFTIME((ts AT TIME ZONE 'UTC') AT TIME ZONE 'Asia/Kolkata', '%Y-%m-%d %H:%M:%S') AS ts,
        percentage,
        state
    FROM upower_charge
    WHERE state IN ('charging','discharging','full','pending-charge','not-charging')
      AND ts >= CURRENT_TIMESTAMP - INTERVAL $DAYS DAY
    ORDER BY ts;
")

# separate dataset: charging-segment ranges, for shaded background bands
CHARGING_BANDS=$(q "
    WITH tagged AS (
        SELECT
            ts,
            state,
            LAG(state) OVER (ORDER BY ts) AS prev_state
        FROM upower_charge
        WHERE state IN ('charging','discharging','full')
          AND ts >= CURRENT_TIMESTAMP - INTERVAL $DAYS DAY
    ),
    boundaries AS (
        SELECT
            ts, state,
            CASE WHEN state = 'charging' AND (prev_state IS NULL OR prev_state != 'charging')
                 THEN 1 ELSE 0 END AS new_band
        FROM tagged
    ),
    bands AS (
        SELECT
            ts, state,
            SUM(new_band) OVER (ORDER BY ts ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS band_id
        FROM boundaries
        WHERE state = 'charging'
    )
    SELECT
        STRFTIME((MIN(ts) AT TIME ZONE 'UTC') AT TIME ZONE 'Asia/Kolkata', '%Y-%m-%d %H:%M:%S') AS start_ts,
        STRFTIME((MAX(ts) AT TIME ZONE 'UTC') AT TIME ZONE 'Asia/Kolkata', '%Y-%m-%d %H:%M:%S') AS end_ts
    FROM bands
    GROUP BY band_id
    HAVING COUNT(*) >= 2;
")

# drain (W) over time — discharging only, from UPower bulk history
DRAIN_DATA=$(q "
    SELECT
        STRFTIME((ts AT TIME ZONE 'UTC') AT TIME ZONE 'Asia/Kolkata', '%Y-%m-%d %H:%M:%S') AS ts,
        watts
    FROM upower_rate
    WHERE state = 'discharging'
      AND ts >= CURRENT_TIMESTAMP - INTERVAL $DAYS DAY
    ORDER BY ts;
")

# daily SOT + drain (from poller-derived daily_battery)
DAILY=$(q "
    SELECT
        date,
        sot_minutes,
        discharge_minutes,
        ROUND(total_discharge_wh, 2) AS total_discharge_wh,
        ROUND(avg_drain_w_sot, 2) AS avg_drain_w_sot,
        n_sessions,
        cycle_count_eod,
        ROUND(health_pct, 2) AS health_pct
    FROM daily_battery
    WHERE date >= CURRENT_DATE - INTERVAL $DAYS DAY
    ORDER BY date;
")

# health over time — sample one row per day from raw samples (more granular than daily_battery)
HEALTH=$(q "
    SELECT
        DATE_TRUNC('day', ts)::DATE AS date,
        ROUND(MAX(energy_full_wh), 2) AS energy_full_wh,
        ROUND(MAX(energy_full_wh) / MAX(energy_full_design_wh) * 100, 2) AS health_pct,
        MAX(cycle_count) AS cycle_count
    FROM battery_samples
    GROUP BY date
    ORDER BY date;
")

# recent discharge sessions table
SESSIONS=$(q "
    SELECT
        STRFTIME((start_ts AT TIME ZONE 'UTC') AT TIME ZONE 'Asia/Kolkata', '%Y-%m-%d %H:%M IST') AS start_ts,
        STRFTIME((end_ts AT TIME ZONE 'UTC') AT TIME ZONE 'Asia/Kolkata', '%H:%M IST') AS end_ts,
        duration_seconds,
        sot_seconds,
        start_pct,
        end_pct,
        ROUND(energy_used_wh, 2) AS energy_used_wh,
        ROUND(avg_drain_w, 2) AS avg_drain_w,
        ROUND(avg_drain_w_sot, 2) AS avg_drain_w_sot,
        ROUND(projected_full_runtime_hours, 2) AS projected_full_runtime_hours
    FROM discharge_sessions
    WHERE start_ts >= CURRENT_TIMESTAMP - INTERVAL $DAYS DAY
    ORDER BY start_ts DESC
    LIMIT 50;
")

# avg drain by hour-of-day (heatmap-style data)
HOURLY=$(q "
    SELECT
        EXTRACT(HOUR FROM (ts AT TIME ZONE 'UTC') AT TIME ZONE 'Asia/Kolkata') AS hour_ist,
        ROUND(AVG(watts), 2) AS avg_w,
        ROUND(MAX(watts), 2) AS peak_w,
        COUNT(*) AS n
    FROM upower_rate
    WHERE state = 'discharging'
      AND ts >= CURRENT_TIMESTAMP - INTERVAL $DAYS DAY
    GROUP BY hour_ist
    ORDER BY hour_ist;
")

# powertop top consumers from latest run
POWERTOP=$(q "
    SELECT
        STRFTIME((r.captured_at AT TIME ZONE 'UTC') AT TIME ZONE 'Asia/Kolkata', '%Y-%m-%d %H:%M IST') AS captured_at,
        r.duration_seconds,
        r.on_ac,
        r.notes,
        p.rank,
        p.description,
        p.pw_estimate_w,
        p.wakeups_per_sec
    FROM powertop_runs r
    LEFT JOIN powertop_top_processes p USING (run_id)
    WHERE r.run_id = (SELECT MAX(run_id) FROM powertop_runs)
    ORDER BY p.rank
    LIMIT 15;
")

GENERATED_AT=$(TZ=Asia/Kolkata date "+%Y-%m-%d %H:%M:%S IST")

# --- emit HTML ---
cat > "$OUT" <<HEAD_EOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>battery-stats — dashboard</title>
<script src="https://cdn.plot.ly/plotly-2.35.2.min.js" charset="utf-8"></script>
<style>
:root {
    --bg: #000000;
    --panel: #0a0a0a;
    --panel-2: #141416;
    --panel-hover: #1a1a1d;
    --fg: #f5f5f5;
    --fg-dim: #6b7280;
    --fg-muted: #4b5563;
    --border: #1f1f23;
    --border-strong: #2a2a30;
    --primary: #a78bfa;
    --primary-soft: rgba(167, 139, 250, 0.12);
    --secondary: #22d3ee;
    --secondary-soft: rgba(34, 211, 238, 0.12);
    --good: #22c55e;
    --good-soft: rgba(34, 197, 94, 0.14);
    --warn: #f59e0b;
    --warn-soft: rgba(245, 158, 11, 0.14);
    --bad: #ef4444;
    --bad-soft: rgba(239, 68, 68, 0.14);
    --pink: #ec4899;
    --shadow: 0 0 0 1px rgba(255, 255, 255, 0.04), 0 1px 2px rgba(0, 0, 0, 0.6);
    --shadow-lg: 0 0 0 1px rgba(255, 255, 255, 0.05), 0 8px 24px rgba(0, 0, 0, 0.7);
}
* { box-sizing: border-box; }
html, body {
    margin: 0; padding: 0;
    background: var(--bg);
    color: var(--fg);
    font-family: 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif;
    font-feature-settings: 'cv11', 'ss01', 'ss03';
    -webkit-font-smoothing: antialiased;
    text-rendering: optimizeLegibility;
}
body { padding: 32px 28px 48px; max-width: 1600px; margin: 0 auto; }
.header { display: flex; align-items: baseline; justify-content: space-between; margin-bottom: 28px; gap: 24px; flex-wrap: wrap; }
.brand { display: flex; align-items: baseline; gap: 12px; }
.brand .dot {
    width: 10px; height: 10px; border-radius: 50%;
    background: linear-gradient(135deg, var(--primary), var(--secondary));
    box-shadow: 0 0 16px rgba(167, 139, 250, 0.45);
    align-self: center;
}
h1 {
    margin: 0;
    font-size: 22px;
    font-weight: 600;
    letter-spacing: -0.02em;
    background: linear-gradient(135deg, #f5f5f5, #a78bfa);
    -webkit-background-clip: text;
    background-clip: text;
    color: transparent;
}
.sub { color: var(--fg-dim); font-size: 12px; letter-spacing: 0.01em; }
.cards {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
    gap: 12px;
    margin-bottom: 24px;
}
.card {
    background: var(--panel);
    border-radius: 14px;
    padding: 18px 20px;
    box-shadow: var(--shadow);
    transition: transform 0.15s ease, box-shadow 0.15s ease;
}
.card:hover { transform: translateY(-1px); box-shadow: var(--shadow-lg); }
.card .label {
    font-size: 11px;
    color: var(--fg-dim);
    text-transform: uppercase;
    letter-spacing: 0.08em;
    font-weight: 500;
    margin-bottom: 10px;
}
.card .value {
    font-size: 26px;
    font-weight: 600;
    line-height: 1;
    letter-spacing: -0.02em;
}
.card .unit { font-size: 13px; color: var(--fg-dim); margin-left: 4px; font-weight: 400; letter-spacing: 0; }
.card .meta { font-size: 11px; color: var(--fg-dim); margin-top: 10px; }
.value.good { color: var(--good); }
.value.warn { color: var(--warn); }
.value.bad { color: var(--bad); }
.panel {
    background: var(--panel);
    border-radius: 16px;
    padding: 20px 22px;
    margin-bottom: 16px;
    box-shadow: var(--shadow);
}
.panel h2 {
    margin: 0 0 14px;
    font-size: 14px;
    font-weight: 600;
    color: var(--fg);
    letter-spacing: -0.005em;
    display: flex;
    align-items: center;
    gap: 10px;
}
.panel h2::before {
    content: '';
    width: 3px; height: 14px;
    border-radius: 2px;
    background: linear-gradient(180deg, var(--primary), var(--secondary));
}
.row { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; }
@media (max-width: 1000px) { .row { grid-template-columns: 1fr; } }
.chart { width: 100%; height: 360px; }
.chart-tall { height: 420px; }
.chart-short { height: 280px; }
table { width: 100%; border-collapse: collapse; font-size: 12.5px; }
th {
    text-align: left;
    padding: 11px 14px;
    background: var(--panel);
    color: var(--fg-dim);
    font-weight: 500;
    text-transform: uppercase;
    font-size: 10px;
    letter-spacing: 0.08em;
    position: sticky;
    top: 0;
    border-bottom: 1px solid var(--border);
}
td { padding: 11px 14px; border-top: 1px solid var(--border); color: var(--fg); }
tr:hover td { background: var(--panel-2); }
.scroll { max-height: 480px; overflow-y: auto; border-radius: 10px; }
.scroll::-webkit-scrollbar { width: 8px; }
.scroll::-webkit-scrollbar-track { background: transparent; }
.scroll::-webkit-scrollbar-thumb { background: var(--border-strong); border-radius: 4px; }
.scroll::-webkit-scrollbar-thumb:hover { background: var(--fg-muted); }
.empty { padding: 40px; text-align: center; color: var(--fg-dim); font-size: 13px; }
.tag {
    display: inline-block;
    padding: 2px 8px;
    border-radius: 999px;
    font-size: 10.5px;
    font-weight: 500;
    letter-spacing: 0.02em;
}
.tag.discharging { background: var(--bad-soft); color: var(--bad); }
.tag.charging { background: var(--good-soft); color: var(--good); }
.tag.full { background: var(--primary-soft); color: var(--primary); }
footer {
    margin-top: 28px;
    padding-top: 20px;
    border-top: 1px solid var(--border);
    color: var(--fg-dim);
    font-size: 11px;
    text-align: center;
    letter-spacing: 0.02em;
}
code {
    background: var(--panel-2);
    padding: 2px 7px;
    border-radius: 5px;
    font-size: 11.5px;
    font-family: 'JetBrains Mono', 'SF Mono', Menlo, monospace;
    color: var(--secondary);
}
</style>
</head>
<body>
HEAD_EOF

cat >> "$OUT" <<HEADER_EOF
<div class="header">
    <div class="brand">
        <div class="dot"></div>
        <h1>battery-stats</h1>
        <span class="sub">window: last $DAYS days</span>
    </div>
    <div class="sub">generated $GENERATED_AT &middot; <code>$DB</code></div>
</div>

<div class="cards" id="cards"></div>

<div class="panel">
    <h2>Battery % over time</h2>
    <div id="chart-charge" class="chart chart-tall"></div>
</div>

<div class="row">
    <div class="panel">
        <h2>Drain rate (W) — discharging only</h2>
        <div id="chart-drain" class="chart"></div>
    </div>
    <div class="panel">
        <h2>Average drain by hour of day (IST)</h2>
        <div id="chart-hourly" class="chart"></div>
    </div>
</div>

<div class="row">
    <div class="panel">
        <h2>Daily Screen-On-Time</h2>
        <div id="chart-sot" class="chart"></div>
    </div>
    <div class="panel">
        <h2>Daily avg drain (W) — screen on</h2>
        <div id="chart-daily-drain" class="chart"></div>
    </div>
</div>

<div class="panel">
    <h2>Battery health (capacity decay)</h2>
    <div id="chart-health" class="chart chart-short"></div>
</div>

<div class="panel">
    <h2>Recent discharge sessions</h2>
    <div class="scroll">
        <table id="sessions-table">
            <thead>
                <tr>
                    <th>started</th>
                    <th>duration</th>
                    <th>SOT</th>
                    <th>battery %</th>
                    <th>used (Wh)</th>
                    <th>avg W</th>
                    <th>W (screen on)</th>
                    <th>projected full runtime</th>
                </tr>
            </thead>
            <tbody></tbody>
        </table>
    </div>
</div>

<div class="panel">
    <h2>Last powertop top consumers</h2>
    <div id="powertop-meta" class="sub"></div>
    <div class="scroll">
        <table id="powertop-table">
            <thead>
                <tr>
                    <th>#</th>
                    <th>description</th>
                    <th>est. W</th>
                    <th>wakeups/s</th>
                </tr>
            </thead>
            <tbody></tbody>
        </table>
    </div>
</div>

<footer>
    rebuild: <code>battery-stats dashboard [days=14]</code> &middot;
    raw queries: <code>~/.local/bin/duckdb -readonly $DB</code>
</footer>
HEADER_EOF

# emit data block + JS
cat >> "$OUT" <<'JS_PRELUDE'
<script>
const DATA = {
JS_PRELUDE

printf '    stats: %s,\n'      "$STATS"      >> "$OUT"
printf '    charge: %s,\n'     "$CHARGE_DATA">> "$OUT"
printf '    chargingBands: %s,\n' "$CHARGING_BANDS" >> "$OUT"
printf '    drain: %s,\n'      "$DRAIN_DATA" >> "$OUT"
printf '    daily: %s,\n'      "$DAILY"      >> "$OUT"
printf '    health: %s,\n'     "$HEALTH"     >> "$OUT"
printf '    sessions: %s,\n'   "$SESSIONS"   >> "$OUT"
printf '    hourly: %s,\n'     "$HOURLY"     >> "$OUT"
printf '    powertop: %s,\n'   "$POWERTOP"   >> "$OUT"

cat >> "$OUT" <<'JS_EOF'
};

const COLORS = {
    bg: '#000000',
    panel: '#0a0a0a',
    panel2: '#141416',
    fg: '#f5f5f5',
    fgDim: '#6b7280',
    border: '#1f1f23',
    primary: '#a78bfa',
    secondary: '#22d3ee',
    discharging: '#22d3ee',
    charging: '#22c55e',
    drain: '#f59e0b',
    health: '#a78bfa',
    pink: '#ec4899',
};

const baseLayout = (extra = {}) => ({
    paper_bgcolor: COLORS.panel,
    plot_bgcolor: COLORS.panel,
    font: { color: COLORS.fg, family: 'Inter, system-ui, sans-serif', size: 11 },
    margin: { l: 56, r: 16, t: 8, b: 44 },
    xaxis: { gridcolor: COLORS.border, zeroline: false, color: COLORS.fgDim, tickfont: { size: 10 } },
    yaxis: { gridcolor: COLORS.border, zeroline: false, color: COLORS.fgDim, tickfont: { size: 10 } },
    hovermode: 'x unified',
    hoverlabel: { bgcolor: COLORS.bg, bordercolor: COLORS.primary, font: { color: COLORS.fg, family: 'Inter, system-ui, sans-serif', size: 11 } },
    legend: { orientation: 'h', y: -0.22, font: { color: COLORS.fgDim, size: 10 }, bgcolor: 'transparent' },
    ...extra
});

const config = { responsive: true, displaylogo: false, modeBarButtonsToRemove: ['lasso2d', 'select2d'] };

// ---- stats cards ----
function renderCards() {
    const s = (DATA.stats && DATA.stats[0]) || {};
    const cards = [
        {
            label: 'Battery now',
            value: s.capacity_pct !== undefined ? s.capacity_pct + '%' : '—',
            cls: s.capacity_pct >= 50 ? 'good' : s.capacity_pct >= 20 ? 'warn' : 'bad',
            meta: s.state ? `<span class="tag ${s.state}">${s.state}</span>` : '',
        },
        {
            label: 'Power now',
            value: s.power_now_w !== undefined ? s.power_now_w : '—',
            unit: 'W',
            meta: s.screen_active === 'true' || s.screen_active === true ? 'screen active' : 'screen idle',
        },
        {
            label: 'Cycle count',
            value: s.cycle_count !== undefined ? s.cycle_count : '—',
            meta: 'lifetime charge cycles',
        },
        {
            label: 'Battery health',
            value: s.health_pct !== undefined ? s.health_pct : '—',
            unit: '%',
            cls: s.health_pct >= 90 ? 'good' : s.health_pct >= 75 ? 'warn' : 'bad',
            meta: `${s.energy_full_wh ?? '—'} Wh / design ${(s.energy_full_wh && s.health_pct) ? (s.energy_full_wh / s.health_pct * 100).toFixed(1) : '—'} Wh`,
        },
        {
            label: 'Energy stored',
            value: s.energy_now_wh !== undefined ? s.energy_now_wh : '—',
            unit: 'Wh',
            meta: s.last_sample_ts ? `as of ${s.last_sample_ts}` : '',
        },
    ];
    document.getElementById('cards').innerHTML = cards.map(c => `
        <div class="card">
            <div class="label">${c.label}</div>
            <div class="value ${c.cls || ''}">${c.value}<span class="unit">${c.unit || ''}</span></div>
            ${c.meta ? `<div class="meta">${c.meta}</div>` : ''}
        </div>
    `).join('');
}

// ---- chart: battery % ----
// Android-style: one continuous line of % over time, with shaded green bands during charging.
function renderCharge() {
    if (!DATA.charge.length) {
        document.getElementById('chart-charge').innerHTML = '<div class="empty">no data yet</div>';
        return;
    }
    const ts = DATA.charge.map(r => r.ts);
    const pct = DATA.charge.map(r => r.percentage);
    const states = DATA.charge.map(r => r.state);

    const traces = [{
        x: ts, y: pct,
        name: 'battery %',
        type: 'scatter', mode: 'lines',
        line: { color: COLORS.discharging, width: 2, shape: 'linear' },
        fill: 'tozeroy', fillcolor: 'rgba(34, 211, 238, 0.10)',
        customdata: states,
        hovertemplate: '<b>%{y:.0f}%</b><br>%{x}<br>state: %{customdata}<extra></extra>',
        connectgaps: true,
    }];

    // shaded green vertical bands for each charging period
    const shapes = (DATA.chargingBands || []).map(b => ({
        type: 'rect', xref: 'x', yref: 'paper',
        x0: b.start_ts, x1: b.end_ts, y0: 0, y1: 1,
        fillcolor: 'rgba(34, 197, 94, 0.10)',
        line: { width: 0 },
        layer: 'below',
    }));

    Plotly.newPlot('chart-charge', traces, baseLayout({
        yaxis: { gridcolor: COLORS.border, zeroline: false, color: COLORS.fgDim, range: [0, 100], ticksuffix: '%', dtick: 20 },
        xaxis: { gridcolor: COLORS.border, zeroline: false, color: COLORS.fgDim, type: 'date',
                 rangeslider: { thickness: 0.05, bgcolor: COLORS.bg } },
        shapes,
        showlegend: false,
        annotations: shapes.length ? [{
            xref: 'paper', yref: 'paper', x: 1, y: 1.02, xanchor: 'right',
            text: '<span style="color:' + COLORS.charging + '">▮</span> green bands = charging periods',
            showarrow: false, font: { color: COLORS.fgDim, size: 11 },
        }] : [],
    }), config);
}

// ---- chart: drain ----
function renderDrain() {
    if (!DATA.drain.length) {
        document.getElementById('chart-drain').innerHTML = '<div class="empty">no discharge data yet</div>';
        return;
    }
    Plotly.newPlot('chart-drain', [{
        x: DATA.drain.map(r => r.ts),
        y: DATA.drain.map(r => r.watts),
        type: 'scattergl', mode: 'lines',
        line: { color: COLORS.drain, width: 1 },
        name: 'drain',
        hovertemplate: '%{y:.2f} W<extra>%{x}</extra>',
    }], baseLayout({
        yaxis: { gridcolor: COLORS.border, zeroline: false, color: COLORS.fgDim, ticksuffix: ' W' },
        xaxis: { gridcolor: COLORS.border, zeroline: false, color: COLORS.fgDim, type: 'date' },
        showlegend: false,
    }), config);
}

// ---- chart: hourly bars ----
function renderHourly() {
    if (!DATA.hourly.length) {
        document.getElementById('chart-hourly').innerHTML = '<div class="empty">no data yet</div>';
        return;
    }
    Plotly.newPlot('chart-hourly', [{
        x: DATA.hourly.map(r => r.hour_ist),
        y: DATA.hourly.map(r => r.avg_w),
        type: 'bar',
        marker: { color: COLORS.discharging },
        hovertemplate: 'hour %{x}: %{y:.2f} W avg<extra></extra>',
    }], baseLayout({
        yaxis: { gridcolor: COLORS.border, zeroline: false, color: COLORS.fgDim, ticksuffix: ' W' },
        xaxis: { gridcolor: COLORS.border, zeroline: false, color: COLORS.fgDim,
                 tickmode: 'linear', tick0: 0, dtick: 2, title: 'hour of day (IST)' },
        showlegend: false,
    }), config);
}

// ---- chart: SOT bars ----
function renderSot() {
    if (!DATA.daily.length) {
        document.getElementById('chart-sot').innerHTML = '<div class="empty">no daily aggregates yet</div>';
        return;
    }
    Plotly.newPlot('chart-sot', [{
        x: DATA.daily.map(r => r.date),
        y: DATA.daily.map(r => (r.sot_minutes || 0) / 60),
        type: 'bar',
        marker: { color: COLORS.discharging },
        hovertemplate: '%{x}<br>%{y:.2f} h SOT<extra></extra>',
    }], baseLayout({
        yaxis: { gridcolor: COLORS.border, zeroline: false, color: COLORS.fgDim, ticksuffix: ' h' },
        xaxis: { gridcolor: COLORS.border, zeroline: false, color: COLORS.fgDim, type: 'date' },
        showlegend: false,
    }), config);
}

// ---- chart: daily drain ----
function renderDailyDrain() {
    if (!DATA.daily.length) {
        document.getElementById('chart-daily-drain').innerHTML = '<div class="empty">no daily aggregates yet</div>';
        return;
    }
    Plotly.newPlot('chart-daily-drain', [{
        x: DATA.daily.map(r => r.date),
        y: DATA.daily.map(r => r.avg_drain_w_sot),
        type: 'bar',
        marker: { color: COLORS.drain },
        hovertemplate: '%{x}<br>%{y:.2f} W avg<extra></extra>',
    }], baseLayout({
        yaxis: { gridcolor: COLORS.border, zeroline: false, color: COLORS.fgDim, ticksuffix: ' W' },
        xaxis: { gridcolor: COLORS.border, zeroline: false, color: COLORS.fgDim, type: 'date' },
        showlegend: false,
    }), config);
}

// ---- chart: health ----
function renderHealth() {
    if (!DATA.health.length) {
        document.getElementById('chart-health').innerHTML = '<div class="empty">need more days of data</div>';
        return;
    }
    Plotly.newPlot('chart-health', [{
        x: DATA.health.map(r => r.date),
        y: DATA.health.map(r => r.health_pct),
        type: 'scatter', mode: 'lines+markers',
        line: { color: COLORS.health, width: 2 },
        marker: { size: 5 },
        hovertemplate: '%{x}<br>%{y:.2f}%<extra></extra>',
    }], baseLayout({
        yaxis: { gridcolor: COLORS.border, zeroline: false, color: COLORS.fgDim, ticksuffix: '%',
                 range: [80, 102] },
        xaxis: { gridcolor: COLORS.border, zeroline: false, color: COLORS.fgDim, type: 'date' },
        showlegend: false,
    }), config);
}

// ---- table: sessions ----
function renderSessions() {
    const tbody = document.querySelector('#sessions-table tbody');
    if (!DATA.sessions.length) {
        tbody.innerHTML = '<tr><td colspan="8" class="empty">no sessions yet — wait for poller to accumulate samples</td></tr>';
        return;
    }
    const fmtDur = (sec) => {
        if (!sec) return '—';
        const h = Math.floor(sec / 3600);
        const m = Math.floor((sec % 3600) / 60);
        return `${h}h ${m}m`;
    };
    tbody.innerHTML = DATA.sessions.map(s => `
        <tr>
            <td>${s.start_ts || '—'}</td>
            <td>${fmtDur(s.duration_seconds)}</td>
            <td>${fmtDur(s.sot_seconds)}</td>
            <td>${s.start_pct}% → ${s.end_pct}%</td>
            <td>${s.energy_used_wh ?? '—'}</td>
            <td>${s.avg_drain_w ?? '—'}</td>
            <td>${s.avg_drain_w_sot ?? '—'}</td>
            <td>${s.projected_full_runtime_hours ? s.projected_full_runtime_hours + ' h' : '—'}</td>
        </tr>
    `).join('');
}

// ---- table: powertop ----
function renderPowertop() {
    const tbody = document.querySelector('#powertop-table tbody');
    const meta = document.getElementById('powertop-meta');
    if (!DATA.powertop.length || !DATA.powertop[0].rank) {
        tbody.innerHTML = '<tr><td colspan="4" class="empty">no powertop runs yet — try <code>battery-stats powertop 30 "baseline"</code></td></tr>';
        meta.textContent = '';
        return;
    }
    const head = DATA.powertop[0];
    meta.innerHTML = `captured ${head.captured_at} &middot; ${head.duration_seconds}s &middot; ${head.on_ac === 'true' || head.on_ac === true ? 'on AC' : 'on battery'}${head.notes ? ' &middot; ' + head.notes : ''}`;
    tbody.innerHTML = DATA.powertop.map(p => `
        <tr>
            <td>${p.rank ?? '—'}</td>
            <td>${(p.description || '').replace(/[<>&]/g, c => ({ '<':'&lt;', '>':'&gt;', '&':'&amp;' }[c]))}</td>
            <td>${p.pw_estimate_w ?? '—'}</td>
            <td>${p.wakeups_per_sec ?? '—'}</td>
        </tr>
    `).join('');
}

renderCards();
renderCharge();
renderDrain();
renderHourly();
renderSot();
renderDailyDrain();
renderHealth();
renderSessions();
renderPowertop();
</script>
</body>
</html>
JS_EOF

echo "$OUT"
