import AppKit
import SwiftUI

/// In-memory model feeding the peek overlay's SwiftUI root. The panel root
/// observes this so a late-arriving tail/diff fetch can populate the overlay
/// after it has been shown.
final class PeekPanelModel: ObservableObject {
    @Published var source: String = ""
    @Published var tailLines: [String] = []
    @Published var diffPreview: String?
    @Published var isLoading = false
}

/// One-at-a-time overlay showing a full `pane read` tail (≤ 200 lines,
/// scrollable) plus a `git diff --stat` preview for an agent's cwd. Esc and
/// outside-click dismiss; in-flight fetches are cancelled on dismiss so rapid
/// open/close cycles can never stack results (mirrors `endPeek`).
@MainActor
final class PeekPanelController: NSObject, NSWindowDelegate {
    static let shared = PeekPanelController()

    private var panel: NSPanel?
    private let model = PeekPanelModel()
    private var fetchTask: Task<Void, Never>?
    private var clickMonitor: Any?
    private var keyMonitor: Any?

    var isVisible: Bool { panel?.isVisible ?? false }

    private override init() {
        super.init()
    }

    /// Show the overlay docked beside the island for `agent`. One overlay at a
    /// time: when already visible, the existing panel re-points at `agent`.
    func show(agent: AgentSnapshot, adapter: HerdrSocketAdapter) {
        if let panel, panel.isVisible {
            reload(agent: agent, adapter: adapter)
            return
        }
        guard let window = AppDelegate.window,
            let screen = window.screen ?? NSScreen.main
        else { return }
        let contentSize = CGSize(width: 480, height: 420)
        let frame = IslandMetrics.peekFrame(
            anchor: window.frame, screenFrame: screen.frame, size: contentSize,
            scale: screen.backingScaleFactor)
        let panel = KeyablePanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.level = .init(rawValue: Int(Int32.max - 3))
        panel.collectionBehavior = [
            .fullScreenAuxiliary,
            .stationary,
            .canJoinAllSpaces,
            .ignoresCycle,
        ]
        panel.hidesOnDeactivate = false
        panel.delegate = self
        let hosting = NSHostingController(rootView: PeekPanelView(model: model))
        hosting.sizingOptions = []
        panel.contentViewController = hosting
        self.panel = panel
        installDismissMonitors()
        panel.orderFrontRegardless()
        reload(agent: agent, adapter: adapter)
    }

    func dismiss() {
        fetchTask?.cancel()
        fetchTask = nil
        removeDismissMonitors()
        panel?.orderOut(nil)
        panel = nil
    }

    /// Fetch the tail + diff off the main actor, cancelling any in-flight
    /// fetch for the previous agent. Detached so the adapter's socket/CLI I/O
    /// never touches the main thread; the result lands back on the main actor.
    private func reload(agent: AgentSnapshot, adapter: HerdrSocketAdapter) {
        fetchTask?.cancel()
        model.source = agent.source
        model.tailLines = []
        model.diffPreview = nil
        model.isLoading = true
        let paneId = agent.paneId
        let cwd = agent.cwd
        let source = agent.source
        fetchTask = Task.detached {
            let tail: [String]
            if let paneId {
                let raw = await adapter.captureTail(paneId: paneId, lines: 200)
                tail = LogFormatter.cleanedTail(raw, maxLines: 200, maxLineLength: 240)
            } else {
                tail = []
            }
            let diff: String?
            if let cwd {
                diff = await adapter.captureDiff(cwd: cwd)
            } else {
                diff = nil
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self.model.source == source else { return }
                self.model.tailLines = tail
                self.model.diffPreview = diff
                self.model.isLoading = false
            }
        }
    }

    // MARK: - Dismissal (Esc + outside-click)

    private func installDismissMonitors() {
        guard clickMonitor == nil, keyMonitor == nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) {
            [weak self] event in
            guard let self, let panel = self.panel, event.window !== panel else { return event }
            let screenPoint =
                event.window?.convertPoint(toScreen: event.locationInWindow)
                ?? event.locationInWindow
            if !panel.frame.contains(screenPoint) {
                self.dismiss()
                return nil
            }
            return event
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }  // Esc
            self?.dismiss()
            return nil
        }
    }

    private func removeDismissMonitors() {
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        dismiss()
    }
}

/// Dark rounded overlay root: a scrollable log tail on top, the `git diff
/// --stat` preview below. Text is selectable so users can copy log lines.
private struct PeekPanelView: View {
    @ObservedObject var model: PeekPanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("▸").font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white.opacity(0.7))
                Text(model.source)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text("Esc to close")
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundColor(.white.opacity(0.35))
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            Divider().overlay(Color.white.opacity(0.15))
            tailSection
            if let diff = model.diffPreview {
                Divider().overlay(Color.white.opacity(0.15))
                VStack(alignment: .leading, spacing: 4) {
                    Text("git diff --stat")
                        .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.4))
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(diff)
                            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.7))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(10)
            }
        }
        .background(Color(red: 0.06, green: 0.06, blue: 0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        )
        .frame(width: 480, height: 420)
    }

    @ViewBuilder
    private var tailSection: some View {
        if model.isLoading && model.tailLines.isEmpty {
            Text("Reading pane output…")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white.opacity(0.5))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.tailLines.isEmpty {
            Text("No recent output")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white.opacity(0.5))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.tailLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 9.5, weight: .regular, design: .monospaced))
                            .foregroundColor(.white.opacity(0.75))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(10)
            }
        }
    }
}
