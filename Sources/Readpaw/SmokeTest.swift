import Foundation
import AppKit
import UniformTypeIdentifiers

/// Headless verification of every `ContentReader` against a folder of books.
/// Invoked from the synthesized `main` when `--smoke-test <folder>` is passed.
enum SmokeTest {
    static func run(folder: String) {
        let url = URL(fileURLWithPath: folder)
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url,
                                              includingPropertiesForKeys: [.isRegularFileKey],
                                              options: [.skipsHiddenFiles]) else {
            print("Couldn't enumerate \(url.path)")
            return
        }
        var any = false
        for case let fileURL as URL in enumerator {
            guard let format = ComicFormat.from(url: fileURL) else { continue }
            any = true
            print("--- \(fileURL.lastPathComponent) [\(format.displayName)] ---")
            do {
                let size = (try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0
                let item = ComicItem(url: fileURL, format: format, fileSize: size)
                let reader = try ArchiveFactory.makeReader(for: item)
                defer { reader.close() }
                let count = try reader.pageCount()
                print("  pages: \(count)")
                for i in 0..<min(count, 2) {
                    let content = try reader.content(at: i)
                    switch content {
                    case .image(let img):
                        print("  page \(i + 1): image \(Int(img.size.width))x\(Int(img.size.height))")
                    case .htmlFile(let u, _):
                        print("  page \(i + 1): htmlFile \(u.lastPathComponent)")
                    case .htmlString(let s, _):
                        let prefix = s.prefix(120).replacingOccurrences(of: "\n", with: " ")
                        print("  page \(i + 1): htmlString [\(s.count) chars] \(prefix)…")
                    }
                }
                if let cover = (try? reader.coverImage()) ?? nil {
                    print("  cover: \(Int(cover.size.width))x\(Int(cover.size.height))")
                } else {
                    print("  cover: (none)")
                }
            } catch {
                print("  ERROR: \(error.localizedDescription)")
            }
        }
        if !any { print("(no supported files found)") }
    }

    /// `--dump-galaxy <png-path>` — writes a sample galaxy texture for visual review.
    static func dumpGalaxy(to path: String) {
        guard let cg = GalaxyTexture.makeSpiral(size: 1024, arms: 4, twist: 3.4, armWidth: 0.32) else {
            print("Failed to generate galaxy texture")
            return
        }
        let url = URL(fileURLWithPath: path)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            print("Failed to open destination at \(path)")
            return
        }
        CGImageDestinationAddImage(dest, cg, nil)
        if CGImageDestinationFinalize(dest) {
            print("Wrote galaxy texture to \(path)")
        } else {
            print("Failed to write image to \(path)")
        }
    }

    static func dumpStarfield(to path: String) {
        guard let cg = GalaxyTexture.makeStarfield(size: 1024, density: 800) else {
            print("Failed to generate starfield texture")
            return
        }
        let url = URL(fileURLWithPath: path)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            print("Failed to open destination at \(path)")
            return
        }
        CGImageDestinationAddImage(dest, cg, nil)
        _ = CGImageDestinationFinalize(dest)
        print("Wrote starfield to \(path)")
    }
}
