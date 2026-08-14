#if os(iOS)
import SwiftUI
import UIKit

/// Touch-driven horizontal pan for the time grid, mirroring the macOS
/// trackpad side-scroll: a horizontal swipe pans the 3-page strip (with
/// momentum), re-anchoring a page at a time, while vertical swipes stay with
/// the enclosing UIScrollView. The recognizer is installed on the scroll view
/// itself and the scroll view's own pan waits for it to fail, so the two
/// arbitrate purely by initial direction.
struct SideScrollPan: UIViewRepresentable {
    let appState: AppState

    func makeUIView(context: Context) -> UIView {
        let view = AttachView()
        view.coordinator = context.coordinator
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(appState: appState) }

    /// Inert placeholder that walks up to the enclosing UIScrollView once it
    /// lands in a window and installs the pan there.
    final class AttachView: UIView {
        weak var coordinator: Coordinator?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            var v = superview
            while let cur = v, !(cur is UIScrollView) { v = cur.superview }
            if let scroll = v as? UIScrollView { coordinator?.attach(to: scroll) }
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let appState: AppState
        private weak var attachedTo: UIScrollView?
        private var displayLink: CADisplayLink?
        private var velocity: CGFloat = 0
        private var lastTick: CFTimeInterval = 0
        private var panSession = 0
        private var gestureActive = false

        init(appState: AppState) { self.appState = appState }

        func attach(to scrollView: UIScrollView) {
            guard attachedTo !== scrollView else { return }
            attachedTo = scrollView
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            pan.delegate = self
            scrollView.addGestureRecognizer(pan)
            scrollView.panGestureRecognizer.require(toFail: pan)
        }

        /// Begin only for clearly horizontal drags; failing here hands the
        /// touch straight to the scroll view's vertical pan.
        func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
            guard let pan = gesture as? UIPanGestureRecognizer, pan.view is UIScrollView else { return true }
            guard !appState.isZooming, appState.weekPageWidth > 4 else { return false }
            let t = pan.translation(in: pan.view)
            return abs(t.x) > abs(t.y) * 1.2
        }

        @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
            switch pan.state {
            case .began:
                stopDecay()
                panSession = appState.panSession
                gestureActive = true
                appState.isPanning = true
                applyPan(pan.translation(in: pan.view).x)
                pan.setTranslation(.zero, in: pan.view)
            case .changed:
                guard panSession == appState.panSession else { return }
                applyPan(pan.translation(in: pan.view).x)
                pan.setTranslation(.zero, in: pan.view)
            case .ended:
                gestureActive = false
                guard panSession == appState.panSession else { return }
                velocity = pan.velocity(in: pan.view).x
                if abs(velocity) > 50 { startDecay() } else { settle() }
            default:
                gestureActive = false
                if panSession == appState.panSession { settle() }
            }
        }

        // MARK: - Momentum

        private func startDecay() {
            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
            lastTick = CACurrentMediaTime()
        }

        private func stopDecay() {
            displayLink?.invalidate()
            displayLink = nil
        }

        @objc private func tick(_ link: CADisplayLink) {
            // Navigation (Today, go-to-date) bumps panSession; leftover
            // momentum must not re-anchor the grid it just left.
            guard panSession == appState.panSession else {
                stopDecay()
                return
            }
            let now = CACurrentMediaTime()
            let dt = now - lastTick
            lastTick = now
            applyPan(velocity * CGFloat(dt))
            velocity *= pow(UIScrollView.DecelerationRate.normal.rawValue, CGFloat(dt * 1000))
            if abs(velocity) < 20 {
                stopDecay()
                settle()
            }
        }

        // MARK: - Pan math (mirrors KeyMonitor.applyPan / settlePan on macOS)

        private func applyPan(_ dx: CGFloat) {
            var offset = appState.pan.offset + dx
            let pageWidth = appState.weekPageWidth
            let dayCount = max(1, appState.visibleDays.count)
            if pageWidth > 0 {
                while offset <= -pageWidth {
                    appState.panShiftDays(dayCount)
                    offset += pageWidth
                }
                while offset >= pageWidth {
                    appState.panShiftDays(-dayCount)
                    offset -= pageWidth
                }
            }
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { appState.pan.offset = offset }
        }

        /// End of a pan: columns rest where the swipe left them; only
        /// currentDate is re-pointed at the day nearest the visible left edge.
        private func settle() {
            if let anchor = appState.gridAnchor, appState.gridColumnWidth > 4 {
                let dayShift = Int((-appState.pan.offset / appState.gridColumnWidth).rounded())
                if dayShift != 0,
                   let visualFirst = appState.calendar.date(byAdding: .day, value: dayShift, to: anchor) {
                    appState.currentDate = visualFirst
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self, self.displayLink == nil, !self.gestureActive else { return }
                self.appState.isPanning = false
            }
        }
    }
}
#endif
