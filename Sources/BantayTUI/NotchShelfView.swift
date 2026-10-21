import SwiftUI
import AppKit

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

    var body: some View {
        VStack(spacing: 0) {
            if shelfStore.files.isEmpty && clipboardItems.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.white.opacity(0.35))
                    Text("Drop files here to keep them")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.55))
                    Text(retentionHint)
                        .font(.system(size: 9, weight: .regular))
                        .foregroundColor(.white.opacity(0.35))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 92)
            }
            if !shelfStore.files.isEmpty {
                // Thumbnail card strip — the actual "shelf" feel.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(shelfStore.files) { file in
                            shelfCard(file)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .frame(height: 84)
            }
            ForEach(clipboardItems) { item in
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
            Spacer(minLength: 0)
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
                if let icon = file.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 34, height: 34)
                } else {
                    Image(systemName: "doc.fill").font(.system(size: 16))
                        .foregroundColor(.white.opacity(0.5))
                }
            }
            .frame(width: 48, height: 48)
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
            Text(file.name)
                .font(.system(size: 8, weight: .medium))
                .foregroundColor(.white.opacity(0.75))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 64)
        }
        .frame(width: 68)
        .contentShape(Rectangle())
        .draggable(file.url)
        .onTapGesture(count: 2) { NSWorkspace.shared.open(file.url) }
        .onTapGesture(count: 1) { ShelfQuickLook.show(file.url) }
        .help("Click: preview · Double-click: open")
        .contextMenu {
            Button("Quick Look Preview") { ShelfQuickLook.show(file.url) }
            Button("Open") { NSWorkspace.shared.open(file.url) }
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
