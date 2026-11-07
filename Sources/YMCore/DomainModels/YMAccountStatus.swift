import Foundation

public struct YMAccountStatus: Codable, Sendable {
    public let account: YMAccountInfo?
    public let permissions: YMPermissionsInfo?
    public let plus: YMPlusInfo?
    public let subscription: YMSubscriptionInfo?

    public init(
        account: YMAccountInfo? = nil,
        permissions: YMPermissionsInfo? = nil,
        plus: YMPlusInfo? = nil,
        subscription: YMSubscriptionInfo? = nil
    ) {
        self.account = account
        self.permissions = permissions
        self.plus = plus
        self.subscription = subscription
    }

    public var userId: String? {
        account?.uid
    }

    public var displayName: String {
        account?.displayName ?? account?.fullName ?? account?.login ?? "User"
    }

    public var hasActiveSubscription: Bool {
        // 1. Authoritative Yandex Plus flag from API
        if let hasPlus = plus?.hasPlus {
            return hasPlus
        }

        // 2. Explicit full track playback permission (for accounts without explicit plus model)
        if let values = permissions?.values {
            if values.contains("play-full-tracks") || values.contains("play-premium-tracks") {
                return true
            }
        }

        return false
    }

    public var hadAnySubscription: Bool {
        subscription?.hadAnySubscription ?? false
    }

    private static func parseDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string)
    }
}

public struct YMAccountInfo: Codable, Sendable {
    public let uid: String?
    public let login: String?
    public let fullName: String?
    public let displayName: String?
    public let firstName: String?
    public let secondName: String?
    public let registered: Bool?

    enum CodingKeys: String, CodingKey {
        case uid
        case login
        case fullName
        case displayName
        case firstName
        case secondName
        case registered
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.uid = FlexibleIDDecoder.decodeStringIfPresent(from: container, forKey: .uid)
        self.login = try? container.decodeIfPresent(String.self, forKey: .login)
        self.fullName = try? container.decodeIfPresent(String.self, forKey: .fullName)
        self.displayName = try? container.decodeIfPresent(String.self, forKey: .displayName)
        self.firstName = try? container.decodeIfPresent(String.self, forKey: .firstName)
        self.secondName = try? container.decodeIfPresent(String.self, forKey: .secondName)
        self.registered = try? container.decodeIfPresent(Bool.self, forKey: .registered)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(uid, forKey: .uid)
        try container.encodeIfPresent(login, forKey: .login)
        try container.encodeIfPresent(fullName, forKey: .fullName)
        try container.encodeIfPresent(displayName, forKey: .displayName)
        try container.encodeIfPresent(firstName, forKey: .firstName)
        try container.encodeIfPresent(secondName, forKey: .secondName)
        try container.encodeIfPresent(registered, forKey: .registered)
    }
}

public struct YMPermissionsInfo: Codable, Sendable {
    public let until: String?
    public let values: [String]?
    public let defaults: [String]?

    public init(until: String? = nil, values: [String]? = nil, defaults: [String]? = nil) {
        self.until = until
        self.values = values
        self.defaults = defaults
    }

    enum CodingKeys: String, CodingKey {
        case until
        case values
        case defaults = "default"
    }
}

public struct YMPlusInfo: Codable, Sendable {
    public let hasPlus: Bool?
    public let isTutorialCompleted: Bool?

    public init(hasPlus: Bool? = nil, isTutorialCompleted: Bool? = nil) {
        self.hasPlus = hasPlus
        self.isTutorialCompleted = isTutorialCompleted
    }
}

public struct YMSubscriptionInfo: Codable, Sendable {
    public let hadAnySubscription: Bool?
    public let canStartTrial: Bool?

    public init(hadAnySubscription: Bool? = nil, canStartTrial: Bool? = nil) {
        self.hadAnySubscription = hadAnySubscription
        self.canStartTrial = canStartTrial
    }
}
