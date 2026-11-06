import Foundation
import Observation

/// Isolated lightweight progress tracker for audio playback.
/// Bound only to the player progress bar to prevent re-rendering the sidebar,
/// track lists, or navigation hierarchies at high frequency (60fps / 10Hz).
@Observable
@MainActor
public final class PlaybackProgressTracker {
    public var currentTime: Double = 0
    public var duration: Double = 0
    public var isUserSeeking: Bool = false
    public var seekLockUntil: Date = .distantPast

    public init(currentTime: Double = 0, duration: Double = 0) {
        self.currentTime = currentTime
        self.duration = duration
    }

    public var progress: Double {
        get {
            guard duration > 0 else { return 0 }
            return min(max(currentTime / duration, 0), 1)
        }
        set {
            currentTime = newValue * duration
        }
    }

    public var currentTimeFormatted: String {
        formatTime(currentTime)
    }

    public var durationFormatted: String {
        formatTime(duration)
    }

    public var remainingTimeFormatted: String {
        let remaining = max(0, duration - currentTime)
        return "-" + formatTime(remaining)
    }

    public func update(currentTime: Double, duration: Double) {
        // Block ticks while user is dragging OR while AVPlayer async seek is settling
        guard !isUserSeeking, Date() >= seekLockUntil else { return }
        self.currentTime = currentTime
        if duration > 0 {
            self.duration = duration
        }
    }

    public func reset() {
        currentTime = 0
        duration = 0
        isUserSeeking = false
        seekLockUntil = .distantPast
    }

    private func formatTime(_ seconds: Double) -> String {
        guard !seconds.isNaN && !seconds.isInfinite && seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let mins = total / 60
        let secs = total % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
