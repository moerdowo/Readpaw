import Foundation
import AppKit
import Vision

/// One detected text region on the page. `rect` is in normalized image
/// coordinates with the origin at the *top-left* (0,0 = top-left,
/// 1,1 = bottom-right), so callers can scale it straight onto whatever
/// frame the page is being rendered at.
struct OCRBox: Hashable {
    let text: String
    let rect: CGRect            // top-left origin, normalized 0…1
    let confidence: Float
}

/// Wraps Vision's `VNRecognizeTextRequest` so the rest of the app doesn't
/// have to deal with Vision's bottom-left-origin coordinates or its
/// async/observer style. Results are returned with top-left origin.
@MainActor
final class OCRService {
    static let shared = OCRService()

    /// Cache OCR results per (image identity, recognition language) so
    /// flipping the translate toggle off and back on doesn't re-run Vision.
    /// NSCache uses NSImage identity (pointer) as the key — works because
    /// the ZoomablePageView reuses NSImage instances from the model cache.
    private let cache = NSCache<CacheKey, NSArray>()

    private final class CacheKey: NSObject {
        let imageID: ObjectIdentifier
        let language: String

        init(image: NSImage, language: String) {
            self.imageID = ObjectIdentifier(image)
            self.language = language
        }

        override var hash: Int {
            var h = Hasher()
            h.combine(imageID)
            h.combine(language)
            return h.finalize()
        }

        override func isEqual(_ object: Any?) -> Bool {
            guard let o = object as? CacheKey else { return false }
            return o.imageID == imageID && o.language == language
        }
    }

    func recognize(in image: NSImage,
                   recognitionLanguage: String?) async -> [OCRBox] {
        let langKey = recognitionLanguage ?? "auto"
        let key = CacheKey(image: image, language: langKey)
        if let cached = cache.object(forKey: key) as? [OCRBox] {
            return cached
        }

        let result = await Task.detached(priority: .userInitiated) {
            OCRService.runVision(on: image, recognitionLanguage: recognitionLanguage)
        }.value

        cache.setObject(result as NSArray, forKey: key)
        return result
    }

    /// Synchronous Vision invocation. Runs on a background task in
    /// `recognize(...)` so we don't block the main actor during OCR.
    /// Marked `nonisolated` because the class is @MainActor for the cache
    /// but this method touches no shared state of its own.
    nonisolated private static func runVision(on image: NSImage,
                                               recognitionLanguage: String?) -> [OCRBox] {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return []
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if let lang = recognitionLanguage {
            request.recognitionLanguages = [lang]
            request.automaticallyDetectsLanguage = false
        } else {
            request.automaticallyDetectsLanguage = true
        }

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        guard let observations = request.results else { return [] }

        return observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            // Vision returns rects in bottom-left-origin normalized coords;
            // flip Y so callers can use top-left origin consistently.
            let visionRect = observation.boundingBox
            let topLeftRect = CGRect(
                x: visionRect.origin.x,
                y: 1.0 - visionRect.origin.y - visionRect.height,
                width: visionRect.width,
                height: visionRect.height
            )
            return OCRBox(text: candidate.string,
                          rect: topLeftRect,
                          confidence: candidate.confidence)
        }
        // Vision returns one observation per *line* by default. For dense
        // speech bubbles that's usually right — each bubble is its own bubble.
    }
}

extension OCRBox {
    /// Convert this box's normalized rect into a CGRect inside a view of
    /// `size` pixels, optionally with image content scaled by `contentScale`
    /// (e.g. the magnification of an NSScrollView).
    func frameInView(imageSize: CGSize,
                     displaySize: CGSize) -> CGRect {
        // The image is drawn aspectFit-style into displaySize, so figure out
        // the visible image rect first and lay the normalized box inside it.
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = min(displaySize.width / imageSize.width,
                        displaySize.height / imageSize.height)
        let scaledW = imageSize.width  * scale
        let scaledH = imageSize.height * scale
        let offX = (displaySize.width  - scaledW) / 2
        let offY = (displaySize.height - scaledH) / 2
        return CGRect(
            x: offX + rect.origin.x * scaledW,
            y: offY + rect.origin.y * scaledH,
            width:  rect.width  * scaledW,
            height: rect.height * scaledH
        )
    }
}

/// A spatial cluster of OCR boxes that probably belong to the same speech
/// bubble / caption / sign. Translating a whole cluster at once gives the
/// engine the full sentence as context, instead of one line at a time.
struct OCRCluster: Hashable {
    let boxes: [OCRBox]
    let rect: CGRect           // top-left-origin, normalized 0…1 — bounding box of all members
    let text: String           // member texts joined in reading order

    func frameInView(imageSize: CGSize, displaySize: CGSize) -> CGRect {
        OCRBox(text: text, rect: rect, confidence: 1).frameInView(
            imageSize: imageSize,
            displaySize: displaySize
        )
    }
}

