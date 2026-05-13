import Foundation

enum ComicFormat: String, Codable, CaseIterable {
    case cbz
    case cbr
    case zip
    case rar
    case sevenZip
    case pdf

    static func from(url: URL) -> ComicFormat? {
        switch url.pathExtension.lowercased() {
        case "cbz": return .cbz
        case "cbr": return .cbr
        case "zip": return .zip
        case "rar": return .rar
        case "7z": return .sevenZip
        case "pdf": return .pdf
        default: return nil
        }
    }

    var displayName: String {
        switch self {
        case .cbz: return "CBZ"
        case .cbr: return "CBR"
        case .zip: return "ZIP"
        case .rar: return "RAR"
        case .sevenZip: return "7Z"
        case .pdf: return "PDF"
        }
    }

    var isArchive: Bool { self != .pdf }
}

struct ComicItem: Identifiable, Codable, Hashable {
    let id: UUID
    var url: URL
    var title: String
    var format: ComicFormat
    var fileSize: Int64
    var dateAdded: Date
    var lastOpened: Date?
    var lastReadPage: Int
    var pageCount: Int?
    var thumbnailFileName: String?

    init(url: URL, format: ComicFormat, fileSize: Int64) {
        self.id = UUID()
        self.url = url
        self.title = url.deletingPathExtension().lastPathComponent
        self.format = format
        self.fileSize = fileSize
        self.dateAdded = Date()
        self.lastOpened = nil
        self.lastReadPage = 0
        self.pageCount = nil
        self.thumbnailFileName = nil
    }
}
