import Foundation
import MediaPlayer

/// Manages macOS System Remote Command Center integration (Media Keys, Touch Bar, Control Center).
@MainActor
public final class RemoteCommandManager {
    public static let shared = RemoteCommandManager()

    private weak var playerEngine: AudioPlayerEngine?
    public var onLikeToggled: (@Sendable () -> Void)?

    public init(playerEngine: AudioPlayerEngine = AudioPlayerEngine.shared) {
        self.playerEngine = playerEngine
        setupCommands()
    }

    deinit {
        let commandCenter = MPRemoteCommandCenter.shared()
        let commands = [
            commandCenter.playCommand,
            commandCenter.pauseCommand,
            commandCenter.togglePlayPauseCommand,
            commandCenter.nextTrackCommand,
            commandCenter.previousTrackCommand,
            commandCenter.changePlaybackPositionCommand,
            commandCenter.likeCommand
        ]
        for command in commands {
            command.isEnabled = false
            command.removeTarget(nil)
        }
    }

    public func configure(with engine: AudioPlayerEngine) {
        self.playerEngine = engine
    }

    private func setupCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()
        let commands = [
            commandCenter.playCommand,
            commandCenter.pauseCommand,
            commandCenter.togglePlayPauseCommand,
            commandCenter.nextTrackCommand,
            commandCenter.previousTrackCommand,
            commandCenter.changePlaybackPositionCommand,
            commandCenter.likeCommand
        ]
        for command in commands {
            command.removeTarget(nil)
        }

        // Play / Pause / Toggle
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.playerEngine?.play()
            }
            return .success
        }

        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.playerEngine?.pause()
            }
            return .success
        }

        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.playerEngine?.togglePlayPause()
            }
            return .success
        }

        // Track navigation
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.playerEngine?.next()
            }
            return .success
        }

        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.playerEngine?.previous()
            }
            return .success
        }

        // Seek scrubber
        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let positionTime = positionEvent.positionTime
            Task { @MainActor [weak self] in
                self?.playerEngine?.seek(to: positionTime)
                NowPlayingController.shared.updatePlaybackPosition(seconds: positionTime, isPlaying: self?.playerEngine?.isPlaying ?? false)
            }
            return .success
        }

        // Like command
        commandCenter.likeCommand.isEnabled = true
        commandCenter.likeCommand.localizedTitle = "Мне нравится"
        commandCenter.likeCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                if let onLikeToggled = self?.onLikeToggled {
                    onLikeToggled()
                } else if let currentTrack = self?.playerEngine?.currentTrack {
                    await LikesService.shared.toggleLike(track: currentTrack)
                }
            }
            return .success
        }
    }
}
