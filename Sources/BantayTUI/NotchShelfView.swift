import AppKit
import SwiftUI

/// Drop shelf & clipboard history view for the expanded Notch HUD.
struct NotchShelfView: View {
    @ObservedObject var shelfStore = ShelfStore.shared
    let clipboardItems: [ClipboardItem]
    let shelfDropGlow: Bool

    /// "kept for X" hint driven by the configured retention.
    private var retentionHint: String {
        let keep = ShelfKeepDuration.from(
            configRaw: NotchHUDConfig.shared.shelfKeepDuration)
        switch keep {
        case .forever: return "Files stay until you remove them."
        default: return "Files auto-expire after \(keep.rawValue.lowercased())."
        }
    }

    private var isEmpty: Bool {
        shelfStore.files.isEmpty && clipboardItems.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            if isEmpty {
                emptyState
            }
            if !shelfStore.files.isEmpty {
                // Thumbnail card strip: the actual "shelf" feel.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(shelfStore.files) { file in
                            shelfCard(file)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .frame(height: IslandMetrics.shelfStripHeight)
            }
            if !clipboardItems.isEmpty {
                // Clipboard history can outgrow the panel cap. Keep the strip
                // and footer fixed, and scroll only the text rows.
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        ForEach(clipboardItems) { item in
                            clipboardRow(item)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            } else {
                Spacer(minLength: 0)
            }
            shelfFooter
        }
        // Glow feedback when a drop lands.
        .overlay {
            if shelfDropGlow {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.blue.opacity(0.8), lineWidth: 2)
                    .padding(2)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.4), value: shelfDropGlow)
        .task {
            shelfStore.maintain()
            shelfStore.sweepOrphans()
        }
    }

    /// Empty state doubles as the drop-failure surface when nothing landed.
    private var emptyState: some View {
        VStack(spacing: 5) {
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.system(size: 18))
                .foregroundColor(.white.opacity(0.35))
            Text("Drop files, images, links, or text")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.55))
            Text("Drag them back out into any app.")
                .font(.system(size: 9, weight: .regular))
                .foregroundColor(.white.opacity(0.45))
            if shelfStore.isLoading {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.65)
                        .frame(width: 10, height: 10)
                        .tint(.white.opacity(0.55))
                    Text("Adding to shelf...")
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.45))
                }
            } else if let report = shelfStore.lastReport {
                Text(report.shortMessage)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(
                        report.hasFailure
                            ? Color.orange.opacity(0.9)
                            : Color.white.opacity(0.45)
                    )
                    .lineLimit(1)
                    .help(report.detail)
            } else {
                Text(retentionHint)
                    .font(.system(size: 9, weight: .regular))
                    .foregroundColor(.white.opacity(0.35))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: IslandMetrics.shelfEmptyHeight)
    }

    /// Persistent footer: item count, live usage against the configured
    /// budget, and the outcome of the last drop.
    private var shelfFooter: some View {
        HStack(spacing: 6) {
            if shelfStore.isLoading {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.6)
                    .frame(width: 9, height: 9)
                    .tint(.white.opacity(0.55))
                Text("Adding...")
                    .foregroundColor(.white.opacity(0.5))
            } else if let report = shelfStore.lastReport {
                Text(report.shortMessage)
                    .foregroundColor(
                        report.hasFailure
                            ? Color.orange.opacity(0.9)
                            : Color.white.opacity(0.5)
                    )
                    .lineLimit(1)
                    .help(report.detail)
            } else {
                Text(itemCountLabel)
                    .foregroundColor(.white.opacity(0.4))
            }
            Spacer(minLength: 8)
            Text(
                "\(ShelfFormat.bytes(shelfStore.totalBytes)) of "
                    + ShelfFormat.bytes(
                        Int64(NotchHUDConfig.shared.clampedShelfMaxBytes))
            )
            .foregroundColor(.white.opacity(0.38))
            .lineLimit(1)
            .layoutPriority(1)
        }
        .font(.system(size: 8.5, weight: .medium))
        .padding(.horizontal, 16)
        .frame(height: IslandMetrics.shelfFooterHeight)
    }

    private var itemCountLabel: String {
        let count = shelfStore.files.count
        return count == 1 ? "1 item" : "\(count) items"
    }

    private func clipboardRow(_ item: ClipboardItem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard.fill").font(.system(size: 9))
                .foregroundColor(.white.opacity(0.6))
            Text(item.text)
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundColor(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(0)
            Spacer(minLength: 4)
            Button(action: {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(item.text, forType: .string)
            }) {
                Image(systemName: "arrow.uturn.left").font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help("Copy to clipboard")
            .accessibilityLabel("Copy text to clipboard")
            .layoutPriority(1)
        }
        .padding(.horizontal, 16)
        .frame(height: IslandMetrics.rowHeight)
    }

    private func fileSizeText(_ file: ShelfFile) -> String {
        guard let bytes = file.byteCount else { return "Size unavailable" }
        return ShelfFormat.bytes(Int64(bytes))
    }

    /// One thumbnail card: icon, name, hover actions (QuickLook / open /
    /// remove), draggable back out. Mirrors NotchDrop's DropItemView.
    private func shelfCard(_ file: ShelfFile) -> some View {
        VStack(spacing: 3) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                    )
                if let preview = file.imagePreview {
                    Image(nsImage: preview)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else if let icon = file.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 34, height: 34)
                } else {
                    Image(systemName: file.kind.systemImage).font(.system(size: 16))
                        .foregroundColor(.white.opacity(0.5))
                }
            }
            .frame(width: 48, height: 48)
            .overlay(alignment: .bottomTrailing) {
                if file.kind != .file && file.kind != .image {
                    Image(systemName: file.kind.systemImage)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.white.opacity(0.9))
                        .padding(3)
                        .background(Color.black.opacity(0.65).clipShape(Circle()))
                        .offset(x: 3, y: 3)
                }
            }
            .overlay(alignment: .topTrailing) {
                // Remove (⌥-style): a small ✕ always present, like NotchDrop's
                // option-key reveal but simpler to discover.
                Button(action: { shelfStore.remove(file) }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.7))
                        .background(Color.black.opacity(0.6).clipShape(Circle()))
                }
                .buttonStyle(.plain)
                .help("Remove from shelf")
                .offset(x: 4, y: -4)
            }
            Text(file.displayName)
                .font(.system(size: 8, weight: .medium))
                .foregroundColor(.white.opacity(0.75))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 64)
        }
        .frame(width: 68)
        .contentShape(Rectangle())
        .onDrag {
            MainActor.assumeIsolated { ShelfDragSession.begin() }
            return ShelfDragProvider.itemProvider(for: file)
        }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(file.url) }
        .onTapGesture(count: 1) { ShelfQuickLook.show(file.url) }
        .help(
            "\(file.displayName) · \(fileSizeText(file))\n"
                + "Drag out to any app · Click: preview · Double-click: open"
        )
        .accessibilityLabel(
            "\(file.displayName), \(fileSizeText(file)), drag to another app"
        )
        .contextMenu {
            Button("Quick Look Preview") { ShelfQuickLook.show(file.url) }
            if let link = file.linkURL, file.kind == .link {
                Button("Open Link") { NSWorkspace.shared.open(link) }
                Button("Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link.absoluteString, forType: .string)
                }
            } else {
                Button("Open") { NSWorkspace.shared.open(file.url) }
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([file.url])
            }
            Divider()
            Button("Copy Path") { shelfStore.copyPath(file) }
            Button("Copy Content") { shelfStore.copyContent(file) }
            Divider()
            Button("Remove") { shelfStore.remove(file) }
            Button("Clear All Shelf") { shelfStore.removeAll() }
        }
    }
}
