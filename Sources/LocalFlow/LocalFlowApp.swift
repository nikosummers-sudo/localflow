import SwiftUI

@main
struct LocalFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var appState = AppState.shared

    static let shortVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    static let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"

    var body: some Scene {
        MenuBarExtra {
            if !appState.hotkeyActive {
                Text("⚠️ Shortcut inactive — LocalFlow can't see the keyboard")
                    .disabled(true)
                Button("Fix Now (Relaunch LocalFlow)") {
                    appDelegate.relaunch()
                }
                Divider()
            }

            Text(appState.statusMenuText)
                .disabled(true)
            Text(appState.hotkeyBinding.menuHint)
                .disabled(true)

            if appState.canCancelDictation {
                Button("Cancel Dictation (Esc)") {
                    appState.cancelDictation()
                }
            }

            Divider()

            Button("Open LocalFlow") {
                appDelegate.showMainWindow()
            }

            Divider()

            Button("Copy Last Transcript") {
                appState.copyLastTranscript()
            }
            .disabled(appState.lastTranscript.isEmpty)

            Divider()

            Button("Setup & Permissions…") {
                appDelegate.showOnboarding()
            }
            Button("Settings…") {
                appDelegate.showSettings()
            }

            Divider()

            // Support affordances: an always-visible version (so "what version
            // are you on?" is answerable) and a one-click diagnostics bundle.
            Text("LocalFlow v\(Self.shortVersion) (build \(Self.buildNumber))")
                .disabled(true)
            Button("Save Diagnostics to Desktop") {
                appState.saveDiagnostics()
            }

            Divider()

            Button("Quit LocalFlow") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            Image(systemName: appState.hotkeyActive ? appState.status.symbolName : "exclamationmark.triangle")
        }
    }
}
