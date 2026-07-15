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
public extension Color {
    static let matronTimelineTop = adaptive(
        light: (242, 240, 234), dark: (29, 27, 24))       // #f2f0ea
    static let matronTimelineBottom = adaptive(
        light: (232, 229, 220), dark: (23, 21, 18))       // #e8e5dc
    static let matronBubbleBot = adaptive(
        light: (255, 255, 255), dark: (38, 36, 33))       // canvas white
    static let matronBubbleMe = adaptive(
        light: (196, 245, 251), dark: (18, 58, 65))       // #c4f5fb
    /// `rgb(18,16,14 / 0.08)` — warm near-black at 8%.
    static let matronBubbleShadow = Color(
        red: 18 / 255, green: 16 / 255, blue: 14 / 255).opacity(0.08)

    /// Matron's brand accent for interactive chrome (answer chips, Send
    /// buttons): a teal from the own-bubble cyan family, replacing the
    /// system blue `Color.accentColor` that read foreign against the warm
    /// cream palette. Light: deep teal legible on the white card; dark:
    /// brightened cyan legible on the warm-dark surfaces.
    static let matronAccent = adaptive(
        light: (11, 110, 125), dark: (110, 205, 220))

    /// Builds a light/dark adaptive color from 0–255 sRGB components.
    private static func adaptive(
        light: (Double, Double, Double), dark: (Double, Double, Double)
    ) -> Color {
        #if canImport(UIKit) && !os(macOS)
        return Color(UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
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
