import AppKit
import Quartz

/// QuickLook preview controller for shelf items.
final class ShelfQuickLook: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate,
    @unchecked Sendable
{
    static let shared = ShelfQuickLook()
    private var url: URL?

    /// Opens QuickLook preview for the specified file URL.
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
