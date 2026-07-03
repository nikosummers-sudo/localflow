#!/bin/bash
# LocalFlow auto-updater — run hourly by a LaunchAgent. Polls the release
# manifest and, when a newer build exists, downloads the prebuilt, signed app
# and swaps it in. No building, no per-machine signing: every release is signed
# with one stable identity, so macOS keeps the user's permission grants across
# updates. Logs to ~/.localflow/update.log (no dictation content).
set -euo pipefail

MANIFEST_URL="https://raw.githubusercontent.com/nikosummers-sudo/localflow/main/latest.json"
LOG="$HOME/.localflow/update.log"
LOCK="$HOME/.localflow/update.lock"

mkdir -p "$HOME/.localflow"
exec >>"$LOG" 2>&1
[ -f "$LOG" ] && [ "$(wc -l <"$LOG")" -gt 500 ] && { tail -n 200 "$LOG" >"$LOG.tmp" && mv "$LOG.tmp" "$LOG"; }

# One updater at a time. A previous run killed hard (power loss, force reboot)
# leaves the lock dir behind and would block updates FOREVER — treat a lock
# older than 2 hours as stale and clear it.
if [ -d "$LOCK" ] && [ -n "$(find "$LOCK" -maxdepth 0 -mmin +120 2>/dev/null)" ]; then
  rmdir "$LOCK" 2>/dev/null || true
fi
if ! mkdir "$LOCK" 2>/dev/null; then echo "$(date '+%F %T') another update running"; exit 0; fi
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

# Self-heal the LaunchAgent interval (applies at next login; no self-bootout).
PLIST="$HOME/Library/LaunchAgents/com.nikosummers.localflow.updater.plist"
if [ -f "$PLIST" ]; then
  CUR="$(defaults read "$PLIST" StartInterval 2>/dev/null || echo 0)"
  [ "$CUR" != "3600" ] && /usr/bin/sed -i '' \
    "s|<key>StartInterval</key><integer>[0-9]*</integer>|<key>StartInterval</key><integer>3600</integer>|" "$PLIST" 2>/dev/null || true
fi

# Locate the installed app.
APP="/Applications/LocalFlow.app"
[ -d "$APP" ] || APP="$HOME/Applications/LocalFlow.app"
[ -d "$APP" ] || { echo "$(date '+%F %T') no installed app — run the installer"; exit 0; }
DEST_DIR="$(dirname "$APP")"
# Clear debris a previously-interrupted swap may have left beside the app.
rm -rf "$DEST_DIR/LocalFlow.app.new" "$DEST_DIR/LocalFlow.app.old" 2>/dev/null || true

# Fetch the manifest and parse it with plutil (always present; handles JSON).
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; rmdir "$LOCK" 2>/dev/null || true' EXIT
curl -fsSL "$MANIFEST_URL" -o "$TMP/latest.json" || { echo "$(date '+%F %T') manifest fetch failed (offline?)"; exit 0; }

LATEST_BUILD="$(plutil -extract build raw -o - "$TMP/latest.json" 2>/dev/null || echo "")"
URL="$(plutil -extract url raw -o - "$TMP/latest.json" 2>/dev/null || echo "")"
WANT_SHA="$(plutil -extract sha256 raw -o - "$TMP/latest.json" 2>/dev/null || echo "")"
[ -n "$LATEST_BUILD" ] && [ -n "$URL" ] && [ -n "$WANT_SHA" ] || { echo "$(date '+%F %T') bad manifest"; exit 0; }

INSTALLED_BUILD="$(defaults read "$APP/Contents/Info.plist" CFBundleVersion 2>/dev/null || echo 0)"
case "$INSTALLED_BUILD" in ''|*[!0-9]*) INSTALLED_BUILD=0 ;; esac
[ "$LATEST_BUILD" -gt "$INSTALLED_BUILD" ] || exit 0

echo "$(date '+%F %T') updating build $INSTALLED_BUILD -> $LATEST_BUILD"
curl -fsSL "$URL" -o "$TMP/LocalFlow.app.zip" || { echo "$(date '+%F %T') download failed"; exit 0; }
GOT_SHA="$(shasum -a 256 "$TMP/LocalFlow.app.zip" | awk '{print $1}')"
[ "$GOT_SHA" = "$WANT_SHA" ] || { echo "$(date '+%F %T') checksum mismatch ($GOT_SHA != $WANT_SHA) — refusing"; exit 0; }

