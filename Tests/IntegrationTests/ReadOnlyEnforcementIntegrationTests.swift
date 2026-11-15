import ClickHouseKit
import ClickHouseWire
import Foundation
import Network
import os
import Testing
@testable import CcinnClickHouseKit

/// A local HTTP endpoint that counts requests, so a test can prove that a statement did not reach out
/// (server-side request forgery through `url()` and friends). The containers reach it as
/// `host.docker.internal` (override with `CCINNCH_IT_LISTENER_HOST`).
final class RequestListener: @unchecked Sendable {
    static let containerHost = ProcessInfo.processInfo.environment["CCINNCH_IT_LISTENER_HOST"] ?? "host.docker.internal"

    private let listener: NWListener
    private let queue = DispatchQueue(label: "ccinnch.it.listener")
    private let paths = OSAllocatedUnfairLock<[String]>(initialState: [])
    let port: UInt16

    init(port: UInt16) async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
        self.port = port
        listener.newConnectionHandler = { [paths, queue] connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, _ in
                let head = data.map { String(decoding: $0.prefix(512), as: UTF8.self) } ?? ""
                let path = head.split(separator: " ").dropFirst().first.map(String.init) ?? "?"
                paths.withLock { $0.append(path) }
                let body = "pwned"
                connection.send(content: Data("HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8),
                                completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        let ready = OSAllocatedUnfairLock<Bool?>(initialState: nil)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.withLock { $0 = true }
            case .failed, .cancelled: ready.withLock { $0 = $0 ?? false }
            default: break
            }
        }
        listener.start(queue: queue)
        let deadline = ContinuousClock.now + .seconds(5)
        while ready.withLock({ $0 }) == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        guard ready.withLock({ $0 }) == true else { throw ClickHouseError(.network, "The test listener could not start on 127.0.0.1:\(port)") }
    }

    var requests: [String] { paths.withLock { $0 } }
    func url(_ path: String) -> String { "http://\(Self.containerHost):\(port)/\(path)" }
    func stop() { listener.cancel() }
}

/// Statements a read-only connection (MCP read-only access, read-only profiles) must never run. Each
/// either reaches outside the server, changes state, or lifts the limits. `serverRefuses` records
/// what ClickHouse itself does at readonly=1 (measured on 22.8, 24.8 and 26.8): the app guard refuses
/// all of them either way.
struct ReadOnlyCase: Sendable, CustomTestStringConvertible {
    let name: String
    let sql: @Sendable (RequestListener) -> String
    let serverRefuses: Bool
    var testDescription: String { name }

