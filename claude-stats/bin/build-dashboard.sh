#!/bin/bash
# build-dashboard.sh — generate self-contained HTML dashboard from claude.duckdb
# usage: build-dashboard.sh [days=30] [output_path]
set -euo pipefail

DB="$HOME/Documents/claude-stats/claude.duckdb"
DUCKDB="$HOME/.local/bin/duckdb"
SPEC="${1:-30}"
OUT="${2:-/tmp/claude-stats-dashboard.html}"

# ---- resolve the time window ----
# SPEC is either an integer day-count (rolling window, default 30) or
# "month:M[:Y]" for a calendar month. Produces, for every query below:
#   WIN_LO / WIN_HI  — SQL date-literal bounds, used half-open: [WIN_LO, WIN_HI)
#   WINDOW_LABEL     — human label shown in the header
#   WINDOW_DAYS      — denominator for the "active / N days" header stat
#   REBUILD_HINT     — the invocation echoed in the footer
case "$SPEC" in
    month:*)
        IFS=':' read -r _ MONTH YEAR <<< "$SPEC"
        if ! [[ "$MONTH" =~ ^[0-9]+$ ]] || [ "$MONTH" -lt 1 ] || [ "$MONTH" -gt 12 ]; then
            echo "claude-stats: month must be 1-12 (got '$MONTH')" >&2
            exit 1
        fi
        if [ -z "$YEAR" ]; then
            # smart fallback: a month later than the current one means last year
            cur_year=$(date +%Y); cur_month=$(date +%-m)
            if [ "$MONTH" -gt "$cur_month" ]; then
                YEAR=$((cur_year - 1))
            else
                YEAR="$cur_year"
            fi
        fi
        if ! [[ "$YEAR" =~ ^[0-9]{4}$ ]]; then
            echo "claude-stats: year must be 4 digits (got '$YEAR')" >&2
            exit 1
        fi
        MM=$(printf '%02d' "$MONTH")
        WIN_LO="DATE '$YEAR-$MM-01'"
        WIN_HI="DATE '$(date -d "$YEAR-$MM-01 +1 month" +%Y-%m-%d)'"   # first of next month, exclusive
        WINDOW_LABEL="$(date -d "$YEAR-$MM-01" +'%B %Y')"
        WINDOW_DAYS="$(date -d "$YEAR-$MM-01 +1 month -1 day" +%-d)"   # days in this month
        REBUILD_HINT="claude-stats dashboard month $MONTH $YEAR"
        ;;
    *)
        if ! [[ "$SPEC" =~ ^[0-9]+$ ]]; then
            echo "claude-stats: arg must be a day count or 'month M [Y]' (got '$SPEC')" >&2
            exit 1
        fi
        DAYS="$SPEC"
        WIN_LO="CURRENT_DATE - INTERVAL $DAYS DAY"
        WIN_HI="CURRENT_DATE + INTERVAL 1 DAY"          # tomorrow, exclusive (keeps today)
        WINDOW_LABEL="last $DAYS days"
        WINDOW_DAYS="$DAYS"
        REBUILD_HINT="claude-stats dashboard [days=$DAYS]"
        ;;
esac

# bounded predicates spliced into every windowed query (half-open [LO, HI))
WHERE_DATE="date >= $WIN_LO AND date < $WIN_HI"
WHERE_STARTED="started_at >= $WIN_LO AND started_at < $WIN_HI"
WHERE_CSTARTED="c.started_at >= $WIN_LO AND c.started_at < $WIN_HI"

if [ ! -f "$DB" ]; then
    echo "claude-stats: db not found at $DB" >&2
    echo "  run: claude-stats ingest && claude-stats ingest-sessions" >&2
    exit 1
fi

q() { "$DUCKDB" -readonly -json "$DB" "$1"; }

# ---- gather data ----

