import ClickHouseWire
import Foundation
import os
import Testing
@testable import ClickHouseKit

func configuration(port: Int, readOnly: Bool = false) -> ConnectionConfiguration {
    ConnectionConfiguration(endpoint: Endpoint(host: "127.0.0.1", port: port), username: "ccinn", password: "p@ss:w", connectTimeout: 5,
                            readOnly: readOnly)
}

/// Waits (bounded) until `condition` holds.
func eventually(timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

@Suite("Request building")
struct RequestBuilderTests {
    let base = URL(string: "http://127.0.0.1:8123/")!

    @Test func defaultParametersAndHeaders() throws {
        let builder = RequestBuilder(configuration: configuration(port: 8123), baseURL: base, capabilities: ConnectionCapabilities())
        let request = try builder.request(sql: "SELECT 1", queryID: "q1", options: QueryOptions(database: "shop", timeout: 30))
        let query = request.url.query ?? ""
        #expect(query.hasPrefix("query_id=q1&default_format=TabSeparatedWithNamesAndTypes&database=shop"))
        #expect(query.contains("max_execution_time=30"))
        #expect(query.contains("send_progress_in_http_headers=1"))
        #expect(query.contains("cancel_http_readonly_queries_on_client_close=1"))
        #expect(query.contains("enable_http_compression=1"))
        #expect(query.contains("format_tsv_null_representation=%5CN"))
        #expect(!query.contains("&readonly="))
        // Credentials only in the Authorization header, never in the URL.
        #expect(!request.url.absoluteString.contains("p@ss"))
        #expect(request.headers["Authorization"] == "Basic " + Data("ccinn:p@ss:w".utf8).base64EncodedString())
        #expect(request.timeout == 40)
    }

    @Test func readOnlySessionAndLockedSettings() throws {
        let locked = RequestBuilder(configuration: configuration(port: 8123, readOnly: true), baseURL: base,
                                    capabilities: ConnectionCapabilities(settingsLocked: true))
        let options = QueryOptions(session: SessionParameters(id: "s1", check: true, timeout: 600), timeout: 30, waitEndOfQuery: true)
        let query = try locked.request(sql: "SELECT 1", queryID: "q", options: options).url.query ?? ""
        #expect(query == "query_id=q&default_format=TabSeparatedWithNamesAndTypes&session_id=s1&session_check=1&session_timeout=600&wait_end_of_query=1&readonly=1")
    }

    @Test func unsupportedAndExplicitSettings() throws {
        let builder = RequestBuilder(configuration: configuration(port: 8123), baseURL: base,
                                     capabilities: ConnectionCapabilities(unsupportedSettings: ["log_comment"]))
        let query = try builder.request(sql: "SELECT 1", queryID: "q", options: QueryOptions(settings: [("max_threads", "2"), ("enable_http_compression", "0")]))
            .url.query ?? ""
        #expect(!query.contains("log_comment"))
        #expect(query.contains("max_threads=2"))
        #expect(query.components(separatedBy: "enable_http_compression").count == 2)
        #expect(query.hasSuffix("enable_http_compression=0"))
    }

    @Test func largeBodiesAreGzipped() throws {
        let builder = RequestBuilder(configuration: configuration(port: 8123), baseURL: base, capabilities: ConnectionCapabilities())
        let sql = "INSERT INTO t VALUES " + String(repeating: "(1, 'abc'),", count: 10_000) + "(2, 'x')"
        let request = try builder.request(sql: sql, queryID: "q", options: QueryOptions())
        #expect(request.headers["Content-Encoding"] == "gzip")
        #expect(request.body.count < sql.utf8.count / 5)
        #expect(FakeClickHouseServer.gunzip(request.body) == Data(sql.utf8))
    }

    @Test func pathPrefixAndHTTPS() {
        var config = configuration(port: 8443)
        config.secure = true
        config.pathPrefix = "/clickhouse/"
        #expect(config.baseURL?.absoluteString == "https://127.0.0.1:8443/clickhouse/")
        config.endpoint.port = 0
        #expect(config.baseURL == nil)
    }
}

@Suite("Client against a fake server", .serialized)
struct ClientTests {
    @Test func connectProbe() async throws {
        let server = try await FakeClickHouseServer { request in FakeAnswers.standard(request) ?? .empty() }
        defer { server.stop() }
        let client = try await ClickHouseClient.connect(configuration(port: server.port))
        defer { Task { await client.close() } }
        #expect(client.serverInfo.version == ClickHouseVersion(major: 24, minor: 8, patch: 14, build: 39))
        #expect(client.serverInfo.timeZone == "UTC")
        #expect(client.serverInfo.currentUser == "ccinn")
        #expect(client.serverInfo.displayName == "fake-node")
        #expect(client.serverInfo.readonlyLevel == 0)
        #expect(!client.capabilities.settingsLocked)
        #expect(client.systemSchema.has("processes", column: "read_rows"))
        #expect(!client.systemSchema.has("processes", column: "peak_memory_usage"))
        #expect(client.systemSchema.selectList("processes", ["query_id", "peak_memory_usage"]) == "`query_id`, NULL AS `peak_memory_usage`")
    }

    @Test func settingsLockedUserIsDetected() async throws {
        let server = try await FakeClickHouseServer { request in
            if request.parameters["send_progress_in_http_headers"] != nil {
                return .exception(code: 164, name: "READONLY", message: "Cannot modify 'max_execution_time' setting in readonly mode")
            }
            return FakeAnswers.standard(request) ?? .tsv("x\nUInt8\n1\n")
        }
        defer { server.stop() }
        let client = try await ClickHouseClient.connect(configuration(port: server.port))
        defer { Task { await client.close() } }
        #expect(client.capabilities.settingsLocked)
        let result = try await client.run("SELECT 1 AS x", options: QueryOptions(timeout: 5))
        #expect(result.rows == [["1"]])
        #expect(server.requests.last?.parameters["max_execution_time"] == nil)
    }

    @Test func unknownSettingIsDropped() async throws {
        let server = try await FakeClickHouseServer { request in
            if request.parameters["log_comment"] != nil {
                return .exception(code: 115, name: "UNKNOWN_SETTING", message: "Unknown setting 'log_comment'")
            }
            return FakeAnswers.standard(request) ?? .empty()
        }
        defer { server.stop() }
        let client = try await ClickHouseClient.connect(configuration(port: server.port))
        defer { Task { await client.close() } }
        #expect(client.capabilities.unsupportedSettings == ["log_comment"])
        #expect(!client.capabilities.settingsLocked)
    }

    @Test func authenticationErrorSurfaces() async throws {
        let server = try await FakeClickHouseServer { _ in
            .exception(code: 516, name: "AUTHENTICATION_FAILED", message: "ccinn: Authentication failed: password is incorrect", status: 403)
        }
        defer { server.stop() }
        do {
            _ = try await ClickHouseClient.connect(configuration(port: server.port))
            Issue.record("expected failure")
        } catch let error as ClickHouseError {
            #expect(error.kind == .authentication)
            #expect(error.code == 516)
            #expect(error.name == "AUTHENTICATION_FAILED")
        }
    }

    @Test func proxyErrorsAreSummarised() async throws {
        let server = try await FakeClickHouseServer { _ in
            FakeClickHouseServer.Response(status: 502, headers: ["Content-Type": "text/html"],
                                          chunks: [Data("<html><body><h1>502 Bad Gateway</h1>\n<p>upstream down</p></body></html>".utf8)])
        }
        defer { server.stop() }
        do {
            _ = try await ClickHouseClient.connect(configuration(port: server.port))
            Issue.record("expected failure")
        } catch let error as ClickHouseError {
            #expect(error.kind == .server)
            #expect(error.httpStatus == 502)
            #expect(error.message == "HTTP 502: 502 Bad Gateway upstream down")
        }
    }

    @Test func connectionRefusedIsANetworkError() async throws {
        let server = try await FakeClickHouseServer { _ in .empty() }
        let port = server.port
        server.stop()
        try await Task.sleep(for: .milliseconds(50))
        do {
            _ = try await ClickHouseClient.connect(configuration(port: port))
            Issue.record("expected failure")
        } catch let error as ClickHouseError {
            #expect(error.kind == .network)
        }
    }

    @Test func cancelledTaskFailsFastWithoutConnecting() async throws {
        let server = try await FakeClickHouseServer { request in FakeAnswers.standard(request) ?? .empty() }
        defer { server.stop() }
        let task = Task { () -> ClickHouseClient? in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ClickHouseClient.connect(configuration(port: server.port))
        }
        await #expect(throws: ClickHouseError.self) { _ = try await task.value }
        #expect(server.requests.isEmpty)
    }

    @Test func rowLimitStopsReadingAndKillsTheQuery() async throws {
        let rows = (0..<5_000).map { "\($0)\n" }.joined()
        let server = try await FakeClickHouseServer { request in
            if let answer = FakeAnswers.standard(request) { return answer }
            return .tsv("n\nUInt64\n" + rows)
        }
        defer { server.stop() }
        let client = try await ClickHouseClient.connect(configuration(port: server.port))
        defer { Task { await client.close() } }
        let result = try await client.run("SELECT number AS n FROM numbers(5000)", options: QueryOptions(limits: RowLimits(maxRows: 10)))
        #expect(result.rows.count == 10)
        #expect(result.isTruncated)
        #expect(result.columns.first?.type.kind == .integer)
        let killed = await eventually { server.requests(containing: "KILL QUERY WHERE query_id = '\(result.queryID)'").count == 1 }
        #expect(killed)
    }

    @Test func exactLimitIsNotTruncated() async throws {
        let server = try await FakeClickHouseServer { request in
            FakeAnswers.standard(request) ?? .tsv("n\nUInt64\n1\n2\n3\n")
        }
        defer { server.stop() }
        let client = try await ClickHouseClient.connect(configuration(port: server.port))
        defer { Task { await client.close() } }
        let result = try await client.run("SELECT 1", options: QueryOptions(limits: RowLimits(maxRows: 3)))
        #expect(result.rows.count == 3)
        #expect(!result.isTruncated)
        try await Task.sleep(for: .milliseconds(100))
        #expect(server.requests(containing: "KILL QUERY").isEmpty)
    }

    @Test func midStreamExceptionsInEveryFraming() async throws {
        let exception = "Code: 395. DB::Exception: boom. (FUNCTION_THROW_IF_VALUE_IS_NON_ZERO) (version 25.8.33.6 (official build))\n"
        let tag = "abcdefghijklmnop"
        let framings: [FakeClickHouseServer.Response] = [
            .tsv("n\nUInt64\n1\n2\n" + exception),
            {
                var response = FakeClickHouseServer.Response.tsv("n\nUInt64\n1\n2\n" + exception)
                response.breakChunking = true
                return response
            }(),
            {
                var response = FakeClickHouseServer.Response.tsv("n\nUInt64\n1\n\r\n__exception__\r\n\(tag)\r\n\(exception)\(exception.utf8.count) \(tag)\r\n__exception__\r\n",
                                                                 headers: ["X-ClickHouse-Exception-Tag": tag])
                response.breakChunking = true
                return response
            }(),
        ]
        for framing in framings {
            let server = try await FakeClickHouseServer { request in FakeAnswers.standard(request) ?? framing }
            let client = try await ClickHouseClient.connect(configuration(port: server.port))
            do {
                _ = try await client.run("SELECT throwIf(1)")
                Issue.record("expected an exception")
            } catch let error as ClickHouseError {
                #expect(error.code == 395)
                #expect(error.name == "FUNCTION_THROW_IF_VALUE_IS_NON_ZERO")
            }
            await client.close()
            server.stop()
        }
    }

    @Test func explicitFormatIsReturnedAsRawText() async throws {
        let server = try await FakeClickHouseServer { request in
            if let answer = FakeAnswers.standard(request) { return answer }
            return FakeClickHouseServer.Response(status: 200, headers: ["X-ClickHouse-Format": "JSON"], chunks: [Data("{\"data\":[1]}".utf8)])
        }
        defer { server.stop() }
        let client = try await ClickHouseClient.connect(configuration(port: server.port))
        defer { Task { await client.close() } }
        let result = try await client.run("SELECT 1 FORMAT JSON")
        #expect(!result.hasRowSet)
        #expect(result.format == "JSON")
        #expect(result.rawText == "{\"data\":[1]}")
    }

    @Test func cancellationAbortsAndKills() async throws {
        let server = try await FakeClickHouseServer { request in
            if let answer = FakeAnswers.standard(request) { return answer }
            var response = FakeClickHouseServer.Response.tsv("n\nUInt64\n1\n")
            response.headDelay = .seconds(10)
            return response
        }
        defer { server.stop() }
        let client = try await ClickHouseClient.connect(configuration(port: server.port))
        defer { Task { await client.close() } }
        let started = ContinuousClock.now
        let task = Task { try await client.run("SELECT sleep(10)", options: QueryOptions(queryID: "ccinnch-sql-cancel-me")) }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("expected cancellation")
        } catch let error as ClickHouseError {
            #expect(error.kind == .cancelled)
        }
        #expect(ContinuousClock.now - started < .seconds(3))
        let killed = await eventually { !server.requests(containing: "KILL QUERY WHERE query_id = 'ccinnch-sql-cancel-me'").isEmpty }
        #expect(killed)
    }

    @Test func timeoutCancelsAndKills() async throws {
        let server = try await FakeClickHouseServer { request in
            if let answer = FakeAnswers.standard(request) { return answer }
            var response = FakeClickHouseServer.Response.tsv("n\nUInt64\n1\n")
            response.headDelay = .seconds(10)
            return response
        }
        defer { server.stop() }
        let client = try await ClickHouseClient.connect(configuration(port: server.port))
        defer { Task { await client.close() } }
        do {
            _ = try await client.run("SELECT sleep(10)", options: QueryOptions(queryID: "ccinnch-sql-slow", timeout: 0.5))
            Issue.record("expected timeout")
        } catch let error as ClickHouseError {
            #expect(error.kind == .timeout)
        }
        #expect(server.requests.last { $0.queryID == "ccinnch-sql-slow" }?.parameters["max_execution_time"] == "1")
        let killed = await eventually { !server.requests(containing: "query_id = 'ccinnch-sql-slow'").isEmpty }
        #expect(killed)
    }

    @Test func killRetriesBehindALoadBalancer() async throws {
        let attempt = OSAllocatedUnfairLock(initialState: 0)
        let server = try await FakeClickHouseServer { request in
            if request.sql.hasPrefix("KILL QUERY") {
                let count = attempt.withLock { value -> Int in value += 1; return value }
                if count < 3 { return .tsv("kill_status\tquery_id\nString\tString\n", headers: ["X-ClickHouse-Server-Display-Name": "node-\(count)"]) }
                return .tsv("kill_status\tquery_id\nString\tString\nwaiting\tq-remote\n", headers: ["X-ClickHouse-Server-Display-Name": "node-3"])
            }
            if request.sql.contains("FROM system.columns") {
                // A different node answers the schema load: the endpoint is load-balanced.
                return .tsv(FakeAnswers.schema, headers: ["X-ClickHouse-Server-Display-Name": "node-2"])
            }
            return FakeAnswers.standard(request) ?? .empty()
        }
        defer { server.stop() }
        let client = try await ClickHouseClient.connect(configuration(port: server.port))
        defer { Task { await client.close() } }
        #expect(client.isLoadBalanced)
        let outcome = try await client.killQuery(queryID: "q-remote")
        #expect(outcome == .killed(status: "waiting"))
        #expect(server.requests(containing: "KILL QUERY").count == 3)
        // Retries use fresh connections.
        #expect(server.requests(containing: "KILL QUERY").dropFirst().allSatisfy { $0.headers["connection"]?.lowercased() == "close" })
    }

    @Test func singleNodeKillDoesNotRetry() async throws {
        let server = try await FakeClickHouseServer { request in FakeAnswers.standard(request) ?? .empty() }
        defer { server.stop() }
        let client = try await ClickHouseClient.connect(configuration(port: server.port))
        defer { Task { await client.close() } }
        #expect(try await client.killQuery(queryID: "gone") == .notFound)
        #expect(server.requests(containing: "KILL QUERY").count == 1)
    }

    @Test func tolerantSwallowsOnlyServerErrors() async throws {
        let server = try await FakeClickHouseServer { request in
            if let answer = FakeAnswers.standard(request) { return answer }
            if request.sql.contains("missing") { return .exception(code: 60, name: "UNKNOWN_TABLE", message: "Table system.missing does not exist") }
            var response = FakeClickHouseServer.Response.tsv("x\nUInt8\n1\n")
            response.headDelay = .seconds(5)
            return response
        }
        defer { server.stop() }
        let client = try await ClickHouseClient.connect(configuration(port: server.port))
        defer { Task { await client.close() } }
        #expect(try await client.tolerant("SELECT * FROM system.missing") == nil)
        await #expect(throws: ClickHouseError.self) { _ = try await client.tolerant("SELECT slow", timeout: 0.3) }
    }
}

