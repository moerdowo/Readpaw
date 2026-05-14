import SwiftUI
import AppKit
import Combine

enum ReadingDirection: String, CaseIterable, Identifiable, Codable {
    case leftToRight = "Left to Right"
    case rightToLeft = "Right to Left"
    case vertical = "Vertical (Webtoon)"
    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .leftToRight: return "arrow.right"
        case .rightToLeft: return "arrow.left"
        case .vertical: return "arrow.down"
        }
    }
}

enum ZoomMode: Equatable, Hashable, Codable {
    case fitWidth
    case fitHeight
    case fitPage
    case actual
    case custom(CGFloat)

    var label: String {
        switch self {
        case .fitWidth: return "Fit Width"
        case .fitHeight: return "Fit Height"
        case .fitPage: return "Fit Page"
        case .actual: return "Actual Size"
        case .custom(let v): return "\(Int(v * 100))%"
        }
    }

    // Manual Codable so the .custom(CGFloat) associated value can round-trip
    // through library.json. CGFloat isn't Codable on every platform; encoding
    // as Double avoids the issue.
    private enum CodingKeys: String, CodingKey { case kind, value }
    private enum Kind: String, Codable {
        case fitWidth, fitHeight, fitPage, actual, custom
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .fitWidth:  try c.encode(Kind.fitWidth,  forKey: .kind)
        case .fitHeight: try c.encode(Kind.fitHeight, forKey: .kind)
        case .fitPage:   try c.encode(Kind.fitPage,   forKey: .kind)
        case .actual:    try c.encode(Kind.actual,    forKey: .kind)
        case .custom(let v):
            try c.encode(Kind.custom, forKey: .kind)
            try c.encode(Double(v),   forKey: .value)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .fitWidth:  self = .fitWidth
        case .fitHeight: self = .fitHeight
        case .fitPage:   self = .fitPage
        case .actual:    self = .actual
        case .custom:
            let v = try c.decode(Double.self, forKey: .value)
            self = .custom(CGFloat(v))
        }
    }
}

@MainActor
final class ReaderModel: ObservableObject {
    let itemID: ComicItem.ID
    let library: LibraryStore

    @Published var pageCount: Int = 0
    @Published var currentPage: Int = 0
    @Published var direction: ReadingDirection = .leftToRight {
        didSet { if direction != oldValue, !isRestoring { saveSubject.send(()) } }
    }
    @Published var zoomMode: ZoomMode = .fitPage {
        didSet { if zoomMode != oldValue, !isRestoring { saveSubject.send(()) } }
    }
    @Published var backgroundDark: Bool = true
    @Published var loadError: String?
    @Published var isLoading: Bool = true
    @Published var loadingStatus: String = "Opening book…"
    @Published var isTextBook: Bool = false
    @Published var textZoom: CGFloat = 1.0 {
        didSet { if textZoom != oldValue, !isRestoring { saveSubject.send(()) } }
    }
    /// When on, image-based readers (Paged + future Vertical) overlay
    /// OCR'd speech bubbles with on-hover translations. Off by default
    /// because OCR has a one-shot cost per page and translation hits the
    /// network.
    @Published var translateMode: Bool = false {
        didSet {
            // Translate mode and two-page spread don't mix — the OCR
            // overlay is laid out against a single page. Turning one on
            // turns the other off.
            if translateMode, twoPageSpread { twoPageSpread = false }
        }
    }

    /// Two-page spread: render the current page and its neighbour as a
    /// single composed image so the reader shows a book-like spread.
    /// Image-based books only. Persisted per book.
    @Published var twoPageSpread: Bool = false {
        didSet {
            guard twoPageSpread != oldValue else { return }
            if twoPageSpread, translateMode { translateMode = false }
            if twoPageSpread {
                // Snap to an even index so spreads pair up consistently
                // ([0,1], [2,3], …).
                currentPage = currentPage - (currentPage % 2)
            }
            if !isRestoring { saveSubject.send(()) }
        }
    }

    /// Page indices (0-based) the user has bookmarked in this book.
    /// Mirrors `ComicItem.bookmarks`; kept as a Set here for cheap
    /// membership tests and as `@Published` so the toolbar updates live.
    @Published var bookmarkedPages: Set<Int> = []

