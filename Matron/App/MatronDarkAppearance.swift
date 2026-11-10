import UIKit
import ObjectiveC
import MatronDesignSystem

/// Softens the app's dark mode on iPhone and iPad.
///
/// Most screens take their backgrounds from the system: a `List`, a `Form`,
/// a sheet and a navigation stack all draw near-black in dark mode, and none
/// of them offers one place to change it. So the app replaces the system's
/// semantic background and label colours, for itself and in dark mode only.
/// Light mode gets the system colours untouched. If a future iOS stops
/// reading these, the app simply goes back to the system's dark colours.
enum MatronDarkAppearance {
    private static var installed = false

    /// Call once at launch, before any UI is built.
    static func install() {
        guard !installed else { return }
        installed = true
        for (selector, surface) in overrides {
            replace(selector, dark: uiColor(surface))
        }
    }

    private static let overrides: [(Selector, (Double, Double, Double))] = [
        (#selector(getter: UIColor.systemBackground), MatronDarkSurface.page),
        (#selector(getter: UIColor.secondarySystemBackground), MatronDarkSurface.card),
        (#selector(getter: UIColor.tertiarySystemBackground), MatronDarkSurface.raised),
        (#selector(getter: UIColor.systemGroupedBackground), MatronDarkSurface.page),
        (#selector(getter: UIColor.secondarySystemGroupedBackground), MatronDarkSurface.card),
        (#selector(getter: UIColor.tertiarySystemGroupedBackground), MatronDarkSurface.raised),
        (#selector(getter: UIColor.label), MatronDarkSurface.label),
        (#selector(getter: UIColor.secondaryLabel), MatronDarkSurface.secondaryLabel),
    ]

    static func uiColor(_ surface: (Double, Double, Double)) -> UIColor {
        UIColor(red: surface.0 / 255, green: surface.1 / 255, blue: surface.2 / 255, alpha: 1)
    }

    private static func replace(_ selector: Selector, dark: UIColor) {
        guard let method = class_getClassMethod(UIColor.self, selector) else { return }
        typealias Getter = @convention(c) (AnyClass, Selector) -> UIColor
        let system = unsafeBitCast(method_getImplementation(method), to: Getter.self)(UIColor.self, selector)
        let color = UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : system.resolvedColor(with: traits)
        }
        let block: @convention(block) (AnyClass) -> UIColor = { _ in color }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }
}
