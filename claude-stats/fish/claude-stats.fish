function claude-stats --description "Local Claude Code usage analytics — opens dashboard"
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
    echo "DASHBOARD (the goal — interactive HTML in browser):"
    echo "  claude-stats dashboard [days=30]          opens /tmp/claude-stats-dashboard.html"
    echo "                                            (Plotly: cost, tokens, cache,"
    echo "                                             tools, models, repos, context)"
    echo "                                            window: 30 / 90 / 365 days"
    echo
    echo "MAINTENANCE:"
    echo "  claude-stats ingest [SINCE]               daily ccusage ingest (SINCE=YYYYMMDD, default -8d)"
    echo "  claude-stats ingest-sessions              JSONL session ingest (~/.claude/projects)"
    echo "  claude-stats raw <SQL>                    run arbitrary SQL (read+write — debug only)"
    echo
    echo "BACKGROUND:"
    echo "  systemd 02:00 nightly (Persistent)  →  ingest-daily + ingest-sessions + cleanup-old (365-day retention)"
    echo "  claude-clean hook  →  ingest-sessions runs BEFORE per-project deletion"
    echo "  DB: ~/Documents/claude-stats/claude.duckdb  (survives claude-clean)"
    echo
    echo "DOCS:"
    echo "  pulse-docs                                open the internals docs in browser"
end