# headline stats
STATS=$(q "
    WITH win AS (
        SELECT * FROM daily_usage WHERE $WHERE_DATE
    ),
    convo AS (
        SELECT
            COUNT(*) FILTER (WHERE kind = 'main')     AS n_main,
            COUNT(*) FILTER (WHERE kind = 'subagent') AS n_subagent,
            SUM(n_tool_calls)                         AS total_tool_calls
        FROM conversations
        WHERE $WHERE_STARTED
    )
    SELECT
        ROUND(SUM(cost), 2)                                                    AS total_cost,
        COUNT(DISTINCT date)                                                   AS active_days,
        $WINDOW_DAYS                                                           AS window_days,
        SUM(input_tokens + output_tokens + cache_creation_tokens + cache_read_tokens) AS total_tokens,
        SUM(cache_read_tokens)                                                 AS cache_reads,
        SUM(cache_creation_tokens + input_tokens)                              AS uncached_eq,
        ROUND(SUM(cache_read_tokens) * 100.0
              / NULLIF(SUM(input_tokens + cache_creation_tokens + cache_read_tokens), 0), 1) AS cache_hit_pct,
        (SELECT n_main FROM convo)                                             AS n_main_sessions,
        (SELECT n_subagent FROM convo)                                         AS n_subagents,
        (SELECT total_tool_calls FROM convo)                                   AS total_tool_calls,
        ROUND(SUM(cost) / NULLIF(COUNT(DISTINCT date), 0), 2)                  AS avg_cost_per_day
    FROM win;
")

# daily cost stacked by model
DAILY_COST=$(q "
    SELECT
        date::VARCHAR AS date,
        model,
        ROUND(SUM(cost), 4) AS cost
    FROM daily_usage
    WHERE $WHERE_DATE
    GROUP BY date, model
    ORDER BY date, model;
")

# daily token mix (stacked bar: input / output / cache create / cache read)
DAILY_TOKENS=$(q "
    SELECT
        date::VARCHAR AS date,
        SUM(input_tokens)          AS input_tokens,
        SUM(output_tokens)         AS output_tokens,
        SUM(cache_creation_tokens) AS cache_creation_tokens,
        SUM(cache_read_tokens)     AS cache_read_tokens
    FROM daily_usage
    WHERE $WHERE_DATE
    GROUP BY date
    ORDER BY date;
")

# cost by model over the window
BY_MODEL=$(q "
    SELECT
        model,
        ROUND(SUM(cost), 2) AS cost,
        SUM(input_tokens + output_tokens + cache_creation_tokens + cache_read_tokens) AS tokens,
        COUNT(DISTINCT date) AS active_days
    FROM daily_usage
    WHERE $WHERE_DATE
    GROUP BY model
    ORDER BY cost DESC;
")

# cache hit rate over time (per day)
CACHE_TREND=$(q "
    SELECT
        date::VARCHAR AS date,
        ROUND(SUM(cache_read_tokens) * 100.0
              / NULLIF(SUM(input_tokens + cache_creation_tokens + cache_read_tokens), 0), 2) AS cache_hit_pct
    FROM daily_usage
    WHERE $WHERE_DATE
    GROUP BY date
    ORDER BY date;
")

# top tools (window-scoped: tools used in conversations started within window)
TOP_TOOLS=$(q "
    SELECT
        t.tool_name,
        SUM(t.call_count) AS total_calls,
        COUNT(DISTINCT t.session_id) AS sessions
    FROM conversation_tool_usage t
    JOIN conversations c USING (session_id)
    WHERE $WHERE_CSTARTED
    GROUP BY t.tool_name
    ORDER BY total_calls DESC
    LIMIT 15;
")

# top skills (window-scoped). plugin = prefix before ':' or 'personal' if bare name
TOP_SKILLS=$(q "
    SELECT
        CASE WHEN s.skill_name LIKE '%:%'
             THEN split_part(s.skill_name, ':', 1)
             ELSE 'personal' END AS plugin,
        s.skill_name AS full_name,
        CASE WHEN s.skill_name LIKE '%:%'
             THEN split_part(s.skill_name, ':', 2)
             ELSE s.skill_name END AS skill,
        SUM(s.call_count) AS total_calls,
        COUNT(DISTINCT s.session_id) AS sessions
    FROM conversation_skill_usage s
    JOIN conversations c USING (session_id)
    WHERE $WHERE_CSTARTED
    GROUP BY plugin, full_name, skill
    ORDER BY total_calls DESC
    LIMIT 20;
")

# top subagents by name — windowed, only rows where the parent JSONL was still on disk
# at ingest time (agent_type IS NOT NULL). Matches /usage's per-agent breakdown.
TOP_SUBAGENTS=$(q "
    SELECT
        agent_type,
        COUNT(*)               AS sessions,
        SUM(n_tool_calls)      AS total_tool_calls,
        ROUND(AVG(n_tool_calls), 1) AS avg_tool_calls
    FROM conversations
    WHERE kind = 'subagent'
      AND agent_type IS NOT NULL
      AND $WHERE_STARTED
    GROUP BY agent_type
    ORDER BY sessions DESC
    LIMIT 20;
")

# unmatched subagent count for the panel footer (so the user knows what's missing)
SUBAGENT_COVERAGE=$(q "
    SELECT
        COUNT(*) FILTER (WHERE agent_type IS NOT NULL) AS matched,
        COUNT(*) FILTER (WHERE agent_type IS NULL)     AS unmatched
    FROM conversations
    WHERE kind = 'subagent'
      AND $WHERE_STARTED;
")

# top repos by cost — windowed, using project_daily_usage which mirrors daily_usage's
# write semantics with a project_path dimension. Sums to daily_usage exactly for any
# date ccusage could see at ingest time. Days with no project_daily_usage rows show up
# as the "unattributed" gap below (= JSONLs cleaned before they were captured here).
TOP_REPOS=$(q "
    WITH proj_costs AS (
        SELECT
            project_path,
            SUM(cost)                          AS cost,
            MAX(date)                          AS last_activity,
            STRING_AGG(DISTINCT model, ', ')   AS models_used
        FROM project_daily_usage
        WHERE $WHERE_DATE
        GROUP BY project_path
    ),
    conv AS (
        SELECT
            project_path,
            MAX(cwd) AS cwd,
            COUNT(*) FILTER (WHERE kind = 'main')     AS n_main,
            COUNT(*) FILTER (WHERE kind = 'subagent') AS n_subagent,
            SUM(n_tool_calls)                         AS total_tool_calls
        FROM conversations
        WHERE $WHERE_STARTED
        GROUP BY project_path
    )
    SELECT
        COALESCE(NULLIF(c.cwd, ''), p.project_path) AS path,
        ROUND(p.cost, 2)         AS cost,
        p.last_activity::VARCHAR AS last_activity,
        c.n_main,
        c.n_subagent,
        c.total_tool_calls,
        p.models_used
    FROM proj_costs p
    LEFT JOIN conv c USING (project_path)
    ORDER BY p.cost DESC
    LIMIT 12;
")

# attribution gap for the window — daily_usage is the truth; project_daily_usage
# is what we could attribute. Difference = JSONLs deleted before capture.
ATTRIBUTION=$(q "
    WITH d AS (SELECT COALESCE(SUM(cost), 0) AS total FROM daily_usage         WHERE $WHERE_DATE),
         p AS (SELECT COALESCE(SUM(cost), 0) AS attributed FROM project_daily_usage WHERE $WHERE_DATE)
    SELECT
        ROUND((SELECT total      FROM d), 2) AS total,
        ROUND((SELECT attributed FROM p), 2) AS attributed,
        ROUND((SELECT total FROM d) - (SELECT attributed FROM p), 2) AS unattributed,
        ROUND(100.0 * (SELECT attributed FROM p) / NULLIF((SELECT total FROM d), 0), 0) AS attributed_pct;
")

# context-window fullness across main sessions in window
CONTEXT_DIST=$(q "
    WITH base AS (
        SELECT
            COALESCE(NULLIF(model, ''), 'unknown') AS model,
            max_context_tokens AS ctx,
            CASE
                WHEN model LIKE 'claude-opus-4-7%'    THEN 1000000
                WHEN model LIKE 'claude-opus-4-6%'    THEN 200000
                WHEN model LIKE 'claude-sonnet-4-6%'  THEN 200000
                WHEN model LIKE 'claude-sonnet-4-5%'  THEN 200000
                WHEN model LIKE 'claude-haiku-4-5%'   THEN 200000
                ELSE 200000
            END AS window_size
        FROM conversations
        WHERE kind = 'main'
          AND max_context_tokens > 0
          AND $WHERE_STARTED
    )
    SELECT
        CASE
            WHEN ctx * 100.0 / window_size < 25  THEN '< 25% (fresh)'
            WHEN ctx * 100.0 / window_size < 50  THEN '25-50% (light)'
            WHEN ctx * 100.0 / window_size < 75  THEN '50-75% (heavy)'
            WHEN ctx * 100.0 / window_size < 95  THEN '75-95% (near full)'
            ELSE '95-100% (compaction risk)'
        END AS bucket,
        COUNT(*) AS sessions
    FROM base
    GROUP BY bucket
    ORDER BY MIN(ctx * 100.0 / window_size);
")

# recent main sessions
SESSIONS=$(q "
    SELECT
        STRFTIME((started_at AT TIME ZONE 'UTC') AT TIME ZONE 'Asia/Kolkata', '%Y-%m-%d %H:%M IST') AS started,
        CASE WHEN length(cwd) > 60 THEN '...' || substr(cwd, length(cwd) - 57) ELSE cwd END AS cwd,
        git_branch,
        n_user_msgs,
        n_assistant_msgs,
        n_tool_calls,
        ROUND(max_context_tokens / 1000.0, 1) AS max_ctx_k,
        model,
        CASE WHEN length(summary) > 80 THEN substr(summary, 1, 77) || '...' ELSE summary END AS summary
    FROM conversations
    WHERE kind = 'main' AND started_at IS NOT NULL
    ORDER BY started_at DESC
    LIMIT 25;
")

GENERATED_AT=$(TZ=Asia/Kolkata date "+%Y-%m-%d %H:%M:%S IST")

# Pull attribution scalars out of the ATTRIBUTION JSON for header substitution.
# Defaults guard against an empty window (no rows).
ATTR_TOTAL=$(printf '%s' "$ATTRIBUTION"        | jq -r '.[0].total        // 0')
ATTR_ATTRIBUTED=$(printf '%s' "$ATTRIBUTION"   | jq -r '.[0].attributed   // 0')
ATTR_UNATTRIBUTED=$(printf '%s' "$ATTRIBUTION" | jq -r '.[0].unattributed // 0')
ATTR_PCT=$(printf '%s' "$ATTRIBUTION"          | jq -r '.[0].attributed_pct // 100')

SUB_MATCHED=$(printf   '%s' "$SUBAGENT_COVERAGE" | jq -r '.[0].matched   // 0')
SUB_UNMATCHED=$(printf '%s' "$SUBAGENT_COVERAGE" | jq -r '.[0].unmatched // 0')

# ---- emit HTML ----
cat > "$OUT" <<'HEAD_EOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>claude-stats — dashboard</title>
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
    color: var(--fg);
}
.card .value .unit {
    font-size: 13px;
    color: var(--fg-dim);
    margin-left: 4px;
    font-weight: 400;
    letter-spacing: 0;
}
.card .meta { font-size: 11px; color: var(--fg-dim); margin-top: 10px; }
.card.accent .value { color: var(--primary); }
.card.cyan .value { color: var(--secondary); }
.card.good .value { color: var(--good); }
.card.warn .value { color: var(--warn); }
.card.pink .value { color: var(--pink); }
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
.row-3 { display: grid; grid-template-columns: 2fr 1fr; gap: 16px; }
@media (max-width: 1000px) {
    .row, .row-3 { grid-template-columns: 1fr; }
}
.chart { width: 100%; height: 340px; }
.chart-tall { height: 400px; }
.chart-short { height: 260px; }
table { width: 100%; border-collapse: collapse; font-size: 12.5px; }
th {
    text-align: left;
    padding: 11px 14px;
    background: transparent;
    color: var(--fg-dim);
    font-weight: 500;
    text-transform: uppercase;
    font-size: 10px;
    letter-spacing: 0.08em;
    position: sticky;
    top: 0;
    border-bottom: 1px solid var(--border);
    background: var(--panel);
}
td { padding: 11px 14px; border-top: 1px solid var(--border); color: var(--fg); }
td.dim { color: var(--fg-dim); }
td.num { font-variant-numeric: tabular-nums; }
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
    background: var(--panel-2);
    color: var(--fg-dim);
}
.tag.opus { background: var(--primary-soft); color: var(--primary); }
.tag.sonnet { background: var(--secondary-soft); color: var(--secondary); }
.tag.haiku { background: var(--good-soft); color: var(--good); }
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
        <h1>claude-stats</h1>
        <span class="sub">window: $WINDOW_LABEL</span>
    </div>
    <div class="sub">generated $GENERATED_AT &middot; <code>$DB</code></div>
</div>

<div class="cards" id="cards"></div>

<div class="panel">
    <h2>Daily cost (USD) by model</h2>
    <div id="chart-daily-cost" class="chart chart-tall"></div>
</div>

<div class="row">
    <div class="panel">
        <h2>Daily token mix</h2>
        <div id="chart-tokens" class="chart"></div>
    </div>
    <div class="panel">
        <h2>Cache hit rate over time</h2>
        <div id="chart-cache" class="chart"></div>
    </div>
</div>

<div class="row-3">
    <div class="panel">
        <h2>Top tools (calls)</h2>
        <div id="chart-tools" class="chart chart-tall"></div>
    </div>
    <div class="panel">
        <h2>Cost by model</h2>
        <div id="chart-models" class="chart chart-tall"></div>
    </div>
</div>

<div class="panel">
    <h2>Top skills (by plugin)</h2>
    <div id="chart-skills" class="chart chart-tall"></div>
</div>

<div class="panel">
    <h2>Top subagents (by name)</h2>
    <div class="sub" style="margin: -8px 0 8px; color: var(--fg-dim); font-size: 12px;">$SUB_MATCHED matched &middot; $SUB_UNMATCHED unmatched (parent JSONL cleaned before ingest)</div>
    <div id="chart-subagents" class="chart chart-tall"></div>
</div>

<div class="row-3">
    <div class="panel">
        <h2>Top projects &middot; $WINDOW_LABEL</h2>
        <div class="sub" style="margin: -8px 0 8px; color: var(--fg-dim); font-size: 12px;">\$$ATTR_ATTRIBUTED of \$$ATTR_TOTAL attributed (${ATTR_PCT}%) &middot; \$$ATTR_UNATTRIBUTED unattributable (cleaned/missing JSONLs)</div>
        <div id="chart-repos" class="chart chart-tall"></div>
    </div>
    <div class="panel">
        <h2>Context window usage (main sessions)</h2>
        <div id="chart-context" class="chart chart-tall"></div>
    </div>
</div>

<div class="panel">
    <h2>Recent main sessions</h2>
    <div class="scroll">
        <table id="sessions-table">
            <thead>
                <tr>
                    <th>started (IST)</th>
                    <th>cwd</th>
                    <th>branch</th>
                    <th>u/a msgs</th>
                    <th>tools</th>
                    <th>peak ctx</th>
                    <th>model</th>
                    <th>summary</th>
                </tr>
            </thead>
            <tbody></tbody>
        </table>
    </div>
</div>

<footer>
    rebuild: <code>$REBUILD_HINT</code> &middot;
    raw queries: <code>~/.local/bin/duckdb -readonly $DB</code>
</footer>
HEADER_EOF

# data block
cat >> "$OUT" <<'JS_PRELUDE'
<script>
const DATA = {
JS_PRELUDE

printf '    stats: %s,\n'        "$STATS"        >> "$OUT"
printf '    dailyCost: %s,\n'    "$DAILY_COST"   >> "$OUT"
printf '    dailyTokens: %s,\n'  "$DAILY_TOKENS" >> "$OUT"
printf '    byModel: %s,\n'      "$BY_MODEL"     >> "$OUT"
printf '    cacheTrend: %s,\n'   "$CACHE_TREND"  >> "$OUT"
printf '    topTools: %s,\n'     "$TOP_TOOLS"    >> "$OUT"
printf '    topSkills: %s,\n'    "$TOP_SKILLS"   >> "$OUT"
printf '    topSubagents: %s,\n' "$TOP_SUBAGENTS" >> "$OUT"
printf '    topRepos: %s,\n'     "$TOP_REPOS"    >> "$OUT"
printf '    attribution: %s,\n'  "$ATTRIBUTION"  >> "$OUT"
printf '    contextDist: %s,\n'  "$CONTEXT_DIST" >> "$OUT"
printf '    sessions: %s,\n'     "$SESSIONS"     >> "$OUT"

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
    good: '#22c55e',
    warn: '#f59e0b',
    bad: '#ef4444',
    pink: '#ec4899',
    indigo: '#6366f1',
    teal: '#14b8a6',
};

// stable color per model — family hue, version-ranked lightness.
// Each family keeps its brand hue (opus=purple, sonnet=cyan, haiku=green); the
// NEWEST version present gets the bright brand shade and each older sibling dims
// one step. Fully automatic: a new model id slots in by the version embedded in
// its name (claude-opus-4-8 -> 408), so a future model needs no code change.
const MODEL_FAMILIES = {
    opus:   { h: 255, s: 92 },
    sonnet: { h: 189, s: 86 },
    haiku:  { h: 142, s: 71 },
};
const MODEL_BASE_L  = 76;   // newest version lightness (matches today's brand hexes)
const MODEL_L_STEP  = 10;   // dim per older version
const MODEL_L_FLOOR = 38;   // never darker than this (stays legible on AMOLED black)

function familyOf(m) {
    if (!m) return null;
    if (m.includes('opus'))   return 'opus';
    if (m.includes('sonnet')) return 'sonnet';
    if (m.includes('haiku'))  return 'haiku';
    return null;
}

// version sort key from "...-MAJOR-MINOR..." (claude-opus-4-7 -> 407); higher = newer
function versionKey(m) {
    const x = (m || '').match(/-(\d+)-(\d+)/);
    return x ? Number(x[1]) * 100 + Number(x[2]) : 0;
}

// built lazily from every model id across the dataset, memoized for the page
let _modelColorMap = null;
function buildModelColorMap() {
    const ids = new Set();
    for (const src of [DATA.dailyCost, DATA.byModel, DATA.sessions]) {
        if (Array.isArray(src)) src.forEach(r => { if (r && r.model) ids.add(r.model); });
    }
    const byFamily = {};
    for (const id of ids) {
        const fam = familyOf(id);
        if (fam) (byFamily[fam] ||= []).push(id);
    }
    const map = {};
    for (const fam of Object.keys(byFamily)) {
        const { h, s } = MODEL_FAMILIES[fam];
        const ranked = byFamily[fam].sort((a, b) => versionKey(b) - versionKey(a));
        const rankByVersion = {};   // same version => same shade
        let nextRank = 0;
        for (const id of ranked) {
            const vk = versionKey(id);
            if (!(vk in rankByVersion)) rankByVersion[vk] = nextRank++;
            const l = Math.max(MODEL_L_FLOOR, MODEL_BASE_L - rankByVersion[vk] * MODEL_L_STEP);
            map[id] = `hsl(${h}, ${s}%, ${l}%)`;
        }
    }
    return map;
}

function colorForModel(m) {
    if (!m) return COLORS.fgDim;
    if (!_modelColorMap) _modelColorMap = buildModelColorMap();
    return _modelColorMap[m] || COLORS.warn;
}

function tagForModel(m) {
    if (!m) return '';
    const fam = familyOf(m);
    if (!fam) return `<span class="tag">${m}</span>`;
    // family-soft background from the CSS class; text color carries the version shade
    return `<span class="tag ${fam}" style="color:${colorForModel(m)}">${m}</span>`;
}

function fmtNum(n) {
    if (n == null) return '—';
    if (n >= 1e9) return (n / 1e9).toFixed(2) + 'B';
    if (n >= 1e6) return (n / 1e6).toFixed(2) + 'M';
    if (n >= 1e3) return (n / 1e3).toFixed(1) + 'K';
    return n.toString();
}

const baseLayout = (extra = {}) => ({
    paper_bgcolor: COLORS.panel,
    plot_bgcolor: COLORS.panel,
    font: { color: COLORS.fg, family: 'Inter, system-ui, sans-serif', size: 11 },
    margin: { l: 56, r: 16, t: 8, b: 44 },
    xaxis: {
        gridcolor: COLORS.border,
        zeroline: false,
        color: COLORS.fgDim,
        tickfont: { size: 10 },
    },
    yaxis: {
        gridcolor: COLORS.border,
        zeroline: false,
        color: COLORS.fgDim,
        tickfont: { size: 10 },
    },
    hovermode: 'x unified',
    hoverlabel: {
        bgcolor: COLORS.bg,
        bordercolor: COLORS.primary,
        font: { color: COLORS.fg, family: 'Inter, system-ui, sans-serif', size: 11 },
    },
    legend: {
        orientation: 'h',
        y: -0.22,
        font: { color: COLORS.fgDim, size: 10 },
        bgcolor: 'transparent',
    },
    ...extra,
});

const config = { responsive: true, displaylogo: false,
    modeBarButtonsToRemove: ['lasso2d', 'select2d', 'autoScale2d'] };

// ---- cards ----
function renderCards() {
    const s = (DATA.stats && DATA.stats[0]) || {};
    const cards = [
        { label: 'Total spend', value: '$' + (s.total_cost ?? 0), cls: 'accent',
          meta: `~$${s.avg_cost_per_day ?? 0}/day` },
        { label: 'Active days', value: s.active_days ?? 0,
          unit: '/ ' + (s.window_days ?? 0),
          meta: s.window_days ? Math.round((s.active_days || 0) / s.window_days * 100) + '% activity' : '' },
        { label: 'Total tokens', value: fmtNum(s.total_tokens), cls: 'cyan',
          meta: 'input + output + cache' },
        { label: 'Cache hit rate', value: (s.cache_hit_pct ?? '—'), unit: '%',
          cls: (s.cache_hit_pct ?? 0) >= 70 ? 'good' : (s.cache_hit_pct ?? 0) >= 40 ? 'warn' : 'pink',
          meta: fmtNum(s.cache_reads) + ' read tokens' },
        { label: 'Main sessions', value: s.n_main_sessions ?? 0, cls: 'accent',
          meta: (s.n_subagents ?? 0) + ' subagents' },
        { label: 'Tool calls', value: fmtNum(s.total_tool_calls), cls: 'cyan',
          meta: 'across all sessions in window' },
    ];
    document.getElementById('cards').innerHTML = cards.map(c => `
        <div class="card ${c.cls || ''}">
            <div class="label">${c.label}</div>
            <div class="value">${c.value}<span class="unit">${c.unit || ''}</span></div>
            ${c.meta ? `<div class="meta">${c.meta}</div>` : ''}
        </div>
    `).join('');
}

// ---- daily cost stacked bar (one trace per model) ----
function renderDailyCost() {
    if (!DATA.dailyCost.length) {
        document.getElementById('chart-daily-cost').innerHTML = '<div class="empty">no daily cost data in window</div>';
        return;
    }
    const allDates = [...new Set(DATA.dailyCost.map(r => r.date))].sort();
    const models = [...new Set(DATA.dailyCost.map(r => r.model))];
    const traces = models.map(m => {
        const dataMap = Object.fromEntries(
            DATA.dailyCost.filter(r => r.model === m).map(r => [r.date, r.cost])
        );
        return {
            x: allDates,
            y: allDates.map(d => dataMap[d] || 0),
            name: m,
            type: 'bar',
            marker: { color: colorForModel(m), line: { width: 0 } },
            hovertemplate: '%{y:$.2f} <span style="color:#6b7280">' + m + '</span><extra></extra>',
        };
    });
    Plotly.newPlot('chart-daily-cost', traces, baseLayout({
        barmode: 'stack',
        yaxis: { gridcolor: COLORS.border, zeroline: false, color: COLORS.fgDim,
                 tickprefix: '$', tickfont: { size: 10 } },
        xaxis: { gridcolor: COLORS.border, zeroline: false, color: COLORS.fgDim,
                 type: 'date', tickfont: { size: 10 } },
        showlegend: true,
    }), config);
}

// ---- daily token mix ----
function renderTokens() {
    if (!DATA.dailyTokens.length) {
        document.getElementById('chart-tokens').innerHTML = '<div class="empty">no token data</div>';
        return;
    }
    const x = DATA.dailyTokens.map(r => r.date);
    const traces = [
        { name: 'cache read',    y: DATA.dailyTokens.map(r => r.cache_read_tokens),     color: COLORS.primary },
        { name: 'cache create',  y: DATA.dailyTokens.map(r => r.cache_creation_tokens), color: COLORS.secondary },
        { name: 'input',         y: DATA.dailyTokens.map(r => r.input_tokens),          color: COLORS.warn },
        { name: 'output',        y: DATA.dailyTokens.map(r => r.output_tokens),         color: COLORS.pink },
    ].map(t => ({
        x, y: t.y, name: t.name, type: 'bar',
        marker: { color: t.color, line: { width: 0 } },
        hovertemplate: '<b>%{y:.3s}</b> ' + t.name + '<extra></extra>',
    }));
    Plotly.newPlot('chart-tokens', traces, baseLayout({
        barmode: 'stack',
        yaxis: { gridcolor: COLORS.border, zeroline: false, color: COLORS.fgDim, tickformat: '.2s' },
        xaxis: { gridcolor: COLORS.border, zeroline: false, color: COLORS.fgDim, type: 'date' },
        showlegend: true,
    }), config);
}

// ---- cache hit rate ----
function renderCache() {
    if (!DATA.cacheTrend.length) {
        document.getElementById('chart-cache').innerHTML = '<div class="empty">no cache data</div>';
        return;
    }
    Plotly.newPlot('chart-cache', [{
        x: DATA.cacheTrend.map(r => r.date),
        y: DATA.cacheTrend.map(r => r.cache_hit_pct),
        type: 'scatter', mode: 'lines+markers',
        line: { color: COLORS.primary, width: 2.5, shape: 'spline', smoothing: 0.6 },
        marker: { size: 6, color: COLORS.primary, line: { color: COLORS.bg, width: 1 } },
        fill: 'tozeroy',
        fillcolor: 'rgba(167, 139, 250, 0.10)',
        hovertemplate: '<b>%{y:.1f}%</b> hit rate<br><span style="color:#6b7280">%{x}</span><extra></extra>',
    }], baseLayout({
        yaxis: { gridcolor: COLORS.border, zeroline: false, color: COLORS.fgDim,
                 ticksuffix: '%', range: [0, 100] },
        xaxis: { gridcolor: COLORS.border, zeroline: false, color: COLORS.fgDim, type: 'date' },
        showlegend: false,
    }), config);
}

// ---- top tools horizontal bar ----
function renderTools() {
    if (!DATA.topTools.length) {
        document.getElementById('chart-tools').innerHTML = '<div class="empty">no tool data — run claude-stats ingest-sessions</div>';
        return;
    }
    const sorted = [...DATA.topTools].reverse(); // for horizontal bar (bottom = highest)
    Plotly.newPlot('chart-tools', [{
        x: sorted.map(r => r.total_calls),
        y: sorted.map(r => r.tool_name),
        type: 'bar',
        orientation: 'h',
        marker: { color: COLORS.secondary, line: { width: 0 } },
        text: sorted.map(r => fmtNum(r.total_calls)),
        textposition: 'outside',
        textfont: { color: COLORS.fgDim, size: 10 },
        hovertemplate: '<b>%{y}</b><br>%{x:,} calls<br>%{customdata} sessions<extra></extra>',
        customdata: sorted.map(r => r.sessions),
    }], baseLayout({
        margin: { l: 160, r: 50, t: 8, b: 30 },
        yaxis: { gridcolor: 'transparent', zeroline: false, color: COLORS.fg,
                 tickfont: { size: 11 }, automargin: true },
        xaxis: { gridcolor: COLORS.border, zeroline: false, color: COLORS.fgDim, tickformat: '.2s' },
        showlegend: false,
    }), config);
}

// ---- top skills horizontal bar, grouped/colored by plugin ----
function renderSkills() {
    if (!DATA.topSkills.length) {
        document.getElementById('chart-skills').innerHTML = '<div class="empty">no skill data — invoke a skill (e.g. /commit, /spec) and run claude-stats ingest-sessions</div>';
        return;
    }
    // global y-order: ascending (lowest count at bottom = highest at top of horizontal bar)
    const ascending = [...DATA.topSkills].sort((a, b) => a.total_calls - b.total_calls);
    const yOrder = ascending.map(r => r.full_name);

    // group rows by plugin to produce one trace per plugin (auto-legend)
    const byPlugin = {};
    DATA.topSkills.forEach(r => {
        (byPlugin[r.plugin] ||= []).push(r);
    });

    // stable colors for known plugins, fallback palette for the rest
    const pluginColors = {
        'superpowers':           COLORS.primary,
        'agent-skills':          COLORS.secondary,
        'aws-serverless':        COLORS.warn,
        'claude-md-management':  COLORS.pink,
        'frontend-design':       COLORS.indigo,
        'code-simplifier':       COLORS.teal,
        'personal':              COLORS.good,
    };
    const fallbackPalette = [COLORS.indigo, COLORS.teal, COLORS.warn, COLORS.pink, COLORS.bad];
    let fbi = 0;

    // plugin draw order: highest total calls first (so legend reads top-down by importance)
    const pluginOrder = Object.keys(byPlugin).sort((a, b) =>
        byPlugin[b].reduce((s, r) => s + r.total_calls, 0) -
        byPlugin[a].reduce((s, r) => s + r.total_calls, 0)
    );

    const traces = pluginOrder.map(p => {
        const items = byPlugin[p];
        const color = pluginColors[p] || fallbackPalette[fbi++ % fallbackPalette.length];
        return {
            name: p,
            x: items.map(r => r.total_calls),
            y: items.map(r => r.full_name),
            type: 'bar',
            orientation: 'h',
            marker: { color, line: { width: 0 } },
            text: items.map(r => fmtNum(r.total_calls)),
            textposition: 'outside',
            textfont: { color: COLORS.fgDim, size: 10 },
            customdata: items.map(r => [r.skill, r.sessions]),
            hovertemplate:
                '<b>%{customdata[0]}</b><br>' +
                '<span style="color:#6b7280">' + p + '</span><br>' +
                '%{x:,} calls · %{customdata[1]} sessions<extra></extra>',
        };
    });

    Plotly.newPlot('chart-skills', traces, baseLayout({
        margin: { l: 240, r: 60, t: 8, b: 50 },
        yaxis: {
            gridcolor: 'transparent', zeroline: false, color: COLORS.fg,
            tickfont: { size: 11 }, automargin: true,
            categoryorder: 'array', categoryarray: yOrder,
        },
        xaxis: { gridcolor: COLORS.border, zeroline: false, color: COLORS.fgDim, tickformat: '.2s' },
        showlegend: true,
        barmode: 'overlay',
    }), config);
}

// ---- top subagents horizontal bar (count of sessions per agent_type) ----
function renderSubagents() {
    const el = document.getElementById('chart-subagents');
    if (!DATA.topSubagents.length) {
        el.innerHTML = '<div class="empty">no matched subagents in window — dispatch an agent (Task tool) and run claude-stats ingest-sessions</div>';
        return;
    }
    const sorted = [...DATA.topSubagents].reverse();
    Plotly.newPlot('chart-subagents', [{
        x: sorted.map(r => r.sessions),
        y: sorted.map(r => r.agent_type),
        type: 'bar',
        orientation: 'h',
        marker: { color: COLORS.pink, line: { width: 0 } },
        text: sorted.map(r => r.sessions),
        textposition: 'outside',
        textfont: { color: COLORS.fgDim, size: 10 },
        customdata: sorted.map(r => [r.total_tool_calls, r.avg_tool_calls]),
        hovertemplate:
            '<b>%{y}</b><br>%{x} sessions<br>' +
            '%{customdata[0]:,} tool calls (avg %{customdata[1]}/session)<extra></extra>',
    }], baseLayout({
        margin: { l: 220, r: 50, t: 8, b: 30 },
        yaxis: { gridcolor: 'transparent', zeroline: false, color: COLORS.fg,
                 tickfont: { size: 11 }, automargin: true },
        xaxis: { gridcolor: COLORS.border, zeroline: false, color: COLORS.fgDim },
        showlegend: false,
    }), config);
}

// ---- cost by model donut ----
function renderModels() {
    if (!DATA.byModel.length) {
        document.getElementById('chart-models').innerHTML = '<div class="empty">no model data</div>';
        return;
    }
    Plotly.newPlot('chart-models', [{
        labels: DATA.byModel.map(r => r.model),
        values: DATA.byModel.map(r => r.cost),
        type: 'pie',
        hole: 0.62,
        marker: {
            colors: DATA.byModel.map(r => colorForModel(r.model)),
            line: { color: COLORS.panel, width: 3 },
        },
        textinfo: 'label+percent',
        textfont: { color: COLORS.fg, size: 11 },
        hovertemplate: '<b>%{label}</b><br>$%{value:.2f} (%{percent})<extra></extra>',
    }], baseLayout({
        showlegend: false,
        margin: { l: 16, r: 16, t: 8, b: 8 },
        annotations: [{
            text: '$' + DATA.byModel.reduce((a, r) => a + (r.cost || 0), 0).toFixed(0),
            font: { color: COLORS.primary, size: 22, family: 'Inter, system-ui, sans-serif' },
            showarrow: false, x: 0.5, y: 0.5,
        }],
    }), config);
}

// ---- top repos horizontal bar ----
function renderRepos() {
    if (!DATA.topRepos.length) {
        document.getElementById('chart-repos').innerHTML = '<div class="empty">no project data</div>';
        return;
    }
    const sorted = [...DATA.topRepos].reverse();
    const shorten = (p) => {
        if (!p) return '(unknown)';
        const parts = p.split('/').filter(Boolean);
        return parts.slice(-2).join('/') || p;
    };
    Plotly.newPlot('chart-repos', [{
        x: sorted.map(r => r.cost),
        y: sorted.map(r => shorten(r.path)),
        type: 'bar',
        orientation: 'h',
        marker: { color: COLORS.primary, line: { width: 0 } },
        text: sorted.map(r => '$' + (r.cost || 0).toFixed(2)),
        textposition: 'outside',
        textfont: { color: COLORS.fgDim, size: 10 },
        customdata: sorted.map(r => [r.path, r.last_activity, r.n_main, r.total_tool_calls]),
        hovertemplate:
            '<b>%{customdata[0]}</b><br>$%{x:.2f}<br>last: %{customdata[1]}<br>' +
            '%{customdata[2]} main sessions, %{customdata[3]} tool calls<extra></extra>',
    }], baseLayout({
        margin: { l: 200, r: 60, t: 8, b: 30 },
        yaxis: { gridcolor: 'transparent', zeroline: false, color: COLORS.fg,
                 tickfont: { size: 11 }, automargin: true },
        xaxis: { gridcolor: COLORS.border, zeroline: false, color: COLORS.fgDim, tickprefix: '$' },
        showlegend: false,
    }), config);
}

// ---- context distribution ----
function renderContext() {
    if (!DATA.contextDist.length) {
        document.getElementById('chart-context').innerHTML = '<div class="empty">no main sessions in window</div>';
        return;
    }
    const colorMap = {
        '< 25% (fresh)':              COLORS.good,
        '25-50% (light)':             COLORS.secondary,
        '50-75% (heavy)':             COLORS.warn,
        '75-95% (near full)':         COLORS.pink,
        '95-100% (compaction risk)':  COLORS.bad,
    };
    Plotly.newPlot('chart-context', [{
        x: DATA.contextDist.map(r => r.bucket),
        y: DATA.contextDist.map(r => r.sessions),
        type: 'bar',
        marker: { color: DATA.contextDist.map(r => colorMap[r.bucket] || COLORS.fgDim), line: { width: 0 } },
        text: DATA.contextDist.map(r => r.sessions),
        textposition: 'outside',
        textfont: { color: COLORS.fgDim, size: 11 },
        hovertemplate: '<b>%{y}</b> sessions<br>%{x}<extra></extra>',
    }], baseLayout({
        margin: { l: 40, r: 16, t: 8, b: 90 },
        yaxis: { gridcolor: COLORS.border, zeroline: false, color: COLORS.fgDim },
        xaxis: { gridcolor: 'transparent', zeroline: false, color: COLORS.fgDim, tickangle: -25, tickfont: { size: 10 } },
        showlegend: false,
    }), config);
}

// ---- sessions table ----
function renderSessions() {
    const tbody = document.querySelector('#sessions-table tbody');
    if (!DATA.sessions.length) {
        tbody.innerHTML = '<tr><td colspan="8" class="empty">no sessions yet — run claude-stats ingest-sessions</td></tr>';
        return;
    }
    const esc = (s) => (s == null ? '' : String(s).replace(/[<>&]/g, c => ({ '<':'&lt;', '>':'&gt;', '&':'&amp;' }[c])));
    tbody.innerHTML = DATA.sessions.map(s => `
        <tr>
            <td class="dim num">${esc(s.started)}</td>
            <td>${esc(s.cwd) || '<span class="dim">—</span>'}</td>
            <td class="dim">${esc(s.git_branch) || '—'}</td>
            <td class="num">${s.n_user_msgs ?? 0}/${s.n_assistant_msgs ?? 0}</td>
            <td class="num">${s.n_tool_calls ?? 0}</td>
            <td class="num">${s.max_ctx_k != null ? s.max_ctx_k + 'k' : '—'}</td>
            <td>${tagForModel(s.model)}</td>
            <td class="dim">${esc(s.summary) || '—'}</td>
        </tr>
    `).join('');
}

renderCards();
renderDailyCost();
renderTokens();
renderCache();
renderTools();
renderSkills();
renderSubagents();
renderModels();
renderRepos();
renderContext();
renderSessions();
</script>
</body>
</html>
JS_EOF

chmod +x "$OUT" 2>/dev/null || true
echo "$OUT"
