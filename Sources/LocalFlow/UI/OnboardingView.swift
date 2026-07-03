import SwiftUI

struct OnboardingView: View {
    let onRelaunch: () -> Void
    let onPermissionsChanged: () -> Void
    let onOpenMain: () -> Void

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
                Text(allGranted ? "You're all set" : "Welcome to LocalFlow")
                    .font(.title2).bold()
                Text(allGranted
                     ? "Here's how to dictate, correct a misheard word, and make LocalFlow yours."
                     : "Grant these three permissions to dictate anywhere on your Mac. Everything runs locally.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            if allGranted {
                gettingStartedGuide
            } else {
                permissionChecklist
                Spacer(minLength: 8)
                relaunchFooter
            }
        }
        .padding(24)
        .frame(minWidth: 460, minHeight: 600, alignment: .topLeading)
        .tint(Color.ttPurple500)
        .onReceive(timer) { _ in refresh() }
        .onAppear { refresh() }
    }

    // MARK: - Getting-started guide (shown once every permission is granted)

    private var gettingStartedGuide: some View {
        let binding = AppState.shared.hotkeyBinding
        return VStack(alignment: .leading, spacing: 14) {
            guideRow(
                icon: "mic.fill",
                title: "Dictate anywhere",
                detail: binding.guideDictateLine
            )
            if binding.isHold {
                guideRow(
                    icon: "lock.fill",
                    title: "Go hands-free",
                    detail: binding.guideHandsFreeLine
                )
            }
            guideRow(
                icon: "graduationcap.fill",
                title: "It learns your words",
                detail: "Open LocalFlow (Dock icon or menu bar → Open LocalFlow), hover a dictation, hit the pencil, click a misheard word and fix it — it won't get it wrong again.",
                tint: .ttOrange500
            )
            guideRow(
                icon: "gearshape.fill",
                title: "Make it yours",
                detail: "Settings (the gear in the main window) — change the shortcut, add vocabulary, tune the AI cleanup per app."
            )
            guideRow(
                icon: "hand.raised.fill",
                title: "Private by design",
                detail: "Everything runs on this Mac. Nothing you say ever leaves it."
            )

            Spacer(minLength: 8)

            HStack(spacing: 12) {
                Button("Open LocalFlow", action: onOpenMain)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                Button("Relaunch LocalFlow", action: onRelaunch)
            }
            Text("LocalFlow starts automatically at login and lives in your menu bar (the waveform icon).")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func guideRow(icon: String, title: String, detail: String, tint: Color = .ttPurple500) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .font(.title3)
                .frame(width: 26, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Permission checklist (shown until every permission is granted)

    private var permissionChecklist: some View {
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

    private var relaunchFooter: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("After granting Accessibility or Input Monitoring, macOS may require relaunching LocalFlow before the change takes effect.")
                .font(.caption)
                .foregroundColor(.secondary)
            Button("Relaunch LocalFlow", action: onRelaunch)
        }
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
