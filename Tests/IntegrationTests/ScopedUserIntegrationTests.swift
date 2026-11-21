import ClickHouseWire
import Foundation
import Testing
@testable import CcinnClickHouseKit
@testable import ClickHouseKit

extension LiveSuites {
    /// A user whose grants cover one database (`GRANT SELECT ON shop.*`). `system.columns` hides every `system`
    /// table from such a user, who may still read `system.databases` / `tables` / `columns` (and, on 22.8, almost
    /// every `system` table). Before 1.3.1 the app read that as "no columns" and listed nothing.
    @Suite("Database-scoped user", .serialized)
    struct ScopedUserIntegrationTests {
        static let user = "ccinnch_scoped_reader"
        static let password = "scoped-reader-pass"

        /// Runs `body` with a read-only connection as the scoped user and an admin connection; removes the user after.
        func withScopedUser(_ body: (_ reader: ClickHouseClient, _ admin: ClickHouseClient) async throws -> Void) async throws {
            let admin = try await ITEnvironment.connect()
            _ = try await admin.run("CREATE USER OR REPLACE \(Self.user) IDENTIFIED WITH plaintext_password BY '\(Self.password)'")
            _ = try await admin.run("GRANT SELECT ON shop.* TO \(Self.user)")
            do {
                let reader = try await ClickHouseClient.connect(ITEnvironment.configuration(user: Self.user, password: Self.password, readOnly: true))
                do {
                    try await body(reader, admin)
                    await reader.close()
                } catch {
                    await reader.close()
                    throw error
                }
            } catch {
                _ = try? await admin.run("DROP USER IF EXISTS \(Self.user)")
                await admin.close()
                throw error
            }
            _ = try? await admin.run("DROP USER IF EXISTS \(Self.user)")
            await admin.close()
        }

        @Test func catalogCompletionAndMCPSeeTheGrantedDatabase() async throws {
            try await withScopedUser { reader, admin in
                // The condition this suite is about, on every version.
                let hidden = try await reader.execute("SELECT count() FROM system.columns WHERE database = 'system'").scalar
                #expect(hidden == "0", "system.columns lists system tables for a scoped user on this version")

                #expect(try await reader.databases().map(\.name).contains("shop"))
                let tables = try await reader.tables(database: "shop")
                let adminTables = try await admin.tables(database: "shop")
                #expect(!tables.isEmpty)
                #expect(Set(tables.map { "\($0.name) \($0.engine)" }) == Set(adminTables.map { "\($0.name) \($0.engine)" }))
                #expect(tables.allSatisfy { !$0.engine.isEmpty })
                let columns = try await reader.columns(database: "shop", table: "events")
                #expect(!columns.isEmpty)
                #expect(columns.map(\.name) == (try await admin.columns(database: "shop", table: "events")).map(\.name))
                #expect(columns.allSatisfy { !$0.type.isEmpty })

                let vocabulary = try await ServerVocabulary.load(from: reader)
                #expect(vocabulary.functions.count > ServerVocabulary.fallback.functions.count, "server functions, not the static list")
                #expect(vocabulary.settings.count > ServerVocabulary.fallback.settings.count, "server settings, not the static list")
                #expect(vocabulary.functions.contains { $0.name == "sumIf" || $0.name == "sum" })

                let target = try #require(ITEnvironment.url)
                let profile = ConnectionProfile(name: "Scoped", host: target.host ?? "127.0.0.1", port: target.port ?? 8123, username: Self.user,
                                                mcpAccess: .readOnly)
                let tools = ClickHouseMCPTools(resolver: MCPProfileResolver(profiles: [profile], defaultProfile: nil, forceReadOnly: false),
                                               registry: MCPClientRegistry { profile, access in
                                                   try await ClientOpener.open(profile: profile, password: Self.password, sshSecret: nil,
                                                                               readOnlyOverride: access != .readWrite)
                                               }, audit: nil)
                let databases = await tools.call(name: "list_databases", arguments: [:])
                #expect(!databases.isError, "\(databases.payload)")
                #expect("\(databases.payload)".contains("shop"), "\(databases.payload)")
                let listed = await tools.call(name: "list_tables", arguments: ["database": "shop"])
                #expect(!listed.isError, "\(listed.payload)")
                #expect("\(listed.payload)".contains("events"), "\(listed.payload)")
                // Composite answers note a part the user may not read instead of failing as a whole (26.8 refuses
                // system.data_skipping_indices and system.distributed_ddl_queue to this user).
                let described = await tools.call(name: "describe_table", arguments: ["database": "shop", "table": "events"])
                #expect(!described.isError, "\(described.payload)")
                #expect("\(described.payload)".contains("user_id"), "\(described.payload)")
                // 24.8+ refuse system.clusters itself to this user; with it granted, only the DDL queue is refused.
                _ = try await admin.run("GRANT SELECT ON system.clusters TO \(Self.user)")
                let cluster = await tools.call(name: "get_cluster", arguments: [:])
                #expect(!cluster.isError, "\(cluster.payload)")
                #expect("\(cluster.payload)".contains("recent_ddl"), "\(cluster.payload)")
            }
        }

