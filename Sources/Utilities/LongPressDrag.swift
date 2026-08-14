#if os(iOS)
import SwiftUI
import UIKit

/// UIKit long-press-then-drag layer that coexists with UIScrollView the way
/// native drag-to-reorder does: moving early scrolls (and cancels the press),
/// holding still claims the touch, fires a haptic, then tracks the drag.
/// SwiftUI's sequenced LongPress+Drag can't do this inside a ScrollView — it
/// withholds the touch and the scroll pan never starts.
///
/// `onMoved`/translation is measured in window space so it stays correct even
/// while the host view itself is being offset by the drag preview.
struct LongPressDrag: UIViewRepresentable {
    var onTap: ((CGPoint) -> Void)?
    var onBegan: (CGPoint) -> Void = { _ in }
    var onMoved: (CGPoint, CGSize) -> Void = { _, _ in }
    var onEnded: (Bool) -> Void = { _ in }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let press = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePress(_:)))
        press.minimumPressDuration = 0.35
        view.addGestureRecognizer(press)
        if onTap != nil {
            let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
            view.addGestureRecognizer(tap)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject {
        var parent: LongPressDrag
        private var startWindow: CGPoint = .zero
        init(parent: LongPressDrag) { self.parent = parent }

        @objc func handlePress(_ gesture: UILongPressGestureRecognizer) {
            let local = gesture.location(in: gesture.view)
            let window = gesture.location(in: gesture.view?.window)
            switch gesture.state {
            case .began:
                startWindow = window
                Haptics.tap()
                parent.onBegan(local)
            case .changed:
                parent.onMoved(local, CGSize(width: window.x - startWindow.x, height: window.y - startWindow.y))
            case .ended:
                parent.onEnded(true)
            default:
                parent.onEnded(false)
            }
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            parent.onTap?(gesture.location(in: gesture.view))
        }
    }
}
#endif
