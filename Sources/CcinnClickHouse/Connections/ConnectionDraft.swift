import CcinnClickHouseKit
import ClickHouseKit
import Foundation
import Observation

/// Editable copy of a connection profile plus its secrets, with "Test connection".
@MainActor
@Observable
final class ConnectionDraft {
    enum TestState: Equatable {
        case idle
        case running(String)
        case succeeded(String)
        case failed(String)
    }

    let profileID: UUID?
    var name: String
    var color: ProfileColor
    var isFavorite: Bool
    var host: String
    var port: Int
    var secure: Bool {
        didSet {
            // Follow the conventional port when the user flips the protocol without customising it.
            if secure, port == 8123 { port = 8443 }
            if !secure, port == 8443 { port = 8123 }
        }
    }
    var pathPrefix: String
    var username: String
    var password: String
    var defaultDatabase: String
    var defaultCluster: String
    var compression: Bool
    var readOnly: Bool
    var customCACertificate: String
    var skipTLSVerification: Bool
    var confirmMutations: Bool
    var connectTimeout: Double
    var mcpAccess: MCPAccess
    var mcpAllowPrivilegedUser: Bool
    var sshEnabled: Bool
    var ssh: SSHTunnelConfiguration
    var sshSecret: String
    var testState: TestState = .idle

    private let original: ConnectionProfile?
    private var testTask: Task<Void, Never>?
    private var testGeneration: UInt64 = 0

    init(profile: ConnectionProfile?, store: ProfileStore) {
        original = profile
        profileID = profile?.id
        let base = profile ?? ConnectionProfile(color: .orange)
        name = base.name
        color = base.color
        isFavorite = base.isFavorite
        host = base.host
        port = base.port
        secure = base.secure
        pathPrefix = base.pathPrefix
        username = base.username
        password = profile.flatMap(store.password(for:)) ?? ""
        defaultDatabase = base.defaultDatabase ?? ""
        defaultCluster = base.defaultCluster ?? ""
        compression = base.compression
        readOnly = base.readOnly
        customCACertificate = base.customCACertificate ?? ""
        skipTLSVerification = base.skipTLSVerification
        confirmMutations = base.confirmMutations
        connectTimeout = base.connectTimeout
        mcpAccess = base.mcpAccess
        mcpAllowPrivilegedUser = base.mcpAllowPrivilegedUser
        sshEnabled = base.ssh != nil
        ssh = base.ssh ?? SSHTunnelConfiguration(host: "", username: NSUserName(), authentication: .agent)
        sshSecret = profile.flatMap(store.sshSecret(for:)) ?? ""
    }

    func makeProfile() -> ConnectionProfile {
        var profile = original ?? ConnectionProfile()
        profile.name = name.trimmingCharacters(in: .whitespaces)
        profile.color = color
        profile.isFavorite = isFavorite
        profile.host = host.trimmingCharacters(in: .whitespaces)
        profile.port = port
        profile.secure = secure
        profile.pathPrefix = pathPrefix.trimmingCharacters(in: .whitespaces)
        profile.username = username.trimmingCharacters(in: .whitespaces)
        profile.defaultDatabase = defaultDatabase.nilIfEmpty
        profile.defaultCluster = defaultCluster.nilIfEmpty
        profile.compression = compression
        profile.readOnly = readOnly
        profile.customCACertificate = secure ? customCACertificate.nilIfEmpty : nil
        profile.skipTLSVerification = secure && skipTLSVerification
        profile.confirmMutations = confirmMutations
        profile.connectTimeout = min(max(connectTimeout, 1), 120)
        profile.mcpAccess = mcpAccess
        profile.mcpAllowPrivilegedUser = mcpAllowPrivilegedUser
        profile.ssh = sshEnabled ? ssh : nil
        return profile
    }

    var validationErrors: [String] { makeProfile().validationErrors }
    var isValid: Bool { validationErrors.isEmpty }

    func test() {
        testTask?.cancel()
        testGeneration &+= 1
        let generation = testGeneration
        let profile = makeProfile()
        let password = password
        let sshSecret = sshEnabled && ssh.authentication != .agent ? sshSecret : nil
        testState = .running("Connecting to \(profile.endpoint)…")
        let report: @Sendable (String) -> Void = { status in
            Task { @MainActor in
                guard self.testGeneration == generation, case .running = self.testState else { return }
                self.testState = .running(status)
            }
        }
        testTask = Task {
            do {
                let client = try await ConnectionOpener.open(profile: profile, password: password, sshSecret: sshSecret, progress: report)
                let info = client.serverInfo
                let databases = (try? await client.databases().count) ?? 0
                let locked = client.capabilities.settingsLocked
                let enforcedByUserProfile = locked || client.capabilities.serverEnforcesReadOnly
                await client.close()
                guard !Task.isCancelled, testGeneration == generation else { return }
                var message = "Connected to \(info.version.map { "ClickHouse \($0.raw)" } ?? info.versionString)"
                message += " · \(databases) databases"
                if let user = info.currentUser { message += " · \(user)" }
                if let zone = info.timeZone { message += " · \(zone)" }
                if let note = ReadOnlyAdvice.connectionNote(profileIsReadOnly: profile.readOnly, enforcedByUserProfile: enforcedByUserProfile) {
                    message += " · \(note)"
                }
                if locked { message += " · settings are fixed by the server" }
                testState = .succeeded(message)
            } catch {
                guard !Task.isCancelled, testGeneration == generation else { return }
                testState = .failed(describe(error))
            }
        }
    }

    func cancelTest() {
        testTask?.cancel()
        testTask = nil
        testGeneration &+= 1
        testState = .idle
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
