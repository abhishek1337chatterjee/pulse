function battery-stats --description "Query battery analytics from local DuckDB"
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

        case now
            $duckdb -readonly "$db" "
                SELECT
                  STRFTIME((ts AT TIME ZONE 'UTC') AT TIME ZONE 'Asia/Kolkata', '%H:%M:%S') AS ts_ist,
                  capacity_pct AS pct, ROUND(power_now_w, 2) AS watts,
                  state, on_ac, screen_active,
                  ROUND(energy_now_wh, 2) AS energy_wh,
                  ROUND(energy_full_wh / energy_full_design_wh * 100, 1) AS health_pct,
                  cycle_count
                FROM battery_samples
                ORDER BY ts DESC
                LIMIT 5;
            "

        case sot
            set -l days (count $rest); test $days -eq 0; and set days 7; or set days $rest[1]
            $duckdb -readonly "$db" "
                SELECT
                  date,
                  CONCAT(sot_minutes // 60, 'h ', sot_minutes % 60, 'm') AS sot,
                  CONCAT(discharge_minutes // 60, 'h ', discharge_minutes % 60, 'm') AS on_battery,
                  ROUND(total_discharge_wh, 1) AS used_wh,
                  ROUND(avg_drain_w_sot, 2) AS avg_w_screen_on,
                  n_sessions AS sessions
                FROM daily_battery
                WHERE date >= CURRENT_DATE - INTERVAL $days DAY
                ORDER BY date DESC;
            "

        case sessions
            set -l days (count $rest); test $days -eq 0; and set days 3; or set days $rest[1]
            $duckdb -readonly "$db" "
                SELECT
                  STRFTIME((start_ts AT TIME ZONE 'UTC') AT TIME ZONE 'Asia/Kolkata', '%m-%d %H:%M IST') AS started,
                  CONCAT(duration_seconds // 3600, 'h ', (duration_seconds % 3600) // 60, 'm') AS dur,
                  CONCAT(sot_seconds // 3600, 'h ', (sot_seconds % 3600) // 60, 'm') AS sot,
                  start_pct || '%→' || end_pct || '%' AS battery,
                  ROUND(energy_used_wh, 1) AS wh,
                  ROUND(avg_drain_w, 2) AS avg_w,
                  ROUND(avg_drain_w_sot, 2) AS w_sot,
                  ROUND(projected_full_runtime_hours, 1) AS proj_h
                FROM discharge_sessions
                WHERE start_ts >= CURRENT_TIMESTAMP - INTERVAL $days DAY
                ORDER BY start_ts DESC;
            "

        case drain
            # avg drain by hour-of-day across last N days, screen-on samples only
            set -l days (count $rest); test $days -eq 0; and set days 14; or set days $rest[1]
            $duckdb -readonly "$db" "
                SELECT
                  EXTRACT(HOUR FROM (ts AT TIME ZONE 'UTC') AT TIME ZONE 'Asia/Kolkata') AS hour_ist,
                  COUNT(*) AS n_samples,
                  ROUND(AVG(power_now_w), 2) AS avg_w,
                  ROUND(MAX(power_now_w), 2) AS peak_w
                FROM battery_samples
                WHERE state = 'discharging'
                  AND screen_active = true
                  AND ts >= CURRENT_TIMESTAMP - INTERVAL $days DAY
                GROUP BY hour_ist
                ORDER BY hour_ist;
            "

        case health
            $duckdb -readonly "$db" "
                SELECT
                  date,
                  cycle_count_eod AS cycles,
                  ROUND(energy_full_wh_eod, 2) AS full_wh,
                  ROUND(health_pct, 2) AS health_pct
                FROM daily_battery
                WHERE energy_full_wh_eod IS NOT NULL
                ORDER BY date DESC
                LIMIT 30;
            "

        case worst
            set -l days (count $rest); test $days -eq 0; and set days 14; or set days $rest[1]
            $duckdb -readonly "$db" "
                SELECT
                  STRFTIME((start_ts AT TIME ZONE 'UTC') AT TIME ZONE 'Asia/Kolkata', '%m-%d %H:%M IST') AS started,
                  CONCAT(sot_seconds // 60, 'm') AS sot,
                  ROUND(avg_drain_w_sot, 2) AS w_sot,
                  ROUND(energy_used_wh, 1) AS wh,
                  ROUND(projected_full_runtime_hours, 1) AS proj_h
                FROM discharge_sessions
                WHERE start_ts >= CURRENT_TIMESTAMP - INTERVAL $days DAY
                  AND sot_seconds > 600
                ORDER BY avg_drain_w_sot DESC NULLS LAST
                LIMIT 10;
            "

        case graph
            _battery_stats_graph $rest

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

        case dashboard
            set -l days (count $rest); test $days -eq 0; and set days 14; or set days $rest[1]
            set -l html ("$bin/build-dashboard.sh" $days)
            echo "wrote $html"
            xdg-open "$html" >/dev/null 2>&1 &
            disown

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
    echo "RECOMMENDED:"
    echo "  battery-stats dashboard [days=14]         interactive HTML dashboard in browser"
    echo "                                            (Plotly charts, hover/zoom, all metrics)"
    echo
    echo "REPORTS (terminal tables):"
    echo "  battery-stats now                         last 5 raw samples"
    echo "  battery-stats sot [days=7]                daily Screen-On-Time + drain"
    echo "  battery-stats sessions [days=3]           recent discharge sessions"
    echo "  battery-stats worst [days=14]             top 10 highest-drain sessions"
    echo "  battery-stats drain [days=14]             avg drain by hour-of-day (screen on)"
    echo "  battery-stats health                      cycle count + capacity decay"
    echo
    echo "TERMINAL CHARTS (gnuplot Braille — use 'dashboard' for better visuals):"
    echo "  battery-stats graph upower [days=7]       drain (W) — UPower bulk history"
    echo "  battery-stats graph upower-charge [d=7]   battery % — UPower bulk history"
    echo "  battery-stats graph drain [days=7]        drain — poller data (sparse early on)"
    echo "  battery-stats graph charge [days=7]       battery % — poller data"
    echo "  battery-stats graph health                capacity decay over time"
    echo
    echo "POWERTOP (manual sudo run):"
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
end

function _battery_stats_graph
    set -l db "$HOME/Documents/battery-stats/battery.duckdb"
    set -l duckdb "$HOME/.local/bin/duckdb"
    set -l what $argv[1]
    set -l days (count $argv); test $days -lt 2; and set days 7; or set days $argv[2]
    set -l tmp (mktemp)

    switch "$what"
        case drain
            $duckdb -readonly -noheader -csv "$db" "
                SELECT EXTRACT(EPOCH FROM ts), power_now_w
                FROM battery_samples
                WHERE state = 'discharging'
                  AND ts >= CURRENT_TIMESTAMP - INTERVAL $days DAY
                ORDER BY ts;
            " | tr ',' ' ' > "$tmp"
            set title "Drain (W) — last $days day(s), discharging only"

        case charge
            $duckdb -readonly -noheader -csv "$db" "
                SELECT EXTRACT(EPOCH FROM ts), capacity_pct
                FROM battery_samples
                WHERE ts >= CURRENT_TIMESTAMP - INTERVAL $days DAY
                ORDER BY ts;
            " | tr ',' ' ' > "$tmp"
            set title "Charge % — last $days day(s)"

        case health
            $duckdb -readonly -noheader -csv "$db" "
                SELECT EXTRACT(EPOCH FROM date), health_pct
                FROM daily_battery
                WHERE health_pct IS NOT NULL
                ORDER BY date;
            " | tr ',' ' ' > "$tmp"
            set title "Battery health % (energy_full / energy_full_design)"

        case upower
            # use UPower's bulk historical data — much richer than our poller for backfill
            $duckdb -readonly -noheader -csv "$db" "
                SELECT EXTRACT(EPOCH FROM ts), watts
                FROM upower_rate
                WHERE state = 'discharging'
                  AND ts >= CURRENT_TIMESTAMP - INTERVAL $days DAY
                ORDER BY ts;
            " | tr ',' ' ' > "$tmp"
            set title "Drain (W) — UPower history, last $days day(s), discharging"

        case upower-charge
            $duckdb -readonly -noheader -csv "$db" "
                SELECT EXTRACT(EPOCH FROM ts), percentage
                FROM upower_charge
                WHERE ts >= CURRENT_TIMESTAMP - INTERVAL $days DAY
                ORDER BY ts;
            " | tr ',' ' ' > "$tmp"
            set title "Battery % — UPower history, last $days day(s)"

        case '*'
            echo "graph what? drain | charge | health | upower | upower-charge"
            rm -f "$tmp"; return 1
    end

    if not test -s "$tmp"
        echo "no data to graph (run 'battery-stats poll' or wait for the timer)"
        rm -f "$tmp"; return 1
    end

    set -l cols (tput cols 2>/dev/null); test -z "$cols"; and set cols 110
    set -l rows (tput lines 2>/dev/null); test -z "$rows"; and set rows 28
    # leave a couple rows for shell prompt
    set rows (math $rows - 2)
    set -l script (mktemp)
    printf 'set terminal block size %d,%d\n' $cols $rows > $script
    printf 'set title "%s"\n' "$title" >> $script
    printf 'set xdata time\n' >> $script
    printf 'set timefmt "%%s"\n' >> $script
    # tic spacing: ~6-8 labels across the chart regardless of date range
    set -l span_seconds (math "$days * 86400")
    set -l tic_step (math "round($span_seconds / 6)")
    if test "$days" -le 2
        printf 'set format x "%%m-%%d %%H:%%M"\n' >> $script
    else
        printf 'set format x "%%m-%%d"\n' >> $script
    end
    printf 'set xtics %d\n' $tic_step >> $script
    printf 'set xtics rotate by -30\n' >> $script
    printf 'set xlabel ""\n' >> $script
    printf 'set grid\n' >> $script
    printf 'unset key\n' >> $script
    printf 'plot "%s" using 1:2 with lines lc rgb "cyan"\n' "$tmp" >> $script
    gnuplot $script
    rm -f $tmp $script
end
