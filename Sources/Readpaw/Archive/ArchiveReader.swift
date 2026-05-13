import Foundation
import AppKit

protocol ArchiveReader: AnyObject {
    func pageCount() throws -> Int
    func image(at index: Int) throws -> NSImage
    func data(at index: Int) throws -> Data
    func entryName(at index: Int) throws -> String
    func close()
}

enum ArchiveError: LocalizedError {
    case indexOutOfRange
    case noPages
    case decodeFailed
    case toolFailed(String)
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .indexOutOfRange: return "Page index out of range."
        case .noPages: return "No readable pages found in this file."
        case .decodeFailed: return "Could not decode page image."
        case .toolFailed(let m): return m
        case .unsupportedFormat: return "Unsupported file format."
        }
    }
}

enum ArchiveFactory {
    static func makeReader(for item: ComicItem) throws -> ArchiveReader {
        switch item.format {
        case .pdf:
            return try PDFArchiveReader(url: item.url)
        case .cbz, .zip, .cbr, .rar, .sevenZip:
            return try TarArchiveReader(url: item.url)
        }
    }
}

struct ImageEntry {
    let path: String
    let originalIndex: Int
}

enum ImageEntryFilter {
    static let extensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "bmp", "tif", "tiff", "heic", "heif", "avif"
    ]

    static func isImagePath(_ path: String) -> Bool {
        let lower = path.lowercased()
        // Skip Mac metadata
        if lower.contains("__macosx/") { return false }
        if lower.hasSuffix("/") { return false }
        let name = (lower as NSString).lastPathComponent
        if name.hasPrefix(".") { return false }
        guard let dot = lower.lastIndex(of: ".") else { return false }
        let ext = String(lower[lower.index(after: dot)...])
        return extensions.contains(ext)
    }

    static func naturalSort(_ entries: [String]) -> [String] {
        entries.sorted { lhs, rhs in
            lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }
}
