import UIKit

/// List cell for the inverted (y-flipped) chat collection view. The collection
/// view is `scaleY(-1)`, so each cell counter-flips its `contentView` to render
/// upright. The flip MUST be re-asserted in `layoutSubviews`, not set only once at
/// cell-registration time: `UIHostingConfiguration` installs its hosting view on
/// the first layout pass and resets `contentView.transform` back to identity AFTER
/// the registration handler ran. A flip set only at registration is therefore lost
/// on first display and only "sticks" once the cell is recycled on scroll — the
/// bug where every message rendered upside-down until the user scrolled.
///
/// The flip stays on `contentView.transform` (a UIKit layer, not a SwiftUI
/// `.scaleEffect` inside the hosted row) so the row's context-menu long-press
/// preview snapshot renders upright — the reason F40 moved it off the SwiftUI
/// layer in the first place. Re-asserting only when the transform has been reset
/// to identity leaves any transform UIKit applies mid-context-menu-animation
/// untouched. `|scaleY| = 1` so self-sizing is unaffected.
final class InvertedListCell: UICollectionViewListCell {
    override func layoutSubviews() {
        super.layoutSubviews()
        // Restore the counter-flip if a layout-time reset (the hosting-config
        // install) put it back to identity. Guarding on `.isIdentity` targets
        // exactly that reset and leaves any transform UIKit applies during the
        // context-menu lift animation alone.
        if contentView.transform.isIdentity {
            contentView.transform = CGAffineTransform(scaleX: 1, y: -1)
        }
    }
}