        /// The SQL editor's completion, fed as the workspace feeds it, offers the user's tables and columns (before
        /// 1.3.1 it had neither, and only the static function list).
        @Test func completionOffersTheUsersTablesAndColumns() async throws {
            try await withScopedUser { reader, admin in
                let databases = try await reader.databases().map(\.name)
                let objects = try await reader.tables(database: "shop").filter { !$0.isInnerTable }
                let columns = try await reader.columnsByTable(database: "shop", tables: ["events"])
                let schema = SchemaSnapshot(currentDatabase: "shop", databases: databases,
                                            objectsByDatabase: ["shop": objects.map { .init(name: $0.name, family: $0.family) }],
                                            columnsByTable: columns.reduce(into: [:]) { $0[TableKey(database: "shop", table: $1.key)] = $1.value },
                                            vocabulary: try await ServerVocabulary.load(from: reader))
                func labels(_ text: String) -> [String] {
                    let cursor = (text as NSString).range(of: "|").location
                    let source = text.replacingOccurrences(of: "|", with: "")
                    return CompletionEngine.complete(text: source, cursor: cursor, schema: schema).items.map(\.label)
                }
                #expect(labels("SELECT * FROM shop.|").contains("events"))
                #expect(labels("SELECT * FROM |").contains("shop"))
                let firstColumn = try #require(try await admin.columns(database: "shop", table: "events").first?.name)
                #expect(labels("SELECT | FROM shop.events").contains(firstColumn))
                #expect(labels("SELECT e.| FROM shop.events AS e").contains(firstColumn))
            }
        }

        /// System tables the user may read show real values; the others show the server's error, never rows of NULL.
        @Test func insightsAreRealOrRefusedByTheServer() async throws {
            try await withScopedUser { reader, _ in
                func check<T>(_ table: String, _ read: () async throws -> [T], valid: (T) -> Bool) async throws {
                    if try await reader.ensureSystemTable(table) {
                        let rows = try await read()
                        let allValid = rows.allSatisfy(valid)
                        #expect(allValid, "system.\(table) returned rows without values")
                    } else {
                        do {
                            _ = try await read()
                            Issue.record("system.\(table) could not be learned but was read")
                        } catch let error as ClickHouseError {
                            #expect(error.code == 497, "system.\(table): \(error.message)")
                        }
                    }
                }
                try await check("parts", { try await reader.parts(database: "shop", table: "events") }) { !$0.name.isEmpty && !$0.partitionID.isEmpty }
                try await check("parts", { try await reader.partitions(database: "shop", table: "events") }) { !$0.partitionID.isEmpty }
                try await check("processes", { try await reader.runningQueries(includeAppMonitoring: true) }) { !$0.queryID.isEmpty }
                try await check("disks", { try await reader.disks() }) { !$0.name.isEmpty }
                try await check("mutations", { try await reader.mutations(database: "shop", table: "events") }) { !$0.mutationID.isEmpty }
                try await check("dictionaries", { try await reader.dictionaries() }) { !$0.name.isEmpty }
                // Optional tables: read when available, empty when the version lacks them, the server's error when denied.
                let optional: [(String, () async throws -> Void)] = [
                    ("data_skipping_indices", { _ = try await reader.skippingIndices(database: "shop", table: "events") }),
                    ("distributed_ddl_queue", { _ = try await reader.distributedDDLQueue() }),
                    ("query_log", { _ = try await reader.queryLog(.recent) }),
                ]
                for (table, read) in optional {
                    switch try await reader.systemTableAvailability(table) {
                    case .available, .absent:
                        try await read()
                    case .denied:
                        do {
                            try await read()
                            Issue.record("system.\(table) is denied but was read")
                        } catch let error as ClickHouseError {
                            #expect(error.isAccessDenied, "system.\(table): \(error.message)")
                        }
                    }
                }
            }
        }

