import ClickHouseKit
import ClickHouseWire
import Foundation
import Testing

/// Live-server tests. Enable with `CCINNCH_IT_URL=http://127.0.0.1:18101` (a server started by
/// `scripts/ch-up.sh <version>` and seeded by `scripts/seed-demo.sh`).
enum ITEnvironment {
    static let environment = ProcessInfo.processInfo.environment
    static let url = environment["CCINNCH_IT_URL"].flatMap(URL.init(string:))
    static var enabled: Bool { url != nil }
    static let user = environment["CCINNCH_IT_USER"] ?? "ccinn"
    static let password = environment["CCINNCH_IT_PASSWORD"] ?? "ccinn-pass"

    static func configuration(user: String = user, password: String = password, readOnly: Bool = false,
                              url: URL? = url, sessionTimeout: Int = 1800, cluster: String? = nil) -> ConnectionConfiguration {
        let target = url ?? URL(string: "http://127.0.0.1:18101")!
        return ConnectionConfiguration(endpoint: Endpoint(host: target.host ?? "127.0.0.1", port: target.port ?? 8123),
                                       secure: target.scheme == "https", username: user, password: password, defaultCluster: cluster,
                                       connectTimeout: 10, readOnly: readOnly, sessionTimeout: sessionTimeout)
    }

    static func connect(readOnly: Bool = false, sessionTimeout: Int = 1800) async throws -> ClickHouseClient {
        try await ClickHouseClient.connect(configuration(readOnly: readOnly, sessionTimeout: sessionTimeout))
    }
}

/// Waits (bounded) for an async condition.
func waitUntil(_ timeout: Duration = .seconds(10), _ condition: () async throws -> Bool) async rethrows -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if try await condition() { return true }
        try? await Task.sleep(for: .milliseconds(250))
    }
    return try await condition()
}

/// Parent suite: live suites run one after another so a small (768 MB) server is never flooded.
@Suite("Live", .enabled(if: ITEnvironment.enabled), .serialized)
struct LiveSuites {}

extension LiveSuites {
@Suite("ClickHouse live server", .serialized)
struct ClickHouseIntegrationTests {
    @Test func connectAndServerInfo() async throws {
        let client = try await ITEnvironment.connect()
        defer { Task { await client.close() } }
        #expect(client.serverInfo.version != nil)
        #expect(client.serverInfo.currentUser == ITEnvironment.user)
        #expect(!client.capabilities.settingsLocked)
        // Only parser settings an older server lacks (22.8 has none, 24.8 only `dialect`) are dropped.
        #expect(client.capabilities.unsupportedSettings.isSubset(of: ParserSettings.verified.map(\.name)), "\(client.capabilities.unsupportedSettings)")
        #expect(client.systemSchema.has("tables", column: "engine"))
        print("live server: \(client.serverInfo.versionString) tz=\(client.serverInfo.timeZone ?? "-") node=\(client.serverInfo.displayName ?? "-")")
    }

    @Test func typedValuesAndNulls() async throws {
        let client = try await ITEnvironment.connect()
        defer { Task { await client.close() } }
        let result = try await client.run("""
            SELECT toUInt64(18446744073709551615) AS u, toInt128('-170141183460469231731687303715884105728') AS i, \
            toDecimal256('1234567890.123456789', 9) AS d, toNullable('\\\\N') AS literal_n, CAST(NULL AS Nullable(String)) AS null_s, \
            CAST(NULL AS LowCardinality(Nullable(String))) AS null_lc, nan AS f, -inf AS ninf, ['a\\tb', 'c'] AS arr, map('k', 1) AS m, \
            (1, 'x') AS t, toDateTime64('2026-01-02 03:04:05.123', 3, 'Asia/Kuala_Lumpur') AS dt, 'line\\nbreak\\ttab' AS s, \
            toUUID('61f0c404-5cb3-11e7-907b-a6006ad3dba0') AS uuid, toIPv6('::1') AS ip, unhex('C328') AS bin
            """)
        let row = try #require(result.rows.first)
        let names = result.columnNames
        func value(_ name: String) -> String? { row[names.firstIndex(of: name)!] }
        #expect(value("u") == "18446744073709551615")
        #expect(value("i") == "-170141183460469231731687303715884105728")
        #expect(value("d") == "1234567890.123456789")
        #expect(value("literal_n") == "\\N")
        #expect(value("null_s") == nil)
        #expect(value("null_lc") == nil)
        #expect(value("f") == "nan")
        #expect(value("ninf") == "-inf")
        #expect(value("arr") == "['a\\tb','c']")
        #expect(value("m") == "{'k':1}")
        #expect(value("t") == "(1,'x')")
        #expect(value("dt") == "2026-01-02 03:04:05.123")
        #expect(value("s") == "line\nbreak\ttab")
        #expect(value("uuid") == "61f0c404-5cb3-11e7-907b-a6006ad3dba0")
        #expect(value("ip") == "::1")
        #expect(result.columns[names.firstIndex(of: "dt")!].type.timeZone == "Asia/Kuala_Lumpur")
        #expect(result.columns[names.firstIndex(of: "u")!].type.kind == .integer)
        #expect(result.columns[names.firstIndex(of: "null_lc")!].type.isNullable)
        let binaryColumn = names.firstIndex(of: "bin")!
        #expect(result.bytes(row: 0, column: binaryColumn) == Data([0xC3, 0x28]))
    }