ditto -x -k "$TMP/LocalFlow.app.zip" "$TMP/unpacked" || { echo "$(date '+%F %T') unzip failed"; exit 0; }
NEW_APP="$TMP/unpacked/LocalFlow.app"
[ -d "$NEW_APP" ] || { echo "$(date '+%F %T') zip had no app"; exit 0; }
# Sanity: the downloaded app must be the expected build before we swap.
DL_BUILD="$(defaults read "$NEW_APP/Contents/Info.plist" CFBundleVersion 2>/dev/null || echo 0)"
[ "$DL_BUILD" = "$LATEST_BUILD" ] || { echo "$(date '+%F %T') downloaded build $DL_BUILD != $LATEST_BUILD — refusing"; exit 0; }

# The sha256 only proves the download matches the manifest — and both come from
# the same repo, so a compromised repo (or account) could serve arbitrary code
# with a matching sha. Require the stable signing identity ON THE CLIENT before
# anything replaces the live app. (Captured string, not a grep pipe — codesign's
# stderr + pipefail would false-fail.)
if ! codesign --verify --deep --strict "$NEW_APP" >/dev/null 2>&1; then
  echo "$(date '+%F %T') downloaded app FAILS signature verification — refusing"; exit 0
fi
SIG_OUT="$(codesign -dvv "$NEW_APP" 2>&1)"
case "$SIG_OUT" in
  *"Authority=LocalFlow Dev Signing"*) : ;;
  *) echo "$(date '+%F %T') downloaded app not signed by LocalFlow Dev Signing — refusing"; exit 0 ;;
esac
xattr -dr com.apple.quarantine "$NEW_APP" 2>/dev/null || true

# Never kill a dictation in flight. The app maintains this marker while it is
# recording/transcribing/inserting; a FRESH marker defers the update to the next
# hourly run. A stale one (>10 min — the app crashed mid-dictation) is ignored.
BUSY="$HOME/.localflow/dictating"
if [ -f "$BUSY" ] && [ -n "$(find "$BUSY" -mmin -10 2>/dev/null)" ]; then
  echo "$(date '+%F %T') dictation in progress — deferring to next run"; exit 0
fi

# One updater per DESTINATION: two users on one Mac share /Applications, and
# their per-user locks don't serialize each other. Same stale-lock healing.
DEST_LOCK="$DEST_DIR/.localflow-update.lock"
if [ -d "$DEST_LOCK" ] && [ -n "$(find "$DEST_LOCK" -maxdepth 0 -mmin +120 2>/dev/null)" ]; then
  rmdir "$DEST_LOCK" 2>/dev/null || true
fi
if ! mkdir "$DEST_LOCK" 2>/dev/null; then
  echo "$(date '+%F %T') another user's updater holds the destination — deferring"; exit 0
fi
trap 'rmdir "$DEST_LOCK" 2>/dev/null || true; rm -rf "$TMP"; rmdir "$LOCK" 2>/dev/null || true' EXIT

WAS_RUNNING=0
pgrep -x LocalFlow >/dev/null && WAS_RUNNING=1
pkill -x LocalFlow 2>/dev/null || true
sleep 1

# Atomic swap: stage the new copy NEXT TO the live app (same volume, so mv is a
# rename), then swap. The live app is never half-written; power loss leaves the
# old OR the new app intact, plus debris the next run clears.
ditto "$NEW_APP" "$DEST_DIR/LocalFlow.app.new"
mv "$DEST_DIR/LocalFlow.app" "$DEST_DIR/LocalFlow.app.old" 2>/dev/null || true
if ! mv "$DEST_DIR/LocalFlow.app.new" "$DEST_DIR/LocalFlow.app"; then
  echo "$(date '+%F %T') swap failed — restoring previous app"
  mv "$DEST_DIR/LocalFlow.app.old" "$DEST_DIR/LocalFlow.app" 2>/dev/null || true
  exit 0
fi
rm -rf "$DEST_DIR/LocalFlow.app.old" 2>/dev/null || true
xattr -dr com.apple.quarantine "$DEST_DIR/LocalFlow.app" 2>/dev/null || true
if [ "$WAS_RUNNING" = 1 ]; then open "$DEST_DIR/LocalFlow.app"; fi

echo "$(date '+%F %T') updated to build $LATEST_BUILD OK"
