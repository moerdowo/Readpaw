import Foundation

enum ComicFormat: String, Codable, CaseIterable {
    case cbz
    case cbr
    case zip
    case rar
    case sevenZip
    case pdf
    case epub
    case mobi
    case azw
    case azw3
    case fb2
    case txt
    case html

    static func from(url: URL) -> ComicFormat? {
        switch url.pathExtension.lowercased() {
        case "cbz": return .cbz
        case "cbr": return .cbr
        case "zip": return .zip
        case "rar": return .rar
        case "7z": return .sevenZip
        case "pdf": return .pdf
        case "epub": return .epub
        case "mobi", "prc": return .mobi
        case "azw": return .azw
        case "azw3", "kf8": return .azw3
        case "fb2": return .fb2
        case "txt": return .txt
        case "html", "htm", "xhtml": return .html
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
        case .epub: return "EPUB"
        case .mobi: return "MOBI"
        case .azw: return "AZW"
        case .azw3: return "AZW3"
        case .fb2: return "FB2"
        case .txt: return "TXT"
        case .html: return "HTML"
        }
    }

    var isEbook: Bool {
        switch self {
        case .epub, .mobi, .azw, .azw3, .fb2, .txt, .html: return true
        default: return false
        }
    }

    var isImageBased: Bool { !isEbook }
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

    // Per-book reading preferences. Optional so old library.json files
    // without these keys still decode cleanly — Swift's synthesized Codable
    // uses decodeIfPresent for optional fields.
    var lastDirection: ReadingDirection?
    var lastZoomMode: ZoomMode?
    var lastTextZoom: Double?

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
        self.lastDirection = nil
        self.lastZoomMode = nil
        self.lastTextZoom = nil
    }
}
