import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// CW&T design system tokens (cwt-design-system).
/// Ink on paper, Space Mono everywhere, hairline rules, zero radius,
/// color reserved for status. Dark mode inverts to ink-on-cerakote.
enum CWT {
    // MARK: Color

    /// Light/dark adaptive color built from two hex values.
    private static func adaptive(_ light: String, _ dark: String) -> Color {
        #if os(macOS)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(Color(hex: isDark ? dark : light) ?? .black)
        })
        #else
        return Color(uiColor: UIColor { traits in
            UIColor(Color(hex: traits.userInterfaceStyle == .dark ? dark : light) ?? .black)
        })
        #endif
    }

    /// Primary text. Near-black ink; warm paper-white in dark mode.
    static let ink = adaptive("111111", "F4F1E9")
    /// Secondary text, captions.
    static let inkSoft = adaptive("4A4A4A", "B8B5AD")
    /// Hints, disabled, gutter labels.
    static let inkFaint = adaptive("8A8A8A", "77746D")
    /// Hairline borders and grid lines.
    static let rule = adaptive("E3E3E3", "35342F")
    /// Softer internal grid lines.
    static let ruleSoft = adaptive("EFEFEF", "26251F")
    /// Page background. Black-cerakote paper in dark mode.
    static let paper = adaptive("FFFFFF", "1A1A18")
    /// Warm off-white — panels, sidebars, cards.
    static let paper2 = adaptive("F6F5F2", "22211E")
    /// A touch darker — section divides, weekend shading.
    static let paper3 = adaptive("ECECEA", "2A2925")

    /// Status accents — used sparingly (now-line, destructive, availability).
    static let signalRed = Color(hex: "D11D1D")!
    static let signalGreen = adaptive("2E7D4F", "4CAF7A")
    static let signalOrange = Color(hex: "E35A1E")!

    // MARK: Type — Space Mono, bundled

    /// Space Mono ships regular + bold only; snap intermediate weights.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .bold, .heavy, .black, .semibold: name = "SpaceMono-Bold"
        default: name = "SpaceMono-Regular"
        }
        return .custom(name, fixedSize: size)
    }
}

extension View {
    /// iOS paints `.borderedProminent` labels white regardless of tint, which is
    /// invisible on our paper-white dark-mode tint. Pair with every prominent button.
    @ViewBuilder
    func prominentLabel(_ active: Bool = true) -> some View {
        #if os(iOS)
        if active { self.foregroundStyle(CWT.paper) } else { self }
        #else
        self
        #endif
    }
}
