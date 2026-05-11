#!/usr/bin/env bash
# Delete rows older than 365 days across all tables. Runs after each ingest.
set -euo pipefail

DB="${HOME}/Documents/claude-stats/claude.duckdb"
DUCKDB="${HOME}/.local/bin/duckdb"

"$DUCKDB" "$DB" <<'SQL'
DELETE FROM daily_usage WHERE date < (CURRENT_DATE - INTERVAL 365 DAY);

DELETE FROM project_daily_usage WHERE date < (CURRENT_DATE - INTERVAL 365 DAY);

DELETE FROM conversations
WHERE ended_at IS NOT NULL
  AND CAST(ended_at AS DATE) < (CURRENT_DATE - INTERVAL 365 DAY);

-- Orphan tool/skill rows for conversations we just deleted
DELETE FROM conversation_tool_usage
WHERE session_id NOT IN (SELECT session_id FROM conversations);

DELETE FROM conversation_skill_usage
WHERE session_id NOT IN (SELECT session_id FROM conversations);

SELECT
  '[cleanup] daily_usage=' || (SELECT COUNT(*) FROM daily_usage)
  || ' project_daily=' || (SELECT COUNT(*) FROM project_daily_usage)
  || ' conversations=' || (SELECT COUNT(*) FROM conversations)
  || ' tool_rows=' || (SELECT COUNT(*) FROM conversation_tool_usage)
  || ' skill_rows=' || (SELECT COUNT(*) FROM conversation_skill_usage) AS msg;
SQL
