import AppKit
import Quartz

/// QuickLook preview for a shelf file (Phase A A3). Wraps `QLPreviewPanel`
/// so a double-click or the eye button previews the file without launching
/// its app. One shared data source; the panel is ordered front when a new
/// file is shown. UI singleton — all access is on the main thread, so it's
/// marked @unchecked Sendable (satisfies both Swift 6.1 and 6.3 compilers).
final class ShelfQuickLook: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate,
    @unchecked Sendable
{
    static let shared = ShelfQuickLook()
    private var url: URL?

    /// Show QuickLook for `url`, bringing the panel to front. The panel is
    /// driven entirely through its data source/delegate, so both must be set
    /// before ordering front or it opens blank. Always invoked from the main
    /// thread (view actions), so assumeIsolated is safe.
    static func show(_ url: URL) {
        MainActor.assumeIsolated {
            shared.url = url
            guard let panel = QLPreviewPanel.shared() else { return }
            panel.dataSource = shared
            panel.delegate = shared
            if panel.isVisible {
                panel.reloadData()
            } else {
                panel.makeKeyAndOrderFront(nil)
            }
        }
    }

    // MARK: - QLPreviewPanelDataSource

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        url == nil ? 0 : 1
    }

    func previewPanel(
        _ panel: QLPreviewPanel!, previewItemAt index: Int
    ) -> QLPreviewItem! {
        url as NSURL?
    }

    // MARK: - QLPreviewPanelDelegate

    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!)
        -> NSRect
    {
        .zero
    }
}
