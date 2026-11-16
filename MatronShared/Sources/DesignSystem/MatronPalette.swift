import SwiftUI

/// Matron's product palette, ported from matron-web's bubble-layout theme
/// (`res/css/matron/_matron.pcss` in the matron-web repo):
///   - timeline background: vertical cream gradient `#f2f0ea → #e8e5dc`
///   - bot bubble: white (`--cpd-color-bg-canvas-default`)
///   - own-message bubble: light cyan `#c4f5fb`
///   - bubble shadow: `0 1px 2px rgb(18,16,14 / 0.08)`
///
/// The web app is light-only; the dark variants here are warm-neutral
/// equivalents chosen to keep the same figure/ground relationship
/// (bubbles slightly lighter than the timeline behind them).
/// The soft dark palette used on iPhone and iPad, in 0–255 sRGB. The Mac
/// keeps its own dark colours.
public enum MatronDarkSurface {
    public static let page: (Double, Double, Double) = (34, 35, 39)         // #222327
    public static let card: (Double, Double, Double) = (46, 47, 54)         // #2e2f36
    public static let raised: (Double, Double, Double) = (58, 58, 66)       // #3a3a42
    public static let ownBubble: (Double, Double, Double) = (41, 66, 82)    // #294252
    public static let accent: (Double, Double, Double) = (134, 189, 226)    // #86bde2
    public static let label: (Double, Double, Double) = (227, 225, 224)     // #e3e1e0
    public static let secondaryLabel: (Double, Double, Double) = (165, 163, 168) // #a5a3a8

    static var cardCG: (CGFloat, CGFloat, CGFloat) { (CGFloat(card.0), CGFloat(card.1), CGFloat(card.2)) }
    static var ownBubbleCG: (CGFloat, CGFloat, CGFloat) {
        (CGFloat(ownBubble.0), CGFloat(ownBubble.1), CGFloat(ownBubble.2))
    }
}

public extension Color {
    static let matronTimelineTop = adaptive(
        light: (242, 240, 234), dark: (29, 27, 24),
        iPhoneDark: MatronDarkSurface.page)               // #f2f0ea
    static let matronTimelineBottom = adaptive(
        light: (232, 229, 220), dark: (23, 21, 18),
        iPhoneDark: MatronDarkSurface.page)               // #e8e5dc
    static let matronBubbleBot = adaptive(
        light: (255, 255, 255), dark: (38, 36, 33),
        iPhoneDark: MatronDarkSurface.card)               // canvas white
    static let matronBubbleMe = adaptive(
        light: (196, 245, 251), dark: (18, 58, 65),
        iPhoneDark: MatronDarkSurface.ownBubble)          // #c4f5fb
    /// `rgb(18,16,14 / 0.08)` — warm near-black at 8%.
    static let matronBubbleShadow = Color(
        red: 18 / 255, green: 16 / 255, blue: 14 / 255).opacity(0.08)

    /// Matron's brand accent for interactive chrome (answer chips, Send
    /// buttons): a teal from the own-bubble cyan family, replacing the
    /// system blue `Color.accentColor` that read foreign against the warm
    /// cream palette. Light: deep teal legible on the white card; dark:
    /// brightened cyan legible on the warm-dark surfaces.
    static let matronAccent = adaptive(
        light: (11, 110, 125), dark: (110, 205, 220),
        iPhoneDark: MatronDarkSurface.accent)

    /// A plain `List` row's background: the page colour, so rows sit flush
    /// with the header and section headers around them. A plain row with
    /// swipe actions otherwise draws the system's own cell colour, which
    /// the soft dark palette does not reach. Light: white, as the system's.
    static let matronPlainRow = adaptive(
        light: (255, 255, 255), dark: (0, 0, 0),
        iPhoneDark: MatronDarkSurface.page)

    /// Builds a light/dark adaptive color from 0–255 sRGB components.
    /// `iPhoneDark` replaces `dark` on iPhone and iPad, whose dark mode uses
    /// the softer palette (`MatronDarkSurface`).
    private static func adaptive(
        light: (Double, Double, Double), dark: (Double, Double, Double),
        iPhoneDark: (Double, Double, Double)
    ) -> Color {
        #if canImport(UIKit) && !os(macOS)
        return Color(UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? iPhoneDark : light
            return UIColor(red: c.0 / 255, green: c.1 / 255, blue: c.2 / 255, alpha: 1)
        })
        #elseif os(macOS)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.0 / 255, green: c.1 / 255, blue: c.2 / 255, alpha: 1)
        })
        #endif
    }
}

/// The chat timeline's cream backdrop — matron-web's
/// `--matron-room-timeline-background` gradient. Drop behind the whole
/// chat column (timeline + composer) so bubbles and the composer's
/// material both sit on the same warm ground.
public struct MatronTimelineBackground: View {
    public init() {}

    public var body: some View {
        LinearGradient(
            colors: [.matronTimelineTop, .matronTimelineBottom],
            startPoint: .top, endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}

#if canImport(UIKit) && !os(macOS)
/// UIKit twins of the bubble palette for the UIKit chat timeline — the same
/// components as the `Color` statics above (`TextMessageCellTests` pins it).
public extension UIColor {
    static let matronBubbleBot = matronAdaptive(light: (255, 255, 255), dark: MatronDarkSurface.cardCG)
    static let matronBubbleMe = matronAdaptive(light: (196, 245, 251), dark: MatronDarkSurface.ownBubbleCG)
    /// `rgb(18,16,14 / 0.08)` — warm near-black at 8%.
    static let matronBubbleShadow = UIColor(red: 18 / 255, green: 16 / 255, blue: 14 / 255, alpha: 0.08)

    private static func matronAdaptive(light: (CGFloat, CGFloat, CGFloat),
                                       dark: (CGFloat, CGFloat, CGFloat)) -> UIColor {
        UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0 / 255, green: c.1 / 255, blue: c.2 / 255, alpha: 1)
        }
    }
}
#endif