    @Test func midStreamExceptionIsReported() async throws {
        let client = try await ITEnvironment.connect()
        defer { Task { await client.close() } }
        do {
            _ = try await client.run("SELECT number, throwIf(number = 200000) FROM numbers(300000) SETTINGS max_block_size = 1000",
                                     options: QueryOptions(limits: RowLimits(maxRows: 1_000_000)))
            Issue.record("expected an exception")
        } catch let error as ClickHouseError {
            #expect(error.code == 395)
        }
    }

    @Test func serverErrorBeforeData() async throws {
        let client = try await ITEnvironment.connect()
        defer { Task { await client.close() } }
        do {
            _ = try await client.run("SELECT * FROM shop.no_such_table")
            Issue.record("expected an exception")
        } catch let error as ClickHouseError {
            #expect(error.code == 60)
            #expect(error.name == "UNKNOWN_TABLE")
        }
        do {
            _ = try await client.run("SELECT 1,\n  2 FRM t")
            Issue.record("expected a syntax error")
        } catch let error as ClickHouseError {
            #expect(error.code == 62)
            #expect(ClickHouseServerException.errorPosition(in: error.message) != nil)
        }
    }

    @Test func explicitFormatAndComments() async throws {
        let client = try await ITEnvironment.connect()
        defer { Task { await client.close() } }
        let json = try await client.run("SELECT 1 AS x FORMAT JSONEachRow")
        #expect(json.format == "JSONEachRow")
        #expect(json.rawText?.contains("\"x\":1") == true)
        #expect(try await client.run("SELECT 1 /* a /* nested */ b */ AS x").rows == [["1"]])
    }

    @Test func rowLimitTruncatesAndStopsTheServer() async throws {
        let client = try await ITEnvironment.connect()
        defer { Task { await client.close() } }
        let result = try await client.run("SELECT number FROM system.numbers", options: QueryOptions(limits: RowLimits(maxRows: 1000)))
        #expect(result.rows.count == 1000)
        #expect(result.isTruncated)
        let gone = try await waitUntil {
            try await client.execute("SELECT count() FROM system.processes WHERE query_id = \(SQLText.literal(result.queryID))").scalar == "0"
        }
        #expect(gone)
    }

    @Test func cancelStopsTheQueryOnTheServer() async throws {
        let client = try await ITEnvironment.connect()
        defer { Task { await client.close() } }
        let queryID = "ccinnch-sql-it-cancel-\(UUID().uuidString.prefix(8))"
        let task = Task {
            try await client.run("SELECT sleepEachRow(1) FROM numbers(60) SETTINGS max_block_size = 1", options: QueryOptions(queryID: queryID))
        }
        let started = try await waitUntil(.seconds(5)) {
            try await client.execute("SELECT count() FROM system.processes WHERE query_id = \(SQLText.literal(queryID))").scalar == "1"
        }
        #expect(started)
        task.cancel()
        await #expect(throws: ClickHouseError.self) { _ = try await task.value }
        let gone = try await waitUntil(.seconds(8)) {
            try await client.execute("SELECT count() FROM system.processes WHERE query_id = \(SQLText.literal(queryID))").scalar == "0"
        }
        #expect(gone)
    }

    @Test func timeoutIsEnforced() async throws {
        let client = try await ITEnvironment.connect()
        defer { Task { await client.close() } }
        do {
            _ = try await client.run("SELECT sleep(3)", options: QueryOptions(timeout: 1))
            Issue.record("expected a timeout")
        } catch let error as ClickHouseError {
            #expect(error.kind == .timeout || error.code == ClickHouseError.Code.timeoutExceeded)
        }
    }

