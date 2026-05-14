import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main
enum AppMain {
    static func main() {
        let args = CommandLine.arguments
        if let idx = args.firstIndex(of: "--smoke-test"), idx + 1 < args.count {
            SmokeTest.run(folder: args[idx + 1])
            exit(0)
        }
        if let idx = args.firstIndex(of: "--ocr-test"), idx + 1 < args.count {
            OCRDiagnostic.run(imagePath: args[idx + 1])
            exit(0)
        }
        ReadpawApp.main()
    }
}

struct ReadpawApp: App {
    @StateObject private var library = LibraryStore()
    @StateObject private var openBooks = OpenBooks()

    init() {
        // Only force `.regular` when launched as a plain executable (e.g.
        // `swift run`), where nothing has promoted us out of the "background
        // process" activation policy and we'd otherwise come up without a
        // Dock icon or menu bar. When launched as a .app bundle,
        // NSApplicationMain has already set the policy from Info.plist;
        // calling it again from inside App.init has been observed to race
        // SwiftUI startup and SIGTRAP on some macOS versions.
        if Bundle.main.bundleIdentifier == nil {
            NSApplication.shared.setActivationPolicy(.regular)
        }
    }

    var body: some Scene {
        WindowGroup("Readpaw") {
            RootView()
                .environmentObject(library)
                .environmentObject(openBooks)
                // Floor large enough that the onboarding's 480-pt 3D orb,
                // tagline and pill CTA all fit at once without the user
                // having to manually resize the window.
                .frame(minWidth: 760, minHeight: 780)
                .preferredColorScheme(.dark)
                .onAppear {
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        // First-open size — wide enough for the library grid later, tall
        // enough for the welcome screen on first launch. Subsequent opens
        // use whatever frame macOS remembered for the window.
        .defaultSize(width: 980, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Folder…") {
                    library.promptForFolder()
                }
                .keyboardShortcut("o", modifiers: [.command])
                Button("Open File…") {
                    openFilePanel()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Rescan Library") {
                    library.rescan()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Divider()

                Menu("Open Recent") {
                    let recents = library.recentlyOpened
                    if recents.isEmpty {
                        Button("No Recent Books") {}.disabled(true)
                    } else {
                        ForEach(recents.prefix(12)) { item in
                            Button(item.title) {
                                openBooks.open(itemID: item.id, library: library)
                            }
                        }
                        Divider()
                        Button("Clear Menu") {
                            library.clearRecentlyOpened()
                        }
                    }
                }
            }
        }

        WindowGroup("Reader", for: ComicItem.ID.self) { $itemID in
            ReaderWindowHost(itemID: itemID)
                .environmentObject(library)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1100, height: 800)
    }
}

@MainActor
final class OpenBooks: ObservableObject {
    @Published var openItemIDs: Set<ComicItem.ID> = []

    /// Open a book in its own reader window, or bring the existing
    /// window forward if it's already open. Single entry point shared
    /// by the library grid, the drag-and-drop handler, and the
    /// File ▸ Open Recent menu.
    func open(itemID: ComicItem.ID, library: LibraryStore) {
        if openItemIDs.contains(itemID) {
            ReaderWindowController.shared.bringToFront(itemID: itemID)
            return
        }
        openItemIDs.insert(itemID)
        ReaderWindowController.shared.open(itemID: itemID, library: library) { [weak self] in
            self?.openItemIDs.remove(itemID)
        }
    }
}

extension ReadpawApp {
    /// File ▸ Open File… — pick one or more supported files anywhere on
    /// disk, add them to the library as external items, and open them.
    func openFilePanel() {
        let panel = NSOpenPanel()
        panel.title = "Open Book"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        let exts = ["cbz", "cbr", "zip", "rar", "7z", "pdf",
                    "epub", "mobi", "prc", "azw", "azw3", "kf8",
                    "fb2", "txt", "html", "htm", "xhtml"]
        panel.allowedContentTypes = exts.compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK {
            for url in panel.urls {
                if let id = library.addExternalFile(url: url) {
                    openBooks.open(itemID: id, library: library)
                }
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var openBooks: OpenBooks
    @State private var dropTargeted: Bool = false

    var body: some View {
        Group {
            if library.rootFolder == nil {
                OnboardingView()
            } else {
                LibraryView()
            }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10]))
                    .background(Color.accentColor.opacity(0.08))
                    .overlay {
                        Label("Drop to open", systemImage: "arrow.down.doc")
                            .font(.title2.bold())
                            .foregroundStyle(.tint)
                    }
                    .padding(8)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: dropTargeted)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
        }
    }

    /// Accept files dropped anywhere on the main window. Each supported
    /// file is registered as an external library item and opened; the
    /// provider load is async so we hop back to the main actor to touch
    /// the store and the window controller.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers {
            guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { continue }
            accepted = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let u = item as? URL {
                    url = u
                } else {
                    url = nil
                }
                guard let url, ComicFormat.from(url: url) != nil else { return }
                Task { @MainActor in
                    if let id = library.addExternalFile(url: url) {
                        openBooks.open(itemID: id, library: library)
                    }
                }
            }
        }
        return accepted
    }
}
