import ClickHouseWire
import Foundation
import os

/// Column sets of the `system` tables the app reads, so one query shape works on every version
/// (design D10): missing columns are selected as `NULL AS name`, expensive ones are never selected
/// by accident, and optional tables are detected instead of failing.
public final class SystemSchema: Sendable {
    /// Tables loaded at connect time.
    public static let knownTables = [
        "tables", "columns", "databases", "parts", "parts_columns", "detached_parts", "merges", "mutations", "replicas", "replication_queue",
        "processes", "query_log", "disks", "storage_policies", "dictionaries", "clusters", "data_skipping_indices", "projections",
        "projection_parts", "settings", "functions", "zookeeper_connection", "distribution_queue", "distributed_ddl_queue", "macros",
        "merge_tree_settings", "table_engines", "formats", "table_functions", "data_type_families", "aggregate_function_combinators",
        "keywords", "database_engines",
    ]

    public static var loadQuery: String {
        "SELECT table, name FROM system.columns WHERE database = 'system' AND table IN ("
            + knownTables.map(SQLText.literal).joined(separator: ", ") + ")"
    }

    private let state: OSAllocatedUnfairLock<[String: Set<String>]>

    public init(columns: [String: Set<String>]) {
        state = OSAllocatedUnfairLock(initialState: columns)
    }

    convenience init(result: QueryResult) {
        var columns: [String: Set<String>] = [:]
        for record in result.records {
            guard let table = record.text("table"), let name = record.text("name") else { continue }
            columns[table, default: []].insert(name)
        }
        self.init(columns: columns)
    }

    public func hasTable(_ table: String) -> Bool { state.withLock { $0[table] != nil } }

    public func has(_ table: String, column: String) -> Bool { state.withLock { $0[table]?.contains(column) ?? false } }

    public func columns(of table: String) -> Set<String>? { state.withLock { $0[table] } }

    func merge(table: String, columns: Set<String>) {
        state.withLock { $0[table] = columns }
    }

    /// `a, b, NULL AS c` for `system.<table>`; every wanted column exists in the output.
    public func selectList(_ table: String, _ wanted: [String]) -> String {
        let available = columns(of: table) ?? []
        return wanted.map { name in
            available.contains(name) ? SQLText.quoteIdentifier(name) : "NULL AS \(SQLText.quoteIdentifier(name))"
        }.joined(separator: ", ")
    }

    /// `expression AS alias` when `column` exists, `fallback AS alias` otherwise.
    public func expression(_ table: String, column: String, _ expression: String, alias: String, fallback: String = "NULL") -> String {
        has(table, column: column) ? "\(expression) AS \(SQLText.quoteIdentifier(alias))" : "\(fallback) AS \(SQLText.quoteIdentifier(alias))"
    }
}

extension ClickHouseClient {
    /// Ensures the column set of `system.<table>` is known (tables such as `query_log` appear only after
    /// the server first flushes them). Returns `false` when the table does not exist.
    @discardableResult
    public func ensureSystemTable(_ table: String) async throws -> Bool {
        if systemSchema.hasTable(table) { return true }
        let result = try await execute("SELECT name FROM system.columns WHERE database = 'system' AND table = \(SQLText.literal(table))")
        let names = Set(result.rows.compactMap { $0.first ?? nil })
        guard !names.isEmpty else { return false }
        systemSchema.merge(table: table, columns: names)
        return true
    }
}
