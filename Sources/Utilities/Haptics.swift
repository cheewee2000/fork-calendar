import Foundation
#if os(iOS)
import UIKit
#endif

/// Light haptic when a long-press interaction activates (iOS only).
enum Haptics {
    static func tap() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
    }
}
