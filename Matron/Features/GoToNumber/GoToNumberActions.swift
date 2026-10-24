import SwiftUI

/// What a tab asks the shell for: a number opened outright (a search
/// row's tap). The number field itself is the Search tab now.
struct GoToNumberActions {
    /// Opens what `num` names. `nil` when it opened, otherwise the reason
    /// it did not, for the caller to show.
    var open: (Int) async -> String?
}

extension EnvironmentValues {
    /// Set by `AppShellView`; `nil` (previews, tests) opens no numbers.
    @Entry var goToNumber: GoToNumberActions? = nil
}
