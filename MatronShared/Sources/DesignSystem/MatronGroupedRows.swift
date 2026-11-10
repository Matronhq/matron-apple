import SwiftUI

/// Gives every row inside it the app's card colour on iPhone and iPad.
///
/// A `List` or `Form` draws its rows' default background without going
/// through the semantic colours the soft dark palette replaces (see
/// `MatronDarkAppearance`), so left alone its rows stay near-black on a
/// lighter page. Light mode resolves to the system's own colour. No effect
/// on the Mac.
public struct MatronGroupedRows<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        #if os(iOS)
        Group { content }
            .listRowBackground(Color(UIColor.secondarySystemGroupedBackground))
        #else
        content
        #endif
    }
}
