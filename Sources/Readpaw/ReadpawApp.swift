import SwiftUI
import AppKit

@main
enum AppMain {
    static func main() {
        let args = CommandLine.arguments
        if let idx = args.firstIndex(of: "--smoke-test"), idx + 1 < args.count {
            SmokeTest.run(folder: args[idx + 1])
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
                Button("Rescan Library") {
                    library.rescan()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
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

final class OpenBooks: ObservableObject {
    @Published var openItemIDs: Set<ComicItem.ID> = []
}

struct RootView: View {
    @EnvironmentObject var library: LibraryStore

    var body: some View {
        Group {
            if library.rootFolder == nil {
                OnboardingView()
            } else {
                LibraryView()
            }
        }
    }
}
