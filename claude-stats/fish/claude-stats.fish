function claude-stats --description "Local Claude Code usage analytics — opens dashboard"
    set -l db "$HOME/Documents/claude-stats/claude.duckdb"
    set -l duckdb "$HOME/.local/bin/duckdb"

    set -l sub $argv[1]
    set -l rest $argv[2..-1]

    # Help first, so it still works on a fresh install with no database yet.
    if contains -- "$sub" "" help -h --help
        _claude_stats_help
        return 0
    end

    if not test -f "$db"
        echo "claude-stats: db not found at $db"
        echo "  run ~/Documents/claude-stats/bin/ingest-daily.sh first"
        return 1
    end

    switch "$sub"
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

        case raw
            if test -z "$rest[1]"
                echo "claude-stats raw: needs a SQL query as argument"
                return 1
            end
            $duckdb "$db" "$rest"

        case '*'
            printf "Unknown command '%s'.\n\n" $sub
            _claude_stats_help
            return 1
    end
end

function _claude_stats_help
    # Help card data, in the pulse help order: dashboard, maintenance, background, docs.
    set -l dashboard \
        "claude-stats dashboard [days]" "Open the dashboard (30/90/365 days)" \
        "claude-stats dashboard month M [Y]" "One calendar month, e.g. month 4 2025"
    set -l maintenance \
        "claude-stats ingest [SINCE]" "Daily cost ingest (default last 8 days)" \
        "claude-stats ingest-sessions" "Session ingest from ~/.claude/projects" \
        "claude-stats raw <SQL>" "Run any SQL (read+write, debug only)"
    set -l background \
        "systemd 02:00 nightly: ingest + sessions + 365-day cleanup." \
        "claude-clean runs ingest-sessions before it deletes sessions." \
        "DB: ~/Documents/claude-stats/claude.duckdb (survives claude-clean)."
    set -l docs \
        "pulse-docs" "Open the internals docs"

    __pulse_card "claude-stats help" \
        (__pulse_card_pairs Dashboard $dashboard) "" \
        (__pulse_card_pairs Maintenance $maintenance) "" \
        (__pulse_card_bullets Background $background) "" \
        (__pulse_card_pairs Docs $docs)
end
