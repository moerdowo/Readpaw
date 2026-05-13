import Foundation
import AppKit
import Combine

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var items: [ComicItem] = []
    @Published private(set) var isScanning: Bool = false
    @Published private(set) var scanProgress: String = ""
    @Published var rootFolder: URL? {
        didSet { persistRootFolder() }
    }

    private let supportDirectory: URL
    private let libraryFile: URL
    private let thumbnailsDirectory: URL
    private let defaultsKey = "Readpaw.rootFolderBookmark"

    init() {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory,
                                 in: .userDomainMask,
                                 appropriateFor: nil,
                                 create: true)) ?? fm.temporaryDirectory
        let support = base.appendingPathComponent("Readpaw", isDirectory: true)
        try? fm.createDirectory(at: support, withIntermediateDirectories: true)
        let thumbs = support.appendingPathComponent("Thumbnails", isDirectory: true)
        try? fm.createDirectory(at: thumbs, withIntermediateDirectories: true)
        self.supportDirectory = support
        self.thumbnailsDirectory = thumbs
        self.libraryFile = support.appendingPathComponent("library.json")

        loadLibrary()
        restoreRootFolder()
    }

    func thumbnailURL(for item: ComicItem) -> URL? {
        guard let name = item.thumbnailFileName else { return nil }
        return thumbnailsDirectory.appendingPathComponent(name)
    }

    func thumbnailImage(for item: ComicItem) -> NSImage? {
        guard let url = thumbnailURL(for: item),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return NSImage(contentsOf: url)
    }

    func item(withID id: ComicItem.ID) -> ComicItem? {
        items.first(where: { $0.id == id })
    }

    func updateProgress(itemID: ComicItem.ID, page: Int, pageCount: Int?) {
        guard let idx = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[idx].lastReadPage = page
        items[idx].lastOpened = Date()
        if let pc = pageCount { items[idx].pageCount = pc }
        saveLibrary()
    }

    // MARK: - Folder selection

    func promptForFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Your Comics Folder"
        panel.message = "Select the folder containing your comics and manga. Subfolders will be scanned too."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            self.rootFolder = url
            rescan()
        }
    }

    func rescan() {
        guard let root = rootFolder else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.scanFolder(root)
        }
    }

    // MARK: - Scanning

    private func scanFolder(_ root: URL) async {
        await MainActor.run {
            self.isScanning = true
            self.scanProgress = "Scanning…"
        }
        let foundURLs = enumerateComicFiles(root: root)
        let existingItems = await MainActor.run { self.items }
        var existingByPath: [String: ComicItem] = [:]
        for item in existingItems { existingByPath[item.url.path] = item }

        var nextItems: [ComicItem] = []
        for url in foundURLs {
            if let existing = existingByPath[url.path] {
                nextItems.append(existing)
            } else if let format = ComicFormat.from(url: url) {
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
                let new = ComicItem(url: url, format: format, fileSize: size)
                nextItems.append(new)
            }
        }
        nextItems.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

        await MainActor.run {
            self.items = nextItems
            self.scanProgress = "Generating covers…"
            self.saveLibrary()
        }

        await generateMissingThumbnails()

        await MainActor.run {
            self.isScanning = false
            self.scanProgress = ""
        }
    }

    private func enumerateComicFiles(root: URL) -> [URL] {
        let fm = FileManager.default
        let exts: Set<String> = ["cbz", "cbr", "zip", "rar", "7z", "pdf"]
        guard let enumerator = fm.enumerator(at: root,
                                             includingPropertiesForKeys: [.isRegularFileKey],
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return []
        }
        var out: [URL] = []
        for case let u as URL in enumerator {
            if exts.contains(u.pathExtension.lowercased()) {
                out.append(u)
            }
        }
        return out
    }

    private func generateMissingThumbnails() async {
        let snapshot = await MainActor.run { self.items }
        for (idx, item) in snapshot.enumerated() {
            if item.thumbnailFileName != nil,
               let url = thumbnailURL(for: item),
               FileManager.default.fileExists(atPath: url.path) {
                continue
            }
            await MainActor.run {
                self.scanProgress = "Cover \(idx + 1) of \(snapshot.count)…"
            }
            await generateThumbnail(for: item)
        }
    }

    private func generateThumbnail(for item: ComicItem) async {
        guard let reader = try? ArchiveFactory.makeReader(for: item) else { return }
        defer { reader.close() }
        guard let cover = (try? reader.coverImage()) ?? nil else { return }
        let thumb = cover.resized(maxDimension: 600)
        guard let data = thumb.jpegData(compressionQuality: 0.82) else { return }
        let filename = "\(item.id.uuidString).jpg"
        let url = thumbnailsDirectory.appendingPathComponent(filename)
        do {
            try data.write(to: url, options: .atomic)
            await MainActor.run {
                if let idx = self.items.firstIndex(where: { $0.id == item.id }) {
                    self.items[idx].thumbnailFileName = filename
                    if self.items[idx].pageCount == nil {
                        self.items[idx].pageCount = (try? reader.pageCount()) ?? nil
                    }
                    self.saveLibrary()
                }
            }
        } catch {
            // ignore
        }
    }

    // MARK: - Persistence

    private struct Persisted: Codable {
        var items: [ComicItem]
    }

    private func loadLibrary() {
        guard let data = try? Data(contentsOf: libraryFile),
              let decoded = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        self.items = decoded.items
    }

    fileprivate func saveLibrary() {
        let p = Persisted(items: items)
        guard let data = try? JSONEncoder().encode(p) else { return }
        try? data.write(to: libraryFile, options: .atomic)
    }

    private func persistRootFolder() {
        guard let url = rootFolder else {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
            return
        }
        if let bookmark = try? url.bookmarkData(options: [.withSecurityScope],
                                                includingResourceValuesForKeys: nil,
                                                relativeTo: nil) {
            UserDefaults.standard.set(bookmark, forKey: defaultsKey)
        } else if let bookmark = try? url.bookmarkData() {
            UserDefaults.standard.set(bookmark, forKey: defaultsKey)
        }
    }

    private func restoreRootFolder() {
        guard let bookmark = UserDefaults.standard.data(forKey: defaultsKey) else { return }
        var stale = false
        if let url = try? URL(resolvingBookmarkData: bookmark,
                              options: [.withSecurityScope],
                              relativeTo: nil,
                              bookmarkDataIsStale: &stale) {
            _ = url.startAccessingSecurityScopedResource()
            self.rootFolder = url
        } else if let url = try? URL(resolvingBookmarkData: bookmark,
                                      options: [],
                                      relativeTo: nil,
                                      bookmarkDataIsStale: &stale) {
            self.rootFolder = url
        }
    }
}
