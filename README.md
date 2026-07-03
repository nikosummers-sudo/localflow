# LocalFlow

A privacy-first, 100% local dictation app for macOS — a self-hosted take on Wispr Flow.
Hold a key, speak, release, and your words are transcribed **entirely on your Mac** and
inserted wherever your cursor is. No cloud, no accounts, no telemetry.

LocalFlow lives in the menu bar and (by default) the Dock — the Dock icon is optional and
can be turned off in [Settings](#settings) for a menu-bar-only app. It uses
[WhisperKit](https://github.com/argmaxinc/WhisperKit) for on-device speech-to-text.

## Install

**Requirements: an Apple Silicon Mac (M1 or newer) and macOS 14+.** Intel Macs are not supported.

Paste this into Terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/nikosummers-sudo/localflow/main/install.sh | bash
```

The installer builds LocalFlow from source on your Mac (which is why macOS trusts it — no
Gatekeeper warnings), installs it to /Applications, and launches it. Then:

1. Grant the three permissions in the Setup window and click **Relaunch LocalFlow**.
2. The installer offers to set up **AI cleanup** for you (installs [Ollama](https://ollama.com)
   and its `gemma3:4b` model, ~3.5 GB) — say yes, or skip it and add it any time later with
   `ollama pull gemma3:4b`. Dictation works fine without it.
3. Your first dictation downloads the speech model (~1.6 GB, one-time). Wait for **Ready**
   in the menu bar, then hold **Right Option** anywhere and talk.

**Updates are automatic.** The installer sets up a background agent that checks this repo
every 6 hours and quietly rebuilds and swaps in new versions — settings and permissions
survive. You can also update immediately by pasting the install command again, or turn
auto-updates off with:

```bash
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.nikosummers.localflow.updater.plist \
  && rm ~/Library/LaunchAgents/com.nikosummers.localflow.updater.plist
```

## How it works

1. Press your dictation shortcut in any app. By default that's **holding Right Option**
   (tap **Space** while holding to lock recording and dictate hands-free), but you can bind
   any key or combination in Settings — see [Usage](#usage) and [Settings](#settings).
2. LocalFlow records from your microphone while recording is active. A small floating
   **pill** near the bottom of the screen reacts to your voice with an animated level meter,
   so you can see it's listening at a glance.
3. When you end the shortcut (release the held modifier, or press the combo again),
   WhisperKit transcribes the audio locally with your main model.
4. Optionally, a local LLM (via [Ollama](https://ollama.com)) **cleans up** the transcript —
   fixing punctuation and removing filler words and false starts — without changing your
   meaning. This is fully local and falls back to the raw transcript if unavailable.
5. The text is placed on the clipboard and pasted at your cursor via a synthesized
   Cmd+V, then your previous clipboard contents are restored. If no text field is focused,
   LocalFlow instead leaves the transcript on your clipboard (without restoring it) and the
   pill shows **"No input field — copied"** so you can paste it wherever you want.

## Requirements

- Apple Silicon Mac (arm64)
- macOS 14 (Sonoma) or later
- Either **Xcode Command Line Tools** (`xcode-select --install`) or full Xcode
- *(Optional)* **[Ollama](https://ollama.com)** running locally, for AI transcript cleanup.
  Cleanup is enabled by default but degrades gracefully to the raw transcript when Ollama
  isn't running — see [AI transcript cleanup](#ai-transcript-cleanup-ollama).

No Xcode is required — the app builds with Swift Package Manager and is assembled into a
`.app` bundle by a small script.

## Build & run

```bash
make app     # compile (release) and assemble build/LocalFlow.app (ad-hoc signed)
make run     # the above, then launch it
make smoke   # offline transcription self-test using the small "base" model
make clean   # remove .build and build
```

That's it. The menu bar shows a microphone icon when LocalFlow is running.

### Stable signing (recommended)

By default `make app` **ad-hoc signs** the bundle. An ad-hoc signature is different on every
build, so macOS treats each rebuild as a brand-new app and **drops its Accessibility and
Input Monitoring grants** — meaning you have to re-grant permissions (and re-enable
auto-paste and the hotkey) every time you rebuild.

To fix this once, create a stable local code-signing certificate:

```bash
bash Scripts/setup-signing.sh   # one-time; may prompt for your login password
```

This creates and trusts a self-signed **"LocalFlow Dev Signing"** identity in your login
keychain. From then on, `make app` automatically signs with it (it prints
`Signed with identity: LocalFlow Dev Signing`), the signature stays stable across rebuilds,
and your permission grants stick. If the certificate isn't present, the build falls back to
ad-hoc signing and prints a reminder.

### Optional: open in Xcode

A `project.yml` is included for [XcodeGen](https://github.com/yonaskolb/XcodeGen) if you
prefer a full Xcode project. It is **not** used by the `make` build.

```bash
brew install xcodegen
xcodegen generate
open LocalFlow.xcodeproj
```

## First run: one-time model download

The first time a model is used, WhisperKit downloads it once from Hugging Face. This is
the **only** time LocalFlow ever touches the network. After that, everything is offline.

Models are stored under:

```
~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/<model-variant>
```

Approximate download sizes:

| Model            | Size    | Notes                              |
|------------------|---------|------------------------------------|
| `tiny`           | ~75 MB  | Fastest, least accurate            |
| `base`           | ~150 MB | Used by `make smoke`               |
| `small`          | ~500 MB |                                    |
| `large-v3`       | ~1.5 GB | Most accurate                      |
| `large-v3_turbo` | ~1.6 GB | **Default** — accurate and fast    |

The menu bar icon shows a download glyph while a model is loading. If the configured
model can't be loaded, LocalFlow falls back to `base` and shows a brief notice.

### Latency

Transcription runs on-device, so speed depends on your Mac and the chosen model. A few
things keep it fast:

- **Warm-up at launch.** After the model loads, LocalFlow runs a throwaway transcription of
  one second of silence so Core ML / ANE compilation and caching happen up front — the first
  *real* dictation is then as fast as the rest, instead of paying a one-time compile cost.
- **No timestamps.** Decoding skips timestamp-token generation (`withoutTimestamps`), which
  LocalFlow doesn't need for plain insertion.
- **VAD chunking.** Long audio is split at natural silences and the chunks are decoded
  concurrently (`chunkingStrategy: .vad`), which is a large win for long, hands-free
  dictations rather than decoding one long clip serially.
- **Instant capture.** When enabled (the default), the microphone stays warm and a short
  pre-roll of audio is captured continuously, so a dictation starts the instant you press the
  key — with **zero engine-startup delay and no clipped first words**. See
  [Settings](#settings) and [Privacy](#privacy) for exactly what this buffers.
- **Streaming transcription.** During a long dictation, LocalFlow transcribes and cleans the
  audio in **whole chunks while you're still talking** (cutting each chunk at a natural
  silence), so when you release the key only the short *tail* is left to process. The result
  is that time-to-insert stays roughly constant regardless of how long you spoke, instead of
  growing with the length of the dictation. Short dictations that finish before the first
  chunk commits use the original single-pass path unchanged.

## The dictation pill

While you dictate, a small, dark, rounded **pill** appears near the bottom-center of the
screen. It's deliberately compact — no big text box, no border, no hairline — and its job is
to reassure you that LocalFlow is listening. During recording it shows a mic glyph and a row
of thin bars that **animate from your live microphone level**, with a springy pop when you
start speaking. In hands-free (locked) mode it also shows a small lock. As the pipeline
progresses, the same pill morphs through its phases: transcribing, cleaning, a brief
"✓ Inserted", or **"No input field — copied"** when there was nowhere to paste.

The pill never takes keyboard focus from the app you're typing into and ignores the mouse,
so it can't get in your way.

### Optional live text preview

If you want to *read your words as you speak* — not just see the level meter — turn on
**Show live text preview** in [Settings](#settings) (it's **off by default**). When on, the
pill grows into a wider rounded rectangle that also shows a running preview of your words,
powered by a **separate, lightweight preview model** (`base` by default) that runs
alongside — never competing with — your main model.

The preview is **display-only**: the text it shows is a fast approximation and is *never*
what gets inserted. The inserted text always comes from your main model's pass over the full
recording. When the preview is off, the preview model isn't loaded at all, so it costs no
extra memory or compute.

## AI transcript cleanup (Ollama)

LocalFlow can pass the finished transcript through a **local** LLM to tidy it up — fix
punctuation, capitalization and spacing, and remove filler words (“um”, “uh”, “you know”)
and false starts — **without** adding, answering, summarizing, translating, or rephrasing
your content. Everything runs on your Mac via [Ollama](https://ollama.com); the only network
call is to `http://localhost:11434` on the loopback interface.

Setup:

```bash
# 1. Install Ollama (https://ollama.com/download), then pull the default model:
ollama pull gemma3:4b

# 2. Make sure the Ollama server is running (the app talks to localhost:11434):
ollama list        # succeeds when the server is up
```

Cleanup is **enabled by default** and designed to never get in your way:

- **50-character gate.** Transcripts shorter than 50 characters are inserted as-is — too
  little to clean and not worth a round-trip.
- **Divergence guard.** If the cleaned text is suspiciously shorter (<50%) or longer (>160%)
  than the raw transcript — a sign the model rewrote or answered instead of cleaning — the
  raw transcript is inserted instead.
- **Raw fallback.** Any error, timeout (15s budget), or empty result falls back to the raw
  transcript. Cleanup **never** blocks or replaces a valid transcription. When a fallback
  happens, the menu briefly explains why (e.g. *“Cleanup unavailable — inserted raw
  transcript”*).

You can change the model or disable cleanup entirely in [Settings](#settings). To sanity-check
your setup from the command line:

```bash
.build/release/CleanupCheck        # cleans a built-in messy sample; exits non-zero if Ollama is down
```

## Permissions

LocalFlow needs three macOS permissions. The Setup window (menu bar → **Setup &
Permissions…**) walks through them with live status and buttons.

| Permission          | Why                                                            | System Settings pane                                             |
|---------------------|----------------------------------------------------------------|------------------------------------------------------------------|
| **Microphone**      | Records your voice while you dictate.                          | Privacy & Security → Microphone                                  |
| **Accessibility**   | Pastes the transcript into the app you're using (synthetic Cmd+V). | Privacy & Security → Accessibility                          |
| **Input Monitoring**| Detects your dictation shortcut being pressed, system-wide.    | Privacy & Security → Input Monitoring                            |

LocalFlow registers itself in the Input Monitoring pane on first launch, so its row should
already be there to toggle on. If it isn't listed, click the **+** button in that pane and
add LocalFlow from **/Applications**.

If Accessibility is not granted, LocalFlow still transcribes and leaves the text on your
clipboard so you can paste it manually — it just won't auto-paste.

Accessibility also lets LocalFlow check whether the focused element can actually accept text
before pasting. If it can tell you're **not** in a text field (say, focus is on a button or
the desktop), it skips the paste and just leaves the transcript on your clipboard so it isn't
fired into nowhere. When it's unsure, it pastes anyway — a needless paste is less annoying
than a lost transcript.

## Usage

Your dictation shortcut is fully configurable (see [Settings](#settings)); the default is
holding **Right Option**. There are two gesture styles, depending on what you bind:

- **Modifier hold (hold to talk).** Hold the modifier(s), speak, release. The text appears
  at your cursor. While holding, tap **Space** to lock recording — you can then let go and
  keep talking hands-free (the Space keystroke is swallowed, so it won't type into your
  document). Press the modifier again to stop, transcribe, and insert.
- **Key combo (press to toggle).** If you bind a key combination (e.g. **⌘⇧D**), press it
  once to start recording hands-free and press it again to finish. The combo is swallowed
  system-wide while LocalFlow runs, so choose one no other app needs.

The menu bar icon reflects the current state: idle (`mic`), recording (`mic.fill`), locked
recording (`mic.badge.plus`), loading a model, transcribing (`waveform`), cleaning up
(`wand.and.stars`), inserting, and — when there was no text field to paste into —
copied-to-clipboard (`doc.on.clipboard`). Recording auto-stops after 10 minutes in either mode.

The menu also has a **Copy Last Transcript** item that re-copies your most recent dictation
to the clipboard. It's a permanent safety net: even if a paste landed in the wrong place, was
lost, or there was no input field, your last transcript is one click away. (It's disabled
until you've dictated something.)

> Locking needs an active event tap, which requires Input Monitoring. If macOS refuses the
> active tap, LocalFlow falls back to a listen-only tap: lock mode still engages, but the
> Space can't be swallowed before it reaches the focused app.

Clicking the Dock icon (or double-clicking LocalFlow in Finder / Launchpad) opens the **main
window** — the searchable list of your past dictations. A gear button there opens Settings,
and **Setup & Permissions…** is always available from the menu bar.

## Dictation history

Every dictation is saved to a searchable list you can reopen any time — click the **Dock
icon**, choose **Open LocalFlow** from the menu bar, or click the Dock icon again.

- **What it stores.** Each entry keeps the final inserted text, when it was dictated, and the
  app you dictated into. The most recent **200** dictations are kept; older ones drop off.
- **Where it lives.** A single `history.json` under
  `~/Library/Application Support/LocalFlow/`. It is stored **only on this Mac** and never
  leaves it.
- **Re-copy anything.** Hover a row and click **Copy** to put that whole dictation back on
  the clipboard. Row text is also selectable, so you can highlight and copy just part of it.
- **Fix a word — and teach LocalFlow.** Hover a row, click the **pencil (Fix words)**, and
  each word becomes a clickable chip. Click a word (shift-click another to select a phrase
  like "Oh llama"), type the correction ("Ollama"), and choose:
  - **Fix & auto-correct** — rewrites this saved entry *and* teaches your
    [personal dictionary](#settings) so future dictations of that word/phrase auto-correct.
    The correction is added as a whole-word replacement and as a vocabulary term (so it also
    biases transcription and survives AI cleanup).
  - **Just fix here** — only rewrites this one saved entry, teaching nothing.
- **Clear it.** The footer shows a running count and a **Clear History** button (with a
  confirmation) that erases every saved dictation from this Mac.
- **Turn it off.** Settings has a **Save dictation history on this Mac** toggle (on by
  default). With it off, new dictations aren't saved; anything already saved stays until you
  clear it.

## Settings

Menu bar → **Settings…**:

- **Model** — `tiny` / `base` / `small` / `large-v3` / `large-v3_turbo` (default). Changing
  it downloads the new model on next load. A **Reload model** button forces a reload.
- **Dictation shortcut** — click the field and press the keys you want, then let go.
  Recording captures the shortcut with no restart needed. Two styles are supported:
  - *Modifier-only* (one or more modifier keys, e.g. Right Option, or Right ⌘ + Right ⌥) is
    **hold-to-talk** — hold to dictate, tap **Space** while holding to lock hands-free.
  - *Key combo* (a key plus modifiers, e.g. **⌘⇧D**) is **press-to-start / press-again-to-finish**
    and works hands-free. Combos are swallowed system-wide, so pick one no other app needs.

  A **Reset to default** button restores holding Right Option. Bindings that would break
  normal use are refused with an inline note — a plain printable key with no modifier, the
  Space key, and system-reserved combos like ⌘V / ⌘C / ⌘X / ⌘Q / ⌘W.
- **Launch LocalFlow at login** — **on by default**. Starts LocalFlow automatically when you
  log in so it's always ready in the menu bar. Turn it off to launch it yourself.
- **Show LocalFlow in the Dock** — **on by default**. Shows a Dock icon; clicking it opens
  the main window. LocalFlow always stays in the menu bar regardless — turn this off for a
  menu-bar-only app. Toggling it takes effect immediately, no restart needed.
- **Restore clipboard after pasting** — on by default; restores your previous clipboard
  contents ~0.6s after inserting text.
- **Save dictation history on this Mac** — **on by default**. Saves each dictation to the
  searchable list in the main window (see [Dictation history](#dictation-history)). Stored
  only on this Mac, capped at the most recent 200. Turn it off to stop saving new dictations;
  use **Clear History** in the main window to erase what's saved.
- **Microphone**
  - *Instant capture (keeps mic warm)* — **on by default**. Keeps the microphone open so
    dictation starts instantly and never clips your first words. Audio spoken outside a
    dictation lives only in a rolling **2-second in-memory buffer that is continuously
    discarded** — it is never processed, stored, or transmitted. While LocalFlow runs, macOS
    shows the microphone-in-use indicator. Turn this off to only open the mic while you
    dictate (dictation may then clip the very start).
- **AI Cleanup**
  - *Clean up transcripts with AI (Ollama)* — on by default. Runs the finished transcript
    through a local Ollama model (see [AI transcript cleanup](#ai-transcript-cleanup-ollama)).
    Falls back to the raw transcript if Ollama is unavailable.
  - *Model* — the Ollama model to use for cleanup (default `gemma3:4b`).
- **Live text preview**
  - *Show live text preview* — **off by default**. The dictation pill's voice animation is
    always shown while you dictate; turning this on additionally shows a running text preview
    of your words in a wider pill. When off, the preview model isn't loaded at all.
  - *Preview model* — `tiny` or `base` (default), used only for the on-screen preview.

## Troubleshooting

- **Auto-paste stopped working after a rebuild.** An ad-hoc-signed rebuild changes the
  binary's signature, so macOS resets its Accessibility / Input Monitoring grants. The
  permanent fix is [stable signing](#stable-signing-recommended) — run
  `Scripts/setup-signing.sh` once. As a quick workaround, toggle LocalFlow off and on in the
  relevant System Settings pane, or use the **Relaunch LocalFlow** button in Setup.
- **Nothing gets pasted in a password field.** Secure text fields block synthetic paste by
  design. The text stays on your clipboard.
- **The hotkey stopped responding briefly.** macOS can disable an event tap after a timeout
  or heavy input; LocalFlow detects this and re-enables the tap automatically.
- **"Copied — grant Accessibility to auto-paste".** Accessibility isn't granted yet; the
  transcript is on your clipboard. Grant Accessibility in Setup to enable auto-paste.
- **"No input field — copied to clipboard".** LocalFlow determined that the focused element
  can't accept text, so it left the transcript on your clipboard instead of pasting into
  nowhere. Click into a real text field and paste (⌘V), or use **Copy Last Transcript** from
  the menu.
- **Why is the orange microphone indicator always on?** That dot is macOS's privacy
  indicator, shown whenever any app has the microphone open. LocalFlow keeps the mic open
  for **instant capture** (dictation starts instantly, first words never clipped). While
  idle, audio only flows into a 2-second rolling buffer in RAM that is continuously
  overwritten — never transcribed, stored, or transmitted. Prefer the dot to appear only
  while dictating? Turn off *Instant capture* in Settings (dictation then takes a beat to
  start).

## Roadmap

- **Phase 0 — Scaffolding.** Package, build tooling, app bundle. ✅ Done.
- **Phase 1 — MVP.** Push-to-talk dictation with WhisperKit, insertion, permissions
  onboarding, settings. ✅ Done.
- **Phase 2 — Cleanup & live feedback.** Optional local LLM (Ollama, `gemma3:4b`) to tidy
  transcripts; live partial-transcription HUD. ✅ Done.
- **Phase 3 — Power features.** Custom dictionary, voice commands ("new line", "scratch
  that"), per-app modes, configurable shortcuts. ✅ Done.
- **Phase 4 — Polish.** Streaming transcription, instant capture, Dock/menu-bar presence,
  auto-updates. ✅ Largely done — remaining ideas: raw-then-replace insertion, swappable
  Parakeet STT engine.

## Privacy

- **No telemetry.** LocalFlow collects nothing and phones home to nothing.
- **Everything stays local.** Audio never leaves your Mac. Transcription runs on-device via
  WhisperKit / Core ML, and the optional AI cleanup runs on-device via Ollama.
- **Dictation history is local and optional.** When enabled (the default), each dictation's
  final text is saved to `history.json` under `~/Library/Application Support/LocalFlow/`,
  capped at the most recent 200 entries. It is stored **only on this Mac**, never transmitted.
  Turn off *Save dictation history* in [Settings](#settings) to stop saving, or use **Clear
  History** in the main window to erase it.
- **Instant capture is bounded and transient.** With instant capture on (the default), the
  microphone stays open while LocalFlow runs so dictation can start without clipping your
  first words. Audio spoken *outside* a dictation lives only in a rolling **2-second
  in-memory buffer that is continuously discarded** — it is never written to disk, processed,
  or transmitted; only the moment you start a dictation is a brief pre-roll from that buffer
  used, and then only to seed *your* dictation. While LocalFlow runs, macOS shows the
  microphone-in-use indicator so it's always clear when the mic is open. You can turn instant
  capture off in [Settings](#settings) to open the mic only while you actively dictate.
- **No external network access.** There are only two network paths, both under your control:
  the one-time WhisperKit model download from Hugging Face, and the AI-cleanup call to your
  **local** Ollama server at `http://localhost:11434` (loopback only — nothing leaves the
  machine). With models already downloaded and cleanup either local or disabled, LocalFlow
  works fully offline.
