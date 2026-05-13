import Foundation
import AppKit
import PDFKit

final class PDFArchiveReader: ArchiveReader {
    private let document: PDFDocument
    private let renderQueue = DispatchQueue(label: "Readpaw.PDFRender", qos: .userInitiated)

    init(url: URL) throws {
        guard let doc = PDFDocument(url: url) else {
            throw ArchiveError.toolFailed("Failed to open PDF: \(url.lastPathComponent)")
        }
        self.document = doc
    }

    func pageCount() throws -> Int {
        document.pageCount
    }

    func entryName(at index: Int) throws -> String {
        "Page \(index + 1)"
    }

    func data(at index: Int) throws -> Data {
        let img = try image(at: index)
        guard let data = img.jpegData(compressionQuality: 0.92) else {
            throw ArchiveError.decodeFailed
        }
        return data
    }

    func image(at index: Int) throws -> NSImage {
        guard index >= 0, index < document.pageCount else {
            throw ArchiveError.indexOutOfRange
        }
        guard let page = document.page(at: index) else {
            throw ArchiveError.decodeFailed
        }
        let bounds = page.bounds(for: .mediaBox)
        // Render at 2x for crisp display.
        let scale: CGFloat = 2.0
        let size = NSSize(width: bounds.width * scale, height: bounds.height * scale)
        let image = NSImage(size: size)
        image.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState()
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.scaleBy(x: scale, y: scale)
            page.draw(with: .mediaBox, to: ctx)
            ctx.restoreGState()
        }
        image.unlockFocus()
        return image
    }

    func close() {}
}
