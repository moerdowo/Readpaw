import SwiftUI
import AppKit

struct PagedReaderView: View {
    @ObservedObject var model: ReaderModel

    var body: some View {
        GeometryReader { geo in
            ZoomablePageView(model: model,
                             pageIndex: model.currentPage,
                             displaySize: geo.size)
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
                // Keep the same ZoomScrollView (and the same underlying
                // NSScrollView) across page changes — so a pinch zoom the
                // user has done persists into the next page, and there's no
                // tear-down/rebuild flash when flipping pages.
                ZoomScrollView(
                    image: img,
                    zoomMode: model.zoomMode,
                    onUserMagnify: { mag in
                        // Capture the pinch into the model so the next page
                        // (which goes through applyZoom on image swap)
                        // continues at the same magnification.
                        model.zoomMode = .custom(mag)
                    }
                )
            } else if let placeholder = placeholder {
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
        .task(id: pageIndex) {
            await loadCurrent()
        }
    }

    @MainActor
    private func loadCurrent() async {
        // Important: do NOT clear `image` before the new one is ready. Holding
        // the previous page visible until the next decode completes means
        // SwiftUI never has to fall back to the placeholder branch on a page
        // turn (which would cause a flash of the cover thumbnail in
        // windowed mode), and ZoomScrollView stays mounted the whole time so
        // updateNSView can swap the image in place.
        if image == nil {
            placeholder = (pageIndex == 0) ? model.coverThumbnail() : nil
        }
        guard pageIndex >= 0, pageIndex < model.pageCount else { return }
        let img = await model.image(at: pageIndex)
        if !Task.isCancelled, let img {
            image = img
            placeholder = nil
        }
    }
}

struct ZoomScrollView: NSViewRepresentable {
    let image: NSImage
    let zoomMode: ZoomMode
    let onUserMagnify: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onUserMagnify: onUserMagnify) }

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
        context.coordinator.lastImage = image
        context.coordinator.lastZoomMode = zoomMode

        // Capture user pinch-zoom — when the pinch settles, push the chosen
        // magnification back to the model so it persists into the next page
        // (and so the toolbar's zoom menu reflects reality).
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.didEndLiveMagnify(_:)),
            name: NSScrollView.didEndLiveMagnifyNotification,
            object: scroll
        )

        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let container = context.coordinator.container else { return }
        let coord = context.coordinator
        coord.onUserMagnify = onUserMagnify

        let imageChanged = coord.lastImage !== image
        let zoomModeChanged = coord.lastZoomMode != zoomMode

        if imageChanged {
            coord.lastImage = image
            container.imageView?.image = image
            container.frame = NSRect(origin: .zero, size: image.size)
            container.imageView?.frame = container.bounds
            // New page: apply the (book-level) zoom and snap scroll to top
            // immediately so we never paint at the previous page's scroll
            // position. The async pass below catches the case where the
            // contentView bounds aren't valid yet.
            applyZoom(scroll: scroll, container: container, resetScroll: true)
            DispatchQueue.main.async {
                applyZoom(scroll: scroll, container: container, resetScroll: true)
            }
        }

        if zoomModeChanged {
            coord.lastZoomMode = zoomMode
            if coord.suppressNextZoomApply {
                // The user just finished pinching — we updated the model to
                // mirror their magnification, but we don't want to clobber
                // the scroll position by re-running applyZoom right after.
                coord.suppressNextZoomApply = false
            } else if !imageChanged {
                // Toolbar zoom-mode change on the current page. Apply the
                // new magnification without resetting scroll position so the
                // user's reading spot is preserved (only fitPage centres,
                // others just rescale around the current view).
                DispatchQueue.main.async {
                    applyZoom(scroll: scroll, container: container, resetScroll: false)
                }
            }
        }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator,
                                                   name: NSScrollView.didEndLiveMagnifyNotification,
                                                   object: scroll)
    }

    private func applyZoom(scroll: NSScrollView,
                            container: FlippedClipContainer,
                            resetScroll: Bool) {
        let imgSize = image.size
        guard imgSize.width > 0, imgSize.height > 0 else { return }
        // Use the clip view's *frame* (in screen pixels), not its bounds.
        // NSClipView.bounds is in document coordinates and scales inversely
        // with magnification — feeding it back into the fit-* formulas
        // creates a loop where each page-turn computes a magnification that
        // depends on the previous one, so the image drifts smaller (or
        // larger) every page. Fall back to the scroll view's own bounds if
        // the clip view hasn't been tiled yet.
        var viewport = scroll.contentView.frame.size
        if viewport.width <= 0 || viewport.height <= 0 {
            viewport = scroll.bounds.size
        }
        guard viewport.width > 0, viewport.height > 0 else { return }

        switch zoomMode {
        case .fitPage:
            let scale = min(viewport.width / imgSize.width, viewport.height / imgSize.height)
            setContent(scroll: scroll, container: container, size: imgSize, magnification: scale)
            if resetScroll { scrollToTopLeft(scroll: scroll) }
        case .fitWidth:
            let scale = viewport.width / imgSize.width
            setContent(scroll: scroll, container: container, size: imgSize, magnification: scale)
            if resetScroll { scrollToTopLeft(scroll: scroll) }
        case .fitHeight:
            let scale = viewport.height / imgSize.height
            setContent(scroll: scroll, container: container, size: imgSize, magnification: scale)
            if resetScroll { scrollToTopCenterX(scroll: scroll) }
        case .actual:
            setContent(scroll: scroll, container: container, size: imgSize, magnification: 1.0)
            if resetScroll { scrollToTopLeft(scroll: scroll) }
        case .custom(let m):
            setContent(scroll: scroll, container: container, size: imgSize, magnification: m)
            if resetScroll { scrollToTopLeft(scroll: scroll) }
        }
    }

    private func scrollToTopLeft(scroll: NSScrollView) {
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func scrollToTopCenterX(scroll: NSScrollView) {
        guard let doc = scroll.documentView else { return }
        let mag = scroll.magnification
        // Convert the viewport width (screen pixels) into document coords
        // exactly once, instead of double-dividing by mag.
        let viewportWidthScreen = scroll.contentView.frame.width
        let viewportWidthDoc = mag > 0 ? viewportWidthScreen / mag : viewportWidthScreen
        let excessDoc = max(0, doc.frame.width - viewportWidthDoc) / 2
        scroll.contentView.scroll(to: NSPoint(x: excessDoc, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func setContent(scroll: NSScrollView,
                             container: FlippedClipContainer,
                             size: CGSize,
                             magnification: CGFloat) {
        container.frame = NSRect(origin: .zero, size: size)
        container.imageView?.frame = container.bounds
        scroll.magnification = magnification
    }

    final class Coordinator: NSObject {
        weak var scrollView: NSScrollView?
        weak var container: FlippedClipContainer?
        var lastImage: NSImage?
        var lastZoomMode: ZoomMode = .fitPage
        var onUserMagnify: (CGFloat) -> Void
        var suppressNextZoomApply: Bool = false

        init(onUserMagnify: @escaping (CGFloat) -> Void) {
            self.onUserMagnify = onUserMagnify
        }

        @objc func didEndLiveMagnify(_ notification: Notification) {
            guard let scroll = notification.object as? NSScrollView else { return }
            let mag = scroll.magnification
            // We're about to push this magnification onto the model, which
            // will come back through updateNSView as a zoomMode change.
            // Suppress that re-apply so the scroll position the user just
            // pinched into isn't reset under them.
            suppressNextZoomApply = true
            let callback = onUserMagnify
            DispatchQueue.main.async {
                callback(mag)
            }
        }
    }
}

final class FlippedClipContainer: NSView {
    weak var imageView: NSImageView?
    override var isFlipped: Bool { true }
}
