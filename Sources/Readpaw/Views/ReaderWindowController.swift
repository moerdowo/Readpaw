import AppKit
import SwiftUI

@MainActor
final class ReaderWindowController: NSObject {
    static let shared = ReaderWindowController()

    private var windows: [ComicItem.ID: NSWindow] = [:]
    private var delegates: [ObjectIdentifier: WindowDelegate] = [:]

    func open(itemID: ComicItem.ID, library: LibraryStore, onClose: @escaping () -> Void) {
        if let existing = windows[itemID] {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        guard let item = library.item(withID: itemID) else { return }

        let root = ReaderView(itemID: itemID)
            .environmentObject(library)

        let hosting = NSHostingController(rootView: AnyView(root))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = item.title
        window.contentViewController = hosting
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = false
        window.setFrameAutosaveName("Reader-\(itemID.uuidString)")
        window.center()

        let delegate = WindowDelegate { [weak self] in
            guard let self else { return }
            self.windows.removeValue(forKey: itemID)
            onClose()
        }
        window.delegate = delegate
        delegates[ObjectIdentifier(window)] = delegate
        windows[itemID] = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func bringToFront(itemID: ComicItem.ID) {
        windows[itemID]?.makeKeyAndOrderFront(nil)
    }

    private final class WindowDelegate: NSObject, NSWindowDelegate {
        let onClose: () -> Void
        init(onClose: @escaping () -> Void) { self.onClose = onClose }
        func windowWillClose(_ notification: Notification) { onClose() }
    }
}

/// Placeholder used by the WindowGroup-backed reader scene. Not the primary
/// entry point; double-clicking a library card uses `ReaderWindowController`.
struct ReaderWindowHost: View {
    let itemID: ComicItem.ID?

    var body: some View {
        if let id = itemID {
            ReaderView(itemID: id)
        } else {
            Text("No book selected.")
                .foregroundStyle(.secondary)
        }
    }
}
