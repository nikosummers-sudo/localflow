import SwiftUI

struct OnboardingView: View {
    let onRelaunch: () -> Void
    let onPermissionsChanged: () -> Void

    @State private var micGranted = false
    @State private var accessibilityGranted = false
    @State private var inputMonitoringGranted = false

    private let perms = PermissionsManager.shared
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var allGranted: Bool {
        micGranted && accessibilityGranted && inputMonitoringGranted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Welcome to LocalFlow")
                    .font(.title2).bold()
                Text("Grant these three permissions to dictate anywhere on your Mac. Everything runs locally.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            if allGranted {
                successCard
            } else {
                VStack(spacing: 14) {
                    row(
                        title: "Microphone",
                        why: "Captures your voice while you dictate.",
                        granted: micGranted,
                        request: {
                            perms.requestMicrophone { _ in refresh() }
                        },
                        openSettings: perms.openMicrophoneSettings
                    )
                    row(
                        title: "Accessibility",
                        why: "Lets LocalFlow paste the transcript into the app you're using.",
                        granted: accessibilityGranted,
                        request: perms.requestAccessibility,
                        openSettings: perms.openAccessibilitySettings
                    )
                    row(
                        title: "Input Monitoring",
                        why: "Detects your dictation shortcut being pressed, system-wide.",
                        granted: inputMonitoringGranted,
                        request: { _ = perms.requestInputMonitoring() },
                        openSettings: perms.openInputMonitoringSettings,
                        hint: "Not in the list? Click + and add LocalFlow from /Applications."
                    )
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .leading, spacing: 10) {
                Text("After granting Accessibility or Input Monitoring, macOS may require relaunching LocalFlow before the change takes effect.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button("Relaunch LocalFlow", action: onRelaunch)
            }
        }
        .padding(24)
        .frame(minWidth: 460, minHeight: 540, alignment: .topLeading)
        .onReceive(timer) { _ in refresh() }
        .onAppear { refresh() }
    }

    private var successCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundColor(.green)
                .font(.largeTitle)
            VStack(alignment: .leading, spacing: 4) {
                Text("You're all set!").font(.headline)
                Text(AppState.shared.hotkeyBinding.onboardingHint)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Text("LocalFlow starts automatically at login and lives in your menu bar (the microphone icon). You can change that in Settings.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 8)
    }

    private func row(
        title: String,
        why: String,
        granted: Bool,
        request: @escaping () -> Void,
        openSettings: @escaping () -> Void,
        hint: String? = nil
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(granted ? .green : .red)
                .font(.title2)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(why)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                if !granted {
                    HStack(spacing: 8) {
                        Button("Request", action: request)
                        Button("Open System Settings", action: openSettings)
                    }
                    .padding(.top, 2)
                    if let hint {
                        Text(hint)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            Spacer()
        }
    }

    private func refresh() {
        let micNow = perms.microphoneGranted
        // Fire when the mic newly flips to granted so instant capture can start.
        if micNow && !micGranted {
            onPermissionsChanged()
        }
        micGranted = micNow

        accessibilityGranted = perms.accessibilityGranted

        let inputNow = perms.inputMonitoringGranted
        if inputNow && !inputMonitoringGranted {
            onPermissionsChanged()
        }
        inputMonitoringGranted = inputNow
    }
}
