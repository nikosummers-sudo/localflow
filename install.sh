#!/bin/bash
# LocalFlow installer — downloads the prebuilt, signed app and sets up
# automatic updates. No building, no Command Line Tools, no per-machine signing.
#
#   curl -fsSL https://raw.githubusercontent.com/nikosummers-sudo/localflow/main/install.sh | bash
#
# Safe to re-run any time. Updates thereafter are automatic (hourly) and keep
# your permission grants, because every release shares one signing identity.
set -euo pipefail

MANIFEST_URL="https://raw.githubusercontent.com/nikosummers-sudo/localflow/main/latest.json"
UPDATER_URL="https://raw.githubusercontent.com/nikosummers-sudo/localflow/main/Scripts/auto-update.sh"
LF_DIR="$HOME/.localflow"

bold() { printf '\n\033[1m%s\033[0m\n' "$*"; }
fail() { printf '\n❌ %s\n' "$*" >&2; exit 1; }

# ── 1. Platform ──────────────────────────────────────────────────────────────
[ "$(uname -s)" = "Darwin" ] || fail "LocalFlow is macOS-only."
[ "$(uname -m)" = "arm64" ] || fail "LocalFlow needs an Apple Silicon Mac (M1 or newer)."
[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 14 ] || fail "LocalFlow needs macOS 14 (Sonoma) or newer."

# ── 2. Download the prebuilt app via the manifest ────────────────────────────
mkdir -p "$LF_DIR"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
bold "Downloading LocalFlow…"
curl -fsSL "$MANIFEST_URL" -o "$TMP/latest.json" || fail "Couldn't reach the release manifest."
URL="$(plutil -extract url raw -o - "$TMP/latest.json")"
WANT_SHA="$(plutil -extract sha256 raw -o - "$TMP/latest.json")"
BUILD="$(plutil -extract build raw -o - "$TMP/latest.json")"
[ -n "$URL" ] && [ -n "$WANT_SHA" ] || fail "Malformed release manifest."

curl -fsSL "$URL" -o "$TMP/LocalFlow.app.zip" || fail "Couldn't download the app."
GOT_SHA="$(shasum -a 256 "$TMP/LocalFlow.app.zip" | awk '{print $1}')"
[ "$GOT_SHA" = "$WANT_SHA" ] || fail "Checksum mismatch — download corrupted, please retry."
ditto -x -k "$TMP/LocalFlow.app.zip" "$TMP/unpacked" || fail "Couldn't unpack the app."
[ -d "$TMP/unpacked/LocalFlow.app" ] || fail "Downloaded archive had no app."

# ── 3. Install to /Applications (fall back to ~/Applications) ────────────────
DEST="/Applications"; [ -w "$DEST" ] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }
bold "Installing to ${DEST}…"
pkill -x LocalFlow 2>/dev/null || true
sleep 1
rm -rf "$DEST/LocalFlow.app"
ditto "$TMP/unpacked/LocalFlow.app" "$DEST/LocalFlow.app"
# Clear the download quarantine so it opens without a Gatekeeper prompt.
xattr -dr com.apple.quarantine "$DEST/LocalFlow.app" 2>/dev/null || true

# ── 4. Auto-updates: download the updater + (re)install the LaunchAgent ───────
# Migration: remove any older updater agent (including the previous build-from-
# source one) so only the download-based updater runs.
curl -fsSL "$UPDATER_URL" -o "$LF_DIR/auto-update.sh" || fail "Couldn't fetch the updater."
chmod +x "$LF_DIR/auto-update.sh"
PLIST="$HOME/Library/LaunchAgents/com.nikosummers.localflow.updater.plist"
mkdir -p "$HOME/Library/LaunchAgents"
launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
cat >"$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.nikosummers.localflow.updater</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$LF_DIR/auto-update.sh</string>
  </array>
  <key>StartInterval</key><integer>3600</integer>
  <key>RunAtLoad</key><false/>
