import SwiftUI

/// The size an AppKit view that fills whatever it is given answers
/// SwiftUI with: the proposal itself, 10 pt where a dimension is left
/// open (SwiftUI's own default).
///
/// A representable without `sizeThatFits` is measured through AppKit:
/// SwiftUI asks the hosted view for its fitting and intrinsic sizes, which
/// runs Auto Layout over the scroll view and everything in it. In the
/// window's layout passes after each sidebar update that was about two
/// thirds of the time spent measuring the split view. The lists, the
/// timeline and the item thread fill their space, so they answer at once.
enum FillingRepresentableSize {
    static func size(for proposal: ProposedViewSize) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }
}
