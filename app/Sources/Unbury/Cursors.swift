import SwiftUI
import AppKit

extension View {
    /// Add pointing-hand cursor on hover for interactive elements.
    func clickable() -> some View {
        self.onHover { inside in
            if inside {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}