</dict>
</plist>
PLIST
launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || launchctl load "$PLIST" 2>/dev/null || true
# Retire the old build-from-source checkout if it's still around (no longer used).
rm -rf "$LF_DIR/src" 2>/dev/null || true
echo "✓ Auto-updates on: checks hourly, downloads new signed builds, keeps your permissions."

# ── 5. AI transcript cleanup (Ollama) — part of the package ──────────────────
detect_ollama_bin() {
  if command -v ollama >/dev/null 2>&1; then command -v ollama; return 0; fi
  for c in /Applications/Ollama.app/Contents/Resources/ollama /Applications/Ollama.app/Contents/MacOS/ollama; do
    [ -x "$c" ] && { echo "$c"; return 0; }
  done
  return 0
}
wait_for_ollama() {
  for i in $(seq 1 15); do
    "$OLLAMA_BIN" list >/dev/null 2>&1 && return 0
    echo "   …waiting for Ollama (${i}/15) — if its welcome window is open, click through it."
    sleep 10
  done
  return 1
}
ollama_note() {
  echo "⚠️  AI-cleanup setup didn't finish — dictation still works (raw transcripts)."
  echo "   LocalFlow finishes this itself on next launch, or run: ollama pull gemma3:4b"
}
OLLAMA_BIN="$(detect_ollama_bin || true)"
if [ -z "$OLLAMA_BIN" ]; then
  bold "Setting up AI transcript cleanup (Ollama, one-time)…"
  if command -v brew >/dev/null 2>&1; then
    brew install ollama && { brew services start ollama 2>/dev/null || { nohup ollama serve >/dev/null 2>&1 & }; } || ollama_note
  else
    OZIP="$TMP/Ollama-darwin.zip"
    if curl -fL --progress-bar https://ollama.com/download/Ollama-darwin.zip -o "$OZIP" && ditto -x -k "$OZIP" /Applications; then
      bold "⚠️  ACTION NEEDED: Ollama will open — click through its welcome window once (starts its local server)."
      open -a /Applications/Ollama.app
    else
      ollama_note
    fi
  fi
  OLLAMA_BIN="$(detect_ollama_bin || true)"
fi
AI_STATUS="notset"
if [ -n "$OLLAMA_BIN" ]; then
  if wait_for_ollama; then
    if "$OLLAMA_BIN" list 2>/dev/null | grep -q '^gemma3:4b'; then
      AI_STATUS="ready"
    else
      bold "Downloading the cleanup model (gemma3:4b, ~3.3 GB, one-time)…"
      "$OLLAMA_BIN" pull gemma3:4b && AI_STATUS="ready" || { "$OLLAMA_BIN" pull gemma3:4b && AI_STATUS="ready" || ollama_note; }
    fi
  else
    ollama_note
  fi
fi

# ── 6. Launch + verify it actually came up ───────────────────────────────────
open "$DEST/LocalFlow.app" || true
APP_RUNNING="no"
for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x LocalFlow >/dev/null 2>&1 && { APP_RUNNING="yes"; break; }; sleep 1; done
if [ "$APP_RUNNING" = "yes" ]; then
  bold "LocalFlow is running — look for its icon in the Dock and menu bar (top-right)."
  echo "(On MacBooks with a notch, a full menu bar can hide new icons — the Dock icon works regardless.)"
else
  bold "⚠️  LocalFlow didn't start itself — open it: Cmd+Space, type LocalFlow, press Return."
fi

[ "$APP_RUNNING" = "yes" ] && APP_SUM="✓" || APP_SUM="✗ not running — Cmd+Space, type LocalFlow, Return"
[ "$AI_STATUS" = "ready" ] && AI_SUM="✓ ready" || AI_SUM="✗ not set up — LocalFlow finishes it on next launch"
printf '\n────────────────────────────────────────────────────────────\n'
echo "LocalFlow install summary  (build $BUILD)"
echo "  App installed & running:  $APP_SUM"
echo "  Auto-updates:             ✓ hourly, permission-safe"
echo "  AI cleanup (Ollama):      $AI_SUM"
echo "  Next: grant the 3 permissions in the Setup window (once — updates won't reset them)."
echo "────────────────────────────────────────────────────────────"
