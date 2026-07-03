# LocalFlow Handover Runbook

**Deadline: before 25 August 2026** (Niko's last day). Two things must transfer or the
installed fleet is orphaned: the **distribution repo** and the **signing certificate**.
Everything else (build, release, code) is documented in the README.

## Why this matters

Every installed copy of LocalFlow polls
`https://raw.githubusercontent.com/nikosummers-sudo/localflow/main/latest.json` hourly,
unauthenticated, and downloads release zips from this repo's GitHub Releases. If this
repo disappears, updates silently stop fleet-wide (the app keeps working, frozen at its
last build). If the signing cert is lost, no future update can ever be installed
without resetting every user's macOS permissions.

## 1. Repo migration

The new home MUST be able to serve files publicly — **a private repo breaks the update
feed** (clients fetch without auth). Two acceptable shapes:

- **Option A (simplest):** a public repo under the company org, e.g.
  `Triptease-Mktg/localflow` — full source + releases. The source contains no secrets
  and no user data (verified in the July 2026 security audit; the diagnostic log
  contract forbids transcript content).
- **Option B (minimal public surface):** source in any private repo + a small PUBLIC
  `…/localflow-releases` repo containing only `latest.json`, `install.sh`,
  `uninstall.sh`, `Scripts/auto-update.sh`, and the release assets.

### Migration steps (order matters)

1. Create the new repo; push full history (`git push <new-remote> main`).
2. In the new repo's copy, update the hardcoded URLs to point at the new repo:
   - `Scripts/auto-update.sh` → `MANIFEST_URL`
   - `install.sh` → `MANIFEST_URL`, `UPDATER_URL`
   - `Scripts/release.sh` → `REPO`
   - `README.md` → the install/uninstall one-liners
3. Cut a **transition release from the OLD repo** (`bash Scripts/release.sh` in the old
   checkout) whose *bundled* `Scripts/auto-update.sh` already points at the NEW repo.
   The app syncs its bundled updater to `~/.localflow/auto-update.sh` at every launch,
   so every machine self-migrates to the new feed within one update+launch cycle —
   zero user action.
4. Publish the SAME build in the new repo too: create the matching GitHub Release with
   the same zip, and commit a `latest.json` with the same build number, new asset URL,
   and the same sha256.
5. All later releases: from the new repo only. Leave the old repo's final `latest.json`
   in place as long as possible so stragglers still reach the transition build.

## 2. Signing certificate

Releases are signed with **"LocalFlow Dev Signing"** — a self-signed certificate that
exists ONLY in Niko's login keychain (created by `Scripts/setup-signing.sh`). Users'
macOS permission grants (Microphone / Accessibility / Input Monitoring) are bound to
this identity, and every machine's updater **refuses** builds signed by anything else.

- **Export (on Niko's Mac, before departure):** Keychain Access → My Certificates →
  "LocalFlow Dev Signing" → export as `.p12` with a strong password. Or:
  `security export -k ~/Library/Keychains/login.keychain-db -t identities -f pkcs12 -o localflow-signing.p12 -P '<password>'`
- **Store:** the `.p12` and its password in the company password vault (separate items).
- **Import (successor's Mac):** double-click the `.p12`, enter the password, then in
  Keychain Access set the private key's Access Control to allow `codesign`, or run a
  build once and click "Always Allow". Verify with:
  `security find-identity -v -p codesigning | grep "LocalFlow Dev Signing"`

**If the cert is ever lost:** create a new one (`Scripts/setup-signing.sh`), then ship
a transition release FIRST whose bundled `auto-update.sh` accepts the new identity in
its signature check — and warn users that macOS will re-ask for the three permissions
once after the switch.

## 3. Release workflow (for the successor)

From the repo root on a Mac with the cert installed and `gh` authenticated with write
access: `bash Scripts/release.sh <version>` — builds, signs, verifies, publishes the
GitHub Release, updates `latest.json`, pushes. The fleet updates itself within the hour.
