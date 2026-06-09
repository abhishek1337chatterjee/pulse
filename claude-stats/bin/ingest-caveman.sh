#!/usr/bin/env bash
# Ingest the caveman plugin's session log into caveman_sessions.
#
# Source: ~/.claude/.caveman-history.jsonl (appended by caveman's hooks;
# swept by claude-clean — so this must run BEFORE any sweep, same as
# ingest-sessions.py).
#
# Source quirks handled here:
#   - duplicate lines per session (hook double-fires) -> GROUP BY session_id,
#     keep the latest row by ts (arg_max), INSERT OR REPLACE on the PK
#   - ts is epoch milliseconds -> stored as naive UTC TIMESTAMP (repo rule)
#   - est_saved_usd is IGNORED (plugin's price table lags new models)
#
# est_saved_tokens is the plugin's own estimate (output × fixed benchmark
# ratio) — stored for reference only. The dashboard's measured comparison
# joins session PRESENCE here against conversations.total_output_tokens.
set -euo pipefail

HIST="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.caveman-history.jsonl"
DB="${HOME}/Documents/claude-stats/claude.duckdb"
DUCKDB="${HOME}/.local/bin/duckdb"

if [ ! -s "$HIST" ]; then
    echo "[ingest-caveman] no caveman history at $HIST — nothing to ingest"
    exit 0
fi

"$DUCKDB" "$DB" <<SQL
INSERT OR REPLACE INTO caveman_sessions
  (session_id, last_ts, mode, model, output_tokens, est_saved_tokens, ingested_at)
SELECT
    session_id,
    (to_timestamp(MAX(ts) / 1000.0) AT TIME ZONE 'UTC') AS last_ts,
    arg_max(mode, ts)                                   AS mode,
    arg_max(model, ts)                                  AS model,
    COALESCE(arg_max(output_tokens, ts), 0)             AS output_tokens,
    COALESCE(arg_max(est_saved_tokens, ts), 0)          AS est_saved_tokens,
    CURRENT_TIMESTAMP
FROM read_ndjson('$HIST',
    columns = {
        ts: 'BIGINT',
        session_id: 'VARCHAR',
        mode: 'VARCHAR',
        model: 'VARCHAR',
        output_tokens: 'BIGINT',
        est_saved_tokens: 'BIGINT'
    },
    ignore_errors = true)
WHERE session_id IS NOT NULL AND ts IS NOT NULL
GROUP BY session_id;

SELECT '[ingest-caveman] caveman_sessions: '
    || (SELECT COUNT(*) FROM caveman_sessions) AS msg;
SQL
