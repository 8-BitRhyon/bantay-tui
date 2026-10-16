import SwiftUI

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

extension Color {
    public init(flxLight light: Color, dark: Color) {
        #if os(macOS)
            self.init(
                nsColor: NSColor(name: nil) { appearance in
                    switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
                    case .darkAqua: NSColor(dark)
                    default: NSColor(light)
                    }
                })
        #else
            self.init(
                uiColor: UIColor { traits in
                    traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
                })
        #endif
    }
}
