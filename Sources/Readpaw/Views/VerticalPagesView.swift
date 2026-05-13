import SwiftUI
import AppKit

struct VerticalPagesView: View {
    @ObservedObject var model: ReaderModel
    @State private var currentVisible: Int = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 0) {
                    ForEach(0..<model.pageCount, id: \.self) { idx in
                        VerticalPageRow(model: model, pageIndex: idx)
                            .id(idx)
                            .onAppear {
                                if abs(idx - model.currentPage) <= 1 {
                                    return
                                }
                                model.setPage(idx)
                            }
                    }
                }
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    withAnimation(.none) {
                        proxy.scrollTo(model.currentPage, anchor: .top)
                    }
                }
            }
            .onChange(of: model.currentPage) { _, newPage in
                if !VerticalScrollState.isUserScrolling {
                    proxy.scrollTo(newPage, anchor: .top)
                }
            }
        }
    }
}

enum VerticalScrollState {
    static var isUserScrolling: Bool = false
}

struct VerticalPageRow: View {
    @ObservedObject var model: ReaderModel
    let pageIndex: Int
    @State private var image: NSImage?
    @State private var loadTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geo in
            content(viewportWidth: geo.size.width)
                .frame(maxWidth: .infinity)
        }
        .frame(height: rowHeight)
        .onAppear(perform: loadImage)
        .onDisappear { loadTask?.cancel() }
    }

    private var rowHeight: CGFloat {
        guard let img = image, img.size.width > 0 else { return 800 }
        // We don't know viewport width at this point; assume window width 1000.
        let aspect = img.size.height / img.size.width
        return min(2400, max(400, 1000 * aspect))
    }

    @ViewBuilder
    private func content(viewportWidth: CGFloat) -> some View {
        if let img = image {
            let aspect = img.size.width > 0 ? img.size.height / img.size.width : 1
            Image(nsImage: img)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: viewportWidth, height: viewportWidth * aspect)
        } else {
            ZStack {
                Color.clear
                ProgressView()
                    .tint(model.backgroundDark ? .white : .black)
            }
        }
    }

    private func loadImage() {
        loadTask?.cancel()
        loadTask = Task { @MainActor in
            let img = await model.image(at: pageIndex)
            if !Task.isCancelled {
                self.image = img
            }
        }
    }
}
