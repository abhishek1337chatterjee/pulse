#!/bin/bash
# poll.sh — single battery + screen-state sample, append to DuckDB
# invoked every ~5 min by the systemd user timer
set -euo pipefail

DB="$HOME/Documents/battery-stats/battery.duckdb"
DUCKDB="$HOME/.local/bin/duckdb"
BAT="/sys/class/power_supply/BAT0"
AC="/sys/class/power_supply/AC"

[ -d "$BAT" ] || { echo "no BAT0" >&2; exit 0; }

# raw sysfs reads (microunits)
energy_now_uwh=$(cat "$BAT/energy_now")
energy_full_uwh=$(cat "$BAT/energy_full")
energy_full_design_uwh=$(cat "$BAT/energy_full_design")
power_now_uw=$(cat "$BAT/power_now" 2>/dev/null || echo 0)
voltage_uv=$(cat "$BAT/voltage_now")
capacity=$(cat "$BAT/capacity")
cycles=$(cat "$BAT/cycle_count" 2>/dev/null || echo 0)
state=$(cat "$BAT/status" | tr '[:upper:]' '[:lower:]')
on_ac=$(cat "$AC/online" 2>/dev/null || echo 0)

# screen state — Wayland-native
idle_hint="false"
screensaver="false"
if [ -n "${XDG_SESSION_ID:-}" ]; then
    h=$(loginctl show-session "$XDG_SESSION_ID" -p IdleHint --value 2>/dev/null || echo "no")
    [ "$h" = "yes" ] && idle_hint="true"
fi
if command -v gdbus >/dev/null 2>&1; then
    s=$(timeout 2 gdbus call --session \
            --dest org.gnome.ScreenSaver \
            --object-path /org/gnome/ScreenSaver \
            --method org.gnome.ScreenSaver.GetActive 2>/dev/null || echo "(false,)")
    [[ "$s" == *"true"* ]] && screensaver="true"
fi
screen_active="true"
[ "$idle_hint" = "true" ] && screen_active="false"
[ "$screensaver" = "true" ] && screen_active="false"

# brightness
brightness_pct="NULL"
for bl in /sys/class/backlight/*/; do
    if [ -d "$bl" ]; then
        cur=$(cat "$bl/brightness" 2>/dev/null || echo 0)
        max=$(cat "$bl/max_brightness" 2>/dev/null || echo 1)
        [ "$max" -gt 0 ] && brightness_pct=$(( cur * 100 / max ))
        break
    fi
done

# convert to base units
e_now=$(awk -v v="$energy_now_uwh" 'BEGIN{printf "%.6f", v/1000000}')
e_full=$(awk -v v="$energy_full_uwh" 'BEGIN{printf "%.6f", v/1000000}')
e_full_des=$(awk -v v="$energy_full_design_uwh" 'BEGIN{printf "%.6f", v/1000000}')
p_now=$(awk -v v="$power_now_uw" 'BEGIN{printf "%.6f", v/1000000}')
v_now=$(awk -v v="$voltage_uv" 'BEGIN{printf "%.6f", v/1000000}')

on_ac_bool="false"
[ "$on_ac" = "1" ] && on_ac_bool="true"

ts=$(date -u +"%Y-%m-%d %H:%M:%S")

"$DUCKDB" "$DB" <<SQL
INSERT INTO battery_samples
  (ts, energy_now_wh, energy_full_wh, energy_full_design_wh, power_now_w,
   voltage_v, capacity_pct, cycle_count, state, on_ac,
   screen_active, idle_hint, screensaver_active, brightness_pct)
VALUES
  ('$ts', $e_now, $e_full, $e_full_des, $p_now,
   $v_now, $capacity, $cycles, '$state', $on_ac_bool,
   $screen_active, $idle_hint, $screensaver, $brightness_pct)
ON CONFLICT (ts) DO NOTHING;
SQL

# Refresh derived tables so dashboard reflects every poll.
# Use flock so concurrent runs (e.g. manual + timer) don't collide on the DB.
LOCK="/tmp/battery-stats-aggregate.lock"
flock -n "$LOCK" -c "$HOME/Documents/battery-stats/bin/aggregate-daily.sh >/dev/null 2>&1" || true
