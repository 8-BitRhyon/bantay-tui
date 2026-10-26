import SwiftUI

/// Scratchpad and notes editor for the expanded Notch HUD.
struct NotchNotesView: View {
    @ObservedObject private var notesStore = NotesStore.shared
    @State private var copiedNotes = false

    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    var body: some View {
        let words = notesStore.noteText
            .split(whereSeparator: \.isWhitespace).count
        let chars = notesStore.noteText.count

        return VStack(spacing: 6) {
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(BantayTheme.statusWorking)
                        .frame(width: 5, height: 5)
                    Text("Scratchpad")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundColor(BantayTheme.textPrimary)
                    Text("•")
                        .font(.system(size: 8.5))
                        .foregroundColor(BantayTheme.textTertiary)
                    Text("\(words)w, \(chars)c")
                        .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                        .foregroundColor(BantayTheme.textTertiary)
                    Text("•")
                        .font(.system(size: 8.5))
                        .foregroundColor(BantayTheme.textTertiary)
                    Text("Autosaved")
                        .font(.system(size: 8.5))
                        .foregroundColor(BantayTheme.textTertiary.opacity(0.8))
                }

                Spacer(minLength: 4)

                if !notesStore.noteText.isEmpty {
                    Button(action: {
                        copyToClipboard(notesStore.noteText)
                        withAnimation(BantayTheme.springSnappy) {
                            copiedNotes = true
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            withAnimation(.easeOut) {
                                copiedNotes = false
                            }
                        }
                    }) {
                        HStack(spacing: 3) {
                            Image(systemName: copiedNotes ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 8.5))
                            Text(copiedNotes ? "Copied" : "Copy")
                                .font(.system(size: 8.5, weight: .medium))
                        }
                        .foregroundColor(
                            copiedNotes ? BantayTheme.statusCompleted : BantayTheme.textSecondary
                        )
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.08), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Copy notes to clipboard")

                    Button(action: {
                        notesStore.noteText = ""
                    }) {
                        HStack(spacing: 3) {
                            Image(systemName: "trash")
                                .font(.system(size: 8.5))
                            Text("Clear")
                                .font(.system(size: 8.5, weight: .medium))
                        }
                        .foregroundColor(BantayTheme.textTertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.05), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Clear scratchpad")
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                    )

                if notesStore.noteText.isEmpty {
                    Text(
                        "Type quick scratch notes, prompt drafts, or snippets here...\nAutosaved to disk."
                    )
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundColor(BantayTheme.textTertiary.opacity(0.6))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
                }

                TextEditor(text: $notesStore.noteText)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity)
    }
}
