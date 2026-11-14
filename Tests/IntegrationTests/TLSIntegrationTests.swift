import ClickHouseKit
import Foundation
import Testing

/// HTTPS with a private CA. Enable with `CCINNCH_IT_TLS_URL=https://127.0.0.1:18143` and
/// `CCINNCH_IT_TLS_CA=/path/ca.pem` (certificate for clickhouse.test, localhost and 127.0.0.1).
enum TLSEnvironment {
    static let environment = ProcessInfo.processInfo.environment
    static let url = environment["CCINNCH_IT_TLS_URL"].flatMap(URL.init(string:))
    static let caPath = environment["CCINNCH_IT_TLS_CA"]
    static var enabled: Bool { url != nil && caPath != nil }

    static func configuration(tls: TLSOptions, serverName: String? = nil) -> ConnectionConfiguration {
        var configuration = ITEnvironment.configuration(url: url)
        configuration.secure = true
        configuration.tls = tls
        configuration.tlsServerName = serverName
        return configuration
    }
}

@Suite("HTTPS", .enabled(if: TLSEnvironment.enabled), .serialized)
struct TLSIntegrationTests {
    var pem: String { (try? String(contentsOfFile: TLSEnvironment.caPath ?? "", encoding: .utf8)) ?? "" }

    @Test func untrustedCertificateIsRejected() async {
        do {
            _ = try await ClickHouseClient.connect(TLSEnvironment.configuration(tls: TLSOptions()))
            Issue.record("expected a TLS failure")
        } catch let error as ClickHouseError {
            #expect(error.kind == .tls || error.kind == .network)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func customCAIsTrusted() async throws {
        let client = try await ClickHouseClient.connect(TLSEnvironment.configuration(tls: TLSOptions(customCACertificate: pem)))
        defer { Task { await client.close() } }
        #expect(try await client.run("SELECT 'tls ok'").scalar == "tls ok")
        // Large responses are compressed and still decoded over TLS.
        #expect(try await client.run("SELECT number FROM numbers(200000)", options: QueryOptions(limits: RowLimits(maxRows: 300_000))).rows.count == 200_000)
    }

    @Test func certificateIsCheckedAgainstTheOriginalHostThroughATunnel() async throws {
        // As through an SSH tunnel: we dial 127.0.0.1 but verify the name of the real server.
        let good = try await ClickHouseClient.connect(TLSEnvironment.configuration(tls: TLSOptions(customCACertificate: pem), serverName: "clickhouse.test"))
        await good.close()
        await #expect(throws: ClickHouseError.self) {
            _ = try await ClickHouseClient.connect(TLSEnvironment.configuration(tls: TLSOptions(customCACertificate: pem), serverName: "evil.example"))
        }
    }

    @Test func skipVerificationConnects() async throws {
        let client = try await ClickHouseClient.connect(TLSEnvironment.configuration(tls: TLSOptions(skipVerification: true)))
        #expect(client.serverInfo.version != nil)
        await client.close()
    }
}
