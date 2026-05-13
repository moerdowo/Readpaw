import SwiftUI
import AppKit

struct PagedReaderView: View {
    @ObservedObject var model: ReaderModel

    var body: some View {
        GeometryReader { geo in
            ZoomablePageView(model: model,
                             pageIndex: model.currentPage,
                             displaySize: geo.size)
                // Tie SwiftUI view identity to the current page so each page
                // change tears down the previous ZoomScrollView and builds a
                // fresh NSScrollView. Without this, pinch-zoom magnification
                // can leak across pages because the underlying scroll view
                // is reused.
                .id(model.currentPage)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { location in
                    handleClick(at: location, container: geo.size)
                }
        }
    }

    private func handleClick(at location: CGPoint, container: CGSize) {
        // Tap-to-page: tap on right third goes next (in LTR), left third goes prev.
        let third = container.width / 3
        if location.x < third {
            model.direction == .rightToLeft ? model.goNext() : model.goPrev()
        } else if location.x > container.width - third {
            model.direction == .rightToLeft ? model.goPrev() : model.goNext()
        }
    }
}

struct ZoomablePageView: View {
    @ObservedObject var model: ReaderModel
    let pageIndex: Int
    let displaySize: CGSize

    @State private var image: NSImage?
    @State private var placeholder: NSImage?

    var body: some View {
        Group {
            if let img = image {
                ZoomScrollView(image: img, zoomMode: model.zoomMode)
            } else if let placeholder = placeholder {
                // Show the cached cover thumbnail (already on disk) as a soft,
                // slightly-blurred placeholder while the real first page
                // decodes — so the reader never opens to an empty spinner.
                ZStack {
                    Image(nsImage: placeholder)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fit)
                        .blur(radius: 6)
                        .opacity(0.65)
                    ProgressView()
                        .controlSize(.large)
                        .tint(model.backgroundDark ? .white : .black)
                }
            } else {
                ZStack {
                    Color.clear
                    ProgressView()
                        .controlSize(.large)
                        .tint(model.backgroundDark ? .white : .black)
                }
            }
        }
        .frame(width: displaySize.width, height: displaySize.height)
        .clipped()
        // .task(id:) cancels and restarts the decode when pageIndex changes,
        // and runs reliably on first appearance (unlike .onAppear which has
        // ordering quirks inside GeometryReader).
        .task(id: pageIndex) {
            await loadCurrent()
        }
    }

    @MainActor
    private func loadCurrent() async {
        image = nil
        // Only the first page gets a cover placeholder — for subsequent
        // pages the prefetch usually has them ready before the task even runs.
        placeholder = (pageIndex == 0) ? model.coverThumbnail() : nil
        guard pageIndex >= 0, pageIndex < model.pageCount else { return }
        let img = await model.image(at: pageIndex)
        if !Task.isCancelled, img != nil {
            image = img
        }
    }
}

struct ZoomScrollView: NSViewRepresentable {
    let image: NSImage
    let zoomMode: ZoomMode

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.1
        scroll.maxMagnification = 8.0
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.backgroundColor = .clear
        scroll.drawsBackground = false

        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.image = image
        imageView.frame = NSRect(origin: .zero, size: image.size)
        imageView.wantsLayer = true

        let clipped = FlippedClipContainer()
        clipped.frame = imageView.frame
        clipped.addSubview(imageView)
        clipped.imageView = imageView

        scroll.documentView = clipped
        context.coordinator.scrollView = scroll
        context.coordinator.container = clipped
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let container = context.coordinator.container else { return }
        let imageChanged = container.imageView?.image !== image
        if imageChanged {
            container.imageView?.image = image
            container.frame = NSRect(origin: .zero, size: image.size)
            container.imageView?.frame = container.bounds
            // Reset any previous pinch-zoom synchronously so the new page
            // doesn't paint at the old page's magnification. The async pass
            // below refines the layout once the contentView bounds settle.
            applyZoom(scroll: scroll, container: container)
        }
        DispatchQueue.main.async {
            applyZoom(scroll: scroll, container: container)
        }
    }

    private func applyZoom(scroll: NSScrollView, container: FlippedClipContainer) {
        let imgSize = image.size
        guard imgSize.width > 0, imgSize.height > 0 else { return }
        let viewport = scroll.contentView.bounds.size
        guard viewport.width > 0, viewport.height > 0 else { return }

        switch zoomMode {
        case .fitPage:
            let scale = min(viewport.width / imgSize.width, viewport.height / imgSize.height)
            setContent(scroll: scroll, container: container, size: imgSize, magnification: scale)
            // The whole page fits; align top-left so a tall page that just
            // barely overshoots height-wise still shows the top.
            scrollToTopLeft(scroll: scroll, container: container)
        case .fitWidth:
            let scale = viewport.width / imgSize.width
            setContent(scroll: scroll, container: container, size: imgSize, magnification: scale)
            scrollToTopLeft(scroll: scroll, container: container)
        case .fitHeight:
            let scale = viewport.height / imgSize.height
            setContent(scroll: scroll, container: container, size: imgSize, magnification: scale)
            // Centered horizontally is the conventional fit-height behaviour,
            // but we still want vertical top.
            scrollToTopCenterX(scroll: scroll, container: container)
        case .actual:
            setContent(scroll: scroll, container: container, size: imgSize, magnification: 1.0)
            scrollToTopLeft(scroll: scroll, container: container)
        case .custom(let m):
            setContent(scroll: scroll, container: container, size: imgSize, magnification: m)
            scrollToTopLeft(scroll: scroll, container: container)
        }
    }

    /// Anchor the document view to (0, 0) in scroll coordinates so a fresh
    /// page always opens at its top-left corner.
    private func scrollToTopLeft(scroll: NSScrollView, container: FlippedClipContainer) {
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// Keep the page horizontally centred (helpful when fit-height leaves
    /// extra width) while still anchoring to the top vertically.
    private func scrollToTopCenterX(scroll: NSScrollView, container: FlippedClipContainer) {
        guard let doc = scroll.documentView else { return }
        let mag = scroll.magnification
        let docWidthInPoints = doc.frame.width
        let viewportWidth = scroll.contentView.bounds.width
        let unscaledExcess = max(0, docWidthInPoints - viewportWidth / mag) / 2
        scroll.contentView.scroll(to: NSPoint(x: unscaledExcess, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func setContent(scroll: NSScrollView, container: FlippedClipContainer, size: CGSize, magnification: CGFloat) {
        container.frame = NSRect(origin: .zero, size: size)
        container.imageView?.frame = container.bounds
        scroll.magnification = magnification
    }

    private func centerContent(scroll: NSScrollView) {
        guard let doc = scroll.documentView else { return }
        let mag = scroll.magnification
        let docSize = NSSize(width: doc.frame.width * mag, height: doc.frame.height * mag)
        let viewport = scroll.contentView.bounds.size
        let x = max(0, (docSize.width / mag - viewport.width) / 2)
        let y = max(0, (docSize.height / mag - viewport.height) / 2)
        scroll.contentView.scroll(to: NSPoint(x: x, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    final class Coordinator {
        weak var scrollView: NSScrollView?
        weak var container: FlippedClipContainer?
    }
}

final class FlippedClipContainer: NSView {
    weak var imageView: NSImageView?
    override var isFlipped: Bool { true }
}
