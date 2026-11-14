import ClickHouseWire
import Foundation

/// One database (`system.databases`).
public struct DatabaseInfo: Sendable, Hashable, Identifiable {
    public var name: String
    public var engine: String
    public var engineFull: String?
    public var comment: String?
    public var uuid: String?

    public init(name: String, engine: String, engineFull: String? = nil, comment: String? = nil, uuid: String? = nil) {
        self.name = name
        self.engine = engine
        self.engineFull = engineFull
        self.comment = comment
        self.uuid = uuid
    }

    public var id: String { name }
    public var engineKind: DatabaseEngineKind { DatabaseEngineKind(engine: engine) }
    public var isSystem: Bool { DatabaseInfo.systemNames.contains(name) }

    static let systemNames: Set<String> = ["system", "information_schema", "INFORMATION_SCHEMA"]

    /// User databases first, system databases last.
    public static func order(_ lhs: DatabaseInfo, _ rhs: DatabaseInfo) -> Bool {
        if lhs.isSystem != rhs.isSystem { return !lhs.isSystem }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}

/// One table, view, dictionary or materialized view (`system.tables`).
public struct TableInfo: Sendable, Hashable, Identifiable {
    public var database: String
    public var name: String
    public var engine: String
    public var engineFull: String?
    public var uuid: String?
    public var isTemporary = false
    public var comment: String?
    public var partitionKey: String?
    public var sortingKey: String?
    public var primaryKey: String?
    public var samplingKey: String?
    public var storagePolicy: String?
    public var totalRows: Int64?
    public var totalBytes: Int64?
    public var totalBytesUncompressed: Int64?
    public var activeParts: Int64?
    public var totalMarks: Int64?
    public var metadataModificationTime: String?
    public var createTableQuery: String?
    public var asSelect: String?
    /// Tables that depend on this one (materialized views reading from it).
    public var dependentTables: [String] = []

    public init(database: String, name: String, engine: String) {
        self.database = database
        self.name = name
        self.engine = engine
    }

    public var id: String { "\(database)\u{1F}\(name)" }
    public var classification: EngineClassification { EngineClassification.classify(engine: engine, database: database) }
    public var family: EngineFamily { classification.family }
    public var qualifiedName: String { SQLText.qualified(database, name) }
    public var engineDefinition: EngineDefinition? { engineFull.map(EngineDefinition.parse) }
    /// Hidden inner tables of materialized views (`.inner.mv`, `.inner_id.uuid`).
    public var isInnerTable: Bool { name.hasPrefix(".inner") }

    /// Compression ratio (uncompressed / compressed) when both sizes are known.
    public var compressionRatio: Double? {
        guard let uncompressed = totalBytesUncompressed, let compressed = totalBytes, compressed > 0, uncompressed > 0 else { return nil }
        return Double(uncompressed) / Double(compressed)
    }
}

/// One column (`system.columns`, plus TTL from the CREATE statement).
public struct ColumnInfo: Sendable, Hashable, Identifiable {
    public var name: String
    public var position: Int
    public var type: String
    public var defaultKind: String?
    public var defaultExpression: String?
    public var comment: String?
    public var codec: String?
    public var ttl: String?
    public var compressedBytes: Int64?
    public var uncompressedBytes: Int64?
    public var marksBytes: Int64?
    public var isInPartitionKey = false
    public var isInSortingKey = false
    public var isInPrimaryKey = false
    public var isInSamplingKey = false

    public init(name: String, position: Int, type: String) {
        self.name = name
        self.position = position
        self.type = type
    }

    public var id: String { name }
    public var parsedType: ClickHouseType { ClickHouseType.parse(type) }

    public var compressionRatio: Double? {
        guard let compressed = compressedBytes, let uncompressed = uncompressedBytes, compressed > 0, uncompressed > 0 else { return nil }
        return Double(uncompressed) / Double(compressed)
    }
}
