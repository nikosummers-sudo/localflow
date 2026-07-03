import AppKit
import ApplicationServices
import CoreGraphics

/// Inserts text at the current cursor location by placing it on the pasteboard and
/// synthesizing Cmd+V, then restoring the previous pasteboard contents. Falls back to
/// leaving the text on the clipboard when Accessibility permission is missing.
///
/// Main-actor isolated: the pending-restore bookkeeping is mutable per-instance
/// state, and the only caller (AppState) is already on the main actor.
@MainActor
final class TextInserter {
    enum Result {
        /// Text was pasted via synthesized Cmd+V.
        case pasted
        /// Accessibility not granted — text left on the clipboard for a manual paste.
        case leftOnClipboard
        /// The focused element is not a text field — text left on the clipboard
        /// (not restored) so the user can paste it into a real input themselves.
        case noInputField
    }

    /// A pasteboard's contents captured by raw type string, so the snapshot is Sendable
    /// and can safely cross into the delayed restore task.
    private typealias PasteboardSnapshot = [[String: Data]]

    /// The most recent clipboard string we overwrote and did NOT restore — because
    /// a fallback path left the transcript on the clipboard, or a pending restore
    /// was cancelled by a following dictation. The app layer can offer it back.
    /// Only non-empty strings that differ from the inserted transcript are recorded.
    private(set) var lastDisplacedClipboard: String?

    /// A restore scheduled after a paste, held so a subsequent insert() can cancel
    /// it before it fires (a fixed-delay restore races slow/large pastes and a
    /// rapid second dictation). Cleared once it runs.
    private var pendingRestore: DispatchWorkItem?

    /// The clipboard string the pending restore would put back, so a cancelled
    /// restore can stash it as displaced instead of silently losing it.
    private var pendingRestoreString: String?

    /// Records a clipboard string we overwrote but will not restore. Ignores empty
    /// strings and the transcript itself (re-offering what we just inserted is
    /// pointless).
    private func stashDisplaced(_ string: String?, transcript: String) {
        guard let string, !string.isEmpty, string != transcript else { return }
        lastDisplacedClipboard = string
    }

    @discardableResult
    func insert(_ text: String, restoreClipboard: Bool, forcePaste: Bool = false) async -> Result {
        let pasteboard = NSPasteboard.general

        // A restore scheduled by an earlier insert() may still be pending. Cancel
        // it so it can't fire mid-paste and clobber what we're about to insert.
        // The clipboard it would have restored is now lost to this dictation —
        // stash it as displaced instead of restoring it.
        if let pending = pendingRestore {
            pending.cancel()
            stashDisplaced(pendingRestoreString, transcript: text)
            pendingRestore = nil
            pendingRestoreString = nil
        }

        // The clipboard content this insert is about to overwrite, captured before
        // any overwrite so the no-restore paths can stash it.
        let previousClipboard = pasteboard.string(forType: .string)

        // When we can inspect the focus and it is positively NOT a text field,
        // don't blast Cmd+V into something that can't take it. Leave the
        // transcript on the clipboard (and do NOT restore) so it survives for a
        // manual paste. Anything ambiguous falls through to the normal paste.
        // `forcePaste` (a per-app rule) skips detection entirely — for apps
        // whose inputs hide from accessibility.
        if !forcePaste, AXIsProcessTrusted(), FocusInspector.classifyFocusedElement() == .notEditable {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            stashDisplaced(previousClipboard, transcript: text)
            return .noInputField
        }

        let saved: PasteboardSnapshot? = restoreClipboard ? TextInserter.snapshot(pasteboard) : nil

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Without Accessibility we cannot synthesize the paste; leave text on the
        // clipboard and do not restore, so the user can paste it manually.
        guard AXIsProcessTrusted() else {
            stashDisplaced(previousClipboard, transcript: text)
            return .leftOnClipboard
        }

        try? await Task.sleep(nanoseconds: 80_000_000)
        synthesizeCommandV()

        if let saved {
            // Scale the restore delay with text size: a large paste takes the
            // target app longer to read the pasteboard, and a fixed delay could
            // restore before it finishes. 600ms base + 1ms/char, capped at 2s.
            let delayMs = min(600 + text.count, 2000)
            pendingRestoreString = previousClipboard
            let work = DispatchWorkItem { [weak self] in
                Task { @MainActor in
                    TextInserter.restore(saved)
                    // Restore ran: the previous clipboard was put back, not
                    // displaced. Clear the pending state so a later insert()
                    // won't cancel-and-stash an already-restored clipboard.
                    self?.pendingRestore = nil
                    self?.pendingRestoreString = nil
                }
            }
            pendingRestore = work
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMs), execute: work)
        }
        return .pasted
    }

    private func synthesizeCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9 // "v"
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> PasteboardSnapshot {
        guard let items = pasteboard.pasteboardItems else { return [] }
        return items.map { item in
            var typed: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    typed[type.rawValue] = data
                }
            }
            return typed
        }
    }

    @MainActor
    private static func restore(_ snapshot: PasteboardSnapshot) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard !snapshot.isEmpty else { return }
        let items = snapshot.map { typed -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (rawType, data) in typed {
                item.setData(data, forType: NSPasteboard.PasteboardType(rawType))
            }
            return item
        }
        pasteboard.writeObjects(items)
    }
}
