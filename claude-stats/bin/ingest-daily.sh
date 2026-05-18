#!/usr/bin/env bash
# Ingest Claude Code daily usage from ccusage into DuckDB.
# Usage: ingest-daily.sh [SINCE_YYYYMMDD]
# Default SINCE = 8 days ago (always keeps the recent week fresh).

set -euo pipefail

# Cron-safe PATH: jq lives in /usr/bin, npx in nvm
export PATH="${HOME}/.nvm/versions/node/v24.14.1/bin:/usr/bin:/bin:${PATH:-}"

DB="${HOME}/Documents/claude-stats/claude.duckdb"
DUCKDB="${HOME}/.local/bin/duckdb"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

SINCE="${1:-$(date -d '8 days ago' +%Y%m%d)}"
CSV="${TMPDIR}/usage.csv"
PROJ_CSV="${TMPDIR}/projects.csv"

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
