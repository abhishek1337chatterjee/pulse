CREATE TABLE IF NOT EXISTS daily_usage (
    date DATE NOT NULL,
    model VARCHAR NOT NULL,
    input_tokens BIGINT NOT NULL DEFAULT 0,
    output_tokens BIGINT NOT NULL DEFAULT 0,
    cache_creation_tokens BIGINT NOT NULL DEFAULT 0,
    cache_read_tokens BIGINT NOT NULL DEFAULT 0,
    cost DOUBLE NOT NULL DEFAULT 0.0,
    ingested_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (date, model)
);

CREATE INDEX IF NOT EXISTS idx_daily_usage_date ON daily_usage(date);
CREATE INDEX IF NOT EXISTS idx_daily_usage_model ON daily_usage(model);

-- v2: one row per .jsonl file (main conversation OR subagent transcript)
CREATE TABLE IF NOT EXISTS conversations (
    session_id VARCHAR PRIMARY KEY,
    project_path VARCHAR,
    cwd VARCHAR,
    git_branch VARCHAR,
    kind VARCHAR NOT NULL DEFAULT 'main',     -- 'main' or 'subagent'
    parent_session_id VARCHAR,                -- NULL for main, parent UUID for subagent
    started_at TIMESTAMP,
    ended_at TIMESTAMP,
    n_user_msgs INTEGER NOT NULL DEFAULT 0,
    n_assistant_msgs INTEGER NOT NULL DEFAULT 0,
    n_tool_calls INTEGER NOT NULL DEFAULT 0,
    max_context_tokens BIGINT NOT NULL DEFAULT 0,
    model VARCHAR,                            -- model in use at max_context_tokens
    summary VARCHAR,
    ingested_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_conversations_project ON conversations(project_path);
CREATE INDEX IF NOT EXISTS idx_conversations_started ON conversations(started_at);

-- v5: subagent_type from parent's Agent tool_use, matched via the agentId
-- string emitted in the parent's tool_result. Only populated when kind='subagent'
-- AND the parent JSONL is still on disk; NULL otherwise. Nullable on purpose —
-- queries must filter `kind='subagent' AND agent_type IS NOT NULL`.
ALTER TABLE conversations ADD COLUMN IF NOT EXISTS agent_type VARCHAR;

-- v2: per-tool call counts per conversation
CREATE TABLE IF NOT EXISTS conversation_tool_usage (
    session_id VARCHAR,
    tool_name VARCHAR,
    call_count INTEGER NOT NULL,
    PRIMARY KEY (session_id, tool_name)
);

CREATE INDEX IF NOT EXISTS idx_tool_usage_tool ON conversation_tool_usage(tool_name);

-- v3: per-skill call counts per conversation. Extracted from `Skill` tool_use
-- blocks (input.skill). Names are "<plugin>:<skill>" for plugin-namespaced
-- skills, or bare "<skill>" for personal/user-scoped skills.
CREATE TABLE IF NOT EXISTS conversation_skill_usage (
    session_id VARCHAR,
    skill_name VARCHAR,
    call_count INTEGER NOT NULL,
    PRIMARY KEY (session_id, skill_name)
);

CREATE INDEX IF NOT EXISTS idx_skill_usage_skill ON conversation_skill_usage(skill_name);

-- v4: per-(project, date, model) cost breakdown from `ccusage claude daily --instances --breakdown --json`.
-- Mirrors daily_usage's write semantics: INSERT OR REPLACE on the rolling 8-day window driven by
-- ingest-daily.sh; rows older than 8 days are immutable. Adds project_path so per-project cost
-- can be windowed AND reconciled against daily_usage to the cent (sum over project_path = daily row).
CREATE TABLE IF NOT EXISTS project_daily_usage (
    project_path VARCHAR NOT NULL,
    date         DATE    NOT NULL,
    model        VARCHAR NOT NULL,
    input_tokens          BIGINT NOT NULL DEFAULT 0,
    output_tokens         BIGINT NOT NULL DEFAULT 0,
    cache_creation_tokens BIGINT NOT NULL DEFAULT 0,
    cache_read_tokens     BIGINT NOT NULL DEFAULT 0,
    cost         DOUBLE  NOT NULL DEFAULT 0.0,
    ingested_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (project_path, date, model)
);

CREATE INDEX IF NOT EXISTS idx_project_daily_usage_date         ON project_daily_usage(date);
CREATE INDEX IF NOT EXISTS idx_project_daily_usage_project_path ON project_daily_usage(project_path);

-- v6: real output-token total per session, summed from usage.output_tokens
-- across all assistant messages in the JSONL. NULL for rows ingested before
-- v6 whose JSONLs were already cleaned — queries must filter IS NOT NULL.
ALTER TABLE conversations ADD COLUMN IF NOT EXISTS total_output_tokens BIGINT;

-- v6: caveman plugin session log, from ~/.claude/.caveman-history.jsonl.
-- One row per session (the source appends duplicates; ingest keeps the
-- latest by ts). Presence of a session_id here = caveman mode was active.
-- est_saved_tokens is the PLUGIN'S OWN ESTIMATE (output × fixed benchmark
-- ratio, no counterfactual) — kept for reference, never presented as a
-- measured number. The measured comparison joins this table against
-- conversations.total_output_tokens instead. No USD column on purpose:
-- the plugin's price table lags new models and reports $0.
CREATE TABLE IF NOT EXISTS caveman_sessions (
    session_id VARCHAR PRIMARY KEY,
    last_ts TIMESTAMP,                        -- naive UTC, from epoch-ms ts
    mode VARCHAR,
    model VARCHAR,
    output_tokens BIGINT NOT NULL DEFAULT 0,
    est_saved_tokens BIGINT NOT NULL DEFAULT 0,
    ingested_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_caveman_sessions_ts ON caveman_sessions(last_ts);
