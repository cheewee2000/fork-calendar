import SwiftUI
import CoreText
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// CW&T design system tokens, restyled to match Knife Terminal:
/// Helvetica Now Text for the chrome, JetBrains Mono for the hour gutter,
/// Ghostty's stock dark palette and its "Tomorrow" light sibling, hairline
/// rules, zero radius, color reserved for status.
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

    /// Primary text. Tomorrow's charcoal; white on Ghostty's dark.
    static let ink = adaptive("4D4D4C", "FFFFFF")
    /// Secondary text, captions. ≥4.5:1 on paper in both modes (HIG).
    static let inkSoft = adaptive("6B6D70", "C5C8C6")
    /// Hints, disabled, gutter labels. Both modes clear 4.5:1 on paper (HIG).
    static let inkFaint = adaptive("767676", "9AA0AB")
    /// Hairline borders and grid lines.
    static let rule = adaptive("E0E0E0", "3D424D")
    /// Softer internal grid lines.
    static let ruleSoft = adaptive("EFEFEF", "33383F")
    /// Page background. Ghostty's blue-grey in dark mode.
    static let paper = adaptive("FFFFFF", "282C34")
    /// Panels, sidebars, cards.
    static let paper2 = adaptive("F7F7F7", "2E323B")
    /// A touch darker — section divides, weekend shading.
    static let paper3 = adaptive("EEEEEE", "343945")

    /// Chrome highlight — Tomorrow blue / Ghostty periwinkle.
    static let accent = adaptive("4271AE", "B2B9F4")

    /// Status accents — used sparingly (now-line, destructive, availability).
    static let signalRed = adaptive("C82829", "CC6666")
    static let signalGreen = adaptive("718C00", "B5BD68")
    /// "Needs you" orange, the terminal's attention color.
    static let signalOrange = adaptive("F5871F", "DE935F")

    // MARK: Type

    /// Helvetica Now Text is a licensed font and isn't in the repo. Drop the
    /// two .otf files into Sources/Fonts and they ride along in the bundle
    /// (macOS registers them via ATSApplicationFontsPath; iOS registers them
    /// here, since they're deliberately not listed under UIAppFonts so a
    /// checkout without them still builds). Without them the chrome falls
    /// back to the system font.
    static let helveticaNow: Bool = {
        #if os(iOS)
        let urls = (Bundle.main.urls(forResourcesWithExtension: "otf", subdirectory: nil) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("HelveticaNow") }
        if !urls.isEmpty {
            CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil)
        }
        return UIFont(name: "HelveticaNowText-Regular", size: 12) != nil
        #else
        return NSFont(name: "HelveticaNowText-Regular", size: 12) != nil
        #endif
    }()

    /// Chrome type: Helvetica Now Text, Medium for emphasis.
    static func ui(_ size: CGFloat, bold: Bool = false) -> Font {
        if helveticaNow {
            return .custom(bold ? "HelveticaNowText-Medium" : "HelveticaNowText-Regular", fixedSize: size)
        }
        return .system(size: size, weight: bold ? .medium : .regular)
    }

    /// Grid type: JetBrains Mono (bundled, OFL) for hour labels.
    static func mono(_ size: CGFloat, bold: Bool = false) -> Font {
        .custom(bold ? "JetBrainsMono-Bold" : "JetBrainsMono-Regular", fixedSize: size)
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

// MARK: - Controls

/// Knife's foot-button look: square, 1px-bordered, chrome type; hover tints,
/// press darkens, `on` inverts (ink fill, paper text). Shared by
/// `CWTButtonStyle` and `cwtFace()` so a `Menu` label matches the buttons.
struct CWTFace: ViewModifier {
    var on = false
    var size: CGFloat = 12
    var pressed = false
    @Environment(\.isEnabled) private var isEnabled
    @State private var hover = false

    func body(content: Content) -> some View {
        content
            .font(CWT.ui(size)).lineLimit(1)
            // Not fixed horizontally, so a label with `.frame(maxWidth: .infinity)`
            // can still fill its row.
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(on ? CWT.paper : CWT.ink)
            .padding(.horizontal, 10).padding(.vertical, 5)
            // HIG macOS minimum hit target.
            .frame(minHeight: 24)
            .background(on ? CWT.ink.opacity(pressed ? 0.7 : 0.9)
                           : CWT.ink.opacity(pressed ? 0.16 : hover && isEnabled ? 0.07 : 0))
            .overlay(Rectangle().stroke(CWT.ink.opacity(on ? 0.9 : 0.35), lineWidth: 1))
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { hover = $0 }
    }
}

struct CWTButtonStyle: ButtonStyle {
    var on = false
    var size: CGFloat = 12

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(CWTFace(on: on, size: size, pressed: configuration.isPressed))
    }
}

extension ButtonStyle where Self == CWTButtonStyle {
    static var cwt: CWTButtonStyle { CWTButtonStyle() }
    static func cwt(on: Bool = false, size: CGFloat = 12) -> CWTButtonStyle {
        CWTButtonStyle(on: on, size: size)
    }
}

extension View {
    /// The `CWTButtonStyle` face for non-button views, e.g. a `Menu` label.
    func cwtFace(on: Bool = false, size: CGFloat = 12) -> some View {
        modifier(CWTFace(on: on, size: size))
    }
}
