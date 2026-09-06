import AppKit
import Combine
import Foundation

public struct MediaTrack: Equatable, Sendable {
    public let title: String
    public let artist: String
    public let album: String
    public let isPlaying: Bool
    public let playerSource: String
    public let artwork: NSImage?

    public init(
        title: String,
        artist: String,
        album: String = "",
        isPlaying: Bool = false,
        playerSource: String = "Music",
        artwork: NSImage? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.isPlaying = isPlaying
        self.playerSource = playerSource
        self.artwork = artwork
    }
}

@MainActor
public final class MediaController: ObservableObject {
    public static let shared = MediaController()

    @Published public private(set) var currentTrack: MediaTrack?
    @Published public private(set) var isPlaying: Bool = false

    private var pollTimer: Timer?

    private init() {
        startPolling()
    }

    public func startPolling() {
        guard ApprovalNotificationController.hasBundleProxy else { return }
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollMediaState()
            }
        }
        pollMediaState()
    }

    public func pollMediaState() {
        Task.detached(priority: .utility) {
            let musicTrack = Self.fetchAppleMusicState()
            let spotifyTrack = musicTrack == nil ? Self.fetchSpotifyState() : nil
            let track = musicTrack ?? spotifyTrack
            await MainActor.run { [weak self] in
                self?.currentTrack = track
                self?.isPlaying = track?.isPlaying ?? false
            }
        }
    }

    public func togglePlayPause() {
        guard let source = currentTrack?.playerSource else { return }
        let script =
            source == "Spotify"
            ? "tell application \"Spotify\" to playpause"
            : "tell application \"Music\" to playpause"
        executeScript(script)
        pollMediaState()
    }

    public func nextTrack() {
        guard let source = currentTrack?.playerSource else { return }
        let script =
            source == "Spotify"
            ? "tell application \"Spotify\" to next track"
            : "tell application \"Music\" to next track"
        executeScript(script)
        pollMediaState()
    }

    public func previousTrack() {
        guard let source = currentTrack?.playerSource else { return }
        let script =
            source == "Spotify"
            ? "tell application \"Spotify\" to previous track"
            : "tell application \"Music\" to previous track"
        executeScript(script)
        pollMediaState()
    }

    private func executeScript(_ source: String) {
        Task.detached(priority: .utility) {
            var error: NSDictionary?
            if let appleScript = NSAppleScript(source: source) {
                appleScript.executeAndReturnError(&error)
            }
        }
    }

    nonisolated private static func fetchAppleMusicState() -> MediaTrack? {
        guard ApprovalNotificationController.hasBundleProxy else { return nil }
        let scriptSource = """
            if application "Music" is running then
                tell application "Music"
                    if player state is playing or player state is paused then
                        set trackTitle to name of current track
                        set trackArtist to artist of current track
                        set trackAlbum to album of current track
                        set pState to (player state is playing)
                        return trackTitle & "|||" & trackArtist & "|||" & trackAlbum & "|||" & (pState as string)
                    end if
                end tell
            end if
            return ""
            """
        var error: NSDictionary?
        guard let script = NSAppleScript(source: scriptSource),
            let descriptor = script.executeAndReturnError(&error).stringValue,
            !descriptor.isEmpty
        else {
            return nil
        }
        let parts = descriptor.components(separatedBy: "|||")
        guard parts.count >= 4 else { return nil }
        let isPlaying = parts[3].lowercased() == "true"
        return MediaTrack(
            title: parts[0],
            artist: parts[1],
            album: parts[2],
            isPlaying: isPlaying,
            playerSource: "Music",
            artwork: nil
        )
    }

    nonisolated private static func fetchSpotifyState() -> MediaTrack? {
        guard ApprovalNotificationController.hasBundleProxy else { return nil }
        let scriptSource = """
            if application "Spotify" is running then
                tell application "Spotify"
                    if player state is playing or player state is paused then
                        set trackTitle to name of current track
                        set trackArtist to artist of current track
                        set trackAlbum to album of current track
                        set pState to (player state is playing)
                        return trackTitle & "|||" & trackArtist & "|||" & trackAlbum & "|||" & (pState as string)
                    end if
                end tell
            end if
            return ""
            """
        var error: NSDictionary?
        guard let script = NSAppleScript(source: scriptSource),
            let descriptor = script.executeAndReturnError(&error).stringValue,
            !descriptor.isEmpty
        else {
            return nil
        }
        let parts = descriptor.components(separatedBy: "|||")
        guard parts.count >= 4 else { return nil }
        let isPlaying = parts[3].lowercased() == "true"
        return MediaTrack(
            title: parts[0],
            artist: parts[1],
            album: parts[2],
            isPlaying: isPlaying,
            playerSource: "Spotify",
            artwork: nil
        )
    }
}
