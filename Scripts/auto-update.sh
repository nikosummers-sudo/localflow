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

# One updater at a time.
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
xattr -dr com.apple.quarantine "$NEW_APP" 2>/dev/null || true

WAS_RUNNING=0
pgrep -x LocalFlow >/dev/null && WAS_RUNNING=1
pkill -x LocalFlow 2>/dev/null || true
sleep 1
rm -rf "$DEST_DIR/LocalFlow.app"
ditto "$NEW_APP" "$DEST_DIR/LocalFlow.app"
xattr -dr com.apple.quarantine "$DEST_DIR/LocalFlow.app" 2>/dev/null || true
[ "$WAS_RUNNING" = 1 ] && open "$DEST_DIR/LocalFlow.app"

echo "$(date '+%F %T') updated to build $LATEST_BUILD OK"