@Suite("Binary values", .serialized)
struct BinaryValueTests {
    @Test func rawBytesSurviveForExport() async throws {
        var bytes = Data("b\nString\n".utf8)
        bytes.append(contentsOf: [0xC3, 0x28, 0x0A])
        bytes.append(Data("plain\n".utf8))
        let body = bytes
        let server = try await FakeClickHouseServer { request in
            if let answer = FakeAnswers.standard(request) { return answer }
            return FakeClickHouseServer.Response(status: 200, headers: ["X-ClickHouse-Format": "TabSeparatedWithNamesAndTypes"], chunks: [body])
        }
        defer { server.stop() }
        let client = try await ClickHouseClient.connect(configuration(port: server.port))
        defer { Task { await client.close() } }
        let result = try await client.run("SELECT unhex('C328')")
        #expect(result.rows.count == 2)
        #expect(result.bytes(row: 0, column: 0) == Data([0xC3, 0x28]))
        #expect(result.bytes(row: 1, column: 0) == Data("plain".utf8))
        #expect(result.binaryCells.count == 1)
    }
}

@Suite("Exceptions beyond limits", .serialized)
struct ExceptionBeyondLimitTests {
    @Test func exceptionInTheSameChunkWinsOverTheRowLimit() async throws {
        let rows = (0..<50).map { "\($0)\n" }.joined()
        let server = try await FakeClickHouseServer { request in
            if let answer = FakeAnswers.standard(request) { return answer }
            return .tsv("n\nUInt64\n" + rows + "Code: 241. DB::Exception: Memory limit exceeded. (MEMORY_LIMIT_EXCEEDED) (version 23.8.16.16 (official build))\n")
        }
        defer { server.stop() }
        let client = try await ClickHouseClient.connect(configuration(port: server.port))
        defer { Task { await client.close() } }
        do {
            _ = try await client.run("SELECT big", options: QueryOptions(limits: RowLimits(maxRows: 10)))
            Issue.record("expected the server exception")
        } catch let error as ClickHouseError {
            #expect(error.code == 241)
        }
    }
}

