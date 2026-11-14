import Foundation
import Testing
@testable import ClickHouseKit

@Suite("SSH tunnel arguments and secrets")
struct SSHTunnelTests {
    let remote = Endpoint(host: "clickhouse.internal", port: 8443)

    @Test func privateKeyModeNeverFallsBackToPasswords() throws {
        let configuration = SSHTunnelConfiguration(host: "bastion", username: "ops", authentication: .privateKey, privateKeyPath: "~/.ssh/id_ed25519")
        let arguments = try SSHTunnel.arguments(for: configuration, localPort: 40000, remote: remote)
        #expect(arguments.contains("PreferredAuthentications=publickey"))
        #expect(arguments.contains("PasswordAuthentication=no"))
        #expect(arguments.contains("KbdInteractiveAuthentication=no"))
        #expect(arguments.contains("127.0.0.1:40000:clickhouse.internal:8443"))
        #expect(arguments.last == "ops@bastion")
        #expect(!arguments.contains { $0.hasPrefix("~") })
    }

    @Test func agentModeRefusesPasswordPrompts() throws {
        let arguments = try SSHTunnel.arguments(for: SSHTunnelConfiguration(host: "bastion", username: "", authentication: .agent), localPort: 1, remote: remote)
        #expect(arguments.contains("PasswordAuthentication=no"))
        #expect(arguments.last == "bastion")
    }

    @Test func optionInjectionIsRejected() {
        #expect(throws: ClickHouseError.self) {
            try SSHTunnel.arguments(for: SSHTunnelConfiguration(host: "-oProxyCommand=evil", username: "u", authentication: .agent), localPort: 1, remote: remote)
        }
        #expect(throws: ClickHouseError.self) {
            try SSHTunnel.arguments(for: SSHTunnelConfiguration(host: "bastion", username: "u x", authentication: .agent), localPort: 1, remote: remote)
        }
        #expect(throws: ClickHouseError.self) {
            try SSHTunnel.arguments(for: SSHTunnelConfiguration(host: "bastion", port: 0, username: "u", authentication: .agent), localPort: 1, remote: remote)
        }
        #expect(throws: ClickHouseError.self) {
            try SSHTunnel.arguments(for: SSHTunnelConfiguration(host: "bastion", username: "u", authentication: .agent), localPort: 1,
                                    remote: Endpoint(host: "-L1:2:3", port: 1))
        }
    }

    @Test func secretFilesAreOwnerOnlyAndRemoved() throws {
        let file = try AskPassHelper.shared.writeSecret("hunter2")
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        #expect(try String(contentsOf: file, encoding: .utf8) == "hunter2")
        AskPassHelper.shared.removeSecret(file)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        // The askpass script reads the file named in the environment; the secret is never in argv.
        let script = try String(contentsOfFile: try AskPassHelper.shared.path(), encoding: .utf8)
        #expect(script.contains("CCINNCH_ASKPASS_FILE"))
    }

    @Test func freeLocalPortIsUsable() throws {
        let port = try SSHTunnel.freeLocalPort()
        #expect((1024...65535).contains(port))
        #expect(!SSHTunnel.canConnect(port: port))
    }
}
