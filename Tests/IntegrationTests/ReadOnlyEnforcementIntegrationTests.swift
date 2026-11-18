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

/// Review: on a read-only connection the editor runs `USE db` through `ReadOnlySQLGuard.prepare`, and ClickHouse runs it
/// at readonly=1.
@Suite("Read-only USE", .enabled(if: ITEnvironment.enabled))
struct ReadOnlyUseIntegrationTests {
    @Test func useRunsOnAReadOnlyConnection() async throws {
        let client = try await ITEnvironment.connect(readOnly: true)
        defer { Task { await client.close() } }
        // In a session, as the editor runs it (22.8 refuses USE without one).
        let session = client.openSession(database: "default")
        for sql in ["USE shop", "USE `shop` /* switch */"] {
            let prepared = try ReadOnlySQLGuard.prepare(sql, autoLimit: 1_000).get()
            #expect(prepared.text == sql)
            _ = try await session.run(prepared.text)
            #expect(try await session.run("SELECT currentDatabase()").scalar == "shop")
        }
        await session.close()
    }
}

/// Review (A): read-only AI tools check the ClickHouse user's grants when they connect.
@Suite("AI access privilege check", .enabled(if: ITEnvironment.enabled), .serialized)
struct AIPrivilegeCheckIntegrationTests {
    private func tools(_ profile: ConnectionProfile, password: String) -> ClickHouseMCPTools {
        let registry = MCPClientRegistry { profile, access in
            try await ClientOpener.open(profile: profile, password: password, sshSecret: nil, readOnlyOverride: access != .readWrite)
        }
        return ClickHouseMCPTools(resolver: MCPProfileResolver(profiles: [profile], defaultProfile: nil, forceReadOnly: false), registry: registry,
                                  audit: nil)
    }

    private func profile(user: String, allow: Bool = false) -> ConnectionProfile {
        let endpoint = ITEnvironment.configuration().endpoint
        return ConnectionProfile(name: "AI \(user)", host: endpoint.host, port: endpoint.port, username: user, defaultDatabase: "shop",
                                 connectTimeout: 30, mcpAccess: .readOnly, mcpAllowPrivilegedUser: allow)
    }

    /// The admin (ALL) and the server-profile read-only user (SOURCES, SYSTEM … on every version) are refused by
    /// default; allowed when the connection opts in.
    @Test func privilegedUsersAreRefusedByDefault() async throws {
        for (user, password) in [(ITEnvironment.user, ITEnvironment.password), ("reader", "reader-pass")] {
            let refused = await tools(profile(user: user), password: password).call(name: "list_tables", arguments: ["database": "shop"])
            #expect(refused.isError, "\(user)")
            #expect(refused.payload.stringValue?.contains("SELECT grants only") == true, "\(user): \(refused.payload.stringValue ?? "")")
            let allowed = await tools(profile(user: user, allow: true), password: password).call(name: "list_tables", arguments: ["database": "shop"])
            #expect(!allowed.isError, "\(user) allowed: \(allowed.payload.stringValue ?? "")")
        }
    }

    /// A user with SELECT on one database only is allowed: the recommended setup.
    @Test func aSelectOnlyUserIsAllowed() async throws {
        let admin = try await ITEnvironment.connect()
        defer { Task { await admin.close() } }
        let user = "ccinn_ai_\(UInt32.random(in: 0...UInt32.max))"
        let password = "pw-\(UUID().uuidString)"
        _ = try await admin.run("CREATE USER \(user) IDENTIFIED WITH plaintext_password BY '\(password)'")
        _ = try await admin.run("GRANT SELECT ON shop.* TO \(user)")
        do {
            let tools = tools(profile(user: user), password: password)
            let tables = await tools.call(name: "list_tables", arguments: ["database": "shop"])
            #expect(!tables.isError, "\(tables.payload.stringValue ?? "")")
            let count = await tools.call(name: "run_query", arguments: ["sql": "SELECT count() FROM shop.events"])
            #expect(!count.isError, "\(count.payload.stringValue ?? "")")
            // The guard still refuses what the grants would deny anyway.
            #expect(await tools.call(name: "run_query", arguments: ["sql": "SELECT * FROM file('x', 'LineAsString')"]).isError)
            // Grants are checked on every call: a privilege granted mid-session refuses the next call.
            _ = try await admin.run("GRANT FILE ON *.* TO \(user)")
            let after = await tools.call(name: "list_tables", arguments: ["database": "shop"])
            #expect(after.isError && after.payload.stringValue?.contains("sources") == true, "\(after.payload.stringValue ?? "")")
        }
        _ = try? await admin.run("DROP USER IF EXISTS \(user)")
    }