@Suite("Stale keep-alive connections", .serialized)
struct StaleConnectionTests {
    @Test func idempotentRequestsAreRetriedOnce() async throws {
        let drops = OSAllocatedUnfairLock(initialState: 0)
        let server = try await FakeClickHouseServer { request in
            if let answer = FakeAnswers.standard(request) { return answer }
            if request.sql.contains("flaky"), drops.withLock({ value -> Bool in value += 1; return value == 1 }) {
                var response = FakeClickHouseServer.Response.empty()
                response.dropConnection = true
                return response
            }
            return .tsv("x\nUInt8\n1\n")
        }
        defer { server.stop() }
        let client = try await ClickHouseClient.connect(configuration(port: server.port))
        defer { Task { await client.close() } }
        #expect(try await client.run("SELECT flaky", options: QueryOptions(idempotent: true)).rows == [["1"]])
        #expect(server.requests(containing: "flaky").count == 2)
    }

    @Test func nonIdempotentRequestsAreNotRetried() async throws {
        let server = try await FakeClickHouseServer { request in
            if let answer = FakeAnswers.standard(request) { return answer }
            var response = FakeClickHouseServer.Response.empty()
            response.dropConnection = true
            return response
        }
        defer { server.stop() }
        let client = try await ClickHouseClient.connect(configuration(port: server.port))
        defer { Task { await client.close() } }
        do {
            _ = try await client.run("INSERT INTO t VALUES (1)")
            Issue.record("expected failure")
        } catch let error as ClickHouseError {
            #expect(error.kind == .network)
        }
        #expect(server.requests(containing: "INSERT").count == 1)
    }
}

