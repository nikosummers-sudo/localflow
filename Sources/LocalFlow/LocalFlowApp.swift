import SwiftUI

@main
struct LocalFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var appState = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            Text(appState.statusMenuText)
                .disabled(true)
            Text(appState.hotkeyBinding.menuHint)
                .disabled(true)

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

            Button("Quit LocalFlow") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            Image(systemName: appState.status.symbolName)
        }
    }
}
