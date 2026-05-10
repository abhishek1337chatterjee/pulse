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

npx --yes ccusage@latest daily --since "$SINCE" --json \
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

ROWS=$(wc -l < "$CSV")
if [[ "$ROWS" -eq 0 ]]; then
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

SELECT
  '[ingest] upserted ' || COUNT(*) || ' rows (since $SINCE)' AS msg
FROM staging;
SQL