@Suite("Proxy-safe query matching", .serialized)
struct ProxyMatchingTests {
    @Test func killAndProgressMatchTheLogCommentMarker() async throws {
        let server = try await FakeClickHouseServer { request in
            if request.sql.contains("FROM system.columns WHERE database = 'system'") {
                return .tsv("table\tname\nString\tString\nprocesses\tquery_id\nprocesses\tSettings\nprocesses\tread_rows\n")
            }
            return FakeAnswers.standard(request) ?? .empty()
        }
        defer { server.stop() }
        let client = try await ClickHouseClient.connect(configuration(port: server.port))
        defer { Task { await client.close() } }
        _ = try await client.killQuery(queryID: "ccinnch-sql-1")
        let kill = try #require(server.requests(containing: "KILL QUERY").first)
        #expect(kill.sql == "KILL QUERY WHERE (query_id = 'ccinnch-sql-1' OR Settings['log_comment'] = 'CcinnClickHouse/ccinnch-sql-1') ASYNC")
        _ = try await client.run("SELECT 1", options: QueryOptions(queryID: "ccinnch-sql-2"))
        #expect(server.requests.last?.parameters["log_comment"] == "CcinnClickHouse/ccinnch-sql-2")
    }
}

@Suite("Read-only must be enforced by the server", .serialized)
struct ReadOnlyEnforcementTests {
    static func probe(readonly: String) -> String {
        "version\ttimezone\tuser\thost\tuptime\tdatabase\treadonly\nString\tString\tString\tString\tUInt32\tString\tString\n24.8.14.39\tUTC\tccinn\tnode-1\t1\tdefault\t\(readonly)\n"
    }