        /// The DESCRIBE header the fallback reads equals what `system.columns` lists (without ALIAS columns, which
        /// `SELECT *` omits), and no column the app selects is an ALIAS.
        @Test func describeHeadersMatchSystemColumns() async throws {
            let admin = try await ITEnvironment.connect()
            defer { Task { await admin.close() } }
            // Every column list the app selects from `system`.
            let wanted: [String: [String]] = [
                "databases": ClickHouseClient.databaseColumns, "tables": ClickHouseClient.tableDetailColumns,
                "columns": ClickHouseClient.columnColumns, "parts": ClickHouseClient.partColumns,
                "data_skipping_indices": ClickHouseClient.skippingIndexColumns, "projections": ClickHouseClient.projectionColumns,
                "replicas": ClickHouseClient.replicaColumns + ["total_replicas", "active_replicas"],
                "replication_queue": ClickHouseClient.queueColumns, "merges": ClickHouseClient.mergeColumns,
                "mutations": ClickHouseClient.mutationColumns, "distribution_queue": ClickHouseClient.distributionQueueColumns,
                "dictionaries": ClickHouseClient.dictionaryColumns, "processes": ClickHouseClient.processColumns,
                "query_log": ClickHouseClient.queryLogColumns, "disks": ClickHouseClient.diskColumns,
                "storage_policies": ClickHouseClient.storagePolicyColumns, "clusters": ClickHouseClient.clusterColumns,
                "zookeeper_connection": ClickHouseClient.keeperConnectionColumns, "distributed_ddl_queue": ClickHouseClient.ddlQueueColumns,
                "functions": ServerVocabulary.functionColumns, "settings": ServerVocabulary.settingColumns,
            ]
            var compared = 0
            for table in SystemSchema.knownTables {
                let listed = try await admin.execute("""
                    SELECT name, default_kind FROM system.columns WHERE database = 'system' AND table = \(SQLText.literal(table))
                    """).records
                guard !listed.isEmpty else { continue }
                let aliases = Set(listed.filter { ["ALIAS", "MATERIALIZED", "EPHEMERAL"].contains($0.raw("default_kind") ?? "") }
                    .compactMap { $0.raw("name") })
                let plain = Set(listed.compactMap { $0.raw("name") }).subtracting(aliases)
                let described: Set<String>
                do {
                    described = Set(try await admin.execute("DESCRIBE (SELECT * FROM system.\(SQLText.quoteIdentifier(table)))").records
                        .compactMap { $0.raw("name") })
                } catch let error as ClickHouseError where error.isFeatureUnavailable {
                    continue
                }
                #expect(described == plain, "system.\(table): DESCRIBE \(described.symmetricDifference(plain).sorted())")
                #expect(aliases.isDisjoint(with: wanted[table] ?? []), "system.\(table): the app selects ALIAS columns \(aliases)")
                compared += 1
            }
            #expect(compared >= 20)
        }
    }
}
