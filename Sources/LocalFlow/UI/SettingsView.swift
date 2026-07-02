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

    @StateObject private var vm = DictionaryViewModel()

    var body: some View {
        TabView {
            GeneralTab(
                onModelChanged: onModelChanged,
                onHotkeyChanged: onHotkeyChanged,
                onPartialsChanged: onPartialsChanged,
                onCleanupChanged: onCleanupChanged,
                onInstantCaptureChanged: onInstantCaptureChanged
            )
            .tabItem { Label("General", systemImage: "gearshape") }

            DictionaryTab(vm: vm)
                .tabItem { Label("Dictionary", systemImage: "text.book.closed") }

            AppsTab(vm: vm)
                .tabItem { Label("Apps", systemImage: "app.badge") }
        }
        .frame(width: 520, height: 640)
    }
}

// MARK: - General

private struct GeneralTab: View {
    let onModelChanged: () -> Void
    let onHotkeyChanged: () -> Void
    let onPartialsChanged: () -> Void
    let onCleanupChanged: () -> Void
    let onInstantCaptureChanged: () -> Void

    @AppStorage("modelName") private var modelName = defaultModelName
    @AppStorage("hotkeyKeyCode") private var hotkeyKeyCode = Int(HotkeyMonitor.defaultKeyCode)
    @AppStorage("restoreClipboard") private var restoreClipboard = true
    @AppStorage("instantCapture") private var instantCapture = true

    @AppStorage("cleanupEnabled") private var cleanupEnabled = true
    @AppStorage("cleanupModel") private var cleanupModel = "gemma3:4b"

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

            Section("Dictation key") {
                Picker("Hold to dictate", selection: $hotkeyKeyCode) {
                    Text("Right Option").tag(61)
                    Text("Right Command").tag(54)
                    Text("Right Control").tag(62)
                }
            }

            Section("Clipboard") {
                Toggle("Restore clipboard after pasting", isOn: $restoreClipboard)
            }

            Section("Microphone") {
                Toggle("Instant capture (keeps mic warm)", isOn: $instantCapture)
                Text("Keeps the microphone open so dictation starts instantly and never clips your first words. Audio spoken outside a dictation lives only in a rolling 2-second in-memory buffer that is continuously discarded — it is never processed, stored, or transmitted. While LocalFlow runs, macOS shows the microphone-in-use indicator. Turn this off to only open the mic while you dictate (dictation may then clip the very start).")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Voice commands") {
                Toggle("Interpret spoken commands", isOn: $voiceCommandsEnabled)
                Text("Say “new line” or “new paragraph” to insert breaks, or “scratch that” to retract your last sentence. Turn off to type those phrases literally.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("AI Cleanup") {
                Toggle("Clean up transcripts with AI (Ollama)", isOn: $cleanupEnabled)
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
        .onChange(of: hotkeyKeyCode) { _, _ in onHotkeyChanged() }
        .onChange(of: showLivePreview) { _, _ in onPartialsChanged() }
        .onChange(of: partialsModel) { _, _ in onPartialsChanged() }
        .onChange(of: cleanupEnabled) { _, _ in onCleanupChanged() }
        .onChange(of: cleanupModel) { _, _ in onCleanupChanged() }
        .onChange(of: instantCapture) { _, _ in onInstantCaptureChanged() }
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