    @Test func proxyThatDropsReadonlyIsRefused() async throws {
        // Like chproxy: the readonly parameter never reaches ClickHouse.
        let server = try await FakeClickHouseServer { request in
            if request.sql.contains("version() AS version") { return .tsv(Self.probe(readonly: "0")) }
            return FakeAnswers.standard(request) ?? .empty()
        }
        defer { server.stop() }
        do {
            _ = try await ClickHouseClient.connect(configuration(port: server.port, readOnly: true))
            Issue.record("a read-only connection must not open when readonly=1 is not applied")
        } catch let error as ClickHouseError {
            #expect(error.kind == .readOnlyNotEnforced)
        }
        #expect(server.requests.first?.parameters["readonly"] == "1")
    }

    @Test func serverThatAppliesReadonlyIsAccepted() async throws {
        let server = try await FakeClickHouseServer { request in
            if request.sql.contains("version() AS version") { return .tsv(Self.probe(readonly: request.parameters["readonly"] ?? "0")) }
            return FakeAnswers.standard(request) ?? .empty()
        }
        defer { server.stop() }
        let client = try await ClickHouseClient.connect(configuration(port: server.port, readOnly: true))
        #expect(client.serverInfo.readonlyLevel == 1)
        await client.close()
        // Read-write connections do not care.
        let writable = try await ClickHouseClient.connect(configuration(port: server.port))
        #expect(writable.serverInfo.readonlyLevel == 0)
        await writable.close()
    }

