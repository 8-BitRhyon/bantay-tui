import SwiftUI

/// Media playback control and status card for the expanded Notch HUD.
struct NotchMediaView: View {
    @ObservedObject private var mediaController = MediaController.shared

    var body: some View {
        VStack(spacing: 8) {
            if let track = mediaController.currentTrack {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(0.1))
                            .frame(width: 48, height: 48)
                        Image(
                            systemName: track.playerSource == "Spotify"
                                ? "music.note.house.fill" : "music.note"
                        )
                        .font(.system(size: 20))
                        .foregroundColor(.green)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)

                        Text(track.artist)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.white.opacity(0.6))
                            .lineLimit(1)

                        Text(track.playerSource)
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(track.playerSource == "Spotify" ? .green : .pink)
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)

                HStack(spacing: 20) {
                    Button(action: { mediaController.previousTrack() }) {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.white)
                    }
                    .buttonStyle(.plain)

                    Button(action: { mediaController.togglePlayPause() }) {
                        Image(
                            systemName: mediaController.isPlaying
                                ? "pause.circle.fill" : "play.circle.fill"
                        )
                        .font(.system(size: 28))
                        .foregroundColor(.cyan)
                    }
                    .buttonStyle(.plain)

                    Button(action: { mediaController.nextTrack() }) {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.white)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 4)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 20))
                        .foregroundColor(.white.opacity(0.35))
                    Text("No media playing")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.55))
                    Text("Start Apple Music or Spotify")
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.35))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 92)
            }
        }
        .padding(.vertical, 8)
    }
}
