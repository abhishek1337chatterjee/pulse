#!/usr/bin/env bash
# install.sh — set up pulse on a fresh machine (or re-sync on this one).
# Idempotent: safe to re-run after `git pull`.
#
# What it does:
#   1. Verifies system dependencies (fish, jq, awk, python3, curl, gnome-screensaver tools)
#   2. Installs DuckDB binary into ~/.local/bin if missing
#   3. Creates ~/Documents/{claude-stats,battery-stats}/ + DuckDB files (from schema)
#   4. Symlinks bin/ scripts + schema.sql from this repo into the live paths
#   5. Symlinks fish functions into ~/.config/fish/functions/
#   6. Symlinks battery-stats systemd units into ~/.config/systemd/user/ and enables timers
#   7. Adds the claude-stats nightly cron entry
#   8. Grants ACL read on /var/lib/upower/* (one-time sudo for battery-stats)
#   9. Installs a sudo-askpass helper (zenity) for powertop captures
#
# The install always uses SYMLINKS, so editing files in this repo immediately
# affects the live installation — no copy/sync step needed after `git pull`.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOME_BIN="$HOME/.local/bin"
FISH_FUNCS="$HOME/.config/fish/functions"
SYSTEMD_USER="$HOME/.config/systemd/user"
CLAUDE_DIR="$HOME/Documents/claude-stats"
BATTERY_DIR="$HOME/Documents/battery-stats"

# ---------- helpers ----------
say()  { printf "\033[1;35m●\033[0m %s\n" "$*"; }
ok()   { printf "  \033[1;32m✓\033[0m %s\n" "$*"; }
warn() { printf "  \033[1;33m!\033[0m %s\n" "$*"; }
fail() { printf "  \033[1;31m✗\033[0m %s\n" "$*"; exit 1; }

link() {
    # link <src> <dst> — creates a symlink, backing up an existing non-link file
    local src="$1" dst="$2"
    if [ -L "$dst" ]; then
        local cur
        cur=$(readlink "$dst")
        if [ "$cur" = "$src" ]; then
            ok "$(basename "$dst") → already linked"
            return
        fi
        rm "$dst"
    elif [ -e "$dst" ]; then
        mv "$dst" "${dst}.bak.$(date +%s)"
        warn "$(basename "$dst") existed → backed up"
    fi
    ln -s "$src" "$dst"
    ok "$(basename "$dst") → linked"
}

# ---------- step 1: dependencies ----------
say "1/9  Checking system dependencies"
need=()
for cmd in fish jq awk python3 curl xdg-open google-chrome; do
    command -v "$cmd" >/dev/null || need+=("$cmd")
done
if [ "${#need[@]}" -gt 0 ]; then
    warn "missing: ${need[*]}"
    warn "  on Ubuntu: sudo apt install ${need[*]}"
fi
command -v gdbus    >/dev/null || warn "gdbus missing → screen state detection will be partial"
command -v powertop >/dev/null || warn "powertop missing → 'battery-stats powertop' won't work"
command -v zenity   >/dev/null || warn "zenity missing → sudo-askpass helper needs it"
command -v gh       >/dev/null || warn "gh missing → git push to private repo will need a token"

# ---------- step 2: DuckDB binary ----------
say "2/9  DuckDB binary"
mkdir -p "$HOME_BIN"
if [ ! -x "$HOME_BIN/duckdb" ]; then
    warn "duckdb not in $HOME_BIN, fetching latest"
    tmp=$(mktemp -d)
    curl -fsSL "https://github.com/duckdb/duckdb/releases/latest/download/duckdb_cli-linux-amd64.zip" \
        -o "$tmp/duckdb.zip"
    (cd "$tmp" && unzip -q duckdb.zip && mv duckdb "$HOME_BIN/duckdb")
    chmod +x "$HOME_BIN/duckdb"
    rm -rf "$tmp"
    ok "installed $("$HOME_BIN/duckdb" --version)"
else
    ok "duckdb $("$HOME_BIN/duckdb" --version | awk '{print $1}') already installed"
fi

# ---------- step 3: DB directories + schemas ----------
say "3/9  Creating data directories + DuckDB files"
mkdir -p "$CLAUDE_DIR/bin" "$BATTERY_DIR/bin"

if [ ! -f "$CLAUDE_DIR/claude.duckdb" ]; then
    "$HOME_BIN/duckdb" "$CLAUDE_DIR/claude.duckdb" < "$REPO/claude-stats/schema.sql"
    ok "claude.duckdb created from schema"
else
    "$HOME_BIN/duckdb" "$CLAUDE_DIR/claude.duckdb" < "$REPO/claude-stats/schema.sql" >/dev/null
    ok "claude.duckdb schema applied (idempotent)"
fi
if [ ! -f "$BATTERY_DIR/battery.duckdb" ]; then
    "$HOME_BIN/duckdb" "$BATTERY_DIR/battery.duckdb" < "$REPO/battery-stats/schema.sql"
    ok "battery.duckdb created from schema"