    static let all: [ReadOnlyCase] = [
        ReadOnlyCase(name: "url", sql: { "SELECT * FROM url('\($0.url("url"))', 'RawBLOB')" }, serverRefuses: true),
        ReadOnlyCase(name: "urlCluster", sql: { "SELECT * FROM urlCluster('ccinn_cluster', '\($0.url("urlcluster"))', 'RawBLOB')" }, serverRefuses: true),
        ReadOnlyCase(name: "s3", sql: { "SELECT * FROM s3('\($0.url("s3/x.csv"))', 'CSV', 'a String')" }, serverRefuses: true),
        ReadOnlyCase(name: "s3Cluster", sql: { "SELECT * FROM s3Cluster('ccinn_cluster', '\($0.url("s3c/x.csv"))', 'CSV', 'a String')" }, serverRefuses: true),
        ReadOnlyCase(name: "file", sql: { _ in "SELECT * FROM file('/etc/passwd', 'LineAsString')" }, serverRefuses: true),
        ReadOnlyCase(name: "remote", sql: { "SELECT * FROM remote('\(RequestListener.containerHost):\($0.port)', system.one)" }, serverRefuses: true),
        ReadOnlyCase(name: "remoteSecure", sql: { "SELECT * FROM remoteSecure('\(RequestListener.containerHost):\($0.port)', system.one)" }, serverRefuses: true),
        ReadOnlyCase(name: "hdfs", sql: { "SELECT * FROM hdfs('hdfs://\(RequestListener.containerHost):\($0.port)/x', 'CSV', 'a String')" }, serverRefuses: true),
        ReadOnlyCase(name: "mysql", sql: { "SELECT * FROM mysql('\(RequestListener.containerHost):\($0.port)', 'd', 't', 'u', 'p')" }, serverRefuses: true),
        ReadOnlyCase(name: "postgresql", sql: { "SELECT * FROM postgresql('\(RequestListener.containerHost):\($0.port)', 'd', 't', 'u', 'p')" }, serverRefuses: true),
        ReadOnlyCase(name: "jdbc", sql: { _ in "SELECT * FROM jdbc('jdbc:mysql://h/db', 't')" }, serverRefuses: true),
        ReadOnlyCase(name: "odbc", sql: { _ in "SELECT * FROM odbc('DSN=x', 'db', 't')" }, serverRefuses: true),
        ReadOnlyCase(name: "executable", sql: { _ in "SELECT * FROM executable('id', 'TSV', 'x String')" }, serverRefuses: true),
        ReadOnlyCase(name: "input", sql: { _ in "SELECT * FROM input('x String')" }, serverRefuses: true),
        ReadOnlyCase(name: "dictionary", sql: { _ in "SELECT * FROM dictionary('nonexistent_dictionary')" }, serverRefuses: true),
        ReadOnlyCase(name: "insert into function", sql: { "INSERT INTO FUNCTION url('\($0.url("insert"))', 'CSV', 'a String') VALUES ('x')" }, serverRefuses: true),
        ReadOnlyCase(name: "system flush logs", sql: { _ in "SYSTEM FLUSH LOGS" }, serverRefuses: true),
        ReadOnlyCase(name: "optimize", sql: { _ in "OPTIMIZE TABLE system.one" }, serverRefuses: true),
        ReadOnlyCase(name: "settings readonly=0", sql: { "SELECT * FROM url('\($0.url("settings"))', 'RawBLOB') SETTINGS readonly = 0" }, serverRefuses: true),
        ReadOnlyCase(name: "settings change", sql: { _ in "SELECT 1 SETTINGS max_threads = 3, max_result_rows = 7" }, serverRefuses: true),
        ReadOnlyCase(name: "into outfile", sql: { _ in "SELECT 1 INTO OUTFILE '/tmp/ccinnch-it-outfile'" }, serverRefuses: true),
        // ClickHouse allows these at readonly=1 (a "change" to the current value is not a change); the
        // guard still refuses them for AI access.
        ReadOnlyCase(name: "settings same value", sql: { _ in "SELECT 1 SETTINGS max_execution_time = 0, max_result_rows = 0" }, serverRefuses: false),
        ReadOnlyCase(name: "kill query", sql: { _ in "KILL QUERY WHERE query_id = 'ccinnch-it-nothing' ASYNC" }, serverRefuses: false),
        ReadOnlyCase(name: "explain insert", sql: { _ in "EXPLAIN AST INSERT INTO t VALUES (1)" }, serverRefuses: false),
    ]
}

private func mcpTools(_ profile: ConnectionProfile, password: String) -> ClickHouseMCPTools {
    ClickHouseMCPTools(resolver: MCPProfileResolver(profiles: [profile], defaultProfile: nil, forceReadOnly: false),
                       registry: MCPClientRegistry { profile, access in
                           try await ClientOpener.open(profile: profile, password: password, sshSecret: nil, readOnlyOverride: access != .readWrite)
                       }, audit: nil)
}

extension LiveSuites {
    @Suite("Read-only access never reaches out (single node)", .serialized)
    struct ReadOnlyEnforcementIntegrationTests {
        static let port: UInt16 = 18198