    @Test func liveProgressPolling() async throws {
        let client = try await ITEnvironment.connect()
        defer { Task { await client.close() } }
        let queryID = "ccinnch-sql-it-progress-\(UUID().uuidString.prefix(8))"
        let task = Task {
            try await client.run("SELECT count() FROM numbers(2000000000) WHERE NOT ignore(sleepEachRow(0)) SETTINGS max_block_size = 100000, max_threads = 1",
                                 options: QueryOptions(queryID: queryID, timeout: 30))
        }
        var seen: QueryProgress?
        _ = try await waitUntil(.seconds(8)) {
            seen = try await client.progress(of: queryID)
            return (seen?.readRows ?? 0) > 0
        }
        #expect((seen?.readRows ?? 0) > 0)
        task.cancel()
        _ = try? await task.value
        let finished = try await waitUntil(.seconds(8)) { try await client.progress(of: queryID) == nil }
        #expect(finished)
    }

    @Test func sessionsKeepContextAndSurviveExpiry() async throws {
        let client = try await ITEnvironment.connect(sessionTimeout: 2)
        defer { Task { await client.close() } }
        let session = client.openSession()
        _ = try await session.run("USE shop")
        _ = try await session.run("SET max_threads = 3")
        let first = try await session.run("SELECT currentDatabase(), getSetting('max_threads')")
        #expect(first.rows == [["shop", "3"]])
        try await Task.sleep(for: .seconds(4))
        let second = try await session.run("SELECT currentDatabase(), getSetting('max_threads')")
        #expect(second.rows == [["shop", "3"]])
        #expect(second.sessionRecreated)
    }

    @Test func readOnlyProfileIsEnforcedByTheServer() async throws {
        let client = try await ITEnvironment.connect(readOnly: true)
        defer { Task { await client.close() } }
        #expect(try await client.run("SELECT count() FROM shop.events").rows.first?.first != nil)
        do {
            _ = try await client.run("CREATE TABLE shop.should_not_exist (a UInt8) ENGINE = Memory")
            Issue.record("expected READONLY")
        } catch let error as ClickHouseError {
            #expect(error.code == ClickHouseError.Code.readonly)
        }
        // Kills of own queries still work in readonly mode.
        #expect(try await client.killQuery(queryID: "nothing-to-kill") == .notFound)
    }

    @Test func settingsLockedReaderDegrades() async throws {
        let client = try await ClickHouseClient.connect(ITEnvironment.configuration(user: "reader", password: "reader-pass", readOnly: true))
        defer { Task { await client.close() } }
        #expect(client.capabilities.settingsLocked)
        #expect(client.serverInfo.readonlyLevel == 1)
        #expect(try await client.run("SELECT 1 AS x", options: QueryOptions(timeout: 10)).rows == [["1"]])
        let session = client.openSession()
        _ = try await session.run("USE shop")
        #expect(try await session.run("SELECT currentDatabase()").rows == [["shop"]])
        #expect(try await client.tables(database: "shop").isEmpty == false)
    }

    @Test func readonlyTwoUserConnectsReadOnly() async throws {
        // A server profile at readonly=2 refuses any change of `readonly`; the app must not send it and
        // keeps the other settings (they may change at readonly=2).
        let client = try await ClickHouseClient.connect(ITEnvironment.configuration(user: "reader2", password: "reader2-pass", readOnly: true))
        defer { Task { await client.close() } }
        #expect(client.serverInfo.readonlyLevel == 2)
        #expect(client.capabilities.serverEnforcesReadOnly)
        #expect(!client.capabilities.settingsLocked)
        #expect(try await client.run("SELECT 1 AS x", options: QueryOptions(timeout: 10)).rows == [["1"]])
        await #expect(throws: ClickHouseError.self) { _ = try await client.run("CREATE TABLE shop.should_not_exist (a UInt8) ENGINE = Memory") }
        // MCP run_query asks for readonly=1 per request, also on read-write profiles.
        let writable = try await ClickHouseClient.connect(ITEnvironment.configuration(user: "reader2", password: "reader2-pass"))
        defer { Task { await writable.close() } }
        #expect(try await writable.run("SELECT 2", options: QueryOptions(readOnly: true)).rows == [["2"]])
    }