else
    "$HOME_BIN/duckdb" "$BATTERY_DIR/battery.duckdb" < "$REPO/battery-stats/schema.sql" >/dev/null
    ok "battery.duckdb schema applied (idempotent)"
fi

# ---------- step 4: symlink bin/ scripts + schema ----------
say "4/9  Linking bin/ scripts and schema.sql into live paths"
link "$REPO/claude-stats/schema.sql" "$CLAUDE_DIR/schema.sql"
for f in "$REPO/claude-stats/bin/"*; do
    link "$f" "$CLAUDE_DIR/bin/$(basename "$f")"
done
link "$REPO/battery-stats/schema.sql" "$BATTERY_DIR/schema.sql"
for f in "$REPO/battery-stats/bin/"*; do
    link "$f" "$BATTERY_DIR/bin/$(basename "$f")"
done

# ---------- step 5: fish functions ----------
say "5/9  Linking fish functions"
mkdir -p "$FISH_FUNCS"
link "$REPO/claude-stats/fish/claude-stats.fish"   "$FISH_FUNCS/claude-stats.fish"
link "$REPO/battery-stats/fish/battery-stats.fish" "$FISH_FUNCS/battery-stats.fish"

# ---------- step 6: systemd timers (battery-stats + claude-stats) ----------
say "6/9  Linking + enabling systemd user timers"
mkdir -p "$SYSTEMD_USER"
for f in "$REPO/battery-stats/systemd/"* "$REPO/claude-stats/systemd/"*; do
    link "$f" "$SYSTEMD_USER/$(basename "$f")"
done
systemctl --user daemon-reload
systemctl --user enable --now battery-stats-poll.timer      >/dev/null 2>&1 && ok "battery-stats-poll.timer enabled"
systemctl --user enable --now battery-stats-aggregate.timer >/dev/null 2>&1 && ok "battery-stats-aggregate.timer enabled"
systemctl --user enable --now claude-stats-ingest.timer     >/dev/null 2>&1 && ok "claude-stats-ingest.timer enabled (Persistent — self-heals across off nights)"

# ---------- step 7: migrate away from old cron entry ----------
say "7/9  Migrating off cron (claude-stats now uses systemd timer)"
if crontab -l 2>/dev/null | grep -qF "$CLAUDE_DIR/bin/ingest-daily.sh"; then
    crontab -l 2>/dev/null | grep -vF "$CLAUDE_DIR/bin/ingest-daily.sh" | crontab -
    ok "removed old cron entry (replaced by claude-stats-ingest.timer)"
else
    ok "no old cron entry to remove"
fi

# ---------- step 8: UPower ACL ----------
say "8/9  Granting read access to /var/lib/upower/*.dat (one-time sudo)"
RATE_SAMPLE=$(ls /var/lib/upower/history-rate-*.dat 2>/dev/null | head -1)
if [ -z "$RATE_SAMPLE" ]; then
    warn "no UPower history files yet (battery on charger? wait a few minutes)"
elif [ -r "$RATE_SAMPLE" ]; then
    ok "already readable"
else
    warn "need sudo to grant ACL — running:"
    warn "  sudo setfacl -m u:$USER:rx /var/lib/upower"
    warn "  sudo setfacl -m u:$USER:r  /var/lib/upower/history-*.dat"
    sudo setfacl -m u:"$USER":rx /var/lib/upower
    sudo setfacl -m u:"$USER":r  /var/lib/upower/history-*.dat || true
    ok "ACL granted"
fi

# ---------- step 9: sudo-askpass helper ----------
say "9/9  sudo-askpass helper (for 'battery-stats powertop')"
ASKPASS="$HOME_BIN/sudo-askpass"
if [ -x "$ASKPASS" ]; then
    ok "$ASKPASS already in place"
else
    cat > "$ASKPASS" <<'ASKPASS_EOF'
#!/bin/sh
# Ask for sudo password via zenity (GUI) — used by SUDO_ASKPASS=$HOME/.local/bin/sudo-askpass
exec zenity --password --title="sudo" 2>/dev/null
ASKPASS_EOF
    chmod +x "$ASKPASS"
    ok "installed $ASKPASS"
fi

cat <<EOF

\033[1;32m✓ pulse install complete\033[0m

next steps:
  1. fish      → exec fish     (re-source functions)
  2. ingest    → claude-stats ingest && claude-stats ingest-sessions
  3. backfill  → battery-stats ingest        (UPower bulk history)
  4. wait 5min → first poll fires automatically
  5. visualise → claude-stats dashboard      # opens in browser
                 battery-stats dashboard

systemd:    systemctl --user list-timers 'battery-stats-*'
cron:       crontab -l | grep claude-stats
DBs:        $CLAUDE_DIR/claude.duckdb
            $BATTERY_DIR/battery.duckdb
EOF
