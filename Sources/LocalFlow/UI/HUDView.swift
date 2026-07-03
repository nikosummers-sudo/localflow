import SwiftUI

/// Observable model the HUD renders from. HUDController derives this from
/// AppState (status + partialText + audioLevel) so the transient "✓ Inserted"
/// and error beats can be sequenced without polluting the app's core state.
@MainActor
final class HUDViewModel: ObservableObject {
    enum Phase: Equatable {
        case hidden
        case listening(locked: Bool)
        case warmingUp
        case transcribing
        case cleaning
        case inserting
        case inserted
        case noInputField
        case error(String)
    }

    @Published var phase: Phase = .hidden
    @Published var partialText: String = ""
    /// Normalized 0–1 mic level driving the voice-reactive bars.
    @Published var audioLevel: Float = 0
    /// When true while listening, the pill shows a "Can't hear you" hint under the
    /// bars — set once a few seconds pass with no audible input.
    @Published var noAudioHint: Bool = false

    var isListening: Bool {
        if case .listening = phase { return true }
        return false
    }
}

/// Floating dictation HUD: a compact, dark, voice-reactive pill. No border, no
/// material (their edge highlight reads as a hairline), no rectangular panel
/// shadow. Purely presentational — every state comes from the view model, and
/// the panel ignores mouse events so it's never interactive.
struct HUDView: View {
    @ObservedObject var vm: HUDViewModel
    @AppStorage("showLivePreview") private var showLivePreview = false

    /// The wider rounded-rect preview only appears when the user opted in AND
    /// there's partial text to show while listening.
    private var showPreviewTail: Bool {
        showLivePreview && vm.isListening && !vm.partialText.isEmpty
    }

    /// The "Can't hear you" hint replaces the preview tail while listening if no
    /// audible input has arrived (it takes priority — with no audio there's no
    /// partial text to preview anyway).
    private var showNoAudioLine: Bool {
        vm.isListening && vm.noAudioHint
    }

    /// The pill widens into a rounded rect whenever a secondary line is showing.
    private var isExpanded: Bool { showNoAudioLine || showPreviewTail }

    var body: some View {
        ZStack {
            Color.clear
            if vm.phase != .hidden {
                pill
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
        }
        .frame(width: 640, height: 120)
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: vm.phase)
    }

    private var pill: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                row
            }

            if showNoAudioLine {
                // Secondary hint while the bars keep animating — the mic is being
                // read but nothing audible is coming through.
                Text("Can't hear you — is the right mic selected?")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.yellow)
                    .lineLimit(1)
                    .fixedSize()
            } else if showPreviewTail {
                // Fixed width so the pill becomes a stable wider rounded rect;
                // head-truncation keeps the freshest words visible.
                Text(tail(of: vm.partialText))
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(2)
                    .truncationMode(.head)
                    .frame(width: 320, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .foregroundStyle(.white)
        .background(pillBackground)
        .shadow(color: .black.opacity(0.32), radius: 12, y: 4)
        .fixedSize()
    }

    /// Capsule (fully rounded ends) when compact; a rounded rect once the
    /// multi-line preview is showing. Solid dark fill — never a material.
    @ViewBuilder
    private var pillBackground: some View {
        if isExpanded {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.black.opacity(0.78))
        } else {
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.78))
        }
    }

    // MARK: - Per-state row

    @ViewBuilder
    private var row: some View {
        switch vm.phase {
        case .listening(let locked):
            Image(systemName: "mic.fill")
                .font(.system(size: 13, weight: .semibold))
            VoiceBars(level: CGFloat(vm.audioLevel))
            if locked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
            }
        case .warmingUp:
            ProgressView()
                .controlSize(.small)
                .tint(.white)
            label("Warming up…")
        case .transcribing:
            ProgressView()
                .controlSize(.small)
                .tint(.white)
            label("Transcribing")
        case .cleaning:
            Image(systemName: "wand.and.stars")
                .font(.system(size: 13, weight: .semibold))
            label("Cleaning")
        case .inserting:
            ProgressView()
                .controlSize(.small)
                .tint(.white)
            label("Inserting")
        case .inserted:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.ttOrange500)
                .symbolEffect(.bounce, value: vm.phase)
            label("Inserted")
        case .noInputField:
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 13, weight: .semibold))
            label("No input field — copied")
        case .error(let message):
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.yellow)
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(2)
                .frame(width: 260, alignment: .leading)
        case .hidden:
            EmptyView()
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .fixedSize()
    }

    /// Keep the last stretch of text so layout stays cheap; head-truncation then
    /// shows the freshest words within 2 lines.
    private func tail(of text: String) -> String {
        let maxChars = 160
        guard text.count > maxChars else { return text }
        return String(text.suffix(maxChars))
    }
}

/// Five thin vertical bars whose heights track the live mic level, with a
/// springy "pop" on speech onset (level crossing a threshold after quiet).
private struct VoiceBars: View {
    var level: CGFloat

    @State private var lastLevel: CGFloat = 0
    @State private var popped = false

    private let barCount = 5
    private let barWidth: CGFloat = 3
    private let baseHeight: CGFloat = 4
    private let maxExtra: CGFloat = 16
    /// Taller in the middle, shorter at the edges — a natural spectrum shape.
    private let weights: [CGFloat] = [0.45, 0.75, 1.0, 0.75, 0.45]
    private let onsetThreshold: CGFloat = 0.22

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<barCount, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(Color.ttVoiceBars[index % Color.ttVoiceBars.count])
                    .frame(width: barWidth, height: height(for: index))
            }
        }
        .frame(height: baseHeight + maxExtra, alignment: .center)
        .scaleEffect(popped ? 1.18 : 1.0, anchor: .center)
        .animation(.spring(response: 0.18, dampingFraction: 0.55), value: level)
        .animation(.spring(response: 0.18, dampingFraction: 0.55), value: popped)
        .onChange(of: level) { _, newValue in
            if lastLevel < onsetThreshold && newValue >= onsetThreshold {
                popped = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) { popped = false }
            }
            lastLevel = newValue
        }
    }

    private func height(for index: Int) -> CGFloat {
        let weight = weights[index % weights.count]
        // A little idle life so the bars never fully flatten while listening.
        let effective = max(level, 0.06)
        return baseHeight + maxExtra * effective * weight
    }
}
