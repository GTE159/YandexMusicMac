import SwiftUI
import AppKit

public enum YMAppTheme: String, CaseIterable, Identifiable, Sendable {
    case system = "system"
    case dark = "dark"
    case light = "light"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: return "Системная"
        case .dark: return "Тёмная"
        case .light: return "Светлая"
        }
    }

    public var subtitle: String {
        switch self {
        case .system: return "Автоматически повторяет оформление macOS"
        case .dark: return "Фирменный глубокий тёмный интерфейс"
        case .light: return "Мягкая нейтральная тема в тёплых тонах"
        }
    }

    public var iconName: String {
        switch self {
        case .system: return "circle.righthalf.filled"
        case .dark: return "moon.fill"
        case .light: return "sun.max.fill"
        }
    }

    public var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .dark: return .dark
        case .light: return .light
        }
    }
}

/// Centralized application theme manager with UserDefaults persistence
/// and real-time AppKit NSWindow appearance synchronization.
@MainActor
@Observable
public final class YMThemeManager {
    public static let shared = YMThemeManager()

    private let themeKey = "ym_app_theme_preference"

    public var currentTheme: YMAppTheme {
        didSet {
            UserDefaults.standard.set(currentTheme.rawValue, forKey: themeKey)
            updateWindowAppearance()
        }
    }

    public init() {
        if let saved = UserDefaults.standard.string(forKey: themeKey),
           let theme = YMAppTheme(rawValue: saved) {
            self.currentTheme = theme
        } else {
            self.currentTheme = .dark
        }
        updateWindowAppearance()
    }

    public func setTheme(_ theme: YMAppTheme) {
        self.currentTheme = theme
    }

    public func updateWindowAppearance() {
        let appKitAppearance: NSAppearance? = switch currentTheme {
        case .system: nil
        case .dark: NSAppearance(named: .darkAqua)
        case .light: NSAppearance(named: .aqua)
        }

        NSApp.appearance = appKitAppearance
        for window in NSApp.windows where !(window is NSPanel) {
            window.appearance = appKitAppearance
        }
    }
}
