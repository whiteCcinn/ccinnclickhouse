import ClickHouseKit
import Foundation
import os
import Security

public enum ProfileColor: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, red, orange, yellow, green, mint, teal, blue, indigo, purple, pink, gray
    public var id: String { rawValue }
}

/// Whether AI clients may use a connection through the built-in MCP server.
public enum MCPAccess: String, Codable, CaseIterable, Identifiable, Sendable {
    case disabled
    case readOnly
    case readWrite

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .disabled: "Off"
        case .readOnly: "Read-only"
        case .readWrite: "Read & write"
        }
    }
}

/// A saved connection. Never contains secrets: passwords live in a `SecretStore` (the Keychain).
public struct ConnectionProfile: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var color: ProfileColor
    public var isFavorite: Bool
    public var host: String
    public var port: Int
    /// HTTPS instead of HTTP.
    public var secure: Bool
    /// Path prefix behind a reverse proxy (`/clickhouse/`).
    public var pathPrefix: String
    public var username: String
    public var defaultDatabase: String?
    /// Cluster used for cluster-wide views and `ON CLUSTER` kills.
    public var defaultCluster: String?
    public var compression: Bool
    /// Server-enforced read-only (`readonly=1`) plus the app's read-only guard.
    public var readOnly: Bool
    /// Extra trusted CA certificate (PEM).
    public var customCACertificate: String?
    public var skipTLSVerification: Bool
    public var ssh: SSHTunnelConfiguration?
    /// Ask before running statements that change data or schema.
    public var confirmMutations: Bool
    public var connectTimeout: Double
    /// AI access through the MCP server (off unless the user opts in).
    public var mcpAccess: MCPAccess
    public var createdAt: Date
    public var lastConnectedAt: Date?

    public init(id: UUID = UUID(), name: String = "", host: String = "127.0.0.1", port: Int = 8123, secure: Bool = false, pathPrefix: String = "",
                username: String = "default", defaultDatabase: String? = nil, defaultCluster: String? = nil, compression: Bool = true,
                readOnly: Bool = false, customCACertificate: String? = nil, skipTLSVerification: Bool = false, color: ProfileColor = .none,
                isFavorite: Bool = false, ssh: SSHTunnelConfiguration? = nil, confirmMutations: Bool = false, connectTimeout: Double = 10,
                mcpAccess: MCPAccess = .disabled, createdAt: Date = Date(), lastConnectedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.secure = secure
        self.pathPrefix = pathPrefix
        self.username = username
        self.defaultDatabase = defaultDatabase
        self.defaultCluster = defaultCluster
        self.compression = compression
        self.readOnly = readOnly
        self.customCACertificate = customCACertificate
        self.skipTLSVerification = skipTLSVerification
        self.color = color
        self.isFavorite = isFavorite
        self.ssh = ssh
        self.confirmMutations = confirmMutations
        self.connectTimeout = connectTimeout
        self.mcpAccess = mcpAccess
        self.createdAt = createdAt
        self.lastConnectedAt = lastConnectedAt
    }

    /// Tolerant decoding: fields added in later versions fall back to their defaults.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        color = (try? container.decodeIfPresent(ProfileColor.self, forKey: .color)) ?? .none
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? "127.0.0.1"
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 8123
        secure = try container.decodeIfPresent(Bool.self, forKey: .secure) ?? false
        pathPrefix = try container.decodeIfPresent(String.self, forKey: .pathPrefix) ?? ""
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? "default"
        defaultDatabase = try container.decodeIfPresent(String.self, forKey: .defaultDatabase)
        defaultCluster = try container.decodeIfPresent(String.self, forKey: .defaultCluster)
        compression = try container.decodeIfPresent(Bool.self, forKey: .compression) ?? true
        readOnly = try container.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false
        customCACertificate = try container.decodeIfPresent(String.self, forKey: .customCACertificate)
        skipTLSVerification = try container.decodeIfPresent(Bool.self, forKey: .skipTLSVerification) ?? false
        ssh = try container.decodeIfPresent(SSHTunnelConfiguration.self, forKey: .ssh)
        confirmMutations = try container.decodeIfPresent(Bool.self, forKey: .confirmMutations) ?? false
        connectTimeout = try container.decodeIfPresent(Double.self, forKey: .connectTimeout) ?? 10
        mcpAccess = (try? container.decodeIfPresent(MCPAccess.self, forKey: .mcpAccess)) ?? .disabled
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        lastConnectedAt = try container.decodeIfPresent(Date.self, forKey: .lastConnectedAt)
    }

    public static func recents(_ profiles: [ConnectionProfile]) -> [ConnectionProfile] {
        profiles.filter { $0.lastConnectedAt != nil }
            .sorted { ($0.lastConnectedAt ?? .distantPast) > ($1.lastConnectedAt ?? .distantPast) }
    }

    public var endpoint: Endpoint { Endpoint(host: host.trimmingCharacters(in: .whitespaces), port: port) }

    public var hostSummary: String {
        let base = "\(username)@\(secure ? "https" : "http")://\(endpoint)\(pathPrefix.nilIfBlank.map { "/" + $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) } ?? "")"
        if let ssh { return "\(base) via \(ssh.host)" }
        return base
    }

    public var displayName: String { name.isEmpty ? endpoint.description : name }

    public func configuration(password: String) -> ConnectionConfiguration {
        ConnectionConfiguration(endpoint: endpoint, secure: secure, pathPrefix: pathPrefix, username: username, password: password,
                                database: defaultDatabase?.nilIfBlank, defaultCluster: defaultCluster?.nilIfBlank,
                                connectTimeout: min(max(connectTimeout, 1), 300), readOnly: readOnly, compression: compression,
                                tls: TLSOptions(customCACertificate: customCACertificate?.nilIfBlank, skipVerification: skipTLSVerification))
    }

    /// Problems that prevent connecting, for inline form validation.
    public var validationErrors: [String] {
        var errors: [String] = []
        if host.trimmingCharacters(in: .whitespaces).isEmpty { errors.append("Enter the server host") }
        if !(1...65_535).contains(port) { errors.append("Port must be between 1 and 65535") }
        if username.trimmingCharacters(in: .whitespaces).isEmpty { errors.append("Enter a user name") }
        if let certificate = customCACertificate?.nilIfBlank, !certificate.contains("BEGIN CERTIFICATE"), Data(base64Encoded: certificate.filter { !$0.isWhitespace }) == nil {
            errors.append("The CA certificate must be PEM text")
        }
        if let ssh {
            if ssh.host.trimmingCharacters(in: .whitespaces).isEmpty { errors.append("Enter the SSH host") }
            if ssh.authentication == .privateKey, (ssh.privateKeyPath ?? "").isEmpty { errors.append("Choose an SSH private key") }
        }
        return errors
    }
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Secrets

