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

enum ZoomMode: Equatable, Hashable {
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
}

@MainActor
final class ReaderModel: ObservableObject {
    let itemID: ComicItem.ID
    let library: LibraryStore

    @Published var pageCount: Int = 0
    @Published var currentPage: Int = 0
    @Published var direction: ReadingDirection = .leftToRight
    @Published var zoomMode: ZoomMode = .fitPage
    @Published var backgroundDark: Bool = true
    @Published var loadError: String?
    @Published var isLoading: Bool = true
    @Published var loadingStatus: String = "Opening book…"
    @Published var isTextBook: Bool = false
    @Published var textZoom: CGFloat = 1.0

    private var reader: ContentReader?
    private var prefetchTasks: [Int: Task<NSImage?, Never>] = [:]
    private var pageCache = NSCache<NSNumber, NSImage>()
    private var contentCache: [Int: PageContent] = [:]
    private var saveDebouncer: AnyCancellable?
    private let saveSubject = PassthroughSubject<Void, Never>()

    init(itemID: ComicItem.ID, library: LibraryStore) {
        self.itemID = itemID
        self.library = library
        pageCache.countLimit = 6

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
        self.isTextBook = isText
        if isText {
            self.direction = .vertical
            self.zoomMode = .fitWidth
        }
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
                let initialPage = max(0, min(last, max(0, count - 1)))

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

    /// For text-based books, intra-chapter paging is handled inside the
    /// WKWebView. WebPageView wires these closures up after each chapter
    /// finishes loading; we invoke them here instead of advancing the chapter
    /// directly. The WebView decides whether to scroll to the next column or
    /// (if already at the end) post a "next-chapter" message back to us via
    /// WKScriptMessageHandler — which lands as a `setPage` from the receiver.
    var textNextPageAction: (() -> Void)?
    var textPrevPageAction: (() -> Void)?

    func goNext() {
        if isTextBook, let action = textNextPageAction {
            action()
            return
        }
        setPage(currentPage + 1)
    }

    func goPrev() {
        if isTextBook, let action = textPrevPageAction {
            action()
            return
        }
        setPage(currentPage - 1)
    }

    /// The cover thumbnail for the current book, used as a low-res placeholder
    /// while page 0 is being decoded so the reader never opens to a blank
    /// progress spinner.
    func coverThumbnail() -> NSImage? {
        guard let item = library.item(withID: itemID) else { return nil }
        return library.thumbnailImage(for: item)
    }

    func setPage(_ index: Int) {
        let clamped = max(0, min(pageCount - 1, index))
        currentPage = clamped
        Task { await prefetchAround(clamped) }
        saveSubject.send(())
    }

    func bumpTextZoom(_ delta: CGFloat) {
        textZoom = max(0.6, min(2.5, textZoom + delta))
    }

    func persistProgress() {
        library.updateProgress(itemID: itemID, page: currentPage, pageCount: pageCount)
    }

    func close() {
        reader?.close()
        reader = nil
        prefetchTasks.values.forEach { $0.cancel() }
        prefetchTasks.removeAll()
        pageCache.removeAllObjects()
        contentCache.removeAll()
        textNextPageAction = nil
        textPrevPageAction = nil
        persistProgress()
    }
}

struct ReaderView: View {
    let itemID: ComicItem.ID
    @EnvironmentObject var library: LibraryStore
    @StateObject private var model: ReaderModelHolder = ReaderModelHolder()
    @State private var jumpPageText: String = ""
    @State private var showJumpField: Bool = false

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
        .background(KeyEventHandlingView { event in
            handleKey(event: event)
        })
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
                    Text(m.isTextBook
                         ? "Chapter \(m.currentPage + 1) / \(m.pageCount)"
                         : "Page \(m.currentPage + 1) / \(m.pageCount)")
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
            }
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
                    model: model
                )
            } else {
                ProgressView()
            }
        }
        .id(model.currentPage)
    }
}
