import AppKit
import Quartz

/// QuickLook preview for a shelf file (Phase A A3). Wraps `QLPreviewPanel`
/// so a double-click or the eye button previews the file without launching
/// its app. One shared data source; the panel is ordered front when a new
/// file is shown.
@MainActor
final class ShelfQuickLook: NSObject, @preconcurrency QLPreviewPanelDataSource,
    @preconcurrency QLPreviewPanelDelegate
{
    static let shared = ShelfQuickLook()
    private var url: URL?

    /// Show QuickLook for `url`, bringing the panel to front. The panel is
    /// driven entirely through its data source/delegate, so both must be set
    /// before ordering front or it opens blank.
    static func show(_ url: URL) {
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
