// Builds Resources/AppIcon.icns from a source PNG by:
//  1. Resizing to 1024×1024.
//  2. Applying a rounded-rect mask with the macOS app-icon corner radius
//     (~22.37 % of the side length, approximating the Big Sur squircle).
//  3. Emitting each required iconset size (16…1024 at 1x and 2x).
//  4. Wrapping the iconset with `iconutil` into AppIcon.icns.
//
// Run:
//   swift scripts/make-appicon.swift <source.png>

import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: make-appicon.swift <source.png>\n".utf8))
    exit(2)
}

let sourcePath = CommandLine.arguments[1]
guard FileManager.default.fileExists(atPath: sourcePath),
      let src = NSImage(contentsOfFile: sourcePath) else {
    FileHandle.standardError.write(Data("Couldn't read source at \(sourcePath)\n".utf8))
    exit(1)
}

let projectRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resourcesDir = projectRoot.appendingPathComponent("Resources", isDirectory: true)
let iconsetDir = resourcesDir.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try? FileManager.default.createDirectory(at: resourcesDir, withIntermediateDirectories: true)
try? FileManager.default.removeItem(at: iconsetDir)
try FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

// Decode the source PNG once as a CGImage so we can draw it into arbitrarily-
// sized CGContexts (NSImage's lockFocus path failed for the 16×16 size with
// "CGImageDestinationFinalize failed for output type 'public.tiff'").
guard let srcCG = (src.cgImage(forProposedRect: nil, context: nil, hints: nil)) else {
    FileHandle.standardError.write(Data("Couldn't get CGImage from source\n".utf8))
    exit(1)
}

/// Render the source image into a square canvas of `side` pixels with a
/// proportional rounded-rect mask. The 22.37 % corner-radius factor matches
/// the macOS Big Sur+ app-icon shape closely enough that the OS won't
/// double-mask the image.
func renderRounded(side: Int) -> Data {
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil,
                              width: side,
                              height: side,
                              bitsPerComponent: 8,
                              bytesPerRow: side * 4,
                              space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        FileHandle.standardError.write(Data("Failed to create CGContext at \(side)\n".utf8))
        exit(1)
    }

    let rect = CGRect(x: 0, y: 0, width: side, height: side)
    let radius = CGFloat(side) * 0.2237
    let clip = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.addPath(clip)
    ctx.clip()
    ctx.interpolationQuality = .high
    ctx.draw(srcCG, in: rect)
    ctx.restoreGState()

    guard let cgOut = ctx.makeImage() else {
        FileHandle.standardError.write(Data("Failed to make image at \(side)\n".utf8))
        exit(1)
    }
    let mutable = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(mutable, UTType.png.identifier as CFString, 1, nil) else {
        FileHandle.standardError.write(Data("Failed to create destination at \(side)\n".utf8))
        exit(1)
    }
    CGImageDestinationAddImage(dest, cgOut, nil)
    if !CGImageDestinationFinalize(dest) {
        FileHandle.standardError.write(Data("Failed to encode PNG at \(side)\n".utf8))
        exit(1)
    }
    return mutable as Data
}

// Each entry: (physical size in px, iconset filename)
let entries: [(Int, String)] = [
    (16,   "icon_16x16.png"),
    (32,   "icon_16x16@2x.png"),
    (32,   "icon_32x32.png"),
    (64,   "icon_32x32@2x.png"),
    (128,  "icon_128x128.png"),
    (256,  "icon_128x128@2x.png"),
    (256,  "icon_256x256.png"),
    (512,  "icon_256x256@2x.png"),
    (512,  "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]

for (side, name) in entries {
    let data = renderRounded(side: side)
    let dest = iconsetDir.appendingPathComponent(name)
    try data.write(to: dest)
    print("  ✓ \(name) (\(side)×\(side))")
}

print("Wrapping with iconutil…")
let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns",
                  "-o", resourcesDir.appendingPathComponent("AppIcon.icns").path,
                  iconsetDir.path]
try proc.run()
proc.waitUntilExit()
guard proc.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed (status \(proc.terminationStatus))\n".utf8))
    exit(1)
}

// Leave the iconset dir as a side-effect — handy for debugging — but the
// .icns is the actual ship artifact.
print("Wrote Resources/AppIcon.icns")
