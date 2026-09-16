#!/usr/bin/env bash
# Ingest Claude Code daily usage from ccusage into DuckDB.
# Usage: ingest-daily.sh [SINCE_YYYYMMDD]
# Default SINCE = 8 days ago (always keeps the recent week fresh).

set -euo pipefail

# Cron-safe PATH. Node comes from nvm, whose version dir changes on every
# upgrade — pinning one 127s the moment nvm bumps node. Source nvm.sh so we
# follow the `default` alias instead. nvm.sh isn't set -eu clean, so guard it.
export NVM_DIR="${HOME}/.nvm"
set +eu
# shellcheck disable=SC1091
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" >/dev/null 2>&1
set -eu
export PATH="${HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"

DB="${HOME}/Documents/claude-stats/claude.duckdb"
DUCKDB="${HOME}/.local/bin/duckdb"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

SINCE="${1:-$(date -d '8 days ago' +%Y%m%d)}"
CSV="${TMPDIR}/usage.csv"
PROJ_CSV="${TMPDIR}/projects.csv"

# --- Sanitized mirror (added 2026-09-16) ---------------------------------
# ccusage 20.0.20 silently drops any entry whose usage.iterations[].model is
# null (ccusage/ccusage#1710; Claude Code 2.1.269 wrote that on 2026-09-12).
# Point ccusage at a mirror of the window's JSONL with `iterations` stripped.
# ccusage sums top-level usage, so totals are byte-identical on unaffected
# data; harmless once a fixed ccusage (>20.0.20) ships.
SRC="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"
MIRROR="${TMPDIR}/cfg"
mkdir -p "$MIRROR/projects"
SINCE_ISO="$(date -d "$SINCE" +%F)"   # SINCE is YYYYMMDD
( cd "$SRC" && find . -name '*.jsonl' -newermt "$SINCE_ISO" -print0 \
  | while IFS= read -r -d '' f; do
      mkdir -p "$MIRROR/projects/$(dirname "$f")"
      jq -c 'del(.message.usage.iterations)' "$f" > "$MIRROR/projects/$f" 2>/dev/null \
        || cp "$f" "$MIRROR/projects/$f"
    done )
export CLAUDE_CONFIG_DIR="$MIRROR"

# (1) per-(date, model) totals  — feeds daily_usage
# ccusage v19 split agents under subcommands; top-level `daily` now aggregates
# all agents and drops modelBreakdowns. `claude daily` preserves the legacy shape.
npx --yes ccusage@latest claude daily --since "$SINCE" --json \
  | jq -r '
      .daily[] as $d
      | $d.modelBreakdowns[]
      | [
          $d.date,
          .modelName,
          (.inputTokens // 0),
          (.outputTokens // 0),
          (.cacheCreationTokens // 0),
          (.cacheReadTokens // 0),
          (.cost // 0)
        ]
      | @csv
    ' > "$CSV"

# (2) per-(project, date, model) breakdown — feeds project_daily_usage.
# Uses --instances to add the project_path dimension. Project_path is the
# ccusage instance key (matches project_path in conversations / project_usage).
npx --yes ccusage@latest claude daily --since "$SINCE" --instances --breakdown --json \
  | jq -r '
      .projects
      | to_entries[] as $p
      | $p.value[] as $d
      | $d.modelBreakdowns[] as $m
      | [
          $p.key,
          $d.date,
          $m.modelName,
          ($m.inputTokens // 0),
          ($m.outputTokens // 0),
          ($m.cacheCreationTokens // 0),
          ($m.cacheReadTokens // 0),
          ($m.cost // 0)
        ]
      | @csv
    ' > "$PROJ_CSV"

ROWS=$(wc -l < "$CSV")
PROJ_ROWS=$(wc -l < "$PROJ_CSV")
if [[ "$ROWS" -eq 0 && "$PROJ_ROWS" -eq 0 ]]; then
  echo "[ingest] no rows from ccusage since $SINCE — nothing to do"
  exit 0
fi

"$DUCKDB" "$DB" <<SQL
CREATE OR REPLACE TEMP TABLE staging AS
SELECT * FROM read_csv('$CSV',
  header=false,
  columns={
    'date': 'DATE',
    'model': 'VARCHAR',
    'input_tokens': 'BIGINT',
    'output_tokens': 'BIGINT',
    'cache_creation_tokens': 'BIGINT',
    'cache_read_tokens': 'BIGINT',
    'cost': 'DOUBLE'
  }
);

INSERT OR REPLACE INTO daily_usage
  (date, model, input_tokens, output_tokens, cache_creation_tokens, cache_read_tokens, cost, ingested_at)
SELECT date, model, input_tokens, output_tokens, cache_creation_tokens, cache_read_tokens, cost, CURRENT_TIMESTAMP
FROM staging;

CREATE OR REPLACE TEMP TABLE staging_proj AS
SELECT * FROM read_csv('$PROJ_CSV',
  header=false,
  columns={
    'project_path': 'VARCHAR',
    'date': 'DATE',
    'model': 'VARCHAR',
    'input_tokens': 'BIGINT',
    'output_tokens': 'BIGINT',
    'cache_creation_tokens': 'BIGINT',
    'cache_read_tokens': 'BIGINT',
    'cost': 'DOUBLE'
  }
);

INSERT OR REPLACE INTO project_daily_usage
  (project_path, date, model, input_tokens, output_tokens, cache_creation_tokens, cache_read_tokens, cost, ingested_at)
SELECT project_path, date, model, input_tokens, output_tokens, cache_creation_tokens, cache_read_tokens, cost, CURRENT_TIMESTAMP
FROM staging_proj;

SELECT
  '[ingest] upserted ' || (SELECT COUNT(*) FROM staging)
  || ' daily rows + ' || (SELECT COUNT(*) FROM staging_proj)
  || ' project-day rows (since $SINCE)' AS msg;
SQL
