<p align="center">
  <img src="Resources/AppIcon.iconset/icon_256x256@2x.png" width="220" alt="Readpaw app icon" />
</p>

<h1 align="center">Readpaw</h1>

<p align="center">
  A native macOS reader for ebooks (epub, mobi, pdf, cbr, cbz)
  <br/>
  Built with SwiftUI. No third-party dependencies.
</p>

---

## Supported formats

**Comics & manga**

| Format | How it's read |
| --- | --- |
| `.cbz` / `.zip` | `/usr/bin/tar` (bsdtar / libarchive) |
| `.cbr` / `.rar` | `/usr/bin/tar` (libarchive RAR reader) |
| `.7z` | `/usr/bin/tar` |
| `.pdf` | PDFKit |

**Ebooks**

| Format | How it's read |
| --- | --- |
| `.epub` | Native OPF/spine parser, chapters rendered in WKWebView |
| `.mobi` / `.azw` / `.azw3` | Native PalmDB + PalmDOC decompressor (un-DRM'd files) |
| `.fb2` | XML → HTML with inline cover & images |
| `.txt` | Auto-paginated, wrapped in styled HTML |
| `.html` / `.xhtml` / `.htm` | Loaded directly, relative resources resolved |

Every reader is implemented in pure Swift or shells out to tools that ship with macOS — there are no third-party dependencies in the build.

## Features

- **Welcome screen** with a small interactive USDZ 3D model — auto-rotates, drag to spin manually.
- **Library** with cover thumbnails generated on first scan (first image for comics, embedded cover for EPUB/FB2, a stylized placeholder for text formats). Search, sort by title / date added / recently opened, resizable cards.
- **Unreadable files are skipped during scan** — the canonical readability check is "can `ArchiveFactory.makeReader` open it?", so broken zips, password-protected PDFs, HUFF/CDIC MOBIs etc. never reach the library.
- **Reader window** that opens at the page's aspect ratio on first open (no more letterboxing tall manga in a 4:3 window) and remembers any user resize via `setFrameAutosaveName` afterwards.
- **Per-format reader behaviour:**
  - **Comics / manga** — reading direction (LTR, RTL for manga, vertical webtoon), zoom modes (Fit Page / Width / Height / Actual / 50–200%), pinch-to-zoom carried per book, click-edges to flip pages, dark/light page background.
  - **Ebooks** — WKWebView rendering, adjustable text size (60–250%), per-chapter navigation, dark/light CSS override that wins over publisher styles, internal vs external link routing.
- **Page slider** at the bottom (auto-mirrored in RTL — fill, drag direction, and endpoint labels all flip).
- **Jump-to-page / chapter** popover via the toolbar counter.
- **Keyboard navigation** — arrow keys, space, page up/down, home/end.
- **Persistent per-book state** — last-read page, reading direction, zoom mode, ebook text size are all remembered across reopens.
- **Multiple windows** — every book opens in its own resizable window.
- **Translate mode** — toggle the speech-bubble icon in the reader toolbar and hover any bubble to see a translation. Apple's Vision framework OCRs the page on-device; translation runs through Google Translate (default, no setup), Bing, or OpenAI (bring your own API key — stored in your macOS Keychain). Source & target languages and the active engine live in the gear-style settings popover next to the toggle.

## Install (prebuilt DMG)

> The DMG is ad-hoc signed but **not Apple-notarised** (that costs a paid Developer ID). On macOS Sequoia the dialog _"Apple could not verify 'Readpaw-x.y.z.dmg' is free of malware"_ now blocks the DMG itself before you can even see what's inside, and the dialog no longer offers an Open Anyway button — you have to clear the quarantine flag first or walk through System Settings.

### Quickest path — one Terminal command, then drag-to-install

1. Download `Readpaw-x.y.z.dmg` from the [Releases](https://github.com/moerdowo/Readpaw/releases) page.
2. Before double-clicking it, run:

   ```bash
   xattr -dr com.apple.quarantine ~/Downloads/Readpaw-0.1.0.dmg
   ```

3. Double-click the DMG, drag **Readpaw** onto **Applications**.
4. Clear quarantine on the installed app once:

   ```bash
   xattr -dr com.apple.quarantine /Applications/Readpaw.app
   ```

5. Launch from Spotlight / Dock as normal.

`xattr -dr com.apple.quarantine …` removes the `com.apple.quarantine` extended attribute macOS attaches to anything downloaded from a browser. Without that attribute, Gatekeeper stops blocking the file.

### Without Terminal — System Settings flow

1. Double-click the DMG. macOS will refuse — click **Done** in the dialog (don't move it to the Bin).
2. Open **System Settings → Privacy & Security** → scroll to the security section near the bottom.
3. Click **Open Anyway** next to the Readpaw-x.y.z.dmg line, authenticate, and macOS will mount the DMG.
4. Drag **Readpaw** onto **Applications**. The first launch will need the same Privacy & Security flow — click "Done" when macOS refuses, then Open Anyway in Settings.

### No-Gatekeeper path — build from source

Local builds aren't quarantined:

```bash
git clone https://github.com/moerdowo/Readpaw.git
cd Readpaw
./scripts/build-app.sh
open build/Readpaw.app
```

## Build & run

```bash
# Quick dev launch (no .app bundle):
swift run

# Headless verification of every reader against a folder of books:
swift run Readpaw --smoke-test /path/to/books

# Build a proper .app you can drop into /Applications:
./scripts/build-app.sh
open build/Readpaw.app

# Wrap the .app in a versioned, ad-hoc-signed DMG for distribution:
./scripts/make-dmg.sh     # writes build/Readpaw-<version>.dmg

# Re-render the app icon from a different source PNG:
swift scripts/make-appicon.swift Resources/AppIcon-source.png
```

**Requirements:** macOS 15+ and the Swift 6.0 toolchain (Xcode 16 or matching Command Line Tools). The target itself is pinned to Swift 5 language mode to keep the codebase off the strict-concurrency upgrade path for now.

## Project layout

```
Sources/Readpaw/
├── ReadpawApp.swift            # @main, scenes, commands
├── SmokeTest.swift             # --smoke-test CLI harness
├── Resources/
│   └── Color_orb.usdz          # onboarding 3D model
├── Models/
│   ├── ComicItem.swift         # book metadata + per-book reading prefs
│   └── LibraryStore.swift      # scanning, persistence, thumbnails
├── Archive/
│   ├── ArchiveReader.swift     # ContentReader protocol + PageContent + factory
│   ├── PDFArchiveReader.swift  # PDFKit-backed
│   ├── TarArchiveReader.swift  # bsdtar / libarchive (zip / rar / 7z)
│   ├── EpubReader.swift        # OPF / spine parser, file-URL chapters
│   ├── MobiReader.swift        # PalmDB + PalmDOC decompression
│   ├── TxtReader.swift         # TXT / HTML / FB2 readers
│   └── EbookStyle.swift        # shared HTML chrome (typography, dark mode)
├── Views/
│   ├── OnboardingView.swift    # welcome screen + pill CTA
│   ├── USDZView.swift          # SceneKit USDZ loader, auto-rotate + drag
│   ├── LibraryView.swift       # grid of covers, search, sort
│   ├── ReaderView.swift        # reader shell + toolbar + dispatch
│   ├── PagedReaderView.swift   # NSScrollView image reader
│   ├── VerticalPagesView.swift # webtoon-style vertical scroll
│   ├── WebPageView.swift       # WKWebView wrapper for ebook content
│   ├── PageSlider.swift        # slider + key-capture host
│   └── ReaderWindowController.swift
└── Utilities/
    └── NSImage+Resize.swift
Resources/
├── Info.plist                  # bundled by build-app.sh
├── AppIcon-source.png          # 1364×1364 source artwork
├── AppIcon.icns                # generated by make-appicon.swift
└── AppIcon.iconset/            # all sizes, kept for re-bundling
scripts/
├── build-app.sh                # SwiftPM build → Readpaw.app + ad-hoc codesign
├── make-dmg.sh                 # Readpaw.app → Readpaw-<version>.dmg
└── make-appicon.swift          # squircle-masked .icns generator
```

## Notes

- Library scan walks the folder tree, skipping hidden / package contents. `__MACOSX/` entries inside zips are filtered out.
- Thumbnails are cached under `~/Library/Application Support/Readpaw/Thumbnails/` and library state lives in `~/Library/Application Support/Readpaw/library.json` next to it.
- EPUBs are extracted to `~/Library/Caches/Readpaw/Books/<uuid>/` while open and the workspace is removed when the reader closes.
- The chosen folder is stored as a security-scoped bookmark in `UserDefaults`.
- DRM'd MOBI/AZW files cannot be opened; HUFF/CDIC-compressed MOBI variants are not yet supported. Both will be silently skipped during scan now that unreadable files are filtered out.
- The app icon is the compass-in-glass-bubble image in `Resources/AppIcon-source.png`; `scripts/make-appicon.swift` masks it with the macOS Big Sur+ squircle (≈ 22.37 % corner radius) and emits an `.icns` containing every required size.

## Credits

The 3D model on the onboarding screen — [`Resources/Color_orb.usdz`](Sources/Readpaw/Resources/Color_orb.usdz) — is by **[Tamminen](https://sketchfab.com/tamminen)** on Sketchfab, used under the Creative Commons Attribution license (CC BY). Many thanks for releasing it freely.

## License

The Readpaw source code is MIT-licensed (see [`LICENSE`](LICENSE)).

The bundled `Color_orb.usdz` model retains its original CC BY license; reuse it under the same terms and credit Tamminen.