    @Test func unknownLevelFailsClosed() async throws {
        let server = try await FakeClickHouseServer { request in
            if request.sql.contains("getSetting") { return .exception(code: 46, name: "UNKNOWN_FUNCTION", message: "Unknown function getSetting") }
            if request.sql.contains("version() AS version") {
                return .tsv("version\ttimezone\tuser\thost\tdatabase\nString\tString\tString\tString\tString\n20.3.1\tUTC\tccinn\tnode-1\tdefault\n")
            }
            return FakeAnswers.standard(request) ?? .empty()
        }
        defer { server.stop() }
        await #expect(throws: ClickHouseError.self) { _ = try await ClickHouseClient.connect(configuration(port: server.port, readOnly: true)) }
    }
}

@Suite("Retry after a dropped connection reached the server", .serialized)
struct RetryReachedServerTests {
    /// The fake received the first attempt's body, then dropped the connection; it treats that query as
    /// still running until a KILL for its id arrives, like ClickHouse would.
    final class Running: @unchecked Sendable {
        let lock = OSAllocatedUnfairLock<(running: Set<String>, dropped: Bool)>(initialState: ([], false))
    }

    @Test func retryUsesAFreshQueryIDAndKillsTheFirstAttempt() async throws {
        let state = Running()
        let server = try await FakeClickHouseServer { request in
            if request.sql.hasPrefix("KILL QUERY"), let id = request.sql.split(separator: "'").dropFirst().first.map(String.init) {
                state.lock.withLock { _ = $0.running.remove(id) }
                return .tsv("kill_status\tquery_id\nString\tString\nfinished\t\(id)\n")
            }
            if let answer = FakeAnswers.standard(request) { return answer }
            guard let id = request.queryID else { return .empty() }
            let dropNow = state.lock.withLock { value -> Bool in
                if value.dropped { return false }
                value.dropped = true
                value.running.insert(id)
                return true
            }
            if dropNow {
                var response = FakeClickHouseServer.Response.empty()
                response.dropConnection = true
                return response
            }
            if state.lock.withLock({ $0.running.contains(id) }) {
                return .exception(code: 216, name: "QUERY_WITH_SAME_ID_IS_ALREADY_RUNNING", message: "Query with id = \(id) is already running")
            }
            return .tsv("x\nUInt8\n1\n")
        }
        defer { server.stop() }
        let client = try await ClickHouseClient.connect(configuration(port: server.port))
        defer { Task { await client.close() } }
        let result = try await client.run("SELECT flaky", options: QueryOptions(queryID: "ccinnch-sql-first", idempotent: true))
        #expect(result.rows == [["1"]])
        let attempts = server.requests(containing: "flaky")
        #expect(attempts.count == 2)
        #expect(attempts[0].queryID == "ccinnch-sql-first")
        #expect(attempts[1].queryID != "ccinnch-sql-first")
        #expect(result.queryID == attempts[1].queryID)
        #expect(await eventually { !server.requests(containing: "query_id = 'ccinnch-sql-first'").isEmpty })
    }

