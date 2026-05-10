function claude-stats --description "Query Claude Code usage stats from local DuckDB"
    set -l db "$HOME/Documents/claude-stats/claude.duckdb"
    set -l duckdb "$HOME/.local/bin/duckdb"

    if not test -f "$db"
        echo "claude-stats: db not found at $db"
        echo "  run ~/Documents/claude-stats/bin/ingest-daily.sh first"
        return 1
    end

    set -l sub $argv[1]
    set -l rest $argv[2..-1]

    switch "$sub"
        case "" "help" "-h" "--help"
            _claude_stats_help
            return 0

        case summary
            $duckdb -readonly "$db" "
                SELECT
                  date,
                  ROUND(SUM(cost), 2) AS cost_usd,
                  SUM(input_tokens + output_tokens + cache_creation_tokens + cache_read_tokens) AS total_tokens,
                  STRING_AGG(model, ', ' ORDER BY model) AS models
                FROM daily_usage
                WHERE date >= CURRENT_DATE - INTERVAL 7 DAY
                GROUP BY date
                ORDER BY date DESC;
            "

        case month
            set -l ym "$rest[1]"
            if test -z "$ym"
                set ym (date +%Y-%m)
            end
            echo "--- $ym by model ---"
            $duckdb -readonly "$db" "
                SELECT
                  model,
                  COUNT(DISTINCT date) AS active_days,
                  SUM(input_tokens) AS input,
                  SUM(output_tokens) AS output,
                  SUM(cache_creation_tokens) AS cache_create,
                  SUM(cache_read_tokens) AS cache_read,
                  ROUND(SUM(cost), 2) AS cost_usd
                FROM daily_usage
                WHERE strftime(date, '%Y-%m') = '$ym'
                GROUP BY model
                ORDER BY cost_usd DESC;
            "
            echo "--- $ym total ---"
            $duckdb -readonly "$db" "
                SELECT
                  COUNT(DISTINCT date) AS active_days,
                  ROUND(SUM(cost), 2) AS total_cost_usd,
                  SUM(input_tokens + output_tokens + cache_creation_tokens + cache_read_tokens) AS total_tokens
                FROM daily_usage
                WHERE strftime(date, '%Y-%m') = '$ym';
            "

        case year
            $duckdb -readonly "$db" "
                SELECT
                  strftime(date, '%Y-%m') AS month,
                  COUNT(DISTINCT date) AS active_days,
                  ROUND(SUM(cost), 2) AS cost_usd,
                  ROUND(SUM(cost) / NULLIF(COUNT(DISTINCT date), 0), 2) AS avg_per_day
                FROM daily_usage
                WHERE date >= CURRENT_DATE - INTERVAL 12 MONTH
                GROUP BY 1
                ORDER BY 1 DESC;
            "

        case top
            set -l limit "$rest[1]"
            if test -z "$limit"
                set limit 10
            end
            $duckdb -readonly "$db" "
                SELECT
                  date,
                  ROUND(SUM(cost), 2) AS cost_usd,
                  SUM(input_tokens + output_tokens + cache_creation_tokens + cache_read_tokens) AS total_tokens,
                  STRING_AGG(model, ', ' ORDER BY model) AS models
                FROM daily_usage
                GROUP BY date
                ORDER BY cost_usd DESC
                LIMIT $limit;
            "

        case models
            $duckdb -readonly "$db" "
                SELECT
                  model,
                  COUNT(DISTINCT date) AS active_days,
                  ROUND(SUM(cost), 2) AS total_cost_usd,
                  ROUND(SUM(cost) / NULLIF(COUNT(DISTINCT date), 0), 2) AS avg_per_active_day,
                  SUM(input_tokens + output_tokens + cache_creation_tokens + cache_read_tokens) AS total_tokens
                FROM daily_usage
                GROUP BY model
                ORDER BY total_cost_usd DESC;
            "

        case cache
            $duckdb -readonly "$db" "
                SELECT
                  strftime(date, '%Y-%m') AS month,
                  ROUND(SUM(cache_read_tokens) * 100.0 / NULLIF(SUM(input_tokens + cache_creation_tokens + cache_read_tokens), 0), 1) AS cache_hit_pct,
                  SUM(cache_read_tokens) AS cache_reads,
                  SUM(cache_creation_tokens) AS cache_writes,
                  SUM(input_tokens) AS uncached_input
                FROM daily_usage
                WHERE date >= CURRENT_DATE - INTERVAL 12 MONTH
                GROUP BY 1
                ORDER BY 1 DESC;
            "

        case tools
            set -l limit "$rest[1]"
            if test -z "$limit"
                set limit 20
            end
            $duckdb -readonly "$db" "
                SELECT
                  tool_name,
                  SUM(call_count) AS total_calls,
                  COUNT(DISTINCT session_id) AS sessions_used_in,
                  ROUND(SUM(call_count) * 1.0 / COUNT(DISTINCT session_id), 1) AS avg_per_session
                FROM conversation_tool_usage
                GROUP BY tool_name
                ORDER BY total_calls DESC
                LIMIT $limit;
            "

        case repos
            set -l limit "$rest[1]"
            if test -z "$limit"
                set limit 20
            end
            # Use -line mode so long paths show in full (one field per line per row).
            $duckdb -readonly -line "$db" "
                SELECT
                  COALESCE(NULLIF(c.cwd, ''), p.project_path) AS path,
                  ROUND(p.total_cost, 2) AS cost_usd,
                  p.last_activity,
                  c.n_main_sessions,
                  c.n_subagents,
                  c.total_tool_calls,
                  p.models_used
                FROM project_usage p
                LEFT JOIN (
                  SELECT
                    project_path,
                    MAX(cwd) AS cwd,
                    COUNT(*) FILTER (WHERE kind = 'main') AS n_main_sessions,
                    COUNT(*) FILTER (WHERE kind = 'subagent') AS n_subagents,
                    SUM(n_tool_calls) AS total_tool_calls
                  FROM conversations
                  GROUP BY project_path
                ) c ON c.project_path = p.project_path
                ORDER BY p.total_cost DESC
                LIMIT $limit;
            "

        case sessions
            set -l limit "$rest[1]"
            if test -z "$limit"
                set limit 10
            end
            $duckdb -readonly "$db" "
                SELECT
                  CAST(started_at AS DATE) AS date,
                  CASE WHEN length(cwd) > 50 THEN '...' || substr(cwd, length(cwd) - 47) ELSE cwd END AS cwd,
                  git_branch AS branch,
                  n_user_msgs AS u_msgs,
                  n_assistant_msgs AS a_msgs,
                  n_tool_calls AS tools,
                  ROUND(max_context_tokens / 1000.0, 1) AS max_ctx_k,
                  CASE WHEN length(summary) > 60 THEN substr(summary, 1, 57) || '...' ELSE summary END AS summary
                FROM conversations
                WHERE kind = 'main' AND started_at IS NOT NULL
                ORDER BY started_at DESC
                LIMIT $limit;
            "

        case compaction
            # Bucket as a percentage of each model's actual context window.
            # Window sizes assume current Anthropic defaults as of 2026:
            #   opus-4-7 = 1M, others = 200K. Update if you start using 1M-variant Sonnet.
            $duckdb -readonly "$db" "
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
                  WHERE kind = 'main' AND max_context_tokens > 0
                ),
                pct AS (
                  SELECT
                    model,
                    ctx,
                    window_size,
                    100.0 * ctx / window_size AS used_pct
                  FROM base
                ),
                bucketed AS (
                  SELECT
                    model,
                    window_size,
                    CASE
                      WHEN used_pct < 25  THEN '1: < 25%    (fresh)'
                      WHEN used_pct < 50  THEN '2: 25-50%   (light)'
                      WHEN used_pct < 75  THEN '3: 50-75%   (heavy)'
                      WHEN used_pct < 95  THEN '4: 75-95%   (near full)'
                      WHEN used_pct <= 100 THEN '5: 95-100% (compaction risk)'
                      ELSE '6: above mapped window (model unmapped or beta)'
                    END AS bucket
                  FROM pct
                )
                SELECT
                  model,
                  window_size / 1000 AS window_k,
                  bucket,
                  COUNT(*) AS sessions
                FROM bucketed
                GROUP BY model, window_size, bucket
                ORDER BY model, bucket;
            "

        case dashboard
            set -l days "$rest[1]"
            if test -z "$days"
                set days 30
            end
            set -l out "/tmp/claude-stats-dashboard.html"
            ~/Documents/claude-stats/bin/build-dashboard.sh $days $out >/dev/null
            echo "wrote $out"
            if command -q xdg-open
                xdg-open "$out" >/dev/null 2>&1 &
            end

        case ingest
            ~/Documents/claude-stats/bin/ingest-daily.sh $rest

        case ingest-sessions
            ~/Documents/claude-stats/bin/ingest-sessions.py

        case raw
            if test -z "$rest[1]"
                echo "claude-stats raw: needs a SQL query as argument"
                return 1
            end
            $duckdb "$db" "$rest"

        case '*'
            echo "claude-stats: unknown subcommand '$sub'"
            echo
            _claude_stats_help
            return 1
    end