    /// Live Text fallback content. Vision's text recogniser fails outright
    /// on stylised manga fonts (verified for Japanese and Chinese — zero
    /// observations across every revision and language hint), so when
    /// translate mode is on for a CJK source language we additionally run
    /// VisionKit's `ImageAnalyzer` ("Live Text") which reads stylised
    /// pages reliably. Live Text only gives a flat transcript with no
    /// per-line bounding boxes, so we render the result in a side panel
    /// instead of the on-image hover overlay.
    @Published var pageTranscriptLines: [String] = []
    /// True iff the side translation panel should be visible. The
    /// translate toggle drives this, plus a toolbar sidebar button so the
    /// user can hide it without leaving translate mode.
    @Published var translationPanelVisible: Bool = false

    /// True while load() is restoring values from the saved item — used to
    /// suppress the didSet observers below so we don't trigger a save during
    /// startup that just re-writes the same values back.
    private var isRestoring: Bool = false

    private var reader: ContentReader?
    private var prefetchTasks: [Int: Task<NSImage?, Never>] = [:]
    private var pageCache = NSCache<NSNumber, NSImage>()
    private var contentCache: [Int: PageContent] = [:]
    /// Low-resolution per-page thumbnails for the page-grid navigator.
    /// Separate from `pageCache` (which holds full-res decodes, limit 6)
    /// so scrolling the grid doesn't evict the pages being read.
    private let pageThumbCache = NSCache<NSNumber, NSImage>()
    private var saveDebouncer: AnyCancellable?
    private let saveSubject = PassthroughSubject<Void, Never>()

    init(itemID: ComicItem.ID, library: LibraryStore) {
        self.itemID = itemID
        self.library = library
        pageCache.countLimit = 6
        pageThumbCache.countLimit = 400

        saveDebouncer = saveSubject
            .debounce(for: .milliseconds(400), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.persistProgress() }
    }

