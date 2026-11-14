import ClickHouseWire
import Foundation

/// Schema browsing (design D10: version-adaptive column lists, fallbacks only on server errors).
extension ClickHouseClient {
    public func databases() async throws -> [DatabaseInfo] {
        let list = systemSchema.selectList("databases", ["name", "engine", "engine_full", "comment", "uuid"])
        let result = try await execute("SELECT \(list) FROM system.databases")
        return result.records.compactMap { record in
            guard let name = record.raw("name") else { return nil }
            return DatabaseInfo(name: name, engine: record.text("engine") ?? "", engineFull: record.text("engine_full"),
                                comment: record.text("comment"), uuid: record.text("uuid"))
        }.sorted(by: DatabaseInfo.order)
    }

    static let tableListColumns = ["database", "name", "engine", "uuid", "is_temporary", "comment", "partition_key", "sorting_key", "primary_key",
                                   "sampling_key", "storage_policy", "total_rows", "total_bytes", "total_bytes_uncompressed", "active_parts",
                                   "total_marks", "metadata_modification_time"]

    /// Tables of one database (without the heavy CREATE statements).
    public func tables(database: String) async throws -> [TableInfo] {
        let list = systemSchema.selectList("tables", Self.tableListColumns)
        let result = try await execute("SELECT \(list) FROM system.tables WHERE database = \(SQLText.literal(database)) ORDER BY name")
        return result.records.compactMap(Self.table(from:))
    }

    /// Full details of one table, including the CREATE statement and dependants.
    public func table(database: String, name: String) async throws -> TableInfo? {
        let list = systemSchema.selectList("tables", Self.tableListColumns + ["engine_full", "create_table_query", "as_select",
                                                                              "dependencies_database", "dependencies_table"])
        let result = try await execute("""
            SELECT \(list) FROM system.tables WHERE database = \(SQLText.literal(database)) AND name = \(SQLText.literal(name))
            """)
        guard let record = result.first, var table = Self.table(from: record) else { return nil }
        table.engineFull = record.text("engine_full")
        table.createTableQuery = record.text("create_table_query")
        table.asSelect = record.text("as_select")
        let databases = record.stringArray("dependencies_database")
        let tables = record.stringArray("dependencies_table")
        table.dependentTables = zip(databases, tables).map { "\($0).\($1)" }
        return table
    }

    static func table(from record: Record) -> TableInfo? {
        guard let database = record.raw("database"), let name = record.raw("name") else { return nil }
        var table = TableInfo(database: database, name: name, engine: record.text("engine") ?? "")
        table.uuid = record.text("uuid")
        table.isTemporary = record.bool("is_temporary") ?? false
        table.comment = record.text("comment")
        table.partitionKey = record.text("partition_key")
        table.sortingKey = record.text("sorting_key")
        table.primaryKey = record.text("primary_key")
        table.samplingKey = record.text("sampling_key")
        table.storagePolicy = record.text("storage_policy")
        table.totalRows = record.int("total_rows")
        table.totalBytes = record.int("total_bytes")
        table.totalBytesUncompressed = record.int("total_bytes_uncompressed")
        table.activeParts = record.int("active_parts")
        table.totalMarks = record.int("total_marks")
        table.metadataModificationTime = record.text("metadata_modification_time")
        return table
    }

    static let columnColumns = ["database", "table", "name", "position", "type", "default_kind", "default_expression", "comment", "compression_codec",
                                "data_compressed_bytes", "data_uncompressed_bytes", "marks_bytes", "is_in_partition_key", "is_in_sorting_key",
                                "is_in_primary_key", "is_in_sampling_key"]

    /// Columns of one table, with codecs, compression and key membership.
    public func columns(database: String, table: String) async throws -> [ColumnInfo] {
        try await columnsByTable(database: database, tables: [table])[table] ?? []
    }

    /// Columns keyed by table name, for the given tables (at most 100) or a whole database.
    public func columnsByTable(database: String, tables: [String]? = nil) async throws -> [String: [ColumnInfo]] {
        let list = systemSchema.selectList("columns", Self.columnColumns)
        var sql = "SELECT \(list) FROM system.columns WHERE database = \(SQLText.literal(database))"
        if let tables {
            guard !tables.isEmpty else { return [:] }
            sql += " AND table IN (\(tables.prefix(100).map(SQLText.literal).joined(separator: ", ")))"
        }
        let result = try await execute(sql)
        var columns: [String: [ColumnInfo]] = [:]
        for record in result.records {
            guard let tableName = record.raw("table"), let name = record.raw("name") else { continue }
            var column = ColumnInfo(name: name, position: Int(clamping: record.int("position") ?? 0), type: record.text("type") ?? "")
            column.defaultKind = record.text("default_kind")
            column.defaultExpression = record.text("default_expression")
            column.comment = record.text("comment")
            column.codec = record.text("compression_codec")
            column.compressedBytes = record.int("data_compressed_bytes")
            column.uncompressedBytes = record.int("data_uncompressed_bytes")
            column.marksBytes = record.int("marks_bytes")
            column.isInPartitionKey = record.bool("is_in_partition_key") ?? false
            column.isInSortingKey = record.bool("is_in_sorting_key") ?? false
            column.isInPrimaryKey = record.bool("is_in_primary_key") ?? false
            column.isInSamplingKey = record.bool("is_in_sampling_key") ?? false
            columns[tableName, default: []].append(column)
        }
        for key in columns.keys { columns[key]?.sort { $0.position < $1.position } }
        return columns
    }

    /// `SHOW CREATE TABLE` (or `DICTIONARY`).
    public func ddl(database: String, name: String, isDictionary: Bool = false) async throws -> String {
        let kind = isDictionary ? "DICTIONARY" : "TABLE"
        let result = try await execute("SHOW CREATE \(kind) \(SQLText.qualified(database, name))")
        return result.scalar ?? ""
    }
}