    @Test func largeStatementsAreCompressed() async throws {
        let client = try await ITEnvironment.connect()
        defer { Task { await client.close() } }
        // ~110 KB: above the 64 KB gzip threshold, below the server's 256 KB max_query_size.
        let values = (0..<20_000).map(String.init).joined(separator: ",")
        let result = try await client.run("SELECT count() FROM numbers(100000) WHERE number IN (\(values))")
        #expect(result.rows == [["20000"]])
    }
}

}

extension LiveSuites {
@Suite("ClickHouse live metadata", .serialized)
struct ClickHouseMetadataIntegrationTests {
    @Test func databasesAndTablesByFamily() async throws {
        let client = try await ITEnvironment.connect()
        defer { Task { await client.close() } }
        let databases = try await client.databases()
        let shop = try #require(databases.first { $0.name == "shop" })
        #expect(shop.engineKind == .atomic)
        #expect(databases.last?.isSystem == true)
        let tables = try await client.tables(database: "shop")
        func family(_ name: String) -> EngineClassification? { tables.first { $0.name == name }?.classification }
        #expect(family("events")?.family == .mergeTree)
        #expect(family("orders_latest")?.variant == .replacing)
        #expect(family("daily_revenue")?.variant == .summing)
        #expect(family("user_uniques")?.variant == .aggregating)
        #expect(family("sessions")?.variant == .collapsing)
        #expect(family("cart_versions")?.variant == .versionedCollapsing)
        #expect(family("daily_revenue_mv")?.family == .materializedView)
        #expect(family("top_countries")?.family == .view)
        #expect(family("country_dict")?.family == .dictionary)
        #expect(family("inserts_buffer")?.family == .memory)
        #expect(family("audit_log")?.family == .log)
        #expect(family("remote_feed")?.family == .integration)
        let events = try #require(tables.first { $0.name == "events" })
        #expect((events.totalRows ?? 0) == 600_000)
        #expect(events.partitionKey == "toYYYYMM(event_date)")
        #expect(events.sortingKey == "event_type, user_id, event_time")
        #expect(events.samplingKey == "user_id")
    }

    @Test func tableDetailsColumnsAndDDL() async throws {
        let client = try await ITEnvironment.connect()
        defer { Task { await client.close() } }
        let table = try #require(try await client.table(database: "shop", name: "events"))
        let definition = try #require(table.engineDefinition)
        #expect(definition.ttl?.contains("event_date") == true)
        #expect(definition.setting("index_granularity") == "8192")
        let create = try #require(table.createTableQuery)
        let details = CreateStatementDetails.parse(create)
        #expect(details.columnTTLs["payload"] != nil)
        #expect(table.dependentTables.contains("shop.daily_revenue_mv"))
        let columns = try await client.columns(database: "shop", table: "events")
        let url = try #require(columns.first { $0.name == "url" })
        #expect(url.codec?.contains("ZSTD") == true)
        #expect(columns.first { $0.name == "user_id" }?.isInSortingKey == true)
        #expect(columns.first { $0.name == "event_date" }?.isInPartitionKey == true)
        #expect(columns.contains { ($0.compressedBytes ?? 0) > 0 })
        let ddl = try await client.ddl(database: "shop", name: "events")
        #expect(ddl.hasPrefix("CREATE TABLE shop.events"))
        #expect(ddl.contains("\n"))
        let mv = try #require(try await client.table(database: "shop", name: "daily_revenue_mv"))
        #expect(CreateStatementDetails.parse(mv.createTableQuery ?? "").materializedViewTarget == "shop.daily_revenue")
        #expect(mv.asSelect?.isEmpty == false)
    }

    @Test func partitionsPartsIndexesProjections() async throws {
        let client = try await ITEnvironment.connect()
        defer { Task { await client.close() } }
        let partitions = try await client.partitions(database: "shop", table: "events")
        #expect(partitions.count >= 9)
        #expect(partitions.allSatisfy { $0.activeParts > 0 })
        #expect(partitions.reduce(0) { $0 + $1.rows } == 600_000)
        let parts = try await client.parts(database: "shop", table: "events")
        #expect(!parts.isEmpty)
        #expect(parts.allSatisfy { $0.isActive && $0.rows > 0 })
        let indices = try await client.skippingIndices(database: "shop", table: "events")
        #expect(Set(indices.map(\.name)) == ["idx_url", "idx_amount"])
        #expect(indices.first { $0.name == "idx_url" }?.granularity == 4)
        let table = try await client.table(database: "shop", name: "events")
        let projections = try await client.projections(database: "shop", table: "events", createStatement: table?.createTableQuery)
        #expect(projections.map(\.name) == ["by_country"])
        let limits = try await client.mergeTreeLimits()
        #expect(limits.partsToDelayInsert > 0)
        let tiny = try #require(try await client.table(database: "shop", name: "tiny_parts"))
        let tinyLimits = limits.overridden(by: tiny.engineDefinition)
        #expect(tinyLimits.partsToDelayInsert == 20)
        let tinyPartitions = try await client.partitions(database: "shop", table: "tiny_parts")
        #expect(PartHealth.warnings(partitions: tinyPartitions, limits: tinyLimits).first?.level == .warning)
    }

