# Readpaw

A native macOS comic & manga reader built with SwiftUI.

## Supported formats

- `.cbz` / `.zip` — image archive
- `.cbr` / `.rar` — image archive (read via macOS's built-in libarchive)
- `.7z` — image archive
- `.pdf` — rendered via PDFKit

Archive support is delivered through `/usr/bin/tar` (bsdtar / libarchive) which ships with macOS, so no third-party dependencies are required.

## Features

- **First-launch folder picker.** Choose a folder; subfolders are scanned automatically.
- **Beautiful library view** with cover thumbnails generated from the first image of each archive (or first page of a PDF). Search, sort by title / date added / recently opened, and resize cover cards on the fly.
- **Reader window** opens on double-click. Includes:
  - Reading direction: **Left-to-Right**, **Right-to-Left** (for manga), or **Vertical (Webtoon)**.
  - Page slider scrubbing at the bottom (auto-mirrored in RTL mode).
  - Jump-to-page popover (click the page counter in the toolbar).
  - Zoom: Fit Page, Fit Width, Fit Height, Actual Size, or fixed percentages (50–200%).
  - Double-page spread toggle.
  - Light / dark page background.
  - Keyboard nav: arrow keys, space, page up/down, home/end.
  - Click the left/right third of a page to flip pages.
- **Resume where you left off.** Last-read page is saved per book.
- **Multiple windows.** Each book opens in its own window.

## Build & run

```bash
# Quick dev launch (no .app bundle):
swift run

# Build a proper .app you can drop into /Applications:
./scripts/build-app.sh
open build/Readpaw.app
```

Requirements: macOS 14+ and the Swift 5.9+ toolchain (Xcode 15 or Command Line Tools).

## Project layout

```
Sources/Readpaw/
├── ReadpawApp.swift            # @main, scenes, commands
├── Models/
│   ├── ComicItem.swift         # book metadata
│   └── LibraryStore.swift      # scanning, persistence, thumbnails
├── Archive/
│   ├── ArchiveReader.swift     # protocol + filter + factory
│   ├── PDFArchiveReader.swift  # PDFKit-backed
│   └── TarArchiveReader.swift  # bsdtar/libarchive-backed (zip/rar/7z)
├── Views/
│   ├── OnboardingView.swift    # first-launch welcome
│   ├── LibraryView.swift       # grid of covers
│   ├── ReaderView.swift        # reader shell + toolbar
│   ├── PagedReaderView.swift   # single/double-page mode (NSScrollView zoom)
│   ├── VerticalPagesView.swift # webtoon-style vertical scroll
│   ├── PageSlider.swift        # slider + key-capture host
│   └── ReaderWindowController.swift
└── Utilities/
    └── NSImage+Resize.swift
Resources/Info.plist             # bundled by build-app.sh
scripts/build-app.sh             # SwiftPM build → Readpaw.app
```

## Notes

- The library scan walks the folder tree and skips hidden / package contents. Mac-specific `__MACOSX/` entries inside zips are filtered out.
- Thumbnails are cached under `~/Library/Application Support/Readpaw/Thumbnails/`.
- Persistent library state (titles, last-read page, page counts) lives in `~/Library/Application Support/Readpaw/library.json`.
- The chosen folder is stored as a security-scoped bookmark in `UserDefaults`.
