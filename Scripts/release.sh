#!/bin/bash
# LocalFlow release cutter — run on Niko's Mac to publish a new version.
#
# Builds the app ONCE, signed with the stable "LocalFlow Dev Signing" identity,
# zips it, publishes it as a GitHub Release asset, and updates latest.json (the
# manifest every installed copy polls). Because every release is signed with the
# SAME identity, macOS keeps users' permission grants across updates — they grant
# once, ever.
#
#   bash Scripts/release.sh [shortVersion]      e.g. bash Scripts/release.sh 0.2.0
#
set -euo pipefail

REPO="nikosummers-sudo/localflow"
IDENTITY="LocalFlow Dev Signing"
PLIST="Sources/LocalFlow/Info.plist"
cd "$(dirname "$0")/.."

command -v gh >/dev/null || { echo "❌ gh CLI not found."; exit 1; }
security find-identity -v -p codesigning | grep -q "$IDENTITY" \
  || { echo "❌ Signing identity '$IDENTITY' missing — run Scripts/setup-signing.sh first."; exit 1; }

# ── Bump versions ────────────────────────────────────────────────────────────
# The build number is tracked in latest.json, NOT the committed source. The
# source Info.plist stays at build 1 on main, so any user's local rebuild (during
# the one-time migration off the old build-from-source updater) is always LOWER
# than any release — the download-updater always supersedes it. We bump the
# WORKING copy only for this build, then revert it before committing.
PB="/usr/libexec/PlistBuddy"
# Read the last build from latest.json with plutil (PlistBuddy can't parse JSON).
CUR_BUILD=1
if [ -f latest.json ]; then
  CUR_BUILD="$(plutil -extract build raw -o - latest.json 2>/dev/null || echo 1)"
fi
case "$CUR_BUILD" in ''|*[!0-9]*) CUR_BUILD=1 ;; esac
NEW_BUILD=$((CUR_BUILD + 1))
SHORT="${1:-$("$PB" -c "Print :CFBundleShortVersionString" "$PLIST")}"
"$PB" -c "Set :CFBundleVersion $NEW_BUILD" "$PLIST"
"$PB" -c "Set :CFBundleShortVersionString $SHORT" "$PLIST"
TAG="v${NEW_BUILD}"
echo "Cutting $TAG (build $NEW_BUILD, version $SHORT)…"

# ── Build + verify it's signed with the STABLE identity (never publish ad-hoc) ─
make app
# Verify via a captured string (NOT a pipe into grep -q): codesign's chatty
# stderr + grep -q's early exit + pipefail would otherwise SIGPIPE into a false
# "ad-hoc" failure.
SIG_OUT="$(codesign -dvv build/LocalFlow.app 2>&1)"
case "$SIG_OUT" in
  *"Authority=$IDENTITY"*) : ;;
  *) echo "❌ Built app is NOT signed with '$IDENTITY' (ad-hoc?). Aborting — an ad-hoc release would reset everyone's permissions."; exit 1 ;;
esac
BUILT_BUILD="$("$PB" -c "Print :CFBundleVersion" build/LocalFlow.app/Contents/Info.plist)"
[ "$BUILT_BUILD" = "$NEW_BUILD" ] || { echo "❌ Built app version $BUILT_BUILD != $NEW_BUILD."; exit 1; }

# ── Zip (ditto -c -k --keepParent preserves the signature + bundle layout) ─────
ZIP="build/LocalFlow.app.zip"
rm -f "$ZIP"
ditto -c -k --keepParent build/LocalFlow.app "$ZIP"
SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
ASSET_URL="https://github.com/${REPO}/releases/download/${TAG}/LocalFlow.app.zip"

# ── Publish the release asset ─────────────────────────────────────────────────
gh release create "$TAG" "$ZIP" \
  --repo "$REPO" \
  --title "LocalFlow $SHORT (build $NEW_BUILD)" \
  --notes "Automated release. Installed copies update themselves within the hour."

# ── Write the manifest every client polls, then commit + push ─────────────────
cat > latest.json <<JSON
{
  "build": $NEW_BUILD,
  "shortVersion": "$SHORT",
  "url": "$ASSET_URL",
  "sha256": "$SHA",
  "minMacOS": 14
}
JSON

# Revert the source version bump — main's Info.plist stays at build 1 so local
# rebuilds can never match a release build. Only the manifest advances.
git checkout -- "$PLIST"

git add latest.json
git commit -m "Release $TAG (build $NEW_BUILD, $SHORT)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
git push origin main

echo
echo "✓ Released $TAG"
echo "  asset:  $ASSET_URL"
echo "  sha256: $SHA"
echo "  Installed copies pick this up within the hour (no user action)."
