import AppKit
import LocalFlowKit
import SwiftUI

/// The app's real home: the live status header plus the searchable list of every
/// dictation saved on this Mac. Rows can be re-copied, deleted, or entered into a
/// per-word "correction" mode that both fixes the saved text and teaches the
/// personal dictionary so future dictations auto-correct.
struct MainWindowView: View {
    @ObservedObject private var appState = AppState.shared

    let onOpenSettings: () -> Void
    let onOpenSetup: () -> Void

    @State private var records: [DictationRecord] = []
    @State private var search = ""
    /// At most one row is in correction mode at a time.
    @State private var correctingRecordID: UUID?
    @State private var showClearConfirm = false

    private var filtered: [DictationRecord] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return records }
        return records.filter { $0.text.lowercased().contains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            searchBar
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 400)
        .tint(Color.ttPurple500)
        .onAppear(perform: reload)
        .onChange(of: appState.historyRevision) { _, _ in reload() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .foregroundStyle(.tint)
                .font(.title3)
            Text("LocalFlow")
                .font(.headline)

            HStack(spacing: 5) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(appState.statusMenuText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.leading, 4)

            Spacer()

            if !PermissionsManager.shared.allGranted {
                Button(action: onOpenSetup) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                }
                .buttonStyle(.borderless)
                .help("Some permissions are missing — open Setup")
            }

            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var statusColor: Color {
        switch appState.status {
        case .recording, .recordingLocked: return .red
        case .transcribing, .cleaning, .pasting, .loadingModel: return .yellow
        case .idle: return .green
        case .noInputField: return .orange
        case .error: return .orange
        }
    }

    // MARK: - Search

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField("Search dictations", text: $search)
                .textFieldStyle(.plain)
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - List / empty state

    @ViewBuilder
    private var content: some View {
        if filtered.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filtered) { record in
                        HistoryRowView(
                            record: record,
                            isCorrecting: correctingRecordID == record.id,
                            onCopy: { copy(record.text) },
                            onDelete: { delete(record) },
                            onToggleCorrect: { toggleCorrect(record) },
                            onApply: { newText, learn, original, corrected in
                                applyCorrection(to: record, newText: newText, learn: learn, original: original, corrected: corrected)
                            }
                        )
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        Divider()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if search.isEmpty {
            gettingStartedPanel
        } else {
            noResultsState
        }
    }

    /// First-run guide shown when no dictations exist yet: the binding-aware
    /// gesture, hands-free (hold bindings only), and the fix-a-word learning loop.
    private var gettingStartedPanel: some View {
        let binding = appState.hotkeyBinding
        return VStack(spacing: 16) {
            Spacer()
            VStack(spacing: 6) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 34))
                    .foregroundColor(.secondary)
                Text("Getting started")
                    .font(.headline)
                    .foregroundColor(.secondary)
            }
            VStack(alignment: .leading, spacing: 12) {
                miniGuideRow(icon: "mic.fill", detail: binding.guideDictateLine)
                if binding.isHold {
                    miniGuideRow(icon: "lock.fill", detail: binding.guideHandsFreeLine)
                }
                miniGuideRow(
                    icon: "graduationcap.fill",
                    detail: "Fix a misheard word right here — hover a dictation, hit the pencil, click the word and correct it, and LocalFlow won't get it wrong again.",
                    tint: .ttOrange500
                )
            }
            .frame(maxWidth: 420)
            Text("Your dictations will be listed here — copy, fix, or delete any of them.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func miniGuideRow(icon: String, detail: String, tint: Color = .ttPurple500) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(tint)
                .font(.body)
                .frame(width: 22, alignment: .center)
            Text(detail)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var noResultsState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 34))
                .foregroundColor(.secondary)
            Text("No dictations match your search")
                .font(.headline)
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 6) {
            Text("\(records.count) dictation\(records.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundColor(.secondary)
            Text("· History is stored only on this Mac.")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Button("Clear History") { showClearConfirm = true }
                .disabled(records.isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .confirmationDialog(
            "Clear all dictation history?",
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) {
                HistoryStore.shared.clear()
                correctingRecordID = nil
                reload()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes every saved dictation from this Mac. It can't be undone.")
        }
    }

    // MARK: - Actions

    private func reload() {
        records = HistoryStore.shared.all()
        if let id = correctingRecordID, !records.contains(where: { $0.id == id }) {
            correctingRecordID = nil
        }
    }

    private func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func delete(_ record: DictationRecord) {
        if correctingRecordID == record.id { correctingRecordID = nil }
        HistoryStore.shared.delete(id: record.id)
        reload()
    }

    private func toggleCorrect(_ record: DictationRecord) {
        correctingRecordID = (correctingRecordID == record.id) ? nil : record.id
    }

    /// Persists the corrected record text and — when the user chose to teach it —
    /// adds the whole-word rule to the personal dictionary AND the corrected
    /// phrase to the vocabulary, so STT bias, cleanup, and the hard replacement
    /// all learn it. Deduplicated so repeated fixes don't pile up.
    private func applyCorrection(to record: DictationRecord, newText: String, learn: Bool, original: String, corrected: String) {
        HistoryStore.shared.updateText(id: record.id, newText: newText)

        if learn {
            var dictionary = LocalFlowConfig.shared.dictionary
            let rule = DictationHistory.makeCorrectionRule(original: original, corrected: corrected)
            if !rule.find.isEmpty,
               !dictionary.replacements.contains(where: {
                   $0.find.caseInsensitiveCompare(rule.find) == .orderedSame && $0.replace == rule.replace
               }) {
                dictionary.replacements.append(rule)
            }
            let term = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
            if !term.isEmpty,
               !dictionary.terms.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) {
                dictionary.terms.append(term)
            }
            LocalFlowConfig.shared.dictionary = dictionary
        }

        reload()
    }
}

