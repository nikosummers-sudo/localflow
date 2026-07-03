#!/bin/bash
# LocalFlow installer — builds from source on your Mac (so macOS trusts it),
# installs to /Applications, and launches it.
#
#   curl -fsSL https://raw.githubusercontent.com/nikosummers-sudo/localflow/main/install.sh | bash
#
# Safe to re-run any time: it updates to the latest version in place.
set -euo pipefail

REPO="https://github.com/nikosummers-sudo/localflow.git"
SRC="$HOME/.localflow/src"

bold() { printf '\n\033[1m%s\033[0m\n' "$*"; }
fail() { printf '\n❌ %s\n' "$*" >&2; exit 1; }

# ── 1. Platform checks ────────────────────────────────────────────────────────
[ "$(uname -s)" = "Darwin" ] || fail "LocalFlow is macOS-only."
[ "$(uname -m)" = "arm64" ] || fail "LocalFlow needs an Apple Silicon Mac (M1 or newer) — Intel Macs aren't supported."
OS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
[ "$OS_MAJOR" -ge 14 ] || fail "LocalFlow needs macOS 14 (Sonoma) or newer — this Mac is on $(sw_vers -productVersion)."

# ── 2. Compiler (Apple Command Line Tools) ───────────────────────────────────
if ! xcode-select -p >/dev/null 2>&1; then
  bold "LocalFlow builds from source and needs Apple's Command Line Tools (one-time, ~5 min)."
  xcode-select --install >/dev/null 2>&1 || true
  fail "A macOS dialog should have opened — install the Command Line Tools, then paste the install command again."
fi
command -v swift >/dev/null 2>&1 || fail "swift not found — finish the Command Line Tools install, then re-run."

# ── 3. Get or update the source ──────────────────────────────────────────────
if [ -d "$SRC/.git" ]; then
  bold "Updating LocalFlow…"
  git -C "$SRC" fetch --depth 1 origin main
  git -C "$SRC" reset --hard origin/main
else
  bold "Downloading LocalFlow…"
  mkdir -p "$(dirname "$SRC")"
  git clone --depth 1 "$REPO" "$SRC"
fi
cd "$SRC"

# ── 4. Per-machine signing cert (keeps macOS permissions stable across updates)
bash Scripts/setup-signing.sh || \
  echo "⚠️  Skipped stable signing — LocalFlow still works, but macOS may re-ask for permissions after updates."

# ── 5. Build and install ─────────────────────────────────────────────────────
bold "Building LocalFlow (first build fetches dependencies — give it a few minutes)…"
make app

DEST="/Applications"
[ -w "$DEST" ] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }
bold "Installing to ${DEST}…"
pkill -x LocalFlow 2>/dev/null || true
rm -rf "$DEST/LocalFlow.app"
ditto build/LocalFlow.app "$DEST/LocalFlow.app"

# ── 6. Ollama for AI transcript cleanup (auto-setup, opt-out) ────────────────
OLLAMA_BIN="$(command -v ollama || true)"
if [ -z "$OLLAMA_BIN" ] && [ -x "/Applications/Ollama.app/Contents/Resources/ollama" ]; then
  OLLAMA_BIN="/Applications/Ollama.app/Contents/Resources/ollama"
fi

wait_for_ollama() {
  local i
  for i in $(seq 1 30); do
    "$OLLAMA_BIN" list >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}

ollama_setup_note() {
  echo "⚠️  Couldn't finish the AI-cleanup setup — dictation still works (transcripts inserted as heard)."
  echo "   To add it later: install Ollama from https://ollama.com then run: ollama pull gemma3:4b"
}

# AI cleanup is part of the package — install Ollama when it's missing.
# A failure here must never break the LocalFlow install itself.
if [ -z "$OLLAMA_BIN" ]; then
  bold "Setting up AI transcript cleanup (Ollama, one-time)…"
  if command -v brew >/dev/null 2>&1; then
    if brew install ollama; then
      brew services start ollama 2>/dev/null || { nohup ollama serve >/dev/null 2>&1 & }
      OLLAMA_BIN="$(command -v ollama || true)"
    else
      ollama_setup_note
    fi
  else
    OZIP="$(mktemp -d)/Ollama-darwin.zip"
    if curl -fL --progress-bar https://ollama.com/download/Ollama-darwin.zip -o "$OZIP" \
       && ditto -x -k "$OZIP" /Applications; then
      rm -f "$OZIP"
      open -a /Applications/Ollama.app
      echo "If Ollama shows a welcome window, click through it — it starts the local server."
      OLLAMA_BIN="/Applications/Ollama.app/Contents/Resources/ollama"
    else
      rm -f "$OZIP"
      ollama_setup_note
    fi
  fi
fi

if [ -n "$OLLAMA_BIN" ]; then
  if wait_for_ollama; then
    if "$OLLAMA_BIN" list 2>/dev/null | grep -q '^gemma3:4b'; then
      echo "✓ AI cleanup is ready (Ollama with gemma3:4b)."
    else
      bold "Downloading the cleanup model (gemma3:4b, ~3.3 GB, one-time)…"
      "$OLLAMA_BIN" pull gemma3:4b || ollama_setup_note
    fi
  else
    ollama_setup_note
  fi
fi

# ── 7. Auto-updates (background check every 6 h; silent rebuild + swap) ──────
PLIST="$HOME/Library/LaunchAgents/com.nikosummers.localflow.updater.plist"
mkdir -p "$HOME/Library/LaunchAgents"
cat >"$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.nikosummers.localflow.updater</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$SRC/Scripts/auto-update.sh</string>
  </array>
  <key>StartInterval</key><integer>21600</integer>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
PLIST
launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || launchctl load "$PLIST" 2>/dev/null || true
echo "✓ Auto-updates on: checks GitHub every 6 hours and swaps in new versions."
echo "  (Disable: launchctl bootout gui/\$(id -u) \"$PLIST\" && rm \"$PLIST\")"

# ── 8. Launch ─────────────────────────────────────────────────────────────────
open "$DEST/LocalFlow.app"
bold "LocalFlow is running — look for the mic icon in your menu bar (top-right)."
cat <<'EOF'
Next steps:
  1. Grant the three permissions in the Setup window (Microphone, Accessibility,
     Input Monitoring), then click "Relaunch LocalFlow".
     (If Input Monitoring doesn't list LocalFlow, click the + button in that
      System Settings pane and add it from /Applications.)
  2. Your first dictation downloads the speech model (~1.6 GB, one-time).
     The menu bar icon shows progress; wait for "Ready".
  3. Hold RIGHT OPTION anywhere and talk. Release to insert.
     Press Right Option + Space to lock hands-free; tap Right Option to finish.

LocalFlow lives in the menu bar (mic icon, top-right) and starts automatically
when you log in. To reopen its Setup window, click the menu bar icon — or
double-click LocalFlow in /Applications.

Updates install themselves automatically (checked every 6 hours).
EOF
