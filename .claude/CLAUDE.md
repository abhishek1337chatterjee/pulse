# pulse — Claude context

Repo for two local analytics CLIs (claude-stats, battery-stats). DuckDB +
fish + Plotly HTML dashboards. Self-hosted, no telemetry.

## Layout (source of truth = this repo, live install = symlinks)

- `claude-stats/{bin,fish,schema.sql}` — Claude Code usage analytics
- `battery-stats/{bin,fish,systemd,schema.sql}` — battery + screen-state analytics
- `fish/pulse-docs.fish` — top-level helper that opens `docs/index.html`
- `install.sh` — idempotent: links bin/fish/systemd into `~/Documents/{claude,battery}-stats/`, `~/.config/fish/functions/`, `~/.config/systemd/user/`
- `docs/` — internals docs site (hub + spoke). Open via `pulse-docs`.
  - `index.html` (landing) → `claude-stats.html`, `battery-stats.html`, `internals.html`
  - `_styles.css` and `_nav.js` are SHARED across spokes (single source of truth for theme + sidebar)
  - When changing CLI commands, schema, pipelines, or schedule — update the relevant spoke
- `docs/*.png` — dashboard screenshots used in README

## Live paths after install (DBs live outside repo)

- `~/Documents/claude-stats/claude.duckdb` — gitignored
- `~/Documents/battery-stats/battery.duckdb` — gitignored
- systemd user timers (all with `Persistent=true` — missed runs fire on next boot):
  - `claude-stats-ingest.timer` — nightly 02:00, chains `ingest-daily` → `ingest-sessions` → `cleanup-old`
  - `battery-stats-poll.timer` — every 5 min
  - `battery-stats-aggregate.timer` — nightly 03:15

## Editing rules

- Schemas use **naive TIMESTAMP** stored as **UTC**. Always wrap display with `(col AT TIME ZONE 'UTC') AT TIME ZONE 'Asia/Kolkata'`. Single `AT TIME ZONE 'Asia/Kolkata'` is a silent no-op — see git history for the bug fix that pattern caused.
- `battery-stats/bin/poll.sh:63` writes UTC via `date -u`. Don't change to local time.
- `battery-stats/bin/ingest-upower.sh` auto-detects `BATTERY_MODEL` from `/sys/class/power_supply/BAT0/model_name` — do not hardcode a serial.
- `battery-stats/bin/powertop-capture.sh` uses `${SUDO_ASKPASS:-$HOME/.local/bin/sudo-askpass}` — do not hardcode `/home/<user>/...`.
- `battery-stats/bin/aggregate-daily.sh` derives `discharge_sessions` + `daily_battery`. Phantom-session filter (line 78): `duration > 60s AND energy_delta > 0.05 Wh` — needed because 1-sample sessions look like 0Wh drains.
- All dashboards (`build-dashboard.sh` in both projects) emit self-contained HTML with Plotly via CDN; no build step. AMOLED theme: `#000000` bg, `#0a0a0a` panel, `#a78bfa` primary, `#22d3ee` secondary.
- **Model colors (claude-stats)**: `colorForModel(m)` in `build-dashboard.sh` keeps a per-family HSL hue (opus/sonnet/haiku) and ranks lightness by the version in the model id — newest = brightest brand shade, older dims by `MODEL_L_STEP`. Version-aware + automatic; a new model needs NO edit. Don't reintroduce a flat family→single-color map (that made `opus-4-7`/`opus-4-8` collide).
- **Dashboard window (claude-stats)**: `build-dashboard.sh` `$1` is a window SPEC — bare int = rolling days, `month:M[:Y]` = calendar month (fish forwards it from `dashboard month M [Y]`). The spec parser computes `WIN_LO`/`WIN_HI` (half-open `[LO, HI)` SQL date literals), `WINDOW_LABEL`, `WINDOW_DAYS`, `REBUILD_HINT`; every windowed query splices `$WHERE_DATE` / `$WHERE_STARTED` / `$WHERE_CSTARTED`. Each `q()` is a separate duckdb process, so bounds are inlined per-query (no session vars). Month upper bound is first-of-next-month exclusive — handles 28/30/31 + timestamp time-of-day correctly. No DB/schema change; read-only.
- Fish CLIs are intentionally MINIMAL — `dashboard` is the only display surface. Keep them that way. No terminal-table reports. The dashboard is strictly more informative than any tabular CLI output, so don't re-add `summary` / `sot` / `worst` etc. The only exceptions: `claude-stats raw <SQL>` (debug escape hatch) and `battery-stats powertop-show` (powertop data isn't in the dashboard yet).
- Help layout: `DASHBOARD → POWERTOP (battery only) → MAINTENANCE → BACKGROUND → DOCS`.
- **Cost attribution (claude-stats v4)**: two tables, both written by `ingest-daily.sh`. `daily_usage` (PK `date,model`) from `ccusage claude daily --json`; `project_daily_usage` (PK `project_path,date,model`) from `ccusage claude daily --instances --breakdown --json`. **Subcommand is `claude daily`, not `daily`** — ccusage v19+ reorganized agents under per-agent subcommands; top-level `daily` aggregates all agents and drops `modelBreakdowns`, which breaks ingest with `Cannot iterate over null`. Same 8-day rolling-rewrite window — rows older than 8 days are immutable. Sums reconcile to the cent for any (date, model) where ccusage could see the JSONLs at ingest. The dashboard's "Top projects" panel windows over `project_daily_usage`; the `attribution` query computes the windowed gap. (Legacy `project_usage` table was removed — replaced by `project_daily_usage`. `ingest-sessions.py` no longer writes any cost data.)

## Tests / verification

- `bash -n install.sh` — syntax check
- `bash -n bin/*.sh` — same for any script you touch
- After editing dashboard SQL: run the script, inspect generated HTML's `DATA = {…}` block (head of `<script>`) to confirm the JSON shape

## What NOT to commit

- `*.duckdb`, `*.html`, `*.bak.*` (already in `.gitignore`)
- The `~/Documents/{claude,battery}-stats/cron.log` files — never end up here, but worth knowing
- Anything under `~/.claude/` (per global rules)

## Common tasks

- **Add a new dashboard chart** → edit `<project>/bin/build-dashboard.sh`: add a `q "..."` block for the data, a `printf '    name: %s,\n' "$VAR"` to embed in JSON, a `<div id="chart-name">` in the HTML, and a `renderName()` JS function. No re-install needed (symlinked).
- **Add a new fish subcommand** → edit `<project>/fish/<project>-stats.fish`: new `case` arm + entry in `_<project>_stats_help`. After save: `exec fish` to re-source.
- **Schema change** → edit `<project>/schema.sql`. `install.sh` re-applies it idempotently (uses `IF NOT EXISTS`). For destructive changes, write a migration block guarded by version check.

## Why this repo exists

Two-laptop disaster recovery. Original setup was scattered across
`~/Documents/`, `~/.config/fish/functions/`, `~/.config/systemd/user/`, and
crontab. This repo collapses them into one tree so a fresh laptop is one
`git clone + ./install.sh` away.
