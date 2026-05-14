import SwiftUI
import AppKit

/// Sits on top of a comic / manga page when translate mode is on. Runs Vision
/// OCR on the page once, then translates each detected text region with the
/// active engine. Hovering a region pops a tooltip with the translation.
///
/// Coordinate system: the overlay is sized to `displaySize` (the same frame
/// as the underlying ZoomScrollView). OCR boxes are normalized image coords;
/// `OCRBox.frameInView` maps them into the same aspect-fit-centered area the
/// page is drawn into, so at .fitPage zoom the tooltips line up exactly with
/// the speech bubbles. Pinch-zooming inside the scroll view scrolls the
/// image but leaves the overlay anchored to the viewport — a known v1
/// compromise, callers can encourage the user back to fit-page via the
/// reader toolbar.
struct TranslateOverlayView: View {
    @ObservedObject var model: ReaderModel
    @ObservedObject var settings: TranslationSettings
    let displaySize: CGSize

    @State private var image: NSImage?
    @State private var boxes: [OCRBox] = []
    @State private var translations: [String: TranslationState] = [:]
    @State private var hoveredBoxID: String?
    @State private var pinnedBoxID: String?

    enum TranslationState: Equatable {
        case loading
        case loaded(String)
        case failed(String)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let img = image {
                // The hit-target rectangles per box.
                ForEach(Array(boxes.enumerated()), id: \.offset) { _, box in
                    let frame = box.frameInView(imageSize: img.size, displaySize: displaySize)
                    if frame.width > 2, frame.height > 2 {
                        boxHitArea(box: box, frame: frame)
                    }
                }
                // The currently-shown tooltip rendered last so it's on top
                // of all boxes.
                if let id = activeBoxID,
                   let box = boxes.first(where: { boxID($0) == id }) {
                    let frame = box.frameInView(imageSize: img.size, displaySize: displaySize)
                    tooltip(for: box, anchor: frame)
                }
            }
        }
        .frame(width: displaySize.width, height: displaySize.height, alignment: .topLeading)
        .allowsHitTesting(true)
        .task(id: model.currentPage) {
            await loadAndScan()
        }
        .onChange(of: settings.engine) {
            // If the user swapped engines mid-page, blow away any failed-
            // translation entries so a hover retries with the new engine.
            translations = translations.filter { _, v in
                if case .failed = v { return false } else { return true }
            }
        }
    }

    private var activeBoxID: String? {
        pinnedBoxID ?? hoveredBoxID
    }

    @ViewBuilder
    private func boxHitArea(box: OCRBox, frame: CGRect) -> some View {
        let id = boxID(box)
        let isActive = (id == activeBoxID)
        Rectangle()
            .strokeBorder(Color.yellow.opacity(isActive ? 0.95 : 0.50), lineWidth: isActive ? 1.6 : 1.0)
            .background(
                Rectangle().fill(Color.yellow.opacity(isActive ? 0.18 : 0.08))
            )
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
            .onHover { hovering in
                if hovering {
                    hoveredBoxID = id
                    // Lazy translate-on-first-hover for engines where a full
                    // page pass would be expensive (OpenAI).
                    if translations[box.text] == nil {
                        kickOff(box: box)
                    }
                } else if hoveredBoxID == id {
                    hoveredBoxID = nil
                }
            }
            .onTapGesture {
                pinnedBoxID = (pinnedBoxID == id) ? nil : id
                if translations[box.text] == nil { kickOff(box: box) }
            }
    }

    @ViewBuilder
    private func tooltip(for box: OCRBox, anchor: CGRect) -> some View {
        let state = translations[box.text] ?? .loading
        VStack(alignment: .leading, spacing: 4) {
            Text(box.text)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(2)
            switch state {
            case .loading:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Translating…").font(.caption).foregroundStyle(.white.opacity(0.7))
                }
            case .loaded(let translation):
                Text(translation)
                    .font(.callout)
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Color(red: 1.0, green: 0.55, blue: 0.55))
                    .lineLimit(3)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: max(200, min(360, displaySize.width * 0.45)), alignment: .leading)
        .background(.black.opacity(0.88))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.55), radius: 14, y: 6)
        .position(tooltipPosition(for: anchor))
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    private func tooltipPosition(for anchor: CGRect) -> CGPoint {
        // Default: above the bubble. If that would push us off the top,
        // fall back to below.
        let preferAbove = anchor.minY > 80
        let approxHeight: CGFloat = 70
        let y = preferAbove ? max(approxHeight / 2, anchor.minY - approxHeight / 2 - 6)
                            : min(displaySize.height - approxHeight / 2, anchor.maxY + approxHeight / 2 + 6)
        let x = min(max(anchor.midX, 120), displaySize.width - 120)
        return CGPoint(x: x, y: y)
    }

    private func boxID(_ box: OCRBox) -> String {
        // Use rect + text so two identical strings at different positions
        // can both be hovered independently.
        "\(Int(box.rect.minX * 10000))-\(Int(box.rect.minY * 10000))-\(box.text)"
    }

    // MARK: - OCR + translation

    private func loadAndScan() async {
        guard model.translateMode else { return }
        translations = [:]
        boxes = []
        image = nil

        guard let img = await model.image(at: model.currentPage) else { return }
        image = img

        let lang = settings.sourceLanguage.visionRecognitionLanguage
        let detected = await OCRService.shared.recognize(in: img, recognitionLanguage: lang)
        let cleaned = detected.filter {
            $0.text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
        }
        boxes = cleaned

        // Kick off translations in parallel for the free engines. For OpenAI
        // we wait for user hover to avoid burning their quota on the whole
        // page upfront.
        if settings.engine != .openai {
            for box in cleaned {
                if translations[box.text] == nil {
                    kickOff(box: box)
                }
            }
        }
    }

    private func kickOff(box: OCRBox) {
        let text = box.text
        translations[text] = .loading
        let sourceCode = settings.sourceLanguage == .auto ? nil : settings.sourceLanguage.rawValue
        let target = settings.targetLanguage.rawValue
        let settingsSnapshot = settings
        Task { @MainActor in
            do {
                let translation = try await Translator.translate(
                    text,
                    source: sourceCode,
                    target: target,
                    settings: settingsSnapshot
                )
                translations[text] = .loaded(translation)
            } catch {
                translations[text] = .failed(error.localizedDescription)
            }
        }
    }
}