        @Test func positiveControlAndEveryCaseRefused() async throws {
            let listener = try await RequestListener(port: Self.port)
            defer { listener.stop() }
            // Positive control: without readonly the server does reach the listener, so "no request"
            // below means something.
            let writable = try await ITEnvironment.connect()
            defer { Task { await writable.close() } }
            _ = try await writable.run("SELECT * FROM url('\(listener.url("control"))', 'RawBLOB')")
            #expect(await waitUntil(.seconds(5)) { listener.requests.contains("/control") })

            let target = try #require(ITEnvironment.url)
            let profile = ConnectionProfile(name: "Live", host: target.host ?? "127.0.0.1", port: target.port ?? 8123,
                                            username: ITEnvironment.user, mcpAccess: .readOnly)
            let tools = mcpTools(profile, password: ITEnvironment.password)
            let readOnly = try await ITEnvironment.connect(readOnly: true)
            defer { Task { await readOnly.close() } }
            #expect(readOnly.serverInfo.readonlyLevel == 1)
            for testCase in ReadOnlyCase.all {
                let sql = testCase.sql(listener)
                let refused = await tools.call(name: "run_query", arguments: ["sql": .string(sql)])
                #expect(refused.isError, "MCP run_query must refuse \(testCase.name)")
                // Bypass the guard: the server must refuse too wherever ClickHouse enforces it.
                var serverError: ClickHouseError?
                do { _ = try await readOnly.run(sql, options: QueryOptions(timeout: 15)) } catch let error as ClickHouseError { serverError = error }
                if testCase.serverRefuses {
                    #expect(serverError != nil, "the server ran \(testCase.name) at readonly=1")
                }
            }
            try await Task.sleep(for: .seconds(1))
            // `url()` may probe before reading (HEAD, then GET), so the control can appear more than once.
            #expect(Set(listener.requests) == ["/control"], "read-only statements reached the listener: \(listener.requests)")
        }
    }
}

extension LiveSuites {
    /// The setup the app recommends (ReadOnlyAdvice.setupSQL): a dedicated user whose settings profile is
    /// read-only and who has SELECT grants only. The server enforces read-only access by itself and denies
    /// external access through missing grants, independent of the app's parameter and guard.
    @Suite("Recommended dedicated read-only user", .serialized)
    struct RecommendedReadOnlyUserTests {
        static let user = "ccinnch_ai_reader"
        static let password = "ai-reader-pass"

        @Test func dedicatedReadOnlyUserWorksForAIAccessAndIsDeniedExternalAccess() async throws {
            let admin = try await ITEnvironment.connect()
            defer { Task { await admin.close() } }
            for statement in [
                "CREATE SETTINGS PROFILE OR REPLACE ccinnch_ai_readonly SETTINGS readonly = 1",
                "CREATE USER OR REPLACE \(Self.user) IDENTIFIED WITH sha256_password BY '\(Self.password)' SETTINGS PROFILE 'ccinnch_ai_readonly'",
                "GRANT SELECT ON shop.* TO \(Self.user)",
            ] { _ = try await admin.run(statement) }
            defer {
                Task {
                    _ = try? await admin.run("DROP USER IF EXISTS \(Self.user)")
                    _ = try? await admin.run("DROP SETTINGS PROFILE IF EXISTS ccinnch_ai_readonly")
                }
            }
            let listener = try await RequestListener(port: 18196)
            defer { listener.stop() }

            // Read-only profile: enforced by the user's own profile (no reliance on the URL parameter).
            let reader = try await ClickHouseClient.connect(ITEnvironment.configuration(user: Self.user, password: Self.password, readOnly: true))
            defer { Task { await reader.close() } }
            #expect(reader.serverInfo.readonlyLevel == 1)
            #expect(reader.capabilities.settingsLocked)
            #expect(try await reader.run("SELECT count() FROM shop.events").rows.first?.first != nil)
            for sql in ["SELECT * FROM url('\(listener.url("ai"))', 'RawBLOB')", "SELECT * FROM file('/etc/passwd', 'LineAsString')",
                        "CREATE TABLE shop.ai_should_not_exist (a UInt8) ENGINE = Memory"] {
                await #expect(throws: ClickHouseError.self, "\(sql)") { _ = try await reader.run(sql, options: QueryOptions(timeout: 15)) }
            }

            // MCP read-only access as this user: metadata and queries work; external access is refused.
            let target = try #require(ITEnvironment.url)
            let profile = ConnectionProfile(name: "AI", host: target.host ?? "127.0.0.1", port: target.port ?? 8123, username: Self.user,
                                            mcpAccess: .readOnly)
            let tools = ClickHouseMCPTools(resolver: MCPProfileResolver(profiles: [profile], defaultProfile: nil, forceReadOnly: false),
                                           registry: MCPClientRegistry { profile, access in
                                               try await ClientOpener.open(profile: profile, password: Self.password, sshSecret: nil,
                                                                           readOnlyOverride: access != .readWrite)
                                           }, audit: nil)
            let tables = await tools.call(name: "list_tables", arguments: ["database": "shop"])
            #expect(!tables.isError, "\(tables.payload)")
            let query = await tools.call(name: "run_query", arguments: ["sql": "SELECT count() AS n FROM shop.events"])
            #expect(!query.isError, "\(query.payload)")
            #expect(await tools.call(name: "run_query", arguments: ["sql": .string("SELECT * FROM url('\(listener.url("ai-mcp"))', 'RawBLOB')")]).isError)
            try await Task.sleep(for: .seconds(1))
            #expect(listener.requests.isEmpty, "\(listener.requests)")
        }
    }
}