    func load() {
        guard let item = library.item(withID: itemID) else {
            self.loadError = "Book not found."
            self.isLoading = false
            return
        }
        let isText = item.format.isEbook

        // Restore saved per-book reading prefs first, behind the
        // `isRestoring` flag so the didSet observers don't try to persist
        // them back out as if the user had just changed them.
        isRestoring = true
        self.isTextBook = isText
        self.bookmarkedPages = Set(item.bookmarks ?? [])
        if isText {
            self.direction = item.lastDirection ?? .vertical
            self.zoomMode  = item.lastZoomMode  ?? .fitWidth
            if let savedTextZoom = item.lastTextZoom {
                self.textZoom = CGFloat(savedTextZoom)
            }
        } else {
            if let savedDirection = item.lastDirection {
                self.direction = savedDirection
            }
            // Image books (comics / manga / PDF) always open at Fit Page,
            // regardless of whatever zoom the user happened to leave the
            // book on last session. Pinch-zoom and toolbar zoom still work
            // during reading — they just don't follow the book into its
            // next open. This matches what most dedicated comic readers
            // do and avoids accidentally landing on a 300%-pinched view
            // a week later with no memory of why.
            self.zoomMode = .fitPage
            self.twoPageSpread = item.lastTwoPage ?? false
        }
        isRestoring = false

        self.isLoading = true
        self.loadingStatus = "Opening book…"
        let format = item.format
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                // 1. Open the archive / parse the table of contents.
                let r = try ArchiveFactory.makeReader(for: item)
                let count = try r.pageCount()
                let last = item.lastReadPage
                var initialPage = max(0, min(last, max(0, count - 1)))
                // Spread mode pairs pages from even indices — snap the
                // restored page so the saved spread re-opens aligned.
                if (item.lastTwoPage ?? false), !format.isEbook {
                    initialPage -= initialPage % 2
                }

                await MainActor.run {
                    self.loadingStatus = "Decoding page \(initialPage + 1)…"
                }

                // 2. For image-based books, decode the first page *here* inside
                //    the same detached task. This means the reader UI never
                //    appears with an empty page — by the time `isLoading` flips
                //    to false the visible page is already in `pageCache`, so
                //    ZoomablePageView.task picks it up synchronously on first
                //    paint instead of showing a second spinner.
                var firstPageImage: NSImage?
                if !format.isEbook {
                    if let content = try? r.content(at: initialPage),
                       case .image(let img) = content {
                        firstPageImage = img
                    }
                }

                await MainActor.run {
                    self.reader = r
                    self.pageCount = count
                    self.currentPage = initialPage
                    if let img = firstPageImage {
                        self.pageCache.setObject(img, forKey: NSNumber(value: initialPage))
                    }
                    self.isTextBook = format.isEbook
                    self.isLoading = false
                }

                // 3. Warm the neighbours in the background — outside the
                //    perceived load critical path.
                if !format.isEbook {
                    await self.prefetchAround(initialPage)
                }
            } catch {
                await MainActor.run {
                    self.loadError = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }

    func image(at index: Int) async -> NSImage? {
        if index < 0 || index >= pageCount { return nil }
        if let cached = pageCache.object(forKey: NSNumber(value: index)) {
            return cached
        }
        if let inFlight = prefetchTasks[index] {
            return await inFlight.value
        }
        let task = makeDecodeTask(index: index)
        prefetchTasks[index] = task
        let img = await task.value
        prefetchTasks.removeValue(forKey: index)
        return img
    }

    func contentSync(at index: Int) -> PageContent? {
        if let cached = contentCache[index] { return cached }
        guard let reader, index >= 0, index < pageCount else { return nil }
        do {
            let c = try reader.content(at: index)
            contentCache[index] = c
            return c
        } catch {
            return nil
        }
    }

    private func makeDecodeTask(index: Int) -> Task<NSImage?, Never> {
        return Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return nil }
            guard let reader = await self.reader else { return nil }
            do {
                let content = try reader.content(at: index)
                guard case .image(let img) = content else { return nil }
                await MainActor.run {
                    self.pageCache.setObject(img, forKey: NSNumber(value: index))
                }
                return img
            } catch {
                return nil
            }
        }
    }

    /// Decode neighbouring pages in parallel so flipping forward is instant.
    /// The current index gets requested first (it'll already be in-flight from
    /// the visible view, but this is harmless thanks to the prefetchTasks dedupe
    /// in image(at:)).
    func prefetchAround(_ index: Int) async {
        guard !isTextBook else { return }
        let radius = 2
        await withTaskGroup(of: Void.self) { group in
            for offset in -radius...radius {
                let i = index + offset
                if i >= 0 && i < pageCount {
                    group.addTask { [weak self] in
                        _ = await self?.image(at: i)
                    }
                }
            }
        }
    }

    /// How many pages a single next/prev step covers. Two in spread
    /// mode for image books, one otherwise.
    var pageStride: Int { (twoPageSpread && !isTextBook) ? 2 : 1 }

    func goNext() { setPage(currentPage + pageStride) }
    func goPrev() { setPage(currentPage - pageStride) }

    // MARK: - Bookmarks

    func isBookmarked(_ page: Int) -> Bool { bookmarkedPages.contains(page) }

    var isCurrentPageBookmarked: Bool { bookmarkedPages.contains(currentPage) }

    /// Toggle the bookmark for a page; persists to the library item.
    func toggleBookmark(at page: Int) {
        let nowOn = library.toggleBookmark(itemID: itemID, page: page)
        if nowOn { bookmarkedPages.insert(page) } else { bookmarkedPages.remove(page) }
    }

    func toggleBookmarkCurrentPage() { toggleBookmark(at: currentPage) }

    // MARK: - Spread / display image

    /// The image to render for `index` — a composed two-page spread when
    /// spread mode is on, otherwise the single decoded page. Both the
    /// paged reader and (when applicable) the translate overlay go
    /// through this so they always agree on what's on screen.
    func displayImage(at index: Int) async -> NSImage? {
        if twoPageSpread && !isTextBook {
            return await spreadImage(leftIndex: index)
        }
        return await image(at: index)
    }

    /// Compose pages `leftIndex` and `leftIndex + 1` side-by-side into a
    /// single image. In right-to-left mode the page order is mirrored so
    /// the lower page number sits on the right. If there's no second
    /// page (last page of an odd-length book) the single page is
    /// returned unchanged.
    func spreadImage(leftIndex: Int) async -> NSImage? {
        guard let first = await image(at: leftIndex) else { return nil }
        guard leftIndex + 1 < pageCount,
              let second = await image(at: leftIndex + 1) else {
            return first
        }
        // Reading order: in RTL the earlier page is on the right.
        let pageA = direction == .rightToLeft ? second : first
        let pageB = direction == .rightToLeft ? first : second
        return ReaderModel.composeSpread(left: pageA, right: pageB)
    }

    /// Draw two page images into one canvas, side by side, vertically
    /// centred against the taller of the two. Nonisolated so the
    /// detached decode tasks can call it off the main actor.
    nonisolated static func composeSpread(left: NSImage, right: NSImage) -> NSImage {
        let lSize = left.size
        let rSize = right.size
        let height = max(lSize.height, rSize.height)
        let width = lSize.width + rSize.width
        guard width > 0, height > 0 else { return left }
        let canvas = NSImage(size: NSSize(width: width, height: height))
        canvas.lockFocus()
        NSColor.clear.set()
        NSBezierPath.fill(NSRect(x: 0, y: 0, width: width, height: height))
        left.draw(in: NSRect(x: 0,
                              y: (height - lSize.height) / 2,
                              width: lSize.width,
                              height: lSize.height))
        right.draw(in: NSRect(x: lSize.width,
                               y: (height - rSize.height) / 2,
                               width: rSize.width,
                               height: rSize.height))
        canvas.unlockFocus()
        return canvas
    }

    // MARK: - Page-grid thumbnails

    /// A small thumbnail of a single page for the page-grid navigator.
    /// Decoded from the full page on first request and cached in a
    /// dedicated, generously-sized cache.
    func pageThumbnail(at index: Int) async -> NSImage? {
        if index < 0 || index >= pageCount { return nil }
        let key = NSNumber(value: index)
        if let cached = pageThumbCache.object(forKey: key) { return cached }
        guard let full = await image(at: index) else { return nil }
        let thumb = full.resized(maxDimension: 220)
        pageThumbCache.setObject(thumb, forKey: key)
        return thumb
    }

    /// The cover thumbnail for the current book, used as a low-res placeholder
    /// while page 0 is being decoded so the reader never opens to a blank
    /// progress spinner.
    func coverThumbnail() -> NSImage? {
        guard let item = library.item(withID: itemID) else { return nil }
        return library.thumbnailImage(for: item)
    }

    func setPage(_ index: Int) {
        var clamped = max(0, min(pageCount - 1, index))
        // Spread mode always lands on the even page of a pair so the
        // composed image stays aligned with the [0,1],[2,3],… pairing.
        if twoPageSpread, !isTextBook {
            clamped -= clamped % 2
        }
        currentPage = clamped
        Task { await prefetchAround(clamped) }
        saveSubject.send(())
    }

    func bumpTextZoom(_ delta: CGFloat) {
        textZoom = max(0.6, min(2.5, textZoom + delta))
    }

    func persistProgress() {
        library.updateProgress(
            itemID: itemID,
            page: currentPage,
            pageCount: pageCount,
            direction: direction,
            zoomMode: zoomMode,
            textZoom: Double(textZoom),
            twoPage: twoPageSpread
        )
    }

    func close() {
        reader?.close()
        reader = nil
        prefetchTasks.values.forEach { $0.cancel() }
        prefetchTasks.removeAll()
        pageCache.removeAllObjects()
        contentCache.removeAll()
        persistProgress()
    }
}