public struct SecretKey: Hashable, Sendable {
    public enum Kind: String, Sendable {
        case password
        case sshSecret
    }

    public let profileID: UUID
    public let kind: Kind

    public init(profileID: UUID, kind: Kind) {
        self.profileID = profileID
        self.kind = kind
    }

    var account: String { "\(profileID.uuidString).\(kind.rawValue)" }
}

public protocol SecretStore: Sendable {
    func secret(for key: SecretKey) throws -> String?
    /// Stores `value`, or deletes the secret when `value` is nil or empty.
    func setSecret(_ value: String?, for key: SecretKey) throws
}

public struct SecretStoreError: Error, LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
}

/// macOS Keychain (generic passwords, this-device-only, available after first unlock).
public struct KeychainSecretStore: SecretStore {
    public let service: String

    public init(service: String = "io.github.whiteccinn.ccinnclickhouse.connections") {
        self.service = service
    }

    public func secret(for key: SecretKey) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw SecretStoreError(message: "Keychain read failed (\(status))")
        }
        return String(decoding: data, as: UTF8.self)
    }

    public func setSecret(_ value: String?, for key: SecretKey) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.account,
        ]
        guard let value, !value.isEmpty else {
            let status = SecItemDelete(base as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw SecretStoreError(message: "Keychain delete failed (\(status))")
            }
            return
        }
        let data = Data(value.utf8)
        let update = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecItemNotFound {
            var item = base
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            item[kSecAttrLabel as String] = "CcinnClickHouse connection secret"
            let status = SecItemAdd(item as CFDictionary, nil)
            guard status == errSecSuccess else { throw SecretStoreError(message: "Keychain write failed (\(status))") }
        } else if update != errSecSuccess {
            throw SecretStoreError(message: "Keychain update failed (\(update))")
        }
    }
}

public final class InMemorySecretStore: SecretStore {
    private let storage = OSAllocatedUnfairLock<[SecretKey: String]>(initialState: [:])

