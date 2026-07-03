import AppKit
import CoreGraphics
import LocalFlowKit
import SwiftUI

/// Editable, persistent-backed state for the Dictionary and Apps tabs. Loads from
/// the shared config store on open and writes back on every change, so edits take
/// effect on the next dictation without a restart.
@MainActor
final class DictionaryViewModel: ObservableObject {
    @Published var terms: [String]
    @Published var replacements: [Replacement]
    @Published var appRules: [AppRule]

    init() {
        let dictionary = LocalFlowConfig.shared.dictionary
        terms = dictionary.terms
        replacements = dictionary.replacements
        appRules = LocalFlowConfig.shared.appRules
    }

    /// Persists the dictionary. Blank/whitespace-only terms are dropped from the
    /// saved copy (so the engine never biases on "") while the editor keeps its
    /// in-progress rows.
    func persistDictionary() {
        let cleanedTerms = terms
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        LocalFlowConfig.shared.dictionary = PersonalDictionary(terms: cleanedTerms, replacements: replacements)
    }

    func persistAppRules() {
        LocalFlowConfig.shared.appRules = appRules
    }

    func addTerm() { terms.append("") }

    func removeTerm(at index: Int) {
        guard terms.indices.contains(index) else { return }
        terms.remove(at: index)
        persistDictionary()
    }

    func addReplacement() {
        replacements.append(Replacement(find: "", replace: ""))
    }

    func removeReplacement(_ replacement: Replacement) {
        replacements.removeAll { $0.id == replacement.id }
        persistDictionary()
    }

    /// Adds a rule for the app the user was in before opening Settings. No-op if a
    /// rule for that app already exists or the app is unknown.
    func addRuleForLastForegroundApp() {
        guard let bundleID = AppState.shared.lastForegroundBundleID else { return }
        guard !appRules.contains(where: { $0.bundleID == bundleID }) else { return }
        let name = AppState.shared.lastForegroundName ?? bundleID
        appRules.append(AppRule(bundleID: bundleID, appName: name))
        persistAppRules()
    }

    func removeRule(_ rule: AppRule) {
        appRules.removeAll { $0.id == rule.id }
        persistAppRules()
    }
}

struct SettingsView: View {
    let onModelChanged: () -> Void
    let onHotkeyChanged: () -> Void
    let onPartialsChanged: () -> Void
    let onCleanupChanged: () -> Void
    let onInstantCaptureChanged: () -> Void
    let onDockVisibilityChanged: (Bool) -> Void
    let onInputDeviceChanged: () -> Void

    @StateObject private var vm = DictionaryViewModel()

    var body: some View {
        TabView {
            GeneralTab(
                onModelChanged: onModelChanged,
                onHotkeyChanged: onHotkeyChanged,
                onPartialsChanged: onPartialsChanged,
                onCleanupChanged: onCleanupChanged,
                onInstantCaptureChanged: onInstantCaptureChanged,
                onDockVisibilityChanged: onDockVisibilityChanged,
                onInputDeviceChanged: onInputDeviceChanged
            )
            .tabItem { Label("General", systemImage: "gearshape") }

            DictionaryTab(vm: vm)
                .tabItem { Label("Dictionary", systemImage: "text.book.closed") }

            AppsTab(vm: vm)
                .tabItem { Label("Apps", systemImage: "app.badge") }
        }
        .frame(width: 520, height: 640)
        .tint(Color.ttPurple500)
    }
}

// MARK: - General

private struct GeneralTab: View {
    let onModelChanged: () -> Void
    let onHotkeyChanged: () -> Void
    let onPartialsChanged: () -> Void
    let onCleanupChanged: () -> Void
    let onInstantCaptureChanged: () -> Void
    let onDockVisibilityChanged: (Bool) -> Void
    let onInputDeviceChanged: () -> Void

    @AppStorage("modelName") private var modelName = defaultModelName
    @AppStorage("inputDeviceUID") private var inputDeviceUID = ""
    @State private var inputDevices: [InputDevice] = []
    @AppStorage("launchAtLogin") private var launchAtLogin = true
    @AppStorage("showInDock") private var showInDock = true
    @AppStorage("restoreClipboard") private var restoreClipboard = true
    @AppStorage("instantCapture") private var instantCapture = true