struct ReaderView: View {
    let itemID: ComicItem.ID
    @EnvironmentObject var library: LibraryStore
    @StateObject private var model: ReaderModelHolder = ReaderModelHolder()
    @State private var jumpPageText: String = ""
    @State private var showJumpField: Bool = false
    @State private var showingTranslateSettings: Bool = false
    @State private var showingPageGrid: Bool = false
    @State private var showingBookmarks: Bool = false

    private var backgroundColor: Color {
        guard let m = model.value else { return Color(red: 0.02, green: 0.04, blue: 0.10) }
        if m.isTextBook {
            return m.backgroundDark
                ? Color(red: 0.04, green: 0.07, blue: 0.16)
                : Color(red: 0.97, green: 0.95, blue: 0.91)
        }
        return m.backgroundDark ? .black : .white
    }

    var body: some View {
        readerBody
            .inspector(isPresented: Binding(
                get: { (model.value?.translationPanelVisible ?? false) && (model.value?.translateMode ?? false) },
                set: { newValue in model.value?.translationPanelVisible = newValue }
            )) {
                if let m = model.value {
                    TranslationPanelView(model: m,
                                          settings: TranslationSettings.shared)
                        .inspectorColumnWidth(min: 260, ideal: 300, max: 380)
                }
            }
    }

