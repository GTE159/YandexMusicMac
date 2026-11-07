import SwiftUI
import AppKit

/// Tracks macOS window display state (fullscreen vs windowed) and responsive dimensions
/// to maintain pixel-perfect, consistent spacing across display modes.
@MainActor
@Observable
public final class WindowState {
    public static let shared = WindowState()

    public var isFullScreen: Bool = false
    public var windowSize: CGSize = CGSize(width: 900, height: 620)

    /// Узкий режим окна (< 720 pt)
    public var isCompactWidth: Bool { windowSize.width < 720 }

    /// Сверхкомпактный режим (< 560 pt)
    public var isMiniWidth: Bool { windowSize.width < 560 }

    @ObservationIgnored
    private var observers: [any NSObjectProtocol] = []

    public func cleanup() {
        for obs in observers {
            NotificationCenter.default.removeObserver(obs)
        }
        observers.removeAll()
    }

    public init() {
        // Observe system window notifications for fullscreen transitions
        let obs1 = NotificationCenter.default.addObserver(
            forName: NSWindow.didEnterFullScreenNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let window = notification.object as? NSWindow
            Task { @MainActor in
                guard let self = self, let window = window, self.isValidAppWindow(window) else { return }
                self.isFullScreen = true
            }
        }

        let obs2 = NotificationCenter.default.addObserver(
            forName: NSWindow.didExitFullScreenNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let window = notification.object as? NSWindow
            Task { @MainActor in
                guard let self = self, let window = window, self.isValidAppWindow(window) else { return }
                self.isFullScreen = false
            }
        }

        let obs3 = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let window = notification.object as? NSWindow
            Task { @MainActor in
                self?.update(from: window)
            }
        }

        self.observers = [obs1, obs2, obs3]
    }

    /// Verifies that the window is the primary application window, not an accessory popup, menu, or tooltip.
    private func isValidAppWindow(_ window: NSWindow) -> Bool {
        guard !(window is NSPanel) else { return false }
        guard window.sheetParent == nil else { return false }
        guard window.level == .normal else { return false }
        guard window.canBecomeMain else { return false }
        if window.identifier?.rawValue.contains("Settings") == true ||
           window.title.contains("Settings") ||
           window.title.contains("Настройки") {
            return false
        }
        let className = window.className
        guard !className.contains("Menu"),
              !className.contains("Popover"),
              !className.contains("Tooltip"),
              !className.contains("Panel") else {
            return false
        }
        let frameSize = window.contentView?.bounds.size ?? window.frame.size
        guard frameSize.width >= 320, frameSize.height >= 240 else {
            return false
        }
        return true
    }

    /// Synchronizes fullscreen state and window size directly with the active NSWindow
    public func update(from window: NSWindow?) {
        guard let window = window, isValidAppWindow(window) else { return }
        let full = window.styleMask.contains(.fullScreen)
        if self.isFullScreen != full {
            self.isFullScreen = full
        }

        let frameSize = window.contentView?.bounds.size ?? window.frame.size
        if abs(self.windowSize.width - frameSize.width) > 1 || abs(self.windowSize.height - frameSize.height) > 1 {
            self.windowSize = frameSize
        }
    }
}
