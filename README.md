# Readpaw

A native macOS reader for comics, manga, and ebooks. Built with SwiftUI.

## Supported formats

### Image-based (comics / manga)
- `.cbz` / `.zip` — image archive
- `.cbr` / `.rar` — image archive (read via macOS's built-in libarchive)
- `.7z` — image archive
- `.pdf` — rendered via PDFKit

### Ebooks
- `.epub` — full XHTML rendering via WKWebView (chapters as pages)
- `.mobi` / `.azw` / `.azw3` — native PalmDB + PalmDOC parser (un-DRM'd files)
- `.fb2` — XML parsed to HTML with inline cover & images
- `.txt` — auto-paginated for large files
- `.html` / `.xhtml` / `.htm` — loaded directly with relative resources

Comics/manga support uses `/usr/bin/tar` (bsdtar / libarchive) that ships with macOS, and ebook readers are implemented natively in Swift — no third-party dependencies.

## Features

- **First-launch welcome screen** with a procedurally-generated rotating spiral galaxy over a calm navy gradient.
- **Library** with cover thumbnails (first image for comics, EPUB/FB2 cover image, or a stylized placeholder for text formats). Search, sort by title / date added / recently opened, and resize cover cards on the fly.
- **Reader window** opens on double-click. Adapts to content type:
  - **Comics/manga:** reading direction (LTR, RTL for manga, vertical webtoon), zoom modes (Fit Page/Width/Height/Actual/50–200%), double-page spread, dark/light page background, click-edges to flip.
  - **Ebooks:** WKWebView rendering with adjustable text size (60–250%), per-chapter navigation, dark/light mode CSS injection, internal/external link handling, persistent reading position.
- **Page slider** scrubbing at the bottom (auto-mirrored in RTL).
- **Jump to page / chapter** popover from the toolbar counter.
- **Keyboard nav:** arrow keys, space, page up/down, home/end.
- **Resume** where you left off. Last-read page is saved per book.
- **Multiple windows.** Each book opens in its own window.

## Build & run

```bash
# Quick dev launch (no .app bundle):
swift run

# Headless verification of every reader against a folder of books:
swift run Readpaw --smoke-test /path/to/books

# Build a proper .app you can drop into /Applications:
./scripts/build-app.sh
open build/Readpaw.app
```

Requirements: macOS 14+ and the Swift 5.9+ toolchain (Xcode 15 or Command Line Tools).

## Project layout

```
Sources/Readpaw/
├── ReadpawApp.swift            # @main, scenes, commands
├── SmokeTest.swift             # --smoke-test CLI flag harness
├── Models/
│   ├── ComicItem.swift         # book metadata (formats, sizes, last-read page)
│   └── LibraryStore.swift      # scanning, persistence, thumbnails
├── Archive/
│   ├── ArchiveReader.swift     # ContentReader protocol + PageContent enum + factory
│   ├── PDFArchiveReader.swift  # PDFKit-backed
│   ├── TarArchiveReader.swift  # bsdtar/libarchive-backed (zip/rar/7z)
│   ├── EpubReader.swift        # OPF/spine parser, file-URL chapter rendering
│   ├── MobiReader.swift        # PalmDB + PalmDOC decompression
│   ├── TxtReader.swift         # TXT / HTML / FB2 readers + EbookStyle wrapper
│   └── EbookStyle.swift        # shared HTML chrome (typography, dark mode)
├── Views/
│   ├── OnboardingView.swift    # welcome screen with rotating galaxy + pill CTA
│   ├── GalaxyView.swift        # SceneKit scene: tilted spinning galaxy disc + static starfield
│   ├── LibraryView.swift       # grid of covers, search, sort, scan progress
│   ├── ReaderView.swift        # reader shell + toolbar + content dispatch
│   ├── PagedReaderView.swift   # single/double-page mode (NSScrollView zoom)
│   ├── VerticalPagesView.swift # webtoon-style vertical scroll
│   ├── WebPageView.swift       # WKWebView wrapper for ebook content
│   ├── PageSlider.swift        # slider + key-capture host
│   └── ReaderWindowController.swift
└── Utilities/
    ├── NSImage+Resize.swift
    └── GalaxyTexture.swift     # procedural galaxy spiral + starfield (value-noise fbm)
Resources/Info.plist             # bundled by build-app.sh
scripts/build-app.sh             # SwiftPM build → Readpaw.app
```

## Notes

- Library scan walks the folder tree, skipping hidden / package contents. `__MACOSX/` entries inside zips are filtered out.
- Thumbnails are cached under `~/Library/Application Support/Readpaw/Thumbnails/`.
- Persistent library state lives in `~/Library/Application Support/Readpaw/library.json`.
- EPUBs are extracted to `~/Library/Caches/Readpaw/Books/<uuid>/` while open; the workspace is removed when the reader closes.
- The chosen folder is stored as a security-scoped bookmark in `UserDefaults`.
- DRM'd MOBI/AZW files cannot be opened; HUFF/CDIC-compressed variants are not yet supported.
- The galaxy texture is generated at runtime: a logarithmic multi-arm spiral with a warm bulge, blue arms, dust lanes from noise, and a separate starfield drawn with additive blending. No image assets shipped.
