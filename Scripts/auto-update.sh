#!/bin/bash
# LocalFlow auto-updater — run periodically by a LaunchAgent (installed by
# install.sh). Checks GitHub for new commits; when found, rebuilds and swaps
# the installed app in place. Logs to ~/.localflow/update.log.
set -euo pipefail

SRC="$HOME/.localflow/src"
LOG="$HOME/.localflow/update.log"
LOCK="$HOME/.localflow/update.lock"

mkdir -p "$HOME/.localflow"
exec >>"$LOG" 2>&1

# Keep the log bounded.
if [ -f "$LOG" ] && [ "$(wc -l <"$LOG")" -gt 500 ]; then
  tail -n 200 "$LOG" >"$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi

# One updater at a time.
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "$(date '+%F %T') another update is already running"
  exit 0
fi
trap 'rmdir "$LOCK"' EXIT

[ -d "$SRC/.git" ] || { echo "$(date '+%F %T') no checkout at $SRC — run the installer"; exit 0; }
cd "$SRC"

# Self-heal the LaunchAgent definition (e.g. interval changes shipped via git).
# Rewrite only — no self-bootout while this very agent is running; launchd
# picks up the new interval at the next login.
PLIST="$HOME/Library/LaunchAgents/com.nikosummers.localflow.updater.plist"
DESIRED_INTERVAL=3600
if [ -f "$PLIST" ]; then
  CUR="$(defaults read "$PLIST" StartInterval 2>/dev/null || echo 0)"
  if [ "$CUR" != "$DESIRED_INTERVAL" ]; then
    /usr/bin/sed -i '' "s|<key>StartInterval</key><integer>[0-9]*</integer>|<key>StartInterval</key><integer>${DESIRED_INTERVAL}</integer>|" "$PLIST" \
      && echo "$(date '+%F %T') updater interval healed ${CUR} -> ${DESIRED_INTERVAL} (applies at next login)"
  fi
fi

git fetch --depth 1 origin main --quiet || { echo "$(date '+%F %T') fetch failed (offline?)"; exit 0; }
LOCAL="$(git rev-parse HEAD)"
REMOTE="$(git rev-parse origin/main)"
[ "$LOCAL" = "$REMOTE" ] && exit 0

echo "$(date '+%F %T') updating ${LOCAL:0:7} -> ${REMOTE:0:7}"
git reset --hard origin/main --quiet
make app

DEST="/Applications"
[ -w "$DEST" ] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }

WAS_RUNNING=0
pgrep -x LocalFlow >/dev/null && WAS_RUNNING=1
pkill -x LocalFlow 2>/dev/null || true
rm -rf "$DEST/LocalFlow.app"
ditto build/LocalFlow.app "$DEST/LocalFlow.app"
# Only relaunch if the user had it running; respect a deliberately-quit app.
[ "$WAS_RUNNING" = 1 ] && open "$DEST/LocalFlow.app"

echo "$(date '+%F %T') updated to ${REMOTE:0:7} OK"