    @AppStorage("historyEnabled") private var historyEnabled = true

    @AppStorage("cleanupEnabled") private var cleanupEnabled = true
    @AppStorage("cleanupModel") private var cleanupModel = "gemma3:4b"
    @AppStorage("cleanupMode") private var cleanupMode = "clean"

    @AppStorage("voiceCommandsEnabled") private var voiceCommandsEnabled = true

    @AppStorage("showLivePreview") private var showLivePreview = false
    @AppStorage("partialsModel") private var partialsModel = "base"

    private let models = ["tiny", "base", "small", "large-v3", "large-v3_turbo"]

    var body: some View {
        Form {
            Section("Speech-to-text model") {
                Picker("Model", selection: $modelName) {
                    ForEach(models, id: \.self) { Text($0).tag($0) }
                }
                Text("Changing the model downloads it from Hugging Face the next time it loads.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button("Reload model", action: onModelChanged)
            }

            Section("Dictation shortcut") {
                ShortcutRecorderView(onHotkeyChanged: onHotkeyChanged)
            }

            Section("Startup") {
                Toggle("Launch LocalFlow at login", isOn: $launchAtLogin)
                Text("Starts LocalFlow automatically when you log in, so it's always ready in the menu bar.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Toggle("Show LocalFlow in the Dock", isOn: $showInDock)
                Text("Adds a Dock icon (on by default) — click it to open this window. LocalFlow always lives in the menu bar either way; turn this off for a menu-bar-only app.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Clipboard") {
                Toggle("Restore clipboard after pasting", isOn: $restoreClipboard)
            }

            Section("History") {
                Toggle("Save dictation history on this Mac", isOn: $historyEnabled)
                Text("Keeps a searchable list of your past dictations (the most recent 200) in LocalFlow's Application Support folder. It never leaves this Mac. Open the main window to review, re-copy, or correct past dictations — and to Clear History. Turn this off to stop saving new dictations; anything already saved stays until you clear it.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Microphone") {
                Picker("Input device", selection: $inputDeviceUID) {
                    Text("System Default").tag("")
                    ForEach(inputDevices) { Text($0.name).tag($0.uid) }
                }
                Text("Pick your mic if the wrong one is being used — e.g. an external mic that isn't the system default.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Toggle("Instant capture (keeps mic warm)", isOn: $instantCapture)
                Text("Keeps the microphone open so dictation starts instantly and never clips your first words. Audio spoken outside a dictation lives only in a rolling 2-second in-memory buffer that is continuously discarded — it is never processed, stored, or transmitted. While LocalFlow runs, macOS shows the microphone-in-use indicator. Turn this off to only open the mic while you dictate (dictation may then clip the very start).")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Voice commands") {
                Toggle("Interpret spoken commands", isOn: $voiceCommandsEnabled)
                Text("Say “new line” or “new paragraph” to insert breaks, or “new bullet” to start a “- ” list line. Commands only ever insert — they never delete your words. Turn off to type those phrases literally.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("AI Cleanup") {
                Toggle("Clean up transcripts with AI (Ollama)", isOn: $cleanupEnabled)
                Picker("Style", selection: $cleanupMode) {
                    Text("Clean").tag("clean")
                    Text("Refine").tag("refine")
                }
                .pickerStyle(.segmented)
                .disabled(!cleanupEnabled)
                Text(cleanupMode == "refine"
                     ? "Refine reformats rambling speech so your point comes across — reorganizes, tightens, and bullets lists, keeping your voice and every name and number. Falls back to Clean if it strays. Long dictations take a few extra seconds."
                     : "Clean fixes punctuation and removes fillers and false starts — never rewords. The safe default.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("Model", text: $cleanupModel)
                Text("Runs locally via Ollama at localhost:11434. If the server is unavailable, LocalFlow inserts the raw transcript instead.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Live text preview") {
                Toggle("Show live text preview", isOn: $showLivePreview)
                Picker("Preview model", selection: $partialsModel) {
                    Text("tiny").tag("tiny")
                    Text("base").tag("base")
                }
                .disabled(!showLivePreview)
                Text("Off by default. The dictation pill always shows a voice animation while you speak; turn this on to also show a running preview of your words. A small model powers the preview — the final inserted text always uses your main model above.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: modelName) { _, _ in onModelChanged() }
        .onChange(of: launchAtLogin) { _, newValue in
            // Best-effort: if the system refuses to (un)register, revert the toggle
            // quietly rather than surfacing a scary error.
            if !LaunchAtLogin.apply(newValue) {
                launchAtLogin = !newValue
            }
        }
        .onChange(of: showInDock) { _, newValue in onDockVisibilityChanged(newValue) }
        .onChange(of: showLivePreview) { _, _ in onPartialsChanged() }
        .onChange(of: partialsModel) { _, _ in onPartialsChanged() }
        .onChange(of: cleanupEnabled) { _, _ in onCleanupChanged() }
        .onChange(of: cleanupModel) { _, _ in onCleanupChanged() }
        .onChange(of: instantCapture) { _, _ in onInstantCaptureChanged() }
        .onChange(of: inputDeviceUID) { _, _ in onInputDeviceChanged() }
        .onAppear { inputDevices = InputDevices.all() }
    }
}

// MARK: - Dictionary

private struct DictionaryTab: View {
    @ObservedObject var vm: DictionaryViewModel

    var body: some View {
        Form {
            Section("Vocabulary") {
                Text("Proper nouns and jargon the model should spell correctly (e.g. Triptease, WhisperKit). These bias transcription and are preserved during cleanup — a soft hint, not a guarantee.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                ForEach(vm.terms.indices, id: \.self) { index in
                    HStack {
                        TextField("Term", text: $vm.terms[index])
                            .textFieldStyle(.roundedBorder)
                        Button(role: .destructive) {
                            vm.removeTerm(at: index)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this term")
                        .accessibilityLabel("Remove \(vm.terms[index].isEmpty ? "term" : vm.terms[index])")
                    }
                }

                Button {
                    vm.addTerm()
                } label: {
                    Label("Add term", systemImage: "plus")
                }
            }

            Section("Replacements") {
                Text("Hard find → replace applied to the final text. Whole-word and case-insensitive by default, so “period” never changes “periodic”. Use this to force spellings the model keeps getting wrong.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                ForEach($vm.replacements) { $replacement in
                    VStack(spacing: 6) {
                        HStack {
                            TextField("Find", text: $replacement.find)
                                .textFieldStyle(.roundedBorder)
                            Image(systemName: "arrow.right")
                                .foregroundColor(.secondary)
                            TextField("Replace", text: $replacement.replace)
                                .textFieldStyle(.roundedBorder)
                            Button(role: .destructive) {
                                vm.removeReplacement(replacement)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove this replacement")
                            .accessibilityLabel("Remove replacement \(replacement.find.isEmpty ? "" : replacement.find)")
                        }
                        HStack {
                            Toggle("Whole word", isOn: $replacement.wholeWord)
                            Toggle("Case-sensitive", isOn: $replacement.caseSensitive)
                            Spacer()
                        }
                        .toggleStyle(.checkbox)
                        .font(.caption)
                    }
                    .padding(.vertical, 2)
                }

                Button {
                    vm.addReplacement()
                } label: {
                    Label("Add replacement", systemImage: "plus")
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: vm.terms) { _, _ in vm.persistDictionary() }
        .onChange(of: vm.replacements) { _, _ in vm.persistDictionary() }
    }
}

// MARK: - Apps

private struct AppsTab: View {
    @ObservedObject var vm: DictionaryViewModel

    var body: some View {
        Form {
            Section("Per-app overrides") {
                Text("Rules bind to the app you start dictating in. Override AI cleanup and add a tone hint so, say, Slack stays casual while email stays formal.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button {
                    vm.addRuleForLastForegroundApp()
                } label: {
                    Label(addButtonTitle, systemImage: "plus.app")
                }
                .disabled(AppState.shared.lastForegroundBundleID == nil)
            }

            ForEach($vm.appRules) { $rule in
                Section(rule.appName.isEmpty ? rule.bundleID : rule.appName) {
                    Picker("AI cleanup", selection: cleanupBinding(for: $rule)) {
                        Text("Inherit global").tag(CleanupChoice.inherit)
                        Text("On").tag(CleanupChoice.on)
                        Text("Off").tag(CleanupChoice.off)
                    }
                    .pickerStyle(.segmented)

                    VStack(alignment: .leading, spacing: 4) {
                        Picker("Insertion", selection: insertionBinding(for: $rule)) {
                            Text("Auto-detect").tag(InsertionChoice.auto)
                            Text("Always paste").tag(InsertionChoice.paste)
                        }
                        .pickerStyle(.segmented)
                        Text("Always paste skips the is-this-a-text-field check — for apps that hide their inputs from macOS accessibility.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Tone hint")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("e.g. Casual Slack message — keep contractions.", text: toneBinding(for: $rule), axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(1...3)
                    }

                    Button(role: .destructive) {
                        vm.removeRule(rule)
                    } label: {
                        Label("Remove rule", systemImage: "trash")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: vm.appRules) { _, _ in vm.persistAppRules() }
    }

    private var addButtonTitle: String {
        if let name = AppState.shared.lastForegroundName {
            return "Add rule for \(name)"
        }
        return "Add rule for current app"
    }

    private enum CleanupChoice: Hashable { case inherit, on, off }
    private enum InsertionChoice: Hashable { case auto, paste }

    private func insertionBinding(for rule: Binding<AppRule>) -> Binding<InsertionChoice> {
        Binding(
            get: { rule.wrappedValue.alwaysPaste ? .paste : .auto },
            set: { choice in
                rule.wrappedValue.insertionMode = (choice == .paste) ? "paste" : nil
            }
        )
    }

    private func cleanupBinding(for rule: Binding<AppRule>) -> Binding<CleanupChoice> {
        Binding(
            get: {
                switch rule.wrappedValue.cleanupEnabled {
                case .none: return .inherit
                case .some(true): return .on
                case .some(false): return .off
                }
            },
            set: { choice in
                switch choice {
                case .inherit: rule.wrappedValue.cleanupEnabled = nil
                case .on: rule.wrappedValue.cleanupEnabled = true
                case .off: rule.wrappedValue.cleanupEnabled = false
                }
            }
        )
    }

    private func toneBinding(for rule: Binding<AppRule>) -> Binding<String> {
        Binding(
            get: { rule.wrappedValue.toneAddendum ?? "" },
            set: { text in
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                rule.wrappedValue.toneAddendum = trimmed.isEmpty ? nil : text
            }
        )
    }
}

// MARK: - Shortcut recorder

/// Records a dictation shortcut by capturing key events while the Settings window is key.
/// Uses a LOCAL NSEvent monitor (no permissions needed): a run of modifier presses that
/// are all released becomes a `.modifierHold`; a non-modifier keyDown becomes a
/// `.comboToggle` carrying whatever modifiers were down. Esc cancels. Invalid bindings
/// (bare printable keys, Space, or system-reserved combos) surface a friendly message.
@MainActor
final class HotkeyRecorderModel: ObservableObject {
    @Published var binding: HotkeyBinding = HotkeyBinding.load()
    @Published var isRecording = false
    @Published var errorMessage: String?

    private let onChange: () -> Void
    private var monitor: Any?
    /// Modifier keycodes currently down, and the deepest set seen this recording.
    private var currentHeld: Set<Int64> = []
    private var maxHeld: Set<Int64> = []

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func toggleRecording() {
        if isRecording { cancelRecording() } else { startRecording() }
    }

    func startRecording() {
        guard monitor == nil else { return }
        errorMessage = nil
        currentHeld = []
        maxHeld = []
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            // Pull out Sendable primitives so the non-Sendable NSEvent never crosses the
            // actor hop. Local monitors are delivered on the main thread already.
            let keyCode = Int64(event.keyCode)
            let cg = HotkeyRecorderModel.cgFlags(event.modifierFlags)
            let isFlagsChanged = (event.type == .flagsChanged)
            let consumed = MainActor.assumeIsolated {
                self.handle(keyCode: keyCode, cgFlags: cg, isFlagsChanged: isFlagsChanged)
            }
            // Consuming (returning nil) keeps the captured keys from actuating buttons.
            return consumed ? nil : event
        }
    }

    func cancelRecording() {
        removeMonitor()
        isRecording = false
        currentHeld = []
        maxHeld = []
    }

    func resetToDefault() {
        cancelRecording()
        errorMessage = nil
        apply(.default)
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(keyCode: Int64, cgFlags: CGEventFlags, isFlagsChanged: Bool) -> Bool {
        isFlagsChanged
            ? handleFlagsChanged(keyCode: keyCode, cgFlags: cgFlags)
            : handleKeyDown(keyCode: keyCode, cgFlags: cgFlags)
    }

    private func handleKeyDown(keyCode code: Int64, cgFlags: CGEventFlags) -> Bool {
        // Function-type keys (arrows, F-keys, Home/End…) carry an implicit fn flag on
        // some keyboards but not others — strip it so the saved combo matches everywhere.
        let mods = HotkeyBinding.normalizedModifiers(forKeyCode: code, flags: cgFlags)
        // Bare Escape cancels; Esc-with-modifiers is a legitimate combo.
        if code == 53 && mods == 0 {
            cancelRecording()
            return true
        }
        finalize(.comboToggle(keyCode: code, requiredModifiers: mods))
        return true
    }

    private func handleFlagsChanged(keyCode code: Int64, cgFlags: CGEventFlags) -> Bool {
        guard let flag = HotkeyBinding.modifierFlag(forKeyCode: code) else { return true }
        let pressed = cgFlags.contains(flag)
        if pressed { currentHeld.insert(code) } else { currentHeld.remove(code) }
        if currentHeld.count > maxHeld.count { maxHeld = currentHeld }
        // All modifiers released with at least one captured → a hold shortcut.
        if currentHeld.isEmpty && !maxHeld.isEmpty {
            finalize(.modifierHold(keyCodes: maxHeld))
        }
        return true
    }

    private func finalize(_ candidate: HotkeyBinding) {
        switch HotkeyBinding.validate(candidate) {
        case .valid:
            removeMonitor()
            isRecording = false
            currentHeld = []
            maxHeld = []
            errorMessage = nil
            apply(candidate)
        case let .invalid(message):
            removeMonitor()
            isRecording = false
            currentHeld = []
            maxHeld = []
            errorMessage = message
        }
    }

    private func apply(_ candidate: HotkeyBinding) {
        binding = candidate
        candidate.save()
        onChange()
    }

    /// Rebuilds CGEventFlags from an NSEvent's flags so recording normalizes exactly the
    /// way the runtime event tap does. `.function` and `.maskSecondaryFn` share a bit, so
    /// fn is captured consistently across both paths.
    static func cgFlags(_ flags: NSEvent.ModifierFlags) -> CGEventFlags {
        var cg = CGEventFlags()
        if flags.contains(.command) { cg.insert(.maskCommand) }
        if flags.contains(.control) { cg.insert(.maskControl) }
        if flags.contains(.option) { cg.insert(.maskAlternate) }
        if flags.contains(.shift) { cg.insert(.maskShift) }
        if flags.contains(.function) { cg.insert(.maskSecondaryFn) }
        return cg
    }
}

private struct ShortcutRecorderView: View {
    @StateObject private var model: HotkeyRecorderModel

    init(onHotkeyChanged: @escaping () -> Void) {
        _model = StateObject(wrappedValue: HotkeyRecorderModel(onChange: onHotkeyChanged))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Shortcut")
                Spacer()
                Button(action: model.toggleRecording) {
                    Text(model.isRecording ? "Press keys… (Esc to cancel)" : model.binding.description)
                        .frame(minWidth: 200)
                }
                .buttonStyle(.bordered)
                .tint(model.isRecording ? Color.ttPurple500 : nil)
            }

            if let error = model.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            Text("Modifier-only shortcuts are hold-to-talk — hold to dictate, tap Space while holding to lock hands-free. Key combos are press-to-start / press-again-to-finish. Combos are captured system-wide (LocalFlow swallows them), so pick one no other app needs.")
                .font(.caption)
                .foregroundColor(.secondary)

            Button("Reset to default (Hold Right Option)", action: model.resetToDefault)
                .buttonStyle(.link)
                .font(.caption)
        }
    }
}
