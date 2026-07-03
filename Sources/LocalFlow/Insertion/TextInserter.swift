import AppKit
import ApplicationServices
import CoreGraphics

/// Inserts text at the current cursor location by placing it on the pasteboard and
/// synthesizing Cmd+V, then restoring the previous pasteboard contents. Falls back to
/// leaving the text on the clipboard when Accessibility permission is missing.
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

    @discardableResult
    func insert(_ text: String, restoreClipboard: Bool, forcePaste: Bool = false) async -> Result {
        let pasteboard = NSPasteboard.general

        // When we can inspect the focus and it is positively NOT a text field,
        // don't blast Cmd+V into something that can't take it. Leave the
        // transcript on the clipboard (and do NOT restore) so it survives for a
        // manual paste. Anything ambiguous falls through to the normal paste.
        // `forcePaste` (a per-app rule) skips detection entirely — for apps
        // whose inputs hide from accessibility.
        if !forcePaste, AXIsProcessTrusted(), FocusInspector.classifyFocusedElement() == .notEditable {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            return .noInputField
        }

        let saved: PasteboardSnapshot? = restoreClipboard ? TextInserter.snapshot(pasteboard) : nil

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Without Accessibility we cannot synthesize the paste; leave text on the
        // clipboard and do not restore, so the user can paste it manually.
        guard AXIsProcessTrusted() else {
            return .leftOnClipboard
        }

        try? await Task.sleep(nanoseconds: 80_000_000)
        synthesizeCommandV()

        if let saved {
            // Restore after the paste has had time to read the pasteboard.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 600_000_000)
                TextInserter.restore(saved)
            }
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