    @Test func sessionLockedByTheFirstAttemptIsWaitedOut() async throws {
        let state = Running()
        let server = try await FakeClickHouseServer { request in
            if request.sql.hasPrefix("KILL QUERY"), let id = request.sql.split(separator: "'").dropFirst().first.map(String.init) {
                state.lock.withLock { _ = $0.running.remove(id) }
                return .tsv("kill_status\tquery_id\nString\tString\nfinished\t\(id)\n")
            }
            if let answer = FakeAnswers.standard(request) { return answer }
            guard let id = request.queryID, request.parameters["session_id"] != nil else { return .tsv("x\nUInt8\n1\n") }
            let dropNow = state.lock.withLock { value -> Bool in
                if value.dropped { return false }
                value.dropped = true
                value.running.insert(id)
                return true
            }
            if dropNow {
                var response = FakeClickHouseServer.Response.empty()
                response.dropConnection = true
                return response
            }
            // While the first attempt "runs", it holds the session.
            if state.lock.withLock({ !$0.running.isEmpty }) {
                return .exception(code: 373, name: "SESSION_IS_LOCKED", message: "Session is locked by a concurrent client")
            }
            return .tsv("x\nUInt8\n1\n")
        }
        defer { server.stop() }
        let client = try await ClickHouseClient.connect(configuration(port: server.port))
        defer { Task { await client.close() } }
        let session = client.openSession()
        #expect(try await session.run("SELECT flaky", idempotent: true).rows == [["1"]])
        let ids = server.requests(containing: "flaky").compactMap(\.queryID)
        #expect(Set(ids).count == ids.count, "every attempt has its own query id")
        #expect(!server.requests(containing: "KILL QUERY WHERE query_id = '\(ids[0])'").isEmpty)
    }

    @Test func writesAreNeverRetriedEvenInASession() async throws {
        let server = try await FakeClickHouseServer { request in
            if let answer = FakeAnswers.standard(request) { return answer }
            var response = FakeClickHouseServer.Response.empty()
            response.dropConnection = true
            return response
        }
        defer { server.stop() }
        let client = try await ClickHouseClient.connect(configuration(port: server.port))
        defer { Task { await client.close() } }
        await #expect(throws: ClickHouseError.self) { _ = try await client.openSession().run("INSERT INTO t SELECT 1", idempotent: false) }
        #expect(server.requests(containing: "INSERT INTO t").count == 1)
    }
}

