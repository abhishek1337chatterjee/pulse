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
            # arg forms:  dashboard [days=30]  |  dashboard month M [Y]
            set -l spec
            if test "$rest[1]" = month
                set -l m "$rest[2]"
                if not string match -qr '^[0-9]+$' -- "$m"; or test "$m" -lt 1 -o "$m" -gt 12
                    echo "claude-stats dashboard month: needs a month 1-12 (e.g. dashboard month 4 [2025])"
                    return 1
                end
                set spec "month:$m"
                test -n "$rest[3]"; and set spec "month:$m:$rest[3]"
            else
                set spec "$rest[1]"
                test -z "$spec"; and set spec 30
            end
            set -l out "/tmp/claude-stats-dashboard.html"
            if not ~/Documents/claude-stats/bin/build-dashboard.sh $spec $out >/dev/null
                return 1
            end
            echo "wrote $out"
            if command -q xdg-open
                xdg-open "$out" >/dev/null 2>&1 &
            end

        case ingest
            ~/Documents/claude-stats/bin/ingest-daily.sh $rest

        case ingest-sessions
            ~/Documents/claude-stats/bin/ingest-sessions.py

        case ingest-caveman
            ~/Documents/claude-stats/bin/ingest-caveman.sh

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
    echo "                                            rolling window: 30 / 90 / 365 days"
    echo "  claude-stats dashboard month M [Y]        a calendar month (M=1-12)"
    echo "                                            year optional; defaults to the most"
    echo "                                            recent occurrence (limited by 365-day"
    echo "                                            retention). e.g. dashboard month 4 2025"
    echo
    echo "MAINTENANCE:"
    echo "  claude-stats ingest [SINCE]               daily ccusage ingest (SINCE=YYYYMMDD, default -8d)"
    echo "  claude-stats ingest-sessions              JSONL session ingest (~/.claude/projects)"
    echo "  claude-stats ingest-caveman               caveman plugin session log (~/.claude/.caveman-history.jsonl)"
    echo "  claude-stats raw <SQL>                    run arbitrary SQL (read+write — debug only)"
    echo
    echo "BACKGROUND:"
    echo "  systemd 02:00 nightly (Persistent)  →  ingest-daily + ingest-sessions + ingest-caveman + cleanup-old (365-day retention)"
    echo "  claude-clean hook  →  ingest-sessions + ingest-caveman run BEFORE deletion/sweep"
    echo "  DB: ~/Documents/claude-stats/claude.duckdb  (survives claude-clean)"
    echo
    echo "DOCS:"
    echo "  pulse-docs                                open the internals docs in browser"
end
