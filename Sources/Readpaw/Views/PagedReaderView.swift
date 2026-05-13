import SwiftUI
import AppKit

struct PagedReaderView: View {
    @ObservedObject var model: ReaderModel

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 12) {
                pageContent(geometry: geo.size)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { location in
                handleClick(at: location, container: geo.size)
            }
        }
    }

    @ViewBuilder
    private func pageContent(geometry: CGSize) -> some View {
        if model.doublePage && model.pageCount > 1 {
            // Show two pages side by side. In RTL the order is swapped.
            let leftIndex = model.direction == .rightToLeft ? model.currentPage + 1 : model.currentPage
            let rightIndex = model.direction == .rightToLeft ? model.currentPage : model.currentPage + 1
            ZoomablePageView(model: model, pageIndex: leftIndex, displaySize: CGSize(width: geometry.width / 2, height: geometry.height))
            ZoomablePageView(model: model, pageIndex: rightIndex, displaySize: CGSize(width: geometry.width / 2, height: geometry.height))
        } else {
            ZoomablePageView(model: model, pageIndex: model.currentPage, displaySize: geometry)
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
    @State private var loadTask: Task<Void, Never>?

    var body: some View {
        Group {
            if let img = image {
                ZoomScrollView(image: img, zoomMode: model.zoomMode)
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
        .onAppear(perform: loadImage)
        .onChange(of: pageIndex) { loadImage() }
        .onDisappear { loadTask?.cancel() }
    }

    private func loadImage() {
        loadTask?.cancel()
        self.image = nil
        guard pageIndex >= 0, pageIndex < model.pageCount else { return }
        loadTask = Task { @MainActor in
            let img = await model.image(at: pageIndex)
            if !Task.isCancelled {
                self.image = img
            }
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
        if container.imageView?.image !== image {
            container.imageView?.image = image
            container.frame = NSRect(origin: .zero, size: image.size)
            container.imageView?.frame = container.bounds
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
            centerContent(scroll: scroll)
        case .fitWidth:
            let scale = viewport.width / imgSize.width
            setContent(scroll: scroll, container: container, size: imgSize, magnification: scale)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 0))
        case .fitHeight:
            let scale = viewport.height / imgSize.height
            setContent(scroll: scroll, container: container, size: imgSize, magnification: scale)
            centerContent(scroll: scroll)
        case .actual:
            setContent(scroll: scroll, container: container, size: imgSize, magnification: 1.0)
            centerContent(scroll: scroll)
        case .custom(let m):
            setContent(scroll: scroll, container: container, size: imgSize, magnification: m)
            centerContent(scroll: scroll)
        }
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
