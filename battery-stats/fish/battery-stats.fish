function battery-stats --description "Local battery analytics — opens dashboard"
    set -l db "$HOME/Documents/battery-stats/battery.duckdb"
    set -l duckdb "$HOME/.local/bin/duckdb"
    set -l bin "$HOME/Documents/battery-stats/bin"

    if not test -f "$db"
        echo "battery-stats: db not found at $db"
        echo "  run: $bin/ingest-upower.sh   (one-time backfill from /var/lib/upower)"
        echo "  and: $bin/poll.sh            (or wait for the systemd timer)"
        return 1
    end

    set -l sub $argv[1]
    set -l rest $argv[2..-1]

    switch "$sub"
        case "" "help" "-h" "--help"
            _battery_stats_help
            return 0

        case dashboard
            set -l days (count $rest); test $days -eq 0; and set days 14; or set days $rest[1]
            set -l html ("$bin/build-dashboard.sh" $days)
            echo "wrote $html"
            xdg-open "$html" >/dev/null 2>&1 &
            disown

        case powertop
            "$bin/powertop-capture.sh" $rest

        case powertop-show
            $duckdb -readonly "$db" "
                SELECT r.run_id, r.captured_at, r.on_ac, r.notes,
                       p.rank, p.description, p.pw_estimate_w AS w
                FROM powertop_runs r
                JOIN powertop_top_processes p USING (run_id)
                WHERE r.run_id = COALESCE($argv[2], (SELECT MAX(run_id) FROM powertop_runs))
                ORDER BY p.rank
                LIMIT 20;
            " 2>/dev/null
            or $duckdb -readonly "$db" "
                SELECT r.run_id, r.captured_at, p.rank, p.description, p.pw_estimate_w AS w
                FROM powertop_runs r
                JOIN powertop_top_processes p USING (run_id)
                WHERE r.run_id = (SELECT MAX(run_id) FROM powertop_runs)
                ORDER BY p.rank;
            "

        case ingest
            "$bin/ingest-upower.sh"

        case aggregate
            "$bin/aggregate-daily.sh"

        case poll
            "$bin/poll.sh" && echo "ok"

        case '*'
            echo "unknown subcommand: $sub"
            _battery_stats_help
            return 1
    end
end

function _battery_stats_help
    echo "battery-stats — local battery analytics (DuckDB-backed)"
    echo
    echo "DASHBOARD (the goal — interactive HTML in browser):"
    echo "  battery-stats dashboard [days=14]         opens /tmp/battery-stats-dashboard.html"
    echo "                                            (Plotly: SOT, drain, sessions,"
    echo "                                             charging bands, hourly heatmap, health)"
    echo
    echo "POWERTOP (manual sudo capture, terminal display):"
    echo "  battery-stats powertop [sec=30] [notes]   capture top energy consumers"
    echo "  battery-stats powertop-show [run_id]      view last (or specific) run"
    echo
    echo "MAINTENANCE:"
    echo "  battery-stats ingest                      backfill from /var/lib/upower/*.dat"
    echo "  battery-stats aggregate                   rebuild sessions + daily rollup"
    echo "  battery-stats poll                        take one sample now (debug)"
    echo
    echo "BACKGROUND:"
    echo "  systemctl --user list-timers battery-stats-*    # poll every 5 min, aggregate nightly 03:15"
    echo "  systemctl --user status battery-stats-poll      # check poller health"
    echo
    echo "DOCS:"
    echo "  pulse-docs                                open the internals docs in browser"
end