    @ViewBuilder
    private var readerBody: some View {
        ZStack {
            backgroundColor
                .ignoresSafeArea()

            Group {
                if let m = model.value {
                    if m.isLoading {
                        ProgressView(m.loadingStatus)
                            .controlSize(.large)
                            .foregroundStyle(m.backgroundDark ? .white : .black)
                    } else if let err = m.loadError {
                        VStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 40))
                                .foregroundStyle(.orange)
                            Text("Couldn't open this file")
                                .font(.title3.bold())
                            Text(err)
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 30)
                        }
                        .foregroundStyle(m.backgroundDark ? .white : .black)
                    } else if m.pageCount > 0 {
                        if m.isTextBook {
                            TextPageView(model: m)
                        } else if m.direction == .vertical {
                            VerticalPagesView(model: m)
                        } else {
                            PagedReaderView(model: m)
                        }
                    } else {
                        Text("No pages.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .toolbar { toolbarContent }
        .safeAreaInset(edge: .bottom) {
            if let m = model.value, m.pageCount > 0, !m.isLoading {
                bottomBar(model: m)
            }
        }
        .background(KeyEventHandlingView(
            onKeyDown: { handleKey(event: $0) },
            onSwipe: { handleSwipe(deltaX: $0) }
        ))
        .onAppear {
            if model.value == nil {
                let m = ReaderModel(itemID: itemID, library: library)
                model.install(m)
                m.load()
            }
        }
        .onDisappear {
            model.value?.close()
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                model.value?.goPrev()
            } label: {
                Image(systemName: (model.value?.direction == .rightToLeft) ? "chevron.right" : "chevron.left")
            }
            .help("Previous page")

            Button {
                model.value?.goNext()
            } label: {
                Image(systemName: (model.value?.direction == .rightToLeft) ? "chevron.left" : "chevron.right")
            }
            .help("Next page")
        }

        ToolbarItemGroup(placement: .principal) {
            if let m = model.value {
                Button {
                    showJumpField.toggle()
                    jumpPageText = "\(m.currentPage + 1)"
                } label: {
                    Text(pageCounterLabel(model: m))
                        .font(.callout.monospacedDigit())
                }
                .buttonStyle(.borderless)
                .help(m.isTextBook ? "Jump to chapter" : "Jump to page")
                .popover(isPresented: $showJumpField) {
                    JumpToPageView(
                        text: $jumpPageText,
                        pageCount: m.pageCount,
                        label: m.isTextBook ? "chapter" : "page"
                    ) { newPage in
                        m.setPage(newPage - 1)
                        showJumpField = false
                    }
                    .padding()
                }
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if let m = model.value {
                if !m.isTextBook {
                    Button {
                        showingPageGrid.toggle()
                    } label: {
                        Image(systemName: "square.grid.2x2")
                    }
                    .help("Page grid")
                    .popover(isPresented: $showingPageGrid) {
                        PageGridView(model: m) { page in
                            m.setPage(page)
                            showingPageGrid = false
                        }
                    }
                }

                Button {
                    m.toggleBookmarkCurrentPage()
                } label: {
                    Image(systemName: m.isCurrentPageBookmarked ? "bookmark.fill" : "bookmark")
                }
                .help(m.isCurrentPageBookmarked ? "Remove bookmark" : "Bookmark this page")
                .keyboardShortcut("d", modifiers: [.command])

                Button {
                    showingBookmarks.toggle()
                } label: {
                    Image(systemName: "list.bullet")
                }
                .help("Bookmarks")
                .popover(isPresented: $showingBookmarks) {
                    BookmarksListView(model: m) { page in
                        m.setPage(page)
                        showingBookmarks = false
                    }
                }

                if !m.isTextBook {
                    Toggle(isOn: Binding(
                        get: { m.twoPageSpread },
                        set: { m.twoPageSpread = $0 })
                    ) {
                        Image(systemName: m.twoPageSpread
                              ? "book.pages.fill" : "book.pages")
                    }
                    .toggleStyle(.button)
                    .help(m.twoPageSpread
                          ? "Single page" : "Two-page spread")

                    Picker("Direction", selection: Binding(
                        get: { m.direction },
                        set: { m.direction = $0 })
                    ) {
                        ForEach(ReadingDirection.allCases) { d in
                            Label(d.rawValue, systemImage: d.systemImage).tag(d)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 170)
                    .help("Reading direction")
                }

                if m.isTextBook {
                    Button { m.bumpTextZoom(-0.1) } label: {
                        Image(systemName: "textformat.size.smaller")
                    }
                    .help("Smaller text")
                    Button { m.bumpTextZoom(+0.1) } label: {
                        Image(systemName: "textformat.size.larger")
                    }
                    .help("Larger text")
                    Text("\(Int(m.textZoom * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Menu {
                        Button("Fit Page") { m.zoomMode = .fitPage }
                        Button("Fit Width") { m.zoomMode = .fitWidth }
                        Button("Fit Height") { m.zoomMode = .fitHeight }
                        Button("Actual Size") { m.zoomMode = .actual }
                        Divider()
                        Button("50%") { m.zoomMode = .custom(0.5) }
                        Button("75%") { m.zoomMode = .custom(0.75) }
                        Button("100%") { m.zoomMode = .custom(1.0) }
                        Button("150%") { m.zoomMode = .custom(1.5) }
                        Button("200%") { m.zoomMode = .custom(2.0) }
                    } label: {
                        Label(m.zoomMode.label, systemImage: "magnifyingglass")
                    }
                    .help("Zoom")
                }

                Toggle(isOn: Binding(
                    get: { m.backgroundDark },
                    set: { m.backgroundDark = $0 })
                ) {
                    Image(systemName: m.backgroundDark ? "moon.fill" : "sun.max.fill")
                }
                .toggleStyle(.button)
                .help("Toggle background")

                if !m.isTextBook {
                    translateControls(model: m)
                }
            }
        }
    }

    /// The page-counter label. Two-page spread shows the page range
    /// ("Pages 3–4 / 120"); everything else shows a single index.
    private func pageCounterLabel(model m: ReaderModel) -> String {
        if m.isTextBook {
            return "Chapter \(m.currentPage + 1) / \(m.pageCount)"
        }
        if m.twoPageSpread, m.currentPage + 1 < m.pageCount {
            return "Pages \(m.currentPage + 1)–\(m.currentPage + 2) / \(m.pageCount)"
        }
        return "Page \(m.currentPage + 1) / \(m.pageCount)"
    }

    /// Translate-mode toggle + settings popover. Only shown for image-based
    /// books — EPUB / MOBI text is already in the document, the user can
    /// pick a system text translator instead.
    @ViewBuilder
    private func translateControls(model m: ReaderModel) -> some View {
        Toggle(isOn: Binding(
            get: { m.translateMode },
            set: { m.translateMode = $0 })
        ) {
            Image(systemName: m.translateMode ? "character.bubble.fill" : "character.bubble")
        }
        .toggleStyle(.button)
        .help(m.translateMode ? "Turn off translation" : "Turn on translation")

        if m.translateMode {
            Toggle(isOn: Binding(
                get: { m.translationPanelVisible },
                set: { m.translationPanelVisible = $0 })
            ) {
                Image(systemName: "sidebar.right")
            }
            .toggleStyle(.button)
            .help(m.translationPanelVisible
                  ? "Hide translation panel"
                  : "Show translation panel (Live Text)")
        }

        Button {
            showingTranslateSettings.toggle()
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .help("Translate settings")
        .popover(isPresented: $showingTranslateSettings) {
            TranslateSettingsView(settings: TranslationSettings.shared)
        }
    }

    private func bottomBar(model m: ReaderModel) -> some View {
        // In right-to-left manga mode the slider thumb already travels
        // right-to-left, but the two endpoint labels used to stay fixed at
        // [current ──●── total]. Swap them so the layout reads as
        // [total ──●── current] — i.e. the high page numbers sit on the left
        // end (where the slider ends up) and the low/current sit on the
        // right end (where the reader starts).
        let isRTL = !m.isTextBook && m.direction == .rightToLeft
        let leftNumber  = isRTL ? m.pageCount : (m.currentPage + 1)
        let rightNumber = isRTL ? (m.currentPage + 1) : m.pageCount
        return VStack(spacing: 6) {
            HStack(spacing: 12) {
                Text("\(leftNumber)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 36, alignment: .trailing)

                PageSlider(
                    value: Binding(
                        get: { Double(m.currentPage) },
                        set: { m.setPage(Int($0.rounded())) }
                    ),
                    range: 0...Double(max(0, m.pageCount - 1)),
                    reversed: isRTL
                )

                Text("\(rightNumber)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 36, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(.black.opacity(0.55))
    }

    /// Trackpad swipe-between-pages. `deltaX > 0` is a swipe toward the
    /// left — page-forward in left-to-right reading, page-back in RTL
    /// manga — mirroring the arrow-key mapping in `handleKey`.
    private func handleSwipe(deltaX: CGFloat) {
        guard let m = model.value else { return }
        let isRTL = !m.isTextBook && m.direction == .rightToLeft
        if deltaX > 0 {
            isRTL ? m.goPrev() : m.goNext()
        } else if deltaX < 0 {
            isRTL ? m.goNext() : m.goPrev()
        }
    }

    private func handleKey(event: NSEvent) -> Bool {
        guard let m = model.value else { return false }
        let leftKey: UInt16 = 123
        let rightKey: UInt16 = 124
        let spaceKey: UInt16 = 49
        let pageUp: UInt16 = 116
        let pageDown: UInt16 = 121
        let homeKey: UInt16 = 115
        let endKey: UInt16 = 119

        switch event.keyCode {
        case leftKey:
            (!m.isTextBook && m.direction == .rightToLeft) ? m.goNext() : m.goPrev()
            return true
        case rightKey:
            (!m.isTextBook && m.direction == .rightToLeft) ? m.goPrev() : m.goNext()
            return true
        case spaceKey, pageDown:
            m.goNext()
            return true
        case pageUp:
            m.goPrev()
            return true
        case homeKey:
            m.setPage(0)
            return true
        case endKey:
            m.setPage(m.pageCount - 1)
            return true
        default:
            return false
        }
    }
}

@MainActor
final class ReaderModelHolder: ObservableObject {
    @Published var value: ReaderModel?
    private var innerSubscription: AnyCancellable?

    /// Install the reader model and bridge its `objectWillChange` to ours so
    /// any @Published change on the inner model (isLoading, pageCount,
    /// currentPage, loadingStatus, …) makes ReaderView re-render. Without
    /// this, the body only re-renders when `value` itself is reassigned, so
    /// the view stays frozen on its initial snapshot.
    func install(_ model: ReaderModel) {
        innerSubscription?.cancel()
        innerSubscription = model.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
        value = model
    }
}

struct JumpToPageView: View {
    @Binding var text: String
    let pageCount: Int
    let label: String
    var onSubmit: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Jump to \(label) (1 – \(pageCount))")
                .font(.callout)
            HStack {
                TextField(label.capitalized, text: $text)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .onSubmit(submit)
                Button("Go", action: submit)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 240)
    }

    private func submit() {
        if let n = Int(text), n >= 1, n <= pageCount {
            onSubmit(n)
        }
    }
}

struct TextPageView: View {
    @ObservedObject var model: ReaderModel

    var body: some View {
        Group {
            if let content = model.contentSync(at: model.currentPage) {
                WebPageView(
                    content: content,
                    darkMode: model.backgroundDark,
                    zoom: model.textZoom,
                    onScrollToTop: {}
                )
            } else {
                ProgressView()
            }
        }
        .id(model.currentPage)
    }
}
