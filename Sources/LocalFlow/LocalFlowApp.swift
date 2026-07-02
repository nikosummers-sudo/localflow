import SwiftUI

@main
struct LocalFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var appState = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            Text(appState.status.menuText)
                .disabled(true)
            Text("Hold Right Option to dictate, or Right Option+Space to lock hands-free; tap Right Option to finish")
                .disabled(true)

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