extension ClusterIntegrationTests {
    /// chproxy drops `readonly` from the URL (verified on chproxy 1.30): read-only access through it is
    /// refused unless the ClickHouse user behind it is read-only itself.
    @Test func readOnlyThroughChproxyFailsClosedOrUsesAReadOnlyUser() async throws {
        let listener = try await RequestListener(port: 18197)
        defer { listener.stop() }
        // Positive control through the proxy: a full-grant user's readonly=1 parameter is dropped.
        let raw = try await ClickHouseClient.connect(ITEnvironment.configuration(url: ClusterEnvironment.proxy))
        defer { Task { await raw.close() } }
        _ = try await raw.run("SELECT * FROM url('\(listener.url("proxy-control"))', 'RawBLOB')", options: QueryOptions(readOnly: true))
        #expect(await waitUntil(.seconds(5)) { listener.requests.contains("/proxy-control") }, "chproxy forwarded readonly=1 after all")

        // 1. A read-only connection as the full-grant user is refused before anything runs.
        do {
            _ = try await ClickHouseClient.connect(ITEnvironment.configuration(readOnly: true, url: ClusterEnvironment.proxy))
            Issue.record("a read-only connection through chproxy must fail closed")
        } catch let error as ClickHouseError {
            #expect(error.kind == .readOnlyNotEnforced)
        }
        let fullGrant = ConnectionProfile(name: "Proxy", host: "127.0.0.1", port: 18110, username: ITEnvironment.user,
                                          defaultCluster: ClusterEnvironment.cluster, mcpAccess: .readOnly)
        let refused = await mcpTools(fullGrant, password: ITEnvironment.password).call(name: "list_databases", arguments: [:])
        #expect(refused.isError)
        #expect(refused.payload.stringValue?.contains("readonly=1") == true)

        // 2. The proxy user mapped to a read-only ClickHouse user works, and the server refuses what the
        //    guard would refuse.
        let readerProfile = ConnectionProfile(name: "Proxy reader", host: "127.0.0.1", port: 18110, username: "reader",
                                              defaultCluster: ClusterEnvironment.cluster, mcpAccess: .readOnly)
        let tools = mcpTools(readerProfile, password: "reader-pass")
        let cluster = await tools.call(name: "get_cluster", arguments: [:])
        #expect(!cluster.isError, "\(cluster.payload)")
        let reader = try await ClickHouseClient.connect(ITEnvironment.configuration(user: "reader", password: "reader-pass", readOnly: true,
                                                                                    url: ClusterEnvironment.proxy))
        defer { Task { await reader.close() } }
        #expect(reader.serverInfo.readonlyLevel == 1)
        for testCase in ReadOnlyCase.all {
            let sql = testCase.sql(listener)
            #expect(await tools.call(name: "run_query", arguments: ["sql": .string(sql)]).isError, "\(testCase.name)")
            if testCase.serverRefuses {
                await #expect(throws: ClickHouseError.self, "\(testCase.name)") { _ = try await reader.run(sql, options: QueryOptions(timeout: 15)) }
            }
        }
        try await Task.sleep(for: .seconds(1))
        #expect(Set(listener.requests) == ["/proxy-control"], "read-only statements reached the listener: \(listener.requests)")
    }
}