// MARK: - Row

/// A single dictation. In normal mode it renders selectable text with a
/// hover-revealed action bar; in correction mode it renders each word as a chip
/// the user can select and rewrite via a popover.
private struct HistoryRowView: View {
    let record: DictationRecord
    let isCorrecting: Bool
    let onCopy: () -> Void
    let onDelete: () -> Void
    let onToggleCorrect: () -> Void
    /// (newText, learn, originalPhrase, correctedPhrase)
    let onApply: (String, Bool, String, String) -> Void

    @State private var hovering = false

    // Correction-mode selection state.
    @State private var anchor: Int?
    @State private var selection: ClosedRange<Int>?
    @State private var showPopover = false
    @State private var draft = ""
    @State private var confirmation: String?

    private var tokens: [HistoryToken] { DictationHistory.tokenize(record.text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            metaRow
            if isCorrecting {
                correctionBody
            } else {
                Text(record.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onChange(of: isCorrecting) { _, nowCorrecting in
            if !nowCorrecting { resetSelection() }
        }
    }

    private var metaRow: some View {
        HStack(spacing: 6) {
            Text(metadataText)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            if hovering || isCorrecting {
                actionBar
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button(action: onCopy) {
                Image(systemName: "doc.on.doc")
            }
            .help("Copy this dictation")

            Button(action: onToggleCorrect) {
                Image(systemName: "pencil")
                    .foregroundColor(isCorrecting ? Color.ttPurple500 : nil)
            }
            .help(isCorrecting ? "Done correcting" : "Fix words")

            Button(action: onDelete) {
                Image(systemName: "trash")
            }
            .help("Delete this dictation")
        }
        .buttonStyle(.borderless)
        .font(.callout)
    }

    private var metadataText: String {
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .abbreviated
        var parts = [
            relative.localizedString(for: record.date, relativeTo: Date()),
            record.date.formatted(date: .omitted, time: .shortened)
        ]
        if let app = record.appName, !app.isEmpty { parts.append(app) }
        return parts.joined(separator: " · ")
    }

    // MARK: Correction mode

    private var correctionBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            ChipFlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(tokens.indices, id: \.self) { index in
                    chip(index)
                }
            }
            .popover(isPresented: $showPopover, arrowEdge: .bottom) {
                popoverContent
            }

            Text("Click a word — shift-click another to extend — then rewrite it.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private func chip(_ index: Int) -> some View {
        let selected = selection?.contains(index) ?? false
        return Text(tokens[index].text)
            .font(.body)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(selected ? Color.ttPurple500.opacity(0.25) : Color.secondary.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(selected ? Color.ttPurple500 : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
            .onTapGesture { handleTap(index) }
    }

    private func handleTap(_ index: Int) {
        let shiftHeld = NSEvent.modifierFlags.contains(.shift)
        if shiftHeld, let a = anchor {
            selection = min(a, index)...max(a, index)
        } else if let current = selection, index == current.lowerBound - 1 {
            // Plain-click an adjacent word to grow the selection.
            selection = index...current.upperBound
        } else if let current = selection, index == current.upperBound + 1 {
            selection = current.lowerBound...index
        } else {
            anchor = index
            selection = index...index
        }
        confirmation = nil
        draft = selection.map { DictationHistory.phrase(in: record.text, selection: $0) } ?? ""
        showPopover = true
    }

    @ViewBuilder
    private var popoverContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let confirmation {
                Label(confirmation, systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Done") { finishCorrection() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Text("Correct “\(originalPhrase)”")
                    .font(.headline)
                TextField("Corrected text", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                HStack {
                    Button("Fix & auto-correct") { apply(learn: true) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                    Button("Just fix here") { apply(learn: false) }
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
        .frame(minWidth: 280)
    }

    private var originalPhrase: String {
        selection.map { DictationHistory.phrase(in: record.text, selection: $0) } ?? ""
    }

    private func apply(learn: Bool) {
        guard let sel = selection else { return }
        let original = DictationHistory.phrase(in: record.text, selection: sel)
        let corrected = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !corrected.isEmpty else { return }
        let newText = DictationHistory.applyingCorrection(to: record.text, selection: sel, corrected: corrected)

        onApply(newText, learn, original, corrected)

        if learn {
            let find = DictationHistory.strippedPhrase(original)
            confirmation = "Will auto-correct “\(find)” → “\(corrected)” from now on."
            // Clear the highlight so it doesn't point at the pre-edit range while
            // the confirmation shows, then close and exit correction mode.
            selection = nil
            anchor = nil
            Task {
                try? await Task.sleep(nanoseconds: 1_900_000_000)
                await MainActor.run { finishCorrection() }
            }
        } else {
            finishCorrection()
        }
    }

    /// Closes the popover, clears selection, and leaves correction mode so the
    /// row re-renders as selectable text with the updated wording.
    private func finishCorrection() {
        showPopover = false
        resetSelection()
        if isCorrecting { onToggleCorrect() }
    }

    private func resetSelection() {
        selection = nil
        anchor = nil
        confirmation = nil
        draft = ""
    }
}

// MARK: - Flow layout

/// Wraps its children left-to-right, breaking to a new line when the next child
/// would overflow — used for the word chips in correction mode. macOS 13+.
private struct ChipFlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let result = arrange(subviews: subviews, maxWidth: maxWidth)
        return CGSize(width: proposal.width ?? result.width, height: result.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let result = arrange(subviews: subviews, maxWidth: bounds.width)
        for (index, subview) in subviews.enumerated() {
            let origin = result.positions[index]
            subview.place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                anchor: .topLeading,
                proposal: ProposedViewSize(subview.sizeThatFits(.unspecified))
            )
        }
    }

    private func arrange(subviews: Subviews, maxWidth: CGFloat) -> (positions: [CGPoint], width: CGFloat, height: CGFloat) {
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxRowWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxRowWidth = max(maxRowWidth, x - spacing)
        }
        return (positions, maxRowWidth, y + rowHeight)
    }
}
