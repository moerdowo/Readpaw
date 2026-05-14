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
