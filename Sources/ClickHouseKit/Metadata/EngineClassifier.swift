import Foundation

/// Table engine families, ordered for grouping in the sidebar (design D13).
public enum EngineFamily: Int, Sendable, CaseIterable, Comparable, Hashable {
    case mergeTree
    case replicatedMergeTree
    case sharedMergeTree
    case distributed
    case materializedView
    case view
    case dictionary
    case streaming
    case integration
    case dataLake
    case log
    case memory
    case system
    case other

    public static func < (lhs: EngineFamily, rhs: EngineFamily) -> Bool { lhs.rawValue < rhs.rawValue }

    public var groupTitle: String {
        switch self {
        case .mergeTree: "MergeTree"
        case .replicatedMergeTree: "Replicated MergeTree"
        case .sharedMergeTree: "Shared MergeTree"
        case .distributed: "Distributed"
        case .materializedView: "Materialized Views"
        case .view: "Views"
        case .dictionary: "Dictionaries"
        case .streaming: "Streaming"
        case .integration: "Integrations"
        case .dataLake: "Data Lakes"
        case .log: "Log"
        case .memory: "Memory & Special"
        case .system: "System"
        case .other: "Other"
        }
    }

    /// Engines that keep data in MergeTree parts (partitions, parts, merges, mutations apply).
    public var hasParts: Bool { self == .mergeTree || self == .replicatedMergeTree || self == .sharedMergeTree }
}

/// The MergeTree variant (independent of replication).
public enum MergeTreeVariant: String, Sendable, CaseIterable, Hashable {
    case plain, replacing, summing, aggregating, collapsing, versionedCollapsing, graphite, coalescing

    public var badge: String? {
        switch self {
        case .plain: nil
        case .replacing: "Replacing"
        case .summing: "Summing"
        case .aggregating: "Aggregating"
        case .collapsing: "Collapsing"
        case .versionedCollapsing: "VCollapsing"
        case .graphite: "Graphite"
        case .coalescing: "Coalescing"
        }
    }
}

/// Classification of one table engine.
public struct EngineClassification: Sendable, Hashable {
    public let engine: String
    public let family: EngineFamily
    public let variant: MergeTreeVariant?
    public let isReplicated: Bool

    public init(engine: String, family: EngineFamily, variant: MergeTreeVariant? = nil, isReplicated: Bool = false) {
        self.engine = engine
        self.family = family
        self.variant = variant
        self.isReplicated = isReplicated
    }

    /// Short badge shown next to the table name.
    public var badge: String? {
        switch family {
        case .mergeTree, .replicatedMergeTree, .sharedMergeTree: variant?.badge
        case .integration, .streaming, .dataLake, .log, .memory, .other: engine
        default: nil
        }
    }

    public static func classify(engine rawEngine: String, database: String = "") -> EngineClassification {
        let engine = rawEngine.trimmingCharacters(in: .whitespaces)
        if engine.hasSuffix("MergeTree") {
            var base = engine
            var family = EngineFamily.mergeTree
            var replicated = false
            if base.hasPrefix("Replicated") {
                base = String(base.dropFirst("Replicated".count))
                family = .replicatedMergeTree
                replicated = true
            } else if base.hasPrefix("Shared") {
                base = String(base.dropFirst("Shared".count))
                family = .sharedMergeTree
                replicated = true
            }
            let variant: MergeTreeVariant = switch base {
            case "ReplacingMergeTree": .replacing
            case "SummingMergeTree": .summing
            case "AggregatingMergeTree": .aggregating
            case "CollapsingMergeTree": .collapsing
            case "VersionedCollapsingMergeTree": .versionedCollapsing
            case "GraphiteMergeTree": .graphite
            case "CoalescingMergeTree": .coalescing
            default: .plain
            }
            return EngineClassification(engine: engine, family: family, variant: variant, isReplicated: replicated)
        }
        let family: EngineFamily
        switch engine {
        case "Distributed": family = .distributed
        case "MaterializedView", "RefreshableMaterializedView": family = .materializedView
        case "View", "LiveView", "WindowView": family = .view
        case "Dictionary": family = .dictionary
        case "Kafka", "RabbitMQ", "NATS", "S3Queue", "AzureQueue", "FileLog", "Redis Streams": family = .streaming
        case "MySQL", "PostgreSQL", "MongoDB", "ODBC", "JDBC", "SQLite", "Redis", "S3", "HDFS", "URL", "File", "AzureBlobStorage",
             "ExternalDistributed", "MaterializedPostgreSQL", "Executable", "ExecutablePool", "COSN", "OSS", "GCS", "YTsaurus", "ArrowFlight":
            family = .integration
        case "Iceberg", "IcebergS3", "IcebergAzure", "IcebergHDFS", "IcebergLocal", "DeltaLake", "DeltaLakeS3", "DeltaLakeAzure", "DeltaLakeLocal",
             "Hudi", "Hive", "Paimon":
            family = .dataLake
        case "TinyLog", "StripeLog", "Log": family = .log
        case "Memory", "Set", "Join", "Buffer", "Null", "Merge", "GenerateRandom", "EmbeddedRocksDB", "KeeperMap", "Loop", "TimeSeries", "Alias":
            family = .memory
        default:
            if engine.hasPrefix("System") || database.lowercased() == "system" || database.lowercased() == "information_schema" {
                family = .system
            } else {
                family = .other
            }
        }
        return EngineClassification(engine: engine, family: family)
    }
}

/// Database engine kinds.
public enum DatabaseEngineKind: String, Sendable, Hashable {
    case atomic, ordinary, replicated, lazy, memory, mysql, materializedMySQL, postgreSQL, materializedPostgreSQL, sqlite, dataLake
    case dictionary, filesystem, backup, shared, other

    public init(engine: String) {
        switch engine.trimmingCharacters(in: .whitespaces) {
        case "Atomic": self = .atomic
        case "Ordinary": self = .ordinary
        case "Replicated": self = .replicated
        case "Lazy": self = .lazy
        case "Memory": self = .memory
        case "MySQL": self = .mysql
        case "MaterializedMySQL", "MaterializeMySQL": self = .materializedMySQL
        case "PostgreSQL": self = .postgreSQL
        case "MaterializedPostgreSQL": self = .materializedPostgreSQL
        case "SQLite": self = .sqlite
        case "DataLakeCatalog", "Iceberg": self = .dataLake
        case "Dictionary": self = .dictionary
        case "Filesystem", "S3", "HDFS": self = .filesystem
        case "Backup": self = .backup
        case "Shared": self = .shared
        default: self = .other
        }
    }

    /// Badge for engines worth pointing out (Atomic is the default and gets none).
    public var badge: String? {
        switch self {
        case .atomic: nil
        case .ordinary: "Ordinary"
        case .replicated: "Replicated"
        case .lazy: "Lazy"
        case .memory: "Memory"
        case .mysql: "MySQL"
        case .materializedMySQL: "MaterializedMySQL"
        case .postgreSQL: "PostgreSQL"
        case .materializedPostgreSQL: "MaterializedPG"
        case .sqlite: "SQLite"
        case .dataLake: "DataLake"
        case .dictionary: "Dictionary"
        case .filesystem: "Files"
        case .backup: "Backup"
        case .shared: "Shared"
        case .other: nil
        }
    }

    /// Engines whose tables live in another system.
    public var isExternal: Bool {
        switch self {
        case .mysql, .materializedMySQL, .postgreSQL, .materializedPostgreSQL, .sqlite, .dataLake, .filesystem: true
        default: false
        }
    }
}
