import Foundation
import AppKit
import SceneKit
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

    /// `--dump-orb <png-path>` — writes the orb surface equirectangular texture.
    static func dumpOrb(to path: String) {
        guard let cg = OrbTexture.makeSurface(width: 1024, height: 512) else {
            print("Failed to generate orb texture")
            return
        }
        writePNG(cg, to: path, label: "orb surface")
    }

    /// Renders the OrbView's SCNScene to an offscreen image so we can verify
    /// how the composited glowing orb looks without bringing up the GUI.
    static func dumpOrbScene(to path: String) {
        let scene = OrbView.buildScene(spinDuration: 70)
        scene.background.contents = NSColor(red: 0.020, green: 0.040, blue: 0.110, alpha: 1.0)

        let renderer = SCNRenderer(device: nil, options: nil)
        renderer.scene = scene
        let img = renderer.snapshot(atTime: 0.0,
                                    with: NSSize(width: 1024, height: 1024),
                                    antialiasingMode: .multisampling4X)
        guard let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("Failed to encode scene PNG")
            return
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("Wrote orb scene to \(path)")
        } catch {
            print("Failed to write scene: \(error)")
        }
    }

    private static func writePNG(_ cg: CGImage, to path: String, label: String) {
        let url = URL(fileURLWithPath: path)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            print("Failed to open destination at \(path)")
            return
        }
        CGImageDestinationAddImage(dest, cg, nil)
        if CGImageDestinationFinalize(dest) {
            print("Wrote \(label) to \(path)")
        } else {
            print("Failed to write \(label) to \(path)")
        }
    }
}
