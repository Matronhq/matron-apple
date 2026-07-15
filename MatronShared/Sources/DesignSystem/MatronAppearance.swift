import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The in-app appearance override: follow the system, or force light/dark.
/// Persisted as its raw value in `UserDefaults` under `storageKey` — each
/// host reads it with `@AppStorage` at the app root (where it's applied)
/// and in the Device settings form (where the picker writes it), so the
/// two stay in sync through the defaults store without a settings service.
public enum MatronAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    public static let storageKey = "MatronAppearance"

    public var id: String { rawValue }

    /// Picker label.
    public var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// iOS application point — value for `.preferredColorScheme(_:)` on the
    /// root view (`nil` = follow the system).
    public var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    #if os(macOS)
    /// Mac application point — value for `NSApp.appearance` (`nil` =
    /// follow the system). Set on the app rather than per-window so the
    /// Settings scene, alerts, and menus all switch together.
    public var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
    #endif

    /// Decodes a stored raw value, tolerating an unset or stale default.
    public init(storedValue: String?) {
        self = storedValue.flatMap(MatronAppearance.init(rawValue:)) ?? .system
    }
}

/// The shared settings-form picker — one row, segmented, identical on both
/// platforms' Device forms.
public struct AppearancePicker: View {
    @AppStorage(MatronAppearance.storageKey) private var appearanceRaw =
        MatronAppearance.system.rawValue

    public init() {}

    public var body: some View {
        Picker("Appearance", selection: $appearanceRaw) {
            ForEach(MatronAppearance.allCases) { appearance in
                Text(appearance.title).tag(appearance.rawValue)
            }
        }
        .pickerStyle(.segmented)
    }
}
