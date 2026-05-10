# pulse — Claude context

Repo for two local analytics CLIs (claude-stats, battery-stats). DuckDB +
fish + Plotly HTML dashboards. Self-hosted, no telemetry.

## Layout (source of truth = this repo, live install = symlinks)

- `claude-stats/{bin,fish,schema.sql}` — Claude Code usage analytics
- `battery-stats/{bin,fish,systemd,schema.sql}` — battery + screen-state analytics
- `install.sh` — idempotent: links bin/fish/systemd into `~/Documents/{claude,battery}-stats/`, `~/.config/fish/functions/`, `~/.config/systemd/user/`
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
- Fish CLIs both use the same help layout: `RECOMMENDED → REPORTS → DRILL-DOWN → MAINTENANCE → BACKGROUND`. Keep new subcommands grouped accordingly.

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
