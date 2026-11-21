import ClickHouseWire
import Foundation
import os
import Testing
@testable import ClickHouseKit

/// A one-shot gate a scripted discovery waits on.
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

private struct ScriptedFailure: Error {}

private extension SystemSchema.Availability {
    var isAvailable: Bool { if case .available = self { true } else { false } }
    var isAbsent: Bool { if case .absent = self { true } else { false } }
    var deniedCode: Int? { if case let .denied(error) = self { error.code } else { nil } }
}

private let accessDenied = ClickHouseError(.server, "reader: Not enough privileges", code: 497)

/// Learning a `system` table's columns: unknown is never "no columns" (design D1, D3).
@Suite("System schema discovery")
struct SystemSchemaTests {
    @Test func aTableLoadedAtConnectNeedsNoDiscovery() async throws {
        let schema = SystemSchema(columns: ["databases": ["name", "engine"]])
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let availability = try await schema.resolve("databases") {
            calls.withLock { $0 += 1 }
            return .absent
        }
        #expect(availability.isAvailable)
        #expect(calls.withLock { $0 } == 0)
    }

    @Test func discoveredColumnsAreRememberedAndUsed() async throws {
        let schema = SystemSchema(columns: [:])
        #expect(schema.columns(of: "databases") == nil, "unknown, not empty")
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let discover: @Sendable () async throws -> SystemSchema.Discovery = {
            calls.withLock { $0 += 1 }
            return .columns(["name", "engine"])
        }
        #expect(try await schema.resolve("databases", discover: discover).isAvailable)
        #expect(try await schema.resolve("databases", discover: discover).isAvailable)
        #expect(calls.withLock { $0 } == 1)
        #expect(schema.selectList("databases", ["name", "uuid"]) == "`name`, NULL AS `uuid`")
    }

    // A table whose columns are not known is not pretended to have none: the server answers values or its error.
    @Test func anUnknownTableIsSelectedByName() {
        #expect(SystemSchema(columns: [:]).selectList("disks", ["name", "path"]) == "`name`, `path`")
    }

    @Test func concurrentCallersShareOneDiscovery() async throws {
        let schema = SystemSchema(columns: [:])
        let gate = Gate()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let discover: @Sendable () async throws -> SystemSchema.Discovery = {
            calls.withLock { $0 += 1 }
            await gate.wait()
            return .columns(["name"])
        }
        let callers = (0..<9).map { _ in Task { try await schema.resolve("tables", discover: discover) } }
        // Every caller is waiting while the one discovery is held open.
        #expect(await eventually { schema.waiterCount("tables") == 9 })
        await gate.open()
        for caller in callers { #expect(try await caller.value.isAvailable) }
        #expect(calls.withLock { $0 } == 1)
    }

    @Test func aCancelledCallerReturnsAtOnceAndTheOthersStillGetTheResult() async throws {
        let schema = SystemSchema(columns: [:])
        let gate = Gate()
        let discover: @Sendable () async throws -> SystemSchema.Discovery = {
            await gate.wait()
            return .columns(["name"])
        }
        let staying = Task { try await schema.resolve("tables", discover: discover) }
        let leaving = Task { try await schema.resolve("tables", discover: discover) }
        #expect(await eventually { schema.waiterCount("tables") == 2 })
        leaving.cancel()
        do {
            _ = try await leaving.value
            Issue.record("a cancelled caller must not wait for the discovery")
        } catch let error as ClickHouseError {
            #expect(error.kind == .cancelled)
        }
        #expect(schema.waiterCount("tables") == 1)
        await gate.open()
        #expect(try await staying.value.isAvailable)
        #expect(schema.hasTable("tables"))
    }

    @Test func aCallerCancelledBeforeAskingNeverWaits() async throws {
        let schema = SystemSchema(columns: [:])
        let gate = Gate()
        let caller = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await schema.resolve("tables") {
                await gate.wait()
                return .absent
            }
        }
        await #expect(throws: ClickHouseError.self) { _ = try await caller.value }
        await gate.open()
    }

    @Test func aDeniedTableIsRememberedForTheRetryInterval() async throws {
        let schema = SystemSchema(columns: [:])
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let discover: @Sendable () async throws -> SystemSchema.Discovery = {
            calls.withLock { $0 += 1 }
            return .denied(accessDenied)
        }
        #expect(try await schema.resolve("parts", discover: discover).deniedCode == 497)
        #expect(try await schema.resolve("parts", discover: discover).deniedCode == 497)
        #expect(calls.withLock { $0 } == 1)
        #expect(!schema.hasTable("parts"))
    }

