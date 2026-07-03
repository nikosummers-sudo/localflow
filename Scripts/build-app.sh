#!/usr/bin/env bash
# Assembles build/LocalFlow.app from the release binary + Info.plist, then signs it.
# Prefers the stable "LocalFlow Dev Signing" identity (created by Scripts/setup-signing.sh)
# so macOS permission grants survive rebuilds; falls back to ad-hoc (-s -) otherwise.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/LocalFlow"
APP="$ROOT/build/LocalFlow.app"

if [[ ! -x "$BIN" ]]; then
    echo "error: $BIN not found — run 'make build' first" >&2
    exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/LocalFlow"
cp "$ROOT/Sources/LocalFlow/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Sources/LocalFlow/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# Bundle the auto-updater script so each release CARRIES its own updater: the
# app syncs it to ~/.localflow/auto-update.sh at launch. Without this, machines
# keep whatever updater their install day shipped, forever — updater fixes
# (atomic swap, signature verification) would never reach existing installs.
# Inside the bundle it's covered by the app's code signature.
cp "$ROOT/Scripts/auto-update.sh" "$APP/Contents/Resources/auto-update.sh"

# SwiftPM emits resource bundles (e.g. WhisperKit's) next to the binary; Bundle.module
# resolves them from Contents/Resources inside a .app, so copy any that exist.
shopt -s nullglob
for bundle in "$ROOT"/.build/release/*.bundle; do
    cp -R "$bundle" "$APP/Contents/Resources/"
done
shopt -u nullglob

# Prefer the stable local certificate if it's installed; otherwise ad-hoc sign.
SIGN_IDENTITY="LocalFlow Dev Signing"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
    if codesign --force -s "$SIGN_IDENTITY" "$APP" 2>/dev/null; then
        echo "Signed with identity: $SIGN_IDENTITY"
    else
        echo "warning: signing with '$SIGN_IDENTITY' failed — falling back to ad-hoc." >&2
        codesign --force -s - "$APP"
        echo "Signed ad-hoc (-)"
    fi
else
    codesign --force -s - "$APP"
    echo "Signed ad-hoc (-) — run Scripts/setup-signing.sh for a stable signature that survives rebuilds"
fi

echo "Built $APP"
