import SwiftUI
import AppKit

enum LibrarySort: String, CaseIterable, Identifiable {
    case title = "Title"
    case dateAdded = "Date Added"
    case lastOpened = "Recently Opened"
    var id: String { rawValue }
}

struct LibraryView: View {
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var openBooks: OpenBooks
    @State private var search: String = ""
    @State private var sort: LibrarySort = .title
    @State private var cardSize: CGFloat = 180

    var filtered: [ComicItem] {
        let base = library.items.filter { item in
            search.isEmpty || item.title.localizedCaseInsensitiveContains(search)
        }
        switch sort {
        case .title:
            return base.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .dateAdded:
            return base.sorted { $0.dateAdded > $1.dateAdded }
        case .lastOpened:
            return base.sorted {
                ($0.lastOpened ?? .distantPast) > ($1.lastOpened ?? .distantPast)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if filtered.isEmpty {
                emptyState
            } else {
                grid
            }
            if library.isScanning {
                Divider()
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(library.scanProgress)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(.bar)
            }
        }
        .frame(minWidth: 800, minHeight: 500)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "books.vertical.fill")
                .foregroundStyle(.tint)
            Text("Library")
                .font(.title2.bold())

            if let folder = library.rootFolder {
                Text(folder.path)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(folder.path)
            }

            Spacer()

            TextField("Search…", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)

            Picker("Sort", selection: $sort) {
                ForEach(LibrarySort.allCases) { s in
                    Text(s.rawValue).tag(s)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 170)

            Slider(value: $cardSize, in: 120...280)
                .frame(width: 120)
                .help("Cover size")

            Button {
                library.rescan()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Rescan library")
            .disabled(library.isScanning)

            Button {
                library.promptForFolder()
            } label: {
                Image(systemName: "folder")
            }
            .help("Change library folder")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 56))
                .foregroundStyle(.tertiary)
            if library.isScanning {
                Text("Scanning your library…")
                    .foregroundStyle(.secondary)
            } else if search.isEmpty {
                Text("No comics found in this folder.")
                    .foregroundStyle(.secondary)
                Button("Choose Another Folder") { library.promptForFolder() }
                    .buttonStyle(.borderedProminent)
            } else {
                Text("No comics match “\(search)”.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: cardSize, maximum: cardSize * 1.4), spacing: 24)]
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 28) {
                ForEach(filtered) { item in
                    LibraryCard(item: item, width: cardSize)
                        .onTapGesture(count: 2) { open(item) }
                        .contextMenu { contextMenu(for: item) }
                }
            }
            .padding(24)
        }
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.5))
    }

    @ViewBuilder
    private func contextMenu(for item: ComicItem) -> some View {
        Button("Open") { open(item) }
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([item.url])
        }
        Divider()
        Button("Mark as Unread") {
            library.updateProgress(itemID: item.id, page: 0, pageCount: item.pageCount)
        }
    }

    private func open(_ item: ComicItem) {
        let id = item.id
        if !openBooks.openItemIDs.contains(id) {
            openBooks.openItemIDs.insert(id)
            ReaderWindowController.shared.open(itemID: id, library: library) {
                openBooks.openItemIDs.remove(id)
            }
        } else {
            ReaderWindowController.shared.bringToFront(itemID: id)
        }
    }
}

struct LibraryCard: View {
    let item: ComicItem
    let width: CGFloat
    @EnvironmentObject var library: LibraryStore
    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let thumb = thumbnail {
                        Image(nsImage: thumb)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        ZStack {
                            Rectangle().fill(Color.gray.opacity(0.18))
                            Image(systemName: "book.closed")
                                .font(.system(size: 36))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(width: width, height: width * 1.45)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.12), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.25), radius: 8, y: 4)

                Text(item.format.displayName)
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.65))
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
                    .padding(6)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let total = item.pageCount {
                    if item.lastReadPage > 0 {
                        Text("Page \(item.lastReadPage + 1) of \(total)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ProgressView(value: Double(item.lastReadPage + 1),
                                     total: Double(max(total, 1)))
                            .progressViewStyle(.linear)
                            .controlSize(.mini)
                    } else {
                        Text("\(total) pages")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(item.format.displayName)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: width, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onAppear(perform: loadThumbnail)
        .onChange(of: item.thumbnailFileName) { loadThumbnail() }
    }

    private func loadThumbnail() {
        if let img = library.thumbnailImage(for: item) {
            self.thumbnail = img
        }
    }
}
