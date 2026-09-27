import Foundation

/// `chat.timeline.uikit` (spec §3): which iOS chat timeline renders.
/// `true` → `ChatTimelineController` (UIKit, TextKit cells); `false` → the
/// SwiftUI `ScrollViewReader` timeline, byte-for-byte as before.
enum ChatTimelineFlag {
    static let key = "chat.timeline.uikit"

    /// Where this binary was distributed — decides the flag's default.
    enum Channel: Equatable {
        case debug
        case testFlight
        case appStore
    }

    /// On by default in Debug and TestFlight, off for the App Store until
    /// the flag has soaked (spec §3).
    static func defaultValue(for channel: Channel) -> Bool {
        switch channel {
        case .debug, .testFlight: return true
        case .appStore: return false
        }
    }

    /// TestFlight installs carry a sandbox receipt; App Store installs a
    /// production one (`receipt`); a dev-signed Release install has none.
    static func channel(isDebugBuild: Bool, receiptURL: URL?) -> Channel {
        if isDebugBuild { return .debug }
        return receiptURL?.lastPathComponent == "sandboxReceipt" ? .testFlight : .appStore
    }

    static var currentChannel: Channel {
        #if DEBUG
        let isDebugBuild = true
        #else
        let isDebugBuild = false
        #endif
        return channel(isDebugBuild: isDebugBuild, receiptURL: Bundle.main.appStoreReceiptURL)
    }

    /// The `@AppStorage` default for this binary.
    static var defaultValue: Bool { defaultValue(for: currentChannel) }
}
