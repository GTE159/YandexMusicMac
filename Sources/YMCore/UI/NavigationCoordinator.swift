import SwiftUI

public enum AppRoute: Hashable, Sendable {
    case artist(id: String, name: String)
    case album(id: String, title: String)
}

/// Centralized app navigation coordinator managing deep links, detail views, lyrics and sub-flows.
@Observable
public final class NavigationCoordinator: @unchecked Sendable {
    public static let shared = NavigationCoordinator()

    public var path: [AppRoute] = []
    public var selectedSection: SidebarSection = .myWave
    public var isLyricsPresented: Bool = false
    public var activeSimilarTrack: YMTrack? = nil

    public init() {}

    public var canGoBack: Bool {
        !path.isEmpty
    }

    public func selectSection(_ section: SidebarSection) {
        self.selectedSection = section
        popToRoot()
    }

    public func navigate(to route: AppRoute) {
        path.append(route)
    }

    public func pop() {
        if !path.isEmpty {
            path.removeLast()
        }
    }

    public func popToRoot() {
        path.removeAll()
    }
}
