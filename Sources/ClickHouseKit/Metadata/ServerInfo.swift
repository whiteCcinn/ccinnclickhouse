import Foundation

/// Parsed ClickHouse release, e.g. `24.8.14.39`.
public struct ClickHouseVersion: Sendable, Comparable, Hashable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let build: Int
    public let raw: String

    public init(major: Int, minor: Int, patch: Int = 0, build: Int = 0, raw: String? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.build = build
        self.raw = raw ?? "\(major).\(minor).\(patch).\(build)"
    }

    /// Accepts `24.8.14.39`, `v23.3.1.2823-lts`, `25.8.1.1 (official build)`; `nil` without `major.minor`.
    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let body = trimmed.drop(while: { !$0.isNumber })
        let numbers = body.prefix(while: { $0.isNumber || $0 == "." }).split(separator: ".").prefix(4).map { Int($0.prefix(9)) ?? 0 }
        guard numbers.count >= 2 else { return nil }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers.count > 2 ? numbers[2] : 0, build: numbers.count > 3 ? numbers[3] : 0,
                  raw: trimmed)
    }

    public static func < (lhs: ClickHouseVersion, rhs: ClickHouseVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch, lhs.build) < (rhs.major, rhs.minor, rhs.patch, rhs.build)
    }

    public static func == (lhs: ClickHouseVersion, rhs: ClickHouseVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch, lhs.build) == (rhs.major, rhs.minor, rhs.patch, rhs.build)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(major)
        hasher.combine(minor)
        hasher.combine(patch)
        hasher.combine(build)
    }

    public func isAtLeast(_ major: Int, _ minor: Int) -> Bool { (self.major, self.minor) >= (major, minor) }

    public var shortDescription: String { "\(major).\(minor)" }
    public var description: String { raw }
}

/// Facts about the connected server, loaded once per client.
public struct ServerInfo: Sendable, Equatable {
    public let versionString: String
    public let version: ClickHouseVersion?
    public let timeZone: String?
    public let currentUser: String?
    /// `hostName()` of the node that answered the probe.
    public let hostName: String?
    /// `X-ClickHouse-Server-Display-Name` (or `hostName()`).
    public let displayName: String?
    public let uptimeSeconds: Int64?
    /// The user's default database.
    public let defaultDatabase: String?
    /// The user's own `readonly` level (0, 1 or 2) before the app adds anything.
    public let readonlyLevel: Int?

    public init(versionString: String, timeZone: String? = nil, currentUser: String? = nil, hostName: String? = nil,
                displayName: String? = nil, uptimeSeconds: Int64? = nil, defaultDatabase: String? = nil, readonlyLevel: Int? = nil) {
        self.versionString = versionString
        version = ClickHouseVersion(versionString)
        self.timeZone = timeZone
        self.currentUser = currentUser
        self.hostName = hostName
        self.displayName = displayName
        self.uptimeSeconds = uptimeSeconds
        self.defaultDatabase = defaultDatabase
        self.readonlyLevel = readonlyLevel
    }
}
