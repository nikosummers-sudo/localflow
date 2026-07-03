import AppKit
import Combine
import SwiftUI

/// A borderless, non-activating panel that must NEVER become key/main — it can
/// never steal focus from the app the user is dictating into.
private final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Owns the floating HUD panel and maps AppState (status + live partial text)
/// onto the HUD's view model, sequencing the transient "✓ Inserted" and error
/// beats. All visibility changes use `orderFrontRegardless()` / `orderOut()`
/// so focus is never taken from the frontmost app.
@MainActor
final class HUDController {
    private let appState: AppState
    private let vm = HUDViewModel()

    private var panel: HUDPanel?
    private var cancellables = Set<AnyCancellable>()

    private var previousStatus: AppState.Status = .idle
    private var hideTask: Task<Void, Never>?

    // Transparent container; the compact pill sizes itself and floats centered.
    // Generous enough to fit the widest state (live-preview tail, error text).
    private let width: CGFloat = 640
    private let height: CGFloat = 120
    private let bottomInset: CGFloat = 140

    init(appState: AppState) {
        self.appState = appState

        appState.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] status in self?.handle(status: status) }
            .store(in: &cancellables)

        appState.$partialText
            .receive(on: RunLoop.main)
            .sink { [weak self] text in self?.handle(partialText: text) }
            .store(in: &cancellables)

        appState.$audioLevel
            .receive(on: RunLoop.main)
            .sink { [weak self] level in self?.vm.audioLevel = level }
            .store(in: &cancellables)

        appState.$showNoAudioHint
            .receive(on: RunLoop.main)
            .sink { [weak self] hint in self?.vm.noAudioHint = hint }
            .store(in: &cancellables)
    }

    // MARK: - Status handling

    private func handle(status: AppState.Status) {
        let previous = previousStatus
        previousStatus = status
        hideTask?.cancel()
        hideTask = nil

        switch status {
        case .recording:
            vm.partialText = appState.partialText
            vm.phase = .listening(locked: false)
            show()

        case .recordingLocked:
            vm.partialText = appState.partialText
            vm.phase = .listening(locked: true)
            show()

        case .transcribing:
            vm.phase = .transcribing
            show()

        case .cleaning:
            vm.phase = .cleaning
            show()

        case .pasting:
            vm.phase = .inserting
            show()

        case .idle:
            // A completed insertion (…-> .pasting -> .idle) earns a brief ✓ beat.
            // Any other route to idle (short recording, empty transcript, launch)
            // just hides.
            if previous == .pasting {
                vm.phase = .inserted
                show()
                scheduleHide(after: 0.8)
            } else {
                hideImmediately()
            }

        case .noInputField:
            vm.phase = .noInputField
            show()
            scheduleHide(after: 4.0)

        case .loadingModel:
            // Model loading isn't a dictation event — keep the HUD out of the way.
            hideImmediately()

        case .error(let message):
            vm.phase = .error(message)
            show()
            scheduleHide(after: 1.8)
        }
    }

    private func handle(partialText text: String) {
        switch vm.phase {
        case .listening(let locked):
            vm.partialText = text
            // Re-affirm phase so the view refreshes even if locked flag unchanged.
            vm.phase = .listening(locked: locked)
        default:
            break
        }
    }

    // MARK: - Visibility

    private func scheduleHide(after seconds: Double) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.hideImmediately()
        }
    }

    private func hideImmediately() {
        vm.phase = .hidden
        vm.partialText = ""
        panel?.orderOut(nil)
    }

    private func show() {
        let panel = ensurePanel()
        position(panel)
        // orderFrontRegardless (never makeKey*) so the focused app keeps focus.
        panel.orderFrontRegardless()
    }

    private func ensurePanel() -> HUDPanel {
        if let panel { return panel }

        let panel = HUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // No panel shadow: a rectangular shadow behind a clear panel is exactly
        // the "thin line" artifact we're removing. The pill carries its own
        // shape-following shadow instead.
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: HUDView(vm: vm))

        self.panel = panel
        return panel
    }

    private func position(_ panel: HUDPanel) {
        let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = screen.midX - width / 2
        let y = screen.minY + bottomInset
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }
}