@Suite("Exception framing split across network chunks", .serialized)
struct SplitExceptionFramingTests {
    /// 26.x: the `__exception__` marker ends one chunk, the tag and message arrive later. The reader must
    /// keep reading after entering the trailer instead of finishing on the partial frame.
    @Test(arguments: [true, false])
    func taggedExceptionSplitAcrossChunks(breakChunking: Bool) async throws {
        let tag = "qrstuvwxyzabcdef"
        let message = "Code: 241. DB::Exception: Memory limit (total) exceeded. (MEMORY_LIMIT_EXCEEDED) (version 26.8.1.1 (official build))\n"
        var rows = "n\nUInt64\n"
        for value in 0..<2_000 { rows += "\(value)\n" }
        var response = FakeClickHouseServer.Response.tsv("", headers: ["X-ClickHouse-Exception-Tag": tag, "Content-Type": "text/tab-separated-values; charset=UTF-8"])
        response.chunks = [Data((rows + "\r\n__exception__\r\n").utf8), Data("\(tag)\r\n\(message)\(message.utf8.count) \(tag)\r\n__exception__\r\n".utf8)]
        response.chunkDelay = .milliseconds(200)
        response.breakChunking = breakChunking
        let framed = response
        let server = try await FakeClickHouseServer { request in FakeAnswers.standard(request) ?? framed }
        defer { server.stop() }
        let client = try await ClickHouseClient.connect(configuration(port: server.port))
        defer { Task { await client.close() } }
        do {
            _ = try await client.run("SELECT number FROM numbers(1e9)")
            Issue.record("expected the server exception")
        } catch let error as ClickHouseError {
            #expect(error.code == 241)
            #expect(error.name == "MEMORY_LIMIT_EXCEEDED")
        }
    }

    /// 22.x–25.x: the plain `Code: …` tail split in the middle.
    @Test func plainExceptionTailSplitAcrossChunks() async throws {
        let message = "Code: 241. DB::Exception: Memory limit (total) exceeded. (MEMORY_LIMIT_EXCEEDED) (version 24.8.14.39 (official build))\n"
        var response = FakeClickHouseServer.Response.tsv("", headers: ["Content-Type": "text/tab-separated-values; charset=UTF-8"])
        let split = message.index(message.startIndex, offsetBy: 30)
        response.chunks = [Data(("n\nUInt64\n1\n2\n" + message[..<split]).utf8), Data(String(message[split...]).utf8)]
        response.chunkDelay = .milliseconds(200)
        let framed = response
        let server = try await FakeClickHouseServer { request in FakeAnswers.standard(request) ?? framed }
        defer { server.stop() }
        let client = try await ClickHouseClient.connect(configuration(port: server.port))
        defer { Task { await client.close() } }
        await #expect(throws: ClickHouseError.self) {
            do { _ = try await client.run("SELECT 1") } catch let error as ClickHouseError {
                #expect(error.code == 241)
                throw error
            }
        }
    }
}

@Suite("Transport start after an early completion", .serialized)
struct TransportEarlyCompletionTests {
    /// A cancel that lands before `start` runs cancels a task that was never resumed; URLSession reports
    /// its completion before `start` stores the continuation. `start` must still return.
    @Test func startAfterTheTaskAlreadyCompletedThrows() async throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URL(string: "http://127.0.0.1:9/")!)
        let delegate = StreamingTaskDelegate(trust: TrustPolicy(tls: TLSOptions(), serverName: nil))
        task.delegate = delegate
        task.cancel()
        #expect(await eventually { task.state == .completed })
        try await Task.sleep(for: .milliseconds(100))
        let finished = OSAllocatedUnfairLock(initialState: false)
        let start = Task {
            defer { finished.withLock { $0 = true } }
            _ = try await delegate.start(task)
        }
        let returned = await eventually(timeout: .seconds(2)) { finished.withLock { $0 } }
        #expect(returned, "start() returned")
        if returned { await #expect(throws: ClickHouseError.self) { try await start.value } }
    }

    /// The caller is cancelled before the request starts: `send` fails fast instead of hanging.
    @Test func sendFromACancelledTaskReturns() async throws {
        let server = try await FakeClickHouseServer { request in FakeAnswers.standard(request) ?? .tsv("x\nUInt8\n1\n") }
        defer { server.stop() }
        let transport = URLSessionTransport()
        defer { transport.close() }
        for _ in 0..<50 {
            let request = HTTPRequest(url: URL(string: "http://127.0.0.1:\(server.port)/?query=SELECT%201")!, method: "POST", headers: [:], body: Data(), timeout: 5)
            let attempt = Task { _ = try await transport.send(request) }
            attempt.cancel()
            _ = try? await attempt.value
        }
    }
}