end

function _claude_stats_help
    echo "claude-stats — local Claude Code usage analytics (DuckDB-backed)"
    echo
    echo "RECOMMENDED:"
    echo "  claude-stats dashboard [days=30]          interactive HTML dashboard in browser"
    echo "                                            (Plotly charts: cost, tokens, cache,"
    echo "                                             tools, models, repos, context)"
    echo
    echo "REPORTS (terminal tables):"
    echo "  claude-stats summary                      last 7 days: cost + tokens per day"
    echo "  claude-stats month [YYYY-MM]              per-model breakdown for a month"
    echo "  claude-stats year                         last 12 months: cost + active-days"
    echo "  claude-stats top [N=10]                   most expensive days, ranked"
    echo "  claude-stats models                       all-time per-model totals"
    echo "  claude-stats cache                        cache hit rate per month (last 12)"
    echo "  claude-stats compaction                   context-window distribution by model"
    echo
    echo "DRILL-DOWN:"
    echo "  claude-stats tools [N=20]                 top N tools by call count"
    echo "  claude-stats repos [N=20]                 top N projects by total cost"
    echo "  claude-stats sessions [N=10]              recent main conversations"
    echo
    echo "MAINTENANCE:"
    echo "  claude-stats ingest [SINCE]               daily ccusage ingest (SINCE=YYYYMMDD, default -8d)"
    echo "  claude-stats ingest-sessions              JSONL session ingest (~/.claude/projects)"
    echo "  claude-stats raw <SQL>                    run arbitrary SQL (read+write)"
    echo
    echo "BACKGROUND:"
    echo "  systemd 02:00 nightly (Persistent)  →  ingest-daily + ingest-sessions + cleanup-old (365-day retention)"
    echo "  claude-clean hook  →  ingest-sessions runs BEFORE per-project deletion"
    echo "  DB: ~/Documents/claude-stats/claude.duckdb  (survives claude-clean)"
end
