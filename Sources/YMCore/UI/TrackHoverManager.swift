import SwiftUI
import AppKit

/// Centralized manager for high-performance track list hover interactions.
/// Guarantees:
/// 1. Strict single source of truth: at most one row can ever be hovered.
/// 2. Zero scroll stutter: hover updates are completely suppressed during active scrolling to maintain 120 FPS.
/// 3. Zero parent re-evaluations: row hover does not invalidate the parent TrackTableView or other rows.
@Observable
@MainActor
public final class TrackHoverManager {
    public static let shared = TrackHoverManager()

    public private(set) var hoveredTrackId: String? = nil
    public private(set) var isScrolling: Bool = false

    private var scrollDebounceTask: Task<Void, Never>? = nil
    private var eventMonitor: Any? = nil

    public init() {
        setupScrollDetection()
    }

    public func isHovered(trackId: String) -> Bool {
        !isScrolling && hoveredTrackId == trackId
    }

    public func setHovered(_ trackId: String?) {
        guard !isScrolling else { return }
        if hoveredTrackId != trackId {
            hoveredTrackId = trackId
        }
    }

    public func clear() {
        if hoveredTrackId != nil {
            hoveredTrackId = nil
        }
    }

    public func notifyScrollActivity() {
        if !isScrolling {
            isScrolling = true
            hoveredTrackId = nil
        }
        scrollDebounceTask?.cancel()
        scrollDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.isScrolling = false
            }
        }
    }

    public func notifyScrollEnded() {
        scrollDebounceTask?.cancel()
        isScrolling = false
    }

    private func setupScrollDetection() {
        // 1. AppKit live scroll notifications for all NSScrollView instances
        NotificationCenter.default.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.notifyScrollActivity()
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSScrollView.didLiveScrollNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.notifyScrollActivity()
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveScrollNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.notifyScrollEnded()
            }
        }

        // 2. Local event monitor for discrete scroll wheel events (trackpad gestures + physical mouse wheels)
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            if abs(event.scrollingDeltaX) > 0.5 || abs(event.scrollingDeltaY) > 0.5 {
                Task { @MainActor [weak self] in
                    self?.notifyScrollActivity()
                }
            }
            return event
        }
    }
}
