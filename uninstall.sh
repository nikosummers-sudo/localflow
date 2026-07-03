#!/bin/bash
# LocalFlow uninstaller — removes the app, the auto-update agent, logs, and
# (optionally) the downloaded speech models. Run:
#
#   curl -fsSL https://raw.githubusercontent.com/nikosummers-sudo/localflow/main/uninstall.sh | bash
#
# Keeps Ollama (other apps may use it) — the last line tells you how to remove
# it too if you want.
set -uo pipefail

bold() { printf '\n\033[1m%s\033[0m\n' "$*"; }

bold "Uninstalling LocalFlow…"

# Stop the app.
pkill -x LocalFlow 2>/dev/null || true

# Remove the auto-update LaunchAgent.
PLIST="$HOME/Library/LaunchAgents/com.nikosummers.localflow.updater.plist"
launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
rm -f "$PLIST"

# Remove the app from both possible locations (plus any interrupted-swap debris).
for DIR in "/Applications" "$HOME/Applications"; do
  rm -rf "$DIR/LocalFlow.app" "$DIR/LocalFlow.app.new" "$DIR/LocalFlow.app.old" 2>/dev/null || true
  rmdir "$DIR/.localflow-update.lock" 2>/dev/null || true
done

# Remove updater state, logs, and app data (dictation history, settings live in
# UserDefaults + Application Support).
rm -rf "$HOME/.localflow"
rm -f "$HOME/Library/Logs/LocalFlow.log"
rm -rf "$HOME/Library/Application Support/LocalFlow"
defaults delete com.nikosummers.LocalFlow 2>/dev/null || true

echo "✓ App, auto-updater, logs, history, and settings removed."

# The speech models are big (~2 GB) but shared-format; ask before removing.
MODELS="$HOME/Documents/huggingface/models/argmaxinc/whisperkit-coreml"
if [ -d "$MODELS" ]; then
  SIZE="$(du -sh "$MODELS" 2>/dev/null | cut -f1)"
  if [ -t 0 ]; then
    printf 'Also delete the downloaded speech models (%s in %s)? [y/N] ' "${SIZE:-~2GB}" "$MODELS"
    read -r REPLY
    case "$REPLY" in [Yy]*) rm -rf "$MODELS"; echo "✓ Speech models removed." ;; *) echo "Kept speech models." ;; esac
  else
    echo "Speech models kept (${SIZE:-~2GB}). Remove them with:"
    echo "  rm -rf \"$MODELS\""
  fi
fi

echo
echo "LocalFlow is uninstalled. Ollama (the AI cleanup engine) was left in place;"
echo "if nothing else uses it: brew uninstall ollama 2>/dev/null; rm -rf /Applications/Ollama.app ~/.ollama"