    public init() {}

    public func secret(for key: SecretKey) throws -> String? { storage.withLock { $0[key] } }

    public func setSecret(_ value: String?, for key: SecretKey) throws {
        storage.withLock { $0[key] = value?.isEmpty == false ? value : nil }
    }
}

/// **Test-only** secret source: `CCINNCLICKHOUSE_TEST_PASSWORD_<PROFILE-UUID>` environment variables,
/// used by the MCP subprocess integration test (documented as test-only in the README). Falls back to
/// the wrapped store for everything else.
public struct EnvironmentTestSecretStore: SecretStore {
    public static let prefix = "CCINNCLICKHOUSE_TEST_PASSWORD_"
    let fallback: any SecretStore
    let environment: [String: String]

    public init(fallback: any SecretStore, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.fallback = fallback
        self.environment = environment
    }

    /// Whether any test secret is present (only then is this store used).
    public static func isActive(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment.keys.contains { $0.hasPrefix(prefix) }
    }

    public func secret(for key: SecretKey) throws -> String? {
        if key.kind == .password, let value = environment[Self.prefix + key.profileID.uuidString.uppercased()] { return value }
        return try fallback.secret(for: key)
    }

    public func setSecret(_ value: String?, for key: SecretKey) throws {
        try fallback.setSecret(value, for: key)
    }
}

// MARK: - Repository

/// Persists profiles as JSON (atomic writes, 0600) and their secrets in a `SecretStore`.
public final class ProfileRepository: Sendable {
    public let directory: URL
    private let secrets: any SecretStore

    /// `CCINNCLICKHOUSE_PROFILE_DIR` overrides the location (used by tests and for portable setups).
    public static var defaultDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["CCINNCLICKHOUSE_PROFILE_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("CcinnClickHouse", isDirectory: true)
    }

    public init(directory: URL = ProfileRepository.defaultDirectory, secrets: any SecretStore = KeychainSecretStore()) {
        self.directory = directory
        self.secrets = secrets
    }

    private var fileURL: URL { directory.appendingPathComponent("connections.json") }

    public func load() throws -> [ConnectionProfile] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([ConnectionProfile].self, from: data)
    }

    public func save(_ profiles: [ConnectionProfile]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try PrivateFile.write(try encoder.encode(profiles), to: fileURL)
    }

    public func storeSecrets(for profile: ConnectionProfile, password: String?, sshSecret: String?) throws {
        try secrets.setSecret(password, for: SecretKey(profileID: profile.id, kind: .password))
        try secrets.setSecret(sshSecret, for: SecretKey(profileID: profile.id, kind: .sshSecret))
    }

    public func password(for profile: ConnectionProfile) -> String? {
        try? secrets.secret(for: SecretKey(profileID: profile.id, kind: .password))
    }

    public func sshSecret(for profile: ConnectionProfile) -> String? {
        try? secrets.secret(for: SecretKey(profileID: profile.id, kind: .sshSecret))
    }

    public func delete(_ profile: ConnectionProfile) throws {
        try secrets.setSecret(nil, for: SecretKey(profileID: profile.id, kind: .password))
        try secrets.setSecret(nil, for: SecretKey(profileID: profile.id, kind: .sshSecret))
    }
}

/// Opens a `ClickHouseClient` for a saved profile, through its SSH tunnel when configured.
/// Shared by the app and the MCP server.
public enum ClientOpener {
    public static func open(profile: ConnectionProfile, password: String, sshSecret: String?, readOnlyOverride: Bool = false,
                            progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> ClickHouseClient {
        if Task.isCancelled { throw ClickHouseError.cancelled() }
        var configuration = profile.configuration(password: password)
        if readOnlyOverride { configuration.readOnly = true }
        var tunnel: SSHTunnel?
        if let ssh = profile.ssh {
            progress("Opening SSH tunnel through \(ssh.host)…")
            tunnel = try await SSHTunnel.open(configuration: ssh, secret: ssh.authentication == .agent ? nil : sshSecret, remote: configuration.endpoint)
        }
        progress("Connecting to \(profile.endpoint) as \(profile.username)…")
        do {
            return try await ClickHouseClient.connect(configuration, tunnel: tunnel)
        } catch {
            // connect() already closed the tunnel it was handed; this covers errors thrown before that.
            tunnel?.close()
            throw error
        }
    }
}
