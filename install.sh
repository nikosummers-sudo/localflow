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
bold "Installing to $DEST…"
pkill -x LocalFlow 2>/dev/null || true
rm -rf "$DEST/LocalFlow.app"
ditto build/LocalFlow.app "$DEST/LocalFlow.app"

# ── 6. Optional: Ollama for AI transcript cleanup ────────────────────────────
if command -v ollama >/dev/null 2>&1; then
  if ollama list 2>/dev/null | grep -q '^gemma3:4b'; then
    echo "✓ Ollama with gemma3:4b found — AI cleanup is ready."
  else
    echo "Ollama found, but the cleanup model is missing. To enable AI cleanup run:"
    echo "    ollama pull gemma3:4b"
  fi
else
  bold "Optional: AI transcript cleanup (removes \"um\"s and false starts, fully on-device)."
  echo "Dictation works fine without it — transcripts are just inserted as heard."
  echo "To enable it: install Ollama from https://ollama.com then run:  ollama pull gemma3:4b"
fi

# ── 7. Launch ─────────────────────────────────────────────────────────────────
open "$DEST/LocalFlow.app"
bold "LocalFlow is running — look for the mic icon in your menu bar (top-right)."
cat <<'EOF'
Next steps:
  1. Grant the three permissions in the Setup window (Microphone, Accessibility,
     Input Monitoring), then click "Relaunch LocalFlow".
  2. Your first dictation downloads the speech model (~1.6 GB, one-time).
     The menu bar icon shows progress; wait for "Ready".
  3. Hold RIGHT OPTION anywhere and talk. Release to insert.
     Press Right Option + Space to lock hands-free; tap Right Option to finish.

To update LocalFlow later, paste the install command again.
EOF