    @Test func aDeniedTableIsAskedAgainAfterTheInterval() async throws {
        // Grants change: "denied" must not be forever.
        let schema = SystemSchema(columns: [:], retryInterval: .zero)
        let answers = OSAllocatedUnfairLock<[SystemSchema.Discovery]>(initialState: [.denied(accessDenied), .columns(["name"])])
        let discover: @Sendable () async throws -> SystemSchema.Discovery = { answers.withLock { $0.removeFirst() } }
        #expect(try await schema.resolve("disks", discover: discover).deniedCode == 497)
        #expect(try await schema.resolve("disks", discover: discover).isAvailable)
    }

    @Test func aTableTheVersionLacksIsRememberedForTheConnection() async throws {
        let schema = SystemSchema(columns: [:], retryInterval: .zero)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let discover: @Sendable () async throws -> SystemSchema.Discovery = {
            calls.withLock { $0 += 1 }
            return .absent
        }
        #expect(try await schema.resolve("projections", discover: discover).isAbsent)
        #expect(try await schema.resolve("projections", discover: discover).isAbsent)
        #expect(calls.withLock { $0 } == 1)
    }

    @Test func aLogTableIsAskedAgainAfterTheInterval() async throws {
        // query_log appears after the first flush.
        let schema = SystemSchema(columns: [:], retryInterval: .zero)
        let answers = OSAllocatedUnfairLock<[SystemSchema.Discovery]>(initialState: [.absent, .columns(["event_time"])])
        let discover: @Sendable () async throws -> SystemSchema.Discovery = { answers.withLock { $0.removeFirst() } }
        #expect(try await schema.resolve("query_log", discover: discover).isAbsent)
        #expect(try await schema.resolve("query_log", discover: discover).isAvailable)
        #expect(schema.has("query_log", column: "event_time"))
    }

    @Test func anEmptyColumnSetIsAbsent() async throws {
        let schema = SystemSchema(columns: [:])
        #expect(try await schema.resolve("disks") { .columns([]) }.isAbsent)
        #expect(!schema.hasTable("disks"))
    }

    @Test func errorsPropagateAndAreNotRemembered() async throws {
        let schema = SystemSchema(columns: [:])
        await #expect(throws: ScriptedFailure.self) { try await schema.resolve("tables") { throw ScriptedFailure() } }
        #expect(try await schema.resolve("tables") { .columns(["name"]) }.isAvailable)
    }
}

/// Requests a user with `GRANT SELECT ON shop.*` only causes: `system.columns` lists no `system` table, while
/// `system.databases` / `tables` / `columns` stay selectable (recorded on 22.8 and 26.8).
enum HiddenSystemSchema {
    static let describeHead = "DESCRIBE (SELECT * FROM system."
    static let header = "name\ttype\nString\tString\n"

    static func describe(_ columns: [String]) -> FakeClickHouseServer.Response {
        .tsv(header + columns.map { "\($0)\tString\n" }.joined())
    }

    /// `table` of `DESCRIBE (SELECT * FROM system.`table`)`, nil for other statements.
    static func describedTable(_ sql: String) -> String? {
        guard sql.hasPrefix(describeHead) else { return nil }
        return String(sql.dropFirst(describeHead.count).prefix { $0 != ")" }).trimmingCharacters(in: CharacterSet(charactersIn: "`"))
    }

    /// The probe; empty `system.columns` answers; DESCRIBE headers of `visible` tables and ACCESS_DENIED for the rest.
    static func handler(visible: [String: [String]], data: @escaping @Sendable (String) -> FakeClickHouseServer.Response?)
        -> @Sendable (FakeClickHouseServer.Request) async -> FakeClickHouseServer.Response {
        { request in
            let sql = request.sql
            if sql.contains("version() AS version") { return .tsv(ReadOnlyEnforcementTests.probe(readonly: request.parameters["readonly"] ?? "0")) }
            if sql == ParserSettings.query { return .tsv(FakeAnswers.settings(request, readonly: request.parameters["readonly"] ?? "0")) }
            if sql.contains("FROM system.columns WHERE database = 'system'") { return .tsv("table\tname\nString\tString\n") }
            if let table = describedTable(sql) {
                guard let columns = visible[table] else {
                    return .exception(code: 497, name: "ACCESS_DENIED",
                                      message: "reader: Not enough privileges. To execute this query, it's necessary to have the grant SELECT ON system.\(table)")
                }
                return describe(columns)
            }
            return data(sql) ?? .exception(code: 497, name: "ACCESS_DENIED", message: "reader: Not enough privileges")
        }
    }
}

