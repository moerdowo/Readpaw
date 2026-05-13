import SwiftUI
import AppKit

struct PageSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let reversed: Bool

    var body: some View {
        Slider(
            value: Binding(
                get: { reversed ? (range.upperBound - value + range.lowerBound) : value },
                set: { new in value = reversed ? (range.upperBound - new + range.lowerBound) : new }
            ),
            in: range,
            step: 1
        )
        .controlSize(.regular)
        .tint(.white)
    }
}

struct KeyEventHandlingView: NSViewRepresentable {
    let onKeyDown: (NSEvent) -> Bool

    func makeNSView(context: Context) -> KeyCatcherView {
        let v = KeyCatcherView()
        v.onKeyDown = onKeyDown
        return v
    }

    func updateNSView(_ nsView: KeyCatcherView, context: Context) {
        nsView.onKeyDown = onKeyDown
    }
}

final class KeyCatcherView: NSView {
    var onKeyDown: ((NSEvent) -> Bool)?
    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            self?.window?.makeFirstResponder(self)
        }
    }
    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true {
            return
        }
        super.keyDown(with: event)
    }
}
