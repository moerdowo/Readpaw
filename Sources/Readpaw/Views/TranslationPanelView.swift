import SwiftUI

/// Side panel that lists every line VisionKit's `ImageAnalyzer` (Live
/// Text) found on the current page plus its translation. Appears in
/// translate mode for pages where Vision's text recogniser fails — i.e.
/// stylised manga fonts where the on-image hover tooltips can't render
/// per-bubble boxes because Live Text doesn't expose them.
///
/// The panel is the only translation surface available for those pages;
/// the per-bubble overlay shown on top of the image continues to work
/// untouched whenever Vision can read the text.
struct TranslationPanelView: View {
    @ObservedObject var model: ReaderModel
    @ObservedObject var settings: TranslationSettings
    /// Translations indexed by original line text — same shape used by
    /// the on-image overlay, but here the lifecycle is tied to
    /// `model.pageTranscriptLines` instead of the OCR cluster set.
    @State private var translations: [String: TranslationState] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if model.pageTranscriptLines.isEmpty {
                empty
            } else {
                content
            }
        }
        .frame(minWidth: 260, idealWidth: 300, maxWidth: 360,
                minHeight: 200, maxHeight: .infinity)
        .background(Material.regular)
        .task(id: TranscriptTaskKey(page: model.currentPage,
                                      lineCount: model.pageTranscriptLines.count,
                                      engine: settings.engine,
                                      source: settings.sourceLanguage,
                                      target: settings.targetLanguage)) {
            translate(model.pageTranscriptLines)
        }
        .onChange(of: settings.engine) { _, _ in
            // Engine swap: drop failed translations so they retry under
            // the new engine; keep successful ones — the text is the
            // same regardless of which engine produced the translation.
            translations = translations.filter { _, v in
                if case .failed = v { return false } else { return true }
            }
            translate(model.pageTranscriptLines)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "character.bubble.fill").foregroundStyle(.tint)
            Text("Page Translation").font(.headline)
            Spacer()
            Button {
                model.translationPanelVisible = false
            } label: {
                Image(systemName: "xmark")
                    .imageScale(.small)
            }
            .buttonStyle(.borderless)
            .help("Hide panel")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "text.viewfinder")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("No text detected on this page.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Turn translate mode off to dismiss.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(Array(model.pageTranscriptLines.enumerated()), id: \.offset) { _, line in
                    let state = translations[line] ?? .loading
                    lineCard(original: line, state: state)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    @ViewBuilder
    private func lineCard(original: String, state: TranslationState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(original)
                .font(.callout)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            switch state {
            case .loading:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Translating…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .loaded(let translation):
                Text(translation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Color(red: 0.85, green: 0.35, blue: 0.35))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.opacity(0.6))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    private func translate(_ lines: [String]) {
        for line in lines where translations[line] == nil {
            kickOff(line: line)
        }
    }

    private func kickOff(line: String) {
        translations[line] = .loading
        let sourceCode = settings.sourceLanguage == .auto ? nil : settings.sourceLanguage.rawValue
        let target = settings.targetLanguage.rawValue
        let settingsSnapshot = settings
        Task { @MainActor in
            do {
                let translation = try await Translator.translate(
                    line,
                    source: sourceCode,
                    target: target,
                    settings: settingsSnapshot
                )
                translations[line] = .loaded(translation)
            } catch {
                translations[line] = .failed(error.localizedDescription)
            }
        }
    }

    /// Identity tuple for `.task(id:)`. Re-runs translation kick-off
    /// when any of the things that invalidate the displayed translations
    /// changes — switching pages, engines, languages.
    private struct TranscriptTaskKey: Equatable {
        let page: Int
        let lineCount: Int
        let engine: TranslationEngineKind
        let source: SupportedLanguage
        let target: SupportedLanguage
    }
}