@Suite("Users without SHOW COLUMNS on system", .serialized)
struct HiddenSystemSchemaClientTests {
    static let visible = [
        "databases": ["name", "engine", "data_path", "metadata_path", "uuid", "engine_full", "comment"],
        "tables": ["database", "name", "uuid", "engine", "is_temporary", "total_rows", "total_bytes"],
    ]

    @Test func databasesAndTablesAreListed() async throws {
        let server = try await FakeClickHouseServer(handler: HiddenSystemSchema.handler(visible: Self.visible) { sql in
            if sql.hasPrefix("SELECT `name`, `engine`") && sql.contains("FROM system.databases") {
                return .tsv("name\tengine\tengine_full\tcomment\tuuid\nString\tString\tNullable(String)\tNullable(String)\tNullable(String)\n"
                    + "shop\tAtomic\t\\N\t\t\\N\n")
            }
            if sql.hasPrefix("SELECT `database`, `name`") && sql.contains("FROM system.tables WHERE database = 'shop'") {
                return .tsv("database\tname\tengine\nString\tString\tString\nshop\tevents\tMergeTree\n")
            }
            return nil
        })
        defer { server.stop() }
        let client = try await ClickHouseClient.connect(configuration(port: server.port, readOnly: true))
        defer { Task { await client.close() } }
        #expect(try await client.databases().map(\.name) == ["shop"])
        let tables = try await client.tables(database: "shop")
        #expect(tables.map(\.name) == ["events"])
        #expect(tables.first?.family == .mergeTree)
        // One discovery per table for the whole connection.
        _ = try await client.databases()
        #expect(server.requests(containing: HiddenSystemSchema.describeHead + "`databases`)").count == 1)
        #expect(server.requests(containing: HiddenSystemSchema.describeHead + "`tables`)").count == 1)
        #expect(server.requests(containing: "NULL AS `name`").isEmpty)
        #expect(server.requests(containing: "AND table = ").isEmpty, "learning is one DESCRIBE, not a system.columns lookup first")
    }

    @Test func aDeniedSystemTableShowsTheServerErrorAndIsAskedOnce() async throws {
        let server = try await FakeClickHouseServer(handler: HiddenSystemSchema.handler(visible: Self.visible) { _ in nil })
        defer { server.stop() }
        let client = try await ClickHouseClient.connect(configuration(port: server.port, readOnly: true))
        defer { Task { await client.close() } }
        for _ in 0..<2 {
            do {
                _ = try await client.disks()
                Issue.record("system.disks is not readable for this user")
            } catch let error as ClickHouseError {
                #expect(error.code == 497)
            }
        }
        #expect(server.requests(containing: HiddenSystemSchema.describeHead + "`disks`)").count == 1)
        #expect(try await client.ensureSystemTable("disks") == false)
        // Should the server allow it after all (a grant within the minute), the query asks for real columns, never NULLs.
        let query = try #require(server.requests(containing: "FROM system.disks").first)
        #expect(query.sql.hasPrefix("SELECT `name`, `path`"))
    }

    // Optional views say "access denied", not "nothing here", for a table the user may not read.
    @Test func deniedOptionalTablesReportTheServerError() async throws {
        let server = try await FakeClickHouseServer(handler: HiddenSystemSchema.handler(visible: Self.visible) { _ in nil })
        defer { server.stop() }
        let client = try await ClickHouseClient.connect(configuration(port: server.port, readOnly: true))
        defer { Task { await client.close() } }
        for read in [{ _ = try await client.skippingIndices(database: "shop", table: "events") },
                     { _ = try await client.queryLog(.recent) },
                     { _ = try await client.distributedDDLQueue() }] as [() async throws -> Void] {
            do {
                try await read()
                Issue.record("a denied optional table must report the server's error")
            } catch let error as ClickHouseError {
                #expect(error.code == 497)
            }
        }
        // Projections fall back to the CREATE statement, which this user may read.
        let projections = try await client.projections(database: "shop", table: "events",
                                                       createStatement: "CREATE TABLE shop.events (a UInt8, PROJECTION p (SELECT a ORDER BY a)) ENGINE = MergeTree ORDER BY a")
        #expect(projections.map(\.name) == ["p"])
    }