    @Test func mutationsAndKill() async throws {
        let client = try await ITEnvironment.connect()
        defer { Task { await client.close() } }
        _ = try await client.run("ALTER TABLE shop.cart_versions UPDATE items = toUInt16(throwIf(1)) WHERE 1")
        var stuck: MutationInfo?
        _ = try await waitUntil(.seconds(20)) {
            stuck = try await client.mutations(database: "shop", table: "cart_versions", activeOnly: true).first
            return stuck?.latestFailReason != nil
        }
        let mutation = try #require(stuck)
        #expect(mutation.command.contains("throwIf"))
        #expect(mutation.isStuck)
        #expect(try await client.killMutation(database: "shop", table: "cart_versions", mutationID: mutation.mutationID) == 1)
        let cleared = try await waitUntil(.seconds(10)) {
            try await client.mutations(database: "shop", table: "cart_versions", activeOnly: true).isEmpty
        }
        #expect(cleared)
    }

    @Test func operationsViews() async throws {
        let client = try await ITEnvironment.connect()
        defer { Task { await client.close() } }
        _ = try await client.merges()
        _ = try await client.replicas()
        _ = try await client.replicationQueue()
        let running = try await client.runningQueries()
        #expect(running.allSatisfy { !$0.isAppMonitoring })
        #expect(try await client.disks().contains { $0.name == "default" && $0.totalSpace > 0 })
        #expect(try await client.storagePolicies().contains { $0.policy == "default" })
        _ = try await client.run("SELECT dictGet('shop.country_dict', 'name', tuple('MY'))")
        let dictionaries = try await client.dictionaries(database: "shop")
        let dictionary = try #require(dictionaries.first { $0.name == "country_dict" })
        #expect(dictionary.status == "LOADED")
        #expect(dictionary.elementCount >= 6)
        try await client.reloadDictionary(dictionary)
        _ = try await client.clusters()
        #expect(try await client.keeperStatus().state == .notConfigured || ProcessInfo.processInfo.environment["CCINNCH_IT_CLUSTER"] != nil)
        _ = try await client.macros()
        _ = try await client.distributedDDLQueue()
    }

    @Test func queryLogAnalyses() async throws {
        let client = try await ITEnvironment.connect()
        defer { Task { await client.close() } }
        _ = try await client.run("SELECT sum(number) FROM numbers(1000000)")
        _ = try? await client.run("SELECT throwIf(1)")
        _ = try await client.run("SYSTEM FLUSH LOGS")
        let slowest = try #require(try await client.queryLog(.slowest, hours: 1))
        #expect(!slowest.isEmpty)
        #expect(slowest.allSatisfy { !$0.queryID.hasPrefix("ccinnch-meta-") })
        let failed = try #require(try await client.queryLog(.failed, hours: 1))
        #expect(failed.contains { $0.query.contains("throwIf") })
        #expect(try await client.queryLog(.memory, hours: 1)?.isEmpty == false)
        #expect(try await client.queryPatterns(hours: 1)?.isEmpty == false)
        #expect(try await client.queryLogByUser(hours: 1)?.contains { $0.user == ITEnvironment.user } == true)
    }

    @Test func explainVariants() async throws {
        let client = try await ITEnvironment.connect()
        defer { Task { await client.close() } }
        for prefix in ["EXPLAIN", "EXPLAIN indexes = 1", "EXPLAIN PIPELINE", "EXPLAIN ESTIMATE", "EXPLAIN AST", "EXPLAIN SYNTAX"] {
            let result = try await client.run("\(prefix) SELECT count() FROM shop.events WHERE user_id = 42")
            #expect(!result.rows.isEmpty, "\(prefix)")
        }
    }
}
}
