import Foundation
import AppKit
import Vision

/// CLI diagnostic for the translate-mode OCR pipeline. Invoked via
/// `swift run Readpaw --ocr-test <imagePath>`. Loads the image, runs
/// Vision OCR on both the upright and 90°-CCW-rotated copies with each
/// CJK language hint, and prints the observations. Used to confirm
/// whether the rotated pass is actually doing its job on a real page
/// before pinning down a translate-mode regression in the UI layer.
enum OCRDiagnostic {
    static func run(imagePath: String) {
        let url = URL(fileURLWithPath: (imagePath as NSString).expandingTildeInPath)
        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            print("Couldn't load CGImage from \(url.path)")
            return
        }
        print("Loaded: \(cgImage.width)×\(cgImage.height) (colorSpace: \(cgImage.colorSpace?.name as? String ?? "nil"))")

        let langs: [(label: String, value: String?)] = [
            ("auto",    nil),
            ("ja-JP",   "ja-JP"),
            ("zh-Hans", "zh-Hans"),
            ("zh-Hant", "zh-Hant"),
        ]

        for (label, lang) in langs {
            print("\n=== \(label) — upright ===")
            let upright = runVision(on: cgImage, lang: lang)
            dump(upright)

            print("\n=== \(label) — rotated 90° CCW ===")
            guard let rotated = rotated90CCW(cgImage) else {
                print("  (rotation produced nil — context init failed)")
                continue
            }
            print("  rotated size: \(rotated.width)×\(rotated.height)")
            let rotatedResults = runVision(on: rotated, lang: lang)
            dump(rotatedResults)
        }
    }

    private static func dump(_ boxes: [(text: String, rect: CGRect, confidence: Float)]) {
        print("  \(boxes.count) observations")
        for b in boxes.prefix(40) {
            let r = b.rect
            let coords = String(format: "[%.3f, %.3f  %.3fx%.3f]",
                                r.minX, r.minY, r.width, r.height)
            let conf = String(format: "%.2f", b.confidence)
            print("  \(coords) (\(conf)): \(b.text)")
        }
        if boxes.count > 40 { print("  …") }
    }

    private static func runVision(on cgImage: CGImage,
                                   lang: String?) -> [(text: String, rect: CGRect, confidence: Float)] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.revision = VNRecognizeTextRequest.currentRevision
        if let lang {
            request.recognitionLanguages = [lang, "en-US"]
            request.automaticallyDetectsLanguage = false
        } else {
            request.recognitionLanguages = ["ja-JP", "zh-Hans", "zh-Hant", "ko-KR", "en-US"]
            request.automaticallyDetectsLanguage = false
        }
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do { try handler.perform([request]) } catch {
            print("  perform failed: \(error)")
            return []
        }
        guard let observations = request.results else { return [] }
        return observations.compactMap { obs in
            guard let cand = obs.topCandidates(1).first else { return nil }
            let v = obs.boundingBox
            // Vision returns bottom-left-origin; flip to top-left.
            let r = CGRect(x: v.origin.x,
                            y: 1.0 - v.origin.y - v.height,
                            width: v.width,
                            height: v.height)
            return (cand.string, r, cand.confidence)
        }
    }

    private static func rotated90CCW(_ cgImage: CGImage) -> CGImage? {
        let w = cgImage.width
        let h = cgImage.height
        let cs = CGColorSpaceCreateDeviceRGB()
        let info: UInt32 = CGImageAlphaInfo.premultipliedLast.rawValue
        if let ctx = CGContext(data: nil,
                                width: h, height: w,
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: cs, bitmapInfo: info) {
            ctx.translateBy(x: CGFloat(h), y: 0)
            ctx.rotate(by: .pi / 2)
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            return ctx.makeImage()
        }
        return nil
    }
}