    @Test func progressDoesNotPollATableTheUserMayNotRead() async throws {
        let server = try await FakeClickHouseServer(handler: HiddenSystemSchema.handler(visible: Self.visible) { _ in nil })
        defer { server.stop() }
        let client = try await ClickHouseClient.connect(configuration(port: server.port, readOnly: true))
        defer { Task { await client.close() } }
        for _ in 0..<3 { #expect(try await client.progress(of: "q1") == nil) }
        #expect(server.requests(containing: "FROM system.processes").isEmpty)
        #expect(server.requests(containing: HiddenSystemSchema.describeHead + "`processes`)").count == 1)
    }

    // Behind chproxy the query id is replaced; once progress polling has learned `processes`, the kill also matches
    // the log_comment marker.
    @Test func killUsesTheMarkerOnceProgressLearnedProcesses() async throws {
        var visible = Self.visible
        visible["processes"] = ["query_id", "Settings", "elapsed"]
        let server = try await FakeClickHouseServer(handler: HiddenSystemSchema.handler(visible: visible) { sql in
            if sql.hasPrefix("KILL QUERY") { return .tsv("kill_status\tquery_id\nString\tString\n") }
            return sql.contains("FROM system.processes") ? .tsv("elapsed\nFloat64\n") : nil
        })
        defer { server.stop() }
        let client = try await ClickHouseClient.connect(configuration(port: server.port, readOnly: true))
        defer { Task { await client.close() } }
        _ = try await client.progress(of: "ccinnch-sql-1")
        _ = try await client.killQuery(queryID: "ccinnch-sql-1")
        let kill = try #require(server.requests(containing: "KILL QUERY").first)
        #expect(kill.sql.contains("Settings['log_comment']"))
    }

    // Review: a kill waited for a lookup of `processes`, worst when the server is slow, which is when users press Stop.
    @Test func aKillIsNeverDelayedByALookup() async throws {
        let server = try await FakeClickHouseServer { request in
            if HiddenSystemSchema.describedTable(request.sql) != nil {
                var slow = HiddenSystemSchema.describe(["query_id"])
                slow.headDelay = .seconds(5)
                return slow
            }
            if request.sql.hasPrefix("KILL QUERY") { return .tsv("kill_status\tquery_id\nString\tString\n") }
            return await HiddenSystemSchema.handler(visible: Self.visible) { _ in nil }(request)
        }
        defer { server.stop() }
        let client = try await ClickHouseClient.connect(configuration(port: server.port, readOnly: true))
        defer { Task { await client.close() } }
        let started = ContinuousClock.now
        _ = try await client.killQuery(queryID: "ccinnch-sql-1")
        #expect(ContinuousClock.now - started < .seconds(3))
        #expect(server.requests(containing: "DESCRIBE").isEmpty)
    }

    // Review: an abandoned lookup sent a KILL, whose kill path started another lookup, on a server already stuck.
    @Test func anAbandonedLookupSendsNoKill() async throws {
        let server = try await FakeClickHouseServer { request in
            if HiddenSystemSchema.describedTable(request.sql) != nil {
                var stuck = HiddenSystemSchema.describe(["name"])
                stuck.headDelay = .seconds(4)
                return stuck
            }
            return await HiddenSystemSchema.handler(visible: Self.visible) { _ in nil }(request)
        }
        defer { server.stop() }
        var settings = configuration(port: server.port, readOnly: true)
        settings.connectTimeout = 1
        let client = try await ClickHouseClient.connect(settings)
        defer { Task { await client.close() } }
        do {
            _ = try await client.databases()
            Issue.record("the lookup must time out")
        } catch let error as ClickHouseError {
            #expect(error.kind == .timeout)
        }
        try await Task.sleep(for: .milliseconds(500))
        #expect(server.requests(containing: "KILL").isEmpty)
        #expect(server.requests(containing: HiddenSystemSchema.describeHead).count == 1)
    }

    // Review 3: 22.x closes idle keep-alive connections after 3 s; a lookup on such a connection is retried once on a
    // fresh one, like every idempotent statement.
    @Test func aLookupOnAStaleConnectionIsRetriedOnce() async throws {
        let drops = OSAllocatedUnfairLock(initialState: 1)
        let base = HiddenSystemSchema.handler(visible: Self.visible) { sql in
            sql.hasPrefix("SELECT `name`, `engine`") && sql.contains("FROM system.databases")
                ? .tsv("name\tengine\nString\tString\nshop\tAtomic\n") : nil
        }
        let server = try await FakeClickHouseServer { request in
            if HiddenSystemSchema.describedTable(request.sql) == "databases", drops.withLock({ value in defer { value -= 1 }; return value > 0 }) {
                return FakeClickHouseServer.Response(dropConnection: true)
            }
            return await base(request)
        }
        defer { server.stop() }
        let client = try await ClickHouseClient.connect(configuration(port: server.port, readOnly: true))
        defer { Task { await client.close() } }
        #expect(try await client.databases().map(\.name) == ["shop"])
        #expect(server.requests(containing: HiddenSystemSchema.describeHead + "`databases`)").count == 2)
        #expect(server.requests(containing: "KILL").isEmpty)
    }

    @Test func aTimeoutWhileLearningPropagatesAndIsNotRemembered() async throws {
        let failures = OSAllocatedUnfairLock(initialState: 1)
        let base = HiddenSystemSchema.handler(visible: Self.visible) { sql in
            sql.hasPrefix("SELECT `name`, `engine`") && sql.contains("FROM system.databases")
                ? .tsv("name\tengine\nString\tString\nshop\tAtomic\n") : nil
        }
        let server = try await FakeClickHouseServer { request in
            if HiddenSystemSchema.describedTable(request.sql) == "databases", failures.withLock({ value in defer { value -= 1 }; return value > 0 }) {
                return .exception(code: 159, name: "TIMEOUT_EXCEEDED", message: "Timeout exceeded: elapsed 30.1 seconds")
            }
            return await base(request)
        }
        defer { server.stop() }
        let client = try await ClickHouseClient.connect(configuration(port: server.port, readOnly: true))
        defer { Task { await client.close() } }
        await #expect(throws: ClickHouseError.self) { _ = try await client.databases() }
        #expect(try await client.databases().map(\.name) == ["shop"])
        #expect(server.requests(containing: HiddenSystemSchema.describeHead + "`databases`)").count == 2)
    }

    @Test func aTableMissingFromTheVersionIsNotAnError() async throws {
        let server = try await FakeClickHouseServer { request in
            if HiddenSystemSchema.describedTable(request.sql) == "projections" {
                return .exception(code: 60, name: "UNKNOWN_TABLE", message: "Table system.projections doesn't exist")
            }
            return FakeAnswers.standard(request) ?? .tsv("name\nString\n")
        }
        defer { server.stop() }
        let client = try await ClickHouseClient.connect(configuration(port: server.port))
        defer { Task { await client.close() } }
        #expect(try await client.ensureSystemTable("projections") == false)
        #expect(try await client.projections(database: "shop", table: "events", createStatement: nil).isEmpty)
        #expect(try await client.projections(database: "shop", table: "events", createStatement: nil).isEmpty)
        #expect(server.requests(containing: "FROM system.projections WHERE").isEmpty)
        // A table the version lacks is asked for once per connection, not every minute.
        #expect(server.requests(containing: HiddenSystemSchema.describeHead + "`projections`)").count == 1)
    }

    @Test func fullGrantUsersSendNothingNew() async throws {
        let server = try await FakeClickHouseServer { request in
            FakeAnswers.standard(request) ?? .tsv("host\tquery_id\nString\tString\nnode-1\tq1\n")
        }
        defer { server.stop() }
        let client = try await ClickHouseClient.connect(configuration(port: server.port))
        defer { Task { await client.close() } }
        _ = try await client.runningQueries(includeAppMonitoring: true)
        _ = try await client.progress(of: "q1")
        #expect(server.requests(containing: "DESCRIBE").isEmpty)
        #expect(server.requests(containing: "AND table = ").isEmpty, "processes was loaded at connect")
    }
}