    /// Review (deny by default): AI access reads `system` through an allow-list and table functions through one, and
    /// never receives object definitions, on any version: 22.8 prints MySQL and dictionary passwords, 24.8 still prints
    /// credentials in URLs, 22.8/24.8 inline view queries into EXPLAIN SYNTAX, and 26.8 prints view literals in plans.
    /// The user holds SELECT ON *.* only, as in the review.
    @Test func aiReadsSystemThroughTheAllowListAndNeverReadsDefinitions() async throws {
        let admin = try await ITEnvironment.connect()
        defer { Task { await admin.close() } }
        let suffix = UInt32.random(in: 0...UInt32.max)
        let user = "zz_mw5_\(suffix)", password = "pw-\(UUID().uuidString)"
        let mysqlTable = "shop.zz_mw5_mysql_\(suffix)", dictionary = "shop.zz_mw5_dict_\(suffix)"
        let urlView = "shop.zz_mw5_url_\(suffix)", filterView = "shop.zz_mw5_filter_\(suffix)", function = "zz_mw5_udf_\(suffix)"
        _ = try await admin.run("CREATE TABLE \(mysqlTable) (a Int8) ENGINE = MySQL('127.0.0.1:1', 'db', 't', 'u', 'ZZSECRET1')")
        _ = try await admin.run("""
            CREATE DICTIONARY \(dictionary) (k UInt64, v String) PRIMARY KEY k SOURCE(CLICKHOUSE(HOST 'localhost' PORT 9000 USER 'default' \
            PASSWORD 'ZZSECRET2' DB 'shop' TABLE 'events')) LAYOUT(FLAT()) LIFETIME(0)
            """)
        _ = try await admin.run("CREATE VIEW \(urlView) AS SELECT * FROM url('http://zzuser:ZZSECRET3@127.0.0.1:1/x.csv', CSV, 'a String')")
        _ = try await admin.run("CREATE VIEW \(filterView) AS SELECT dummy FROM system.one WHERE toString(dummy) != 'ZZSECRET4'")
        _ = try await admin.run("CREATE FUNCTION \(function) AS () -> 'ZZSECRET5'")
        _ = try await admin.run("CREATE USER \(user) IDENTIFIED WITH plaintext_password BY '\(password)'")
        _ = try await admin.run("GRANT SELECT ON *.* TO \(user)")
        do {
            let tools = tools(profile(user: user), password: password)
            func run(_ sql: String) async -> MCPToolResult { await tools.call(name: "run_query", arguments: ["sql": .string(sql)]) }
            func expectNoSecret(_ result: MCPToolResult, _ label: String) {
                let text = result.payload.serialized()
                #expect(!text.contains("ZZSECRET"), "\(label): a definition reached AI access: \(text.prefix(300))")
            }
            // Other sessions' SQL text: refused in every form (the reviewer's repros).
            for sql in ["SELECT command FROM system.mutations", "SELECT * FROM loop('system', 'query_log')", "SELECT * FROM loop(system, query_log)",
                        "SELECT query FROM system.query_log", "SELECT * FROM merge('system', '^query')", "SELECT count() FROM `\\x73ystem`.query_log"] {
                let result = await run(sql)
                // Refused by the guard (its message), never by the server or after reading anything.
                let reason = result.payload.stringValue ?? ""
                #expect(result.isError && (reason.contains("AI access") || reason.contains("escape")), "\(sql): \(reason)")
            }
            #expect(!(await run("SELECT name, engine FROM system.tables WHERE database = 'shop' ORDER BY name LIMIT 3")).isError)
            #expect(!(await run("SELECT count(*) FROM system.tables WHERE database = 'shop'")).isError)
            // Definitions: refused by the guard on every version, with any qualifier, quoting, `*` or SHOW form.
            let names = "database = 'shop' AND name LIKE 'zz_mw5_%\(suffix)'"
            for sql in ["SELECT create_table_query FROM system.tables WHERE \(names)", "SELECT t.create_table_query FROM system.tables AS t WHERE \(names)",
                        "SELECT tables.as_select FROM system.tables WHERE \(names)", "SELECT `engine_full` FROM system.tables WHERE \(names)",
                        "SELECT tuple(*) FROM system.tables WHERE \(names)", "SELECT formatRow('TSV', *) FROM system.tables WHERE \(names)",
                        "SELECT [*] FROM system.tables WHERE \(names)", "SELECT `\\x63reate_table_query` FROM system.tables WHERE \(names)",
                        "SELECT view_definition FROM information_schema.views WHERE table_schema = 'shop'",
                        "SELECT * FROM information_schema.views WHERE table_schema = 'shop'",
                        "SELECT create_query FROM system.functions WHERE name = '\(function)'", "SELECT * FROM system.functions WHERE name = '\(function)'",
                        "SHOW CREATE TABLE \(mysqlTable)", "SHOW CREATE TABLE \(urlView)", "SHOW CREATE DICTIONARY \(dictionary)",
                        "SHOW TABLE \(urlView)", "SHOW VIEW \(urlView)", "SHOW FUNCTIONS LIKE '\(function)'",
                        "EXPLAIN SYNTAX SELECT * FROM \(filterView)", "SELECT * FROM (EXPLAIN SYNTAX SELECT * FROM \(filterView))",
                        "SELECT query FROM system.projections"] {
                let result = await run(sql)
                #expect(result.isError, "\(sql) was not refused")
                expectNoSecret(result, sql)
            }
            // What AI access does get: columns, keys and engine names, plans with quoted strings masked, names.
            for table in ["zz_mw5_mysql_\(suffix)", "zz_mw5_url_\(suffix)", "zz_mw5_filter_\(suffix)"] {
                let describe = await tools.call(name: "describe_table", arguments: ["database": "shop", "table": .string(table)])
                #expect(!describe.isError, "\(describe.payload.stringValue ?? "")")
                #expect(describe.payload["definitions_withheld"] != nil && describe.payload["ddl"] == nil && describe.payload["engine_full"] == nil
                        && describe.payload["as_select"] == nil && describe.payload["settings"] == nil)
                expectNoSecret(describe, "describe_table \(table)")
            }
            let explained = await tools.call(name: "explain_query", arguments: ["sql": .string("SELECT * FROM \(filterView)")])
            #expect(!explained.isError, "\(explained.payload.stringValue ?? "")")
            expectNoSecret(explained, "explain_query")
            let actions = await run("EXPLAIN actions = 1 SELECT * FROM \(filterView)")
            #expect(!actions.isError, "\(actions.payload.stringValue ?? "")")
            expectNoSecret(actions, "EXPLAIN actions = 1")
            // Legitimate data comes back unaltered; an altered value is flagged with the number of masked spans.
            let plain = await run("SELECT 'ssh://git@github.com:22/x' AS url, 'PRIMARY KEY ''id''' AS ddl_like, 's3(''a'',''b'',''c'')' AS call")
            let plainText = plain.payload.serialized()
            #expect(!plain.isError && plain.payload["masked"] == nil, "\(plainText.prefix(300))")
            #expect(plainText.contains("ssh://git@github.com:22/x") && plainText.contains("s3('a','b','c')"), "\(plainText.prefix(300))")
            // The password exists only in the result (reversed in the statement).
            let credential = await run("SELECT concat('http://u:', reverse('9TERCESZZ'), '@h/x') AS url")
            #expect(credential.payload["masked"] == .int(1), "\(credential.payload.serialized().prefix(300))")
            expectNoSecret(credential, "URL password in a result")
            for (tool, arguments) in [("list_tables", ["database": JSONValue.string("shop")]), ("list_dictionaries", ["database": "shop"]),
                                      ("list_databases", [:])] {
                let result = await tools.call(name: tool, arguments: arguments)
                #expect(!result.isError, "\(tool): \(result.payload.stringValue ?? "")")
                expectNoSecret(result, tool)
            }
        }
        _ = try? await admin.run("DROP USER IF EXISTS \(user)")
        _ = try? await admin.run("DROP FUNCTION IF EXISTS \(function)")
        _ = try? await admin.run("DROP VIEW IF EXISTS \(filterView)")
        _ = try? await admin.run("DROP VIEW IF EXISTS \(urlView)")
        _ = try? await admin.run("DROP DICTIONARY IF EXISTS \(dictionary)")
        _ = try? await admin.run("DROP TABLE IF EXISTS \(mysqlTable)")
    }

    /// Review (26.8, confirmed through run_query): a settings profile that switches to polyglot/postgresql reads `'\'` as a
    /// whole string, so `SELECT '\', (subquery) --'` ran a subquery the guard saw inside a string; one that sets
    /// implicit_table_at_top_level gave `SELECT dummy` a table. Read-only requests force the safe values; where the
    /// profile's readonly=1 forbids that, the request-path check refuses every call.
    @Test func profilesThatChangeParsingAreNeutralisedOrRefused() async throws {
        let admin = try await ITEnvironment.connect()
        defer { Task { await admin.close() } }
        let known = try await admin.run("SELECT name FROM system.settings WHERE name IN ('polyglot_dialect', 'implicit_table_at_top_level')").rows
        guard known.count == 2 else { return } // 26.8+: older versions have neither setting
        let suffix = UInt32.random(in: 0...UInt32.max)
        let password = "pw-\(UUID().uuidString)"
        let polyglot = "dialect = 'polyglot', polyglot_dialect = 'postgresql', allow_experimental_polyglot_dialect = 1"
        let implicit = "implicit_table_at_top_level = 'shop.events'"
        let cases: [(name: String, settings: String)] = [("zz_mw5_poly_\(suffix)", polyglot), ("zz_mw5_poly_ro_\(suffix)", polyglot + ", readonly = 1"),
                                                         ("zz_mw5_impl_\(suffix)", implicit), ("zz_mw5_impl_ro_\(suffix)", implicit + ", readonly = 1")]
        func cleanup() async {
            await Task.detached {
                for item in cases {
                    _ = try? await admin.run("DROP USER IF EXISTS \(item.name)")
                    _ = try? await admin.run("DROP SETTINGS PROFILE IF EXISTS \(item.name)")
                }
            }.value
        }
        do {
            for item in cases {
                _ = try await admin.run("CREATE SETTINGS PROFILE \(item.name) SETTINGS \(item.settings)")
                _ = try await admin.run("CREATE USER \(item.name) IDENTIFIED WITH plaintext_password BY '\(password)' SETTINGS PROFILE '\(item.name)'")
                _ = try await admin.run("GRANT SELECT ON *.* TO \(item.name)")
            }
            // The premise: without the forced settings the profile changes what runs (a read-write connection sends none).
            let raw = try await ClickHouseClient.connect(ITEnvironment.configuration(user: cases[0].name, password: password))
            let bypass = try await raw.run("SELECT '\\', (SELECT 6 * 7) AS zz --'")
            await raw.close()
            #expect(bypass.columns.count == 2, "polyglot/postgresql reads the string and the subquery apart")
            let implicitRaw = try await ClickHouseClient.connect(ITEnvironment.configuration(user: cases[2].name, password: password))
            let implicitRows = try await implicitRaw.run("SELECT user_id LIMIT 1")
            await implicitRaw.close()
            #expect(implicitRows.columns.map(\.name) == ["user_id"], "the profile's implicit table answers a query without FROM")

            for item in cases {
                let tools = tools(profile(user: item.name), password: password)
                let sql = item.name.contains("poly") ? "SELECT '\\', (SELECT 6 * 7) AS zz --'" : "SELECT user_id"
                let result = await tools.call(name: "run_query", arguments: ["sql": .string(sql)])
                let text = result.payload.serialized()
                if item.name.contains("_ro_") {
                    // readonly=1 in the profile: nothing can be forced, so every tool is refused, metadata tools included.
                    #expect(result.isError && (text.contains("dialect") || text.contains("implicit_table_at_top_level")), "\(item.name): \(text.prefix(300))")
                    let tables = await tools.call(name: "list_tables", arguments: ["database": "shop"])
                    #expect(tables.isError, "\(item.name): list_tables \(tables.payload.serialized().prefix(200))")
                    await #expect(throws: ClickHouseError.self) {
                        _ = try await ClickHouseClient.connect(ITEnvironment.configuration(user: item.name, password: password, readOnly: true))
                    }
                } else if item.name.contains("poly") {
                    // Forced dialect=clickhouse: one string column, no subquery.
                    #expect(!result.isError && result.payload["columns"]?.arrayValue?.count == 1 && !text.contains("42"), "\(text.prefix(300))")
                } else {
                    // Forced implicit_table_at_top_level='': `user_id` resolves nowhere (a query without FROM reads system.one).
                    #expect(result.isError && text.contains("user_id"), "\(text.prefix(300))")
                }
            }
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }

    /// Review: scalar `file()` needs no FILE grant on 22.8 and 24.8 (it opens files under user_files for a SELECT-only
    /// user); 26.8 requires READ ON FILE. The text guard is the barrier there, and it refuses file() everywhere.
    @Test func scalarFileNeedsNoGrantBefore26AndTheGuardRefusesIt() async throws {
        let admin = try await ITEnvironment.connect()
        defer { Task { await admin.close() } }
        let user = "zz_mw5_file_\(UInt32.random(in: 0...UInt32.max))", password = "pw-\(UUID().uuidString)"
        _ = try await admin.run("CREATE USER \(user) IDENTIFIED WITH plaintext_password BY '\(password)'")
        _ = try await admin.run("GRANT SELECT ON shop.* TO \(user)")
        do {
            let client = try await ClickHouseClient.connect(ITEnvironment.configuration(user: user, password: password, readOnly: true))
            var code: Int?
            do { _ = try await client.run("SELECT file('ccinn_no_such_file')") } catch let error as ClickHouseError { code = error.code }
            await client.close()
            let grantChecked = client.serverInfo.version?.isAtLeast(26, 1) == true
            // 107: the file was opened (and did not exist); 497: refused for lack of READ ON FILE.
            #expect(code == (grantChecked ? 497 : 107), "\(client.serverInfo.versionString): code \(code ?? -1)")
            #expect(ReadOnlySQLGuard.check("SELECT file('ccinn_no_such_file')") != nil)
            #expect(ReadOnlySQLGuard.check("SELECT file('x')", audience: .ai(database: nil)) != nil)
            #expect(ReadOnlySQLGuard.check("SELECT `\\x66ile`('x')") != nil, "the server reads `\\x66ile` as file")
        }
        _ = try? await admin.run("DROP USER IF EXISTS \(user)")
    }

    /// Review: the tools that show other sessions' SQL replace every literal with `?`: a secret in a plain string
    /// literal (not a credential position) never reaches AI access through the query log or the mutation list.
    @Test func otherSessionsSQLReachesAIAccessAsADigest() async throws {
        let admin = try await ITEnvironment.connect()
        defer { Task { await admin.close() } }
        // What a crashed or cancelled run left (its failing mutation would retry until killed).
        await ITCleanup.sweep(admin)
        let suffix = UInt32.random(in: 0...UInt32.max)
        // The reviewer's literal: a secret in a plain string, no credential position.
        let secret = "zz_rv_mutation_secret_\(suffix)", marker = "zz_marker_\(suffix)", table = "shop.zz_mw5_mut_\(suffix)"
        _ = try? await admin.run("SELECT toUInt64('\(secret)') AS \(marker), 98765432 AS n")
        // The table and its failing mutation are removed however the test ends.
        try await ITCleanup.guarding(admin, tables: ["zz_mw5_mut_\(suffix)"]) {
            _ = try await admin.run("CREATE TABLE \(table) (id UInt8, s String) ENGINE = MergeTree ORDER BY id")
            _ = try await admin.run("INSERT INTO \(table) VALUES (1, 'a')")
            _ = try await admin.run("ALTER TABLE \(table) UPDATE s = '\(secret)' WHERE id = 1 SETTINGS mutations_sync = 1")
            // The reviewer's quoted text: a double-quoted "value", an unclosed heredoc, an unquoted INSERT value. All fail,
            // and the server echoes them in its errors (as names, and after `in scope` on 24.8+).
            let quotedSecrets = ["zz_rv_dq_secret_\(suffix)", "zz_rv_heredoc_secret_\(suffix)", "zz_rv_insert_secret_\(suffix)"]
            _ = try? await admin.run("SELECT * FROM \(table) WHERE s = \"\(quotedSecrets[0])\"")
            _ = try? await admin.run("SELECT $s$\(quotedSecrets[1])")
            _ = try? await admin.run("INSERT INTO \(table) VALUES (2, \(quotedSecrets[2]))")
            // Errors that repeat a literal value unquoted: throwIf's message, toUUID's input, and a failing mutation's
            // throwIf message in latest_fail_reason.
            let repeatedSecrets = ["zz_secret_msg_\(suffix)", "zz_secret_uuid_\(suffix)", "zz_secret_mutation_msg_\(suffix)"]
            _ = try? await admin.run("SELECT throwIf(1, '\(repeatedSecrets[0])') FROM \(table)")
            _ = try? await admin.run("SELECT toUUID('\(repeatedSecrets[1])') FROM \(table)")
            _ = try await admin.run("ALTER TABLE \(table) DELETE WHERE throwIf(id = 1, '\(repeatedSecrets[2])') = 0")
            // (Counted, not read: a value that looks like an exception at the end of a result reads as one.)
            let repeated = try await waitUntil {
                let rows = try await admin.run("SELECT count() FROM system.mutations WHERE database = 'shop' AND table = 'zz_mw5_mut_\(suffix)' "
                                               + "AND position(latest_fail_reason, '\(repeatedSecrets[2]):') > 0")
                return rows.rows.first?.first.flatMap { $0 } == "1"
            }
            #expect(repeated, "the server repeats the throwIf message, unquoted, in latest_fail_reason")
            _ = try await admin.run("SYSTEM FLUSH LOGS")
            // Reading the query log needs more than SELECT on a database: the admin, allowed explicitly for this test.
            let tools = tools(profile(user: ITEnvironment.user, allow: true), password: ITEnvironment.password)
            let failed = await tools.call(name: "analyze_query_log", arguments: ["analysis": "failed", "hours": 1, "limit": 200])
            let failedText = failed.payload.serialized()
            #expect(failedText.contains(marker), "the failed query is listed (as a digest)")
            #expect(!failedText.contains(secret) && !failedText.contains("98765432"), "\(failedText.prefix(400))")
            #expect(failedText.contains("zz_mw5_mut_\(suffix)"), "the failed statements on the table are listed (as digests)")
            for quoted in quotedSecrets + repeatedSecrets.prefix(2) {
                #expect(!failedText.contains(quoted), "\(quoted) reached AI access: \(failedText.prefix(600))")
            }
            let patterns = await tools.call(name: "analyze_query_log", arguments: ["analysis": "patterns", "hours": 1, "limit": 200])
            #expect(!patterns.payload.serialized().contains(secret))
            for quoted in quotedSecrets { #expect(!patterns.payload.serialized().contains(quoted), "patterns: \(quoted)") }
            let mutations = await tools.call(name: "get_merges_and_mutations", arguments: ["database": "shop", "table": .string("zz_mw5_mut_\(suffix)"),
                                                                                            "include_finished": true])
            let commands = mutations.payload["mutations"]?.arrayValue?.compactMap { $0["command"]?.stringValue } ?? []
            #expect(commands.count == 2 && commands.allSatisfy { $0.contains("?") && !$0.contains(secret) }, "\(commands)")
            let reasons = mutations.payload["mutations"]?.arrayValue?.compactMap { $0["latest_fail_reason"]?.stringValue } ?? []
            #expect(reasons.contains { $0.contains("DB::") }, "the failing mutation's reason is listed (as a digest): \(reasons)")
            let mutationsText = mutations.payload.serialized()
            #expect(!mutationsText.contains(secret) && !mutationsText.contains(repeatedSecrets[2]), "\(mutationsText.prefix(600))")
        }
    }
}