extension OCRService {
    /// Group line-level OCR observations into per-bubble clusters by
    /// proximity. Two boxes join the same cluster when:
    ///
    /// - they're stacked vertically with a gap of less than ~1.5× the
    ///   average box height AND their horizontal extents overlap
    ///   substantially (typical for multi-line speech bubbles where each
    ///   line is left-aligned under the previous one), or
    /// - they're on the same baseline AND separated by less than a single
    ///   space-width gap (Vision occasionally splits one line into two
    ///   observations across a panel border or wide letter spacing).
    ///
    /// The horizontal-merge rule is intentionally tight: two text blocks
    /// printed side-by-side inside the same bubble (e.g. a translated
    /// page with two stacked sentences arranged as columns) have a
    /// visible gap of at least one character-width between them. That
    /// gap exceeds the threshold below, so the columns stay as separate
    /// clusters and get translated as two distinct sentences.
    ///
    /// Inside each cluster, member boxes are sorted into reading order
    /// (top-to-bottom, then left-to-right) and joined with single spaces
    /// for the translator. The cluster's `rect` is the union of all
    /// member rects so the overlay can draw one hit-zone per bubble
    /// instead of one per line.
    nonisolated static func cluster(_ boxes: [OCRBox]) -> [OCRCluster] {
        guard !boxes.isEmpty else { return [] }

        let avgHeight = boxes.map(\.rect.height).reduce(0, +) / CGFloat(boxes.count)
        let vGapTolerance = avgHeight * 1.5
        // ~one space-width — tight enough that two distinct text columns in
        // the same bubble (separated by a character-width gap) stay split.
        let hGapTolerance = avgHeight * 0.35

        // Union-find over the box indices.
        var parent = Array(0..<boxes.count)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x {
                parent[x] = parent[parent[x]]
                x = parent[x]
            }
            return x
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }

        for i in 0..<boxes.count {
            for j in (i + 1)..<boxes.count {
                let r1 = boxes[i].rect, r2 = boxes[j].rect
                // Edge-to-edge gap on each axis (negative = overlap).
                let hGap = max(r1.minX - r2.maxX, r2.minX - r1.maxX)
                let vGap = max(r1.minY - r2.maxY, r2.minY - r1.maxY)
                // Overlap extent on the OTHER axis (positive = they share that span).
                let hOverlap = min(r1.maxX, r2.maxX) - max(r1.minX, r2.minX)
                let vOverlap = min(r1.maxY, r2.maxY) - max(r1.minY, r2.minY)
                let smallerHeight = min(r1.height, r2.height)
                let smallerWidth  = min(r1.width,  r2.width)

                // Vertical stacking: the two boxes need a real horizontal
                // overlap relative to their own widths — not just any
                // overlap, since adjacent columns might overlap by a single
                // pixel and that shouldn't merge them.
                let verticallyStacked =
                    vGap <= vGapTolerance &&
                    hOverlap > smallerWidth * 0.3

                // Horizontal "same line" merge: the two boxes must share
                // most of their vertical extent (i.e. clearly the same
                // baseline) and sit a space's width apart at most.
                let sameLineSplit =
                    hGap <= hGapTolerance &&
                    vOverlap > smallerHeight * 0.7

                if verticallyStacked || sameLineSplit {
                    union(i, j)
                }
            }
        }

        var groupedIndices: [Int: [Int]] = [:]
        for i in 0..<boxes.count {
            groupedIndices[find(i), default: []].append(i)
        }

        return groupedIndices.values.map { indices in
            let members = indices.map { boxes[$0] }
            let sorted = sortInReadingOrder(members, avgHeight: avgHeight)
            let combinedText = sorted.map(\.text)
                .joined(separator: " ")
                .replacingOccurrences(of: "\u{00A0}", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let minX = sorted.map(\.rect.minX).min() ?? 0
            let minY = sorted.map(\.rect.minY).min() ?? 0
            let maxX = sorted.map(\.rect.maxX).max() ?? 0
            let maxY = sorted.map(\.rect.maxY).max() ?? 0

            return OCRCluster(
                boxes: sorted,
                rect: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY),
                text: combinedText
            )
        }
        // Stable order so tooltips don't shuffle between renders.
        .sorted { lhs, rhs in
            if abs(lhs.rect.minY - rhs.rect.minY) > 0.01 {
                return lhs.rect.minY < rhs.rect.minY
            }
            return lhs.rect.minX < rhs.rect.minX
        }
    }

    /// Sort boxes top-to-bottom, then left-to-right. Boxes whose vertical
    /// midpoints fall within half a line height of each other are
    /// considered the same "row" for the secondary left-to-right sort.
    nonisolated private static func sortInReadingOrder(_ boxes: [OCRBox],
                                                        avgHeight: CGFloat) -> [OCRBox] {
        boxes.sorted { a, b in
            let aMid = a.rect.midY
            let bMid = b.rect.midY
            if abs(aMid - bMid) <= avgHeight * 0.5 {
                return a.rect.minX < b.rect.minX
            }
            return aMid < bMid
        }
    }
}
