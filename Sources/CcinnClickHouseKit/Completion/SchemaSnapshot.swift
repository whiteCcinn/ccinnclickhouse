import ClickHouseKit
import ClickHouseWire
import Foundation

/// Case-insensitive `database.table` key.
public struct TableKey: Hashable, Sendable, CustomStringConvertible {
    public let database: String
    public let table: String

    public init(database: String, table: String) {
        self.database = database.lowercased()
        self.table = table.lowercased()
    }

    public var description: String { "\(database).\(table)" }
}

/// One server setting offered after `SET` / `SETTINGS`.
public struct SettingEntry: Sendable, Hashable {
    public let name: String
    public let type: String?
    public let value: String?
    public let summary: String?

    public init(name: String, type: String? = nil, value: String? = nil, summary: String? = nil) {
        self.name = name
        self.type = type
        self.value = value
        self.summary = summary
    }
}

/// Server-provided vocabulary for completion (design D12), with static fallbacks.
public struct ServerVocabulary: Sendable {
    public var functions: [SQLFunction]
    public var combinators: [String]
    public var settings: [SettingEntry]
    public var formats: [String]
    public var engines: [String]
    public var tableFunctions: [String]
    public var dataTypes: [String]
    public var clusters: [String]
    public var dictionaries: [String]

    public init(functions: [SQLFunction], combinators: [String], settings: [SettingEntry], formats: [String], engines: [String],
                tableFunctions: [String], dataTypes: [String], clusters: [String] = [], dictionaries: [String] = []) {
        self.functions = functions
        self.combinators = combinators
        self.settings = settings
        self.formats = formats
        self.engines = engines
        self.tableFunctions = tableFunctions
        self.dataTypes = dataTypes
        self.clusters = clusters
        self.dictionaries = dictionaries
    }

    public static let fallback = ServerVocabulary(
        functions: StaticVocabulary.aggregateFunctions.map { SQLFunction(name: $0, isAggregate: true) }
            + StaticVocabulary.functions.map { SQLFunction(name: $0, isAggregate: false) },
        combinators: StaticVocabulary.combinators,
        settings: ["max_threads", "max_memory_usage", "max_execution_time", "max_result_rows", "max_block_size", "join_algorithm",
                   "optimize_read_in_order", "use_query_cache", "allow_experimental_analyzer", "log_comment", "readonly"]
            .map { SettingEntry(name: $0) },
        formats: StaticVocabulary.formats, engines: StaticVocabulary.engines, tableFunctions: StaticVocabulary.tableFunctions,
        dataTypes: StaticVocabulary.dataTypes)

    public var aggregateFunctionNames: [String] { functions.filter(\.isAggregate).map(\.name) }

    static let functionColumns = ["name", "is_aggregate", "alias_to", "syntax", "description"]
    static let settingColumns = ["name", "type", "value", "description"]

    /// Loads the vocabulary from `system.*`; each part falls back to the static list when unavailable
    /// (only server errors fall back; timeouts and cancellation propagate).
    public static func load(from client: ClickHouseClient) async throws -> ServerVocabulary {
        var vocabulary = fallback
        let functionColumns = try await client.selectList(system: "functions", Self.functionColumns)
        if let result = try await client.tolerant("SELECT \(functionColumns) FROM system.functions") {
            let functions = result.records.compactMap { record -> SQLFunction? in
                guard let name = record.raw("name"), !name.isEmpty, !name.hasPrefix("_") else { return nil }
                let summary = record.text("description").map { String($0.split(separator: "\n").first ?? "").prefix(200) }.map(String.init)
                let signature = record.text("syntax").map { String($0.prefix(160)) }
                return SQLFunction(name: name, isAggregate: record.bool("is_aggregate") ?? false, signature: signature,
                                   summary: summary ?? record.text("alias_to").map { "Alias of \($0)" })
            }
            if !functions.isEmpty { vocabulary.functions = functions }
        }
        if let result = try await client.tolerant("SELECT name FROM system.aggregate_function_combinators") {
            let names = result.rows.compactMap { $0.first ?? nil }.filter { !$0.isEmpty }
            if !names.isEmpty { vocabulary.combinators = names }
        }
        let settingColumns = try await client.selectList(system: "settings", Self.settingColumns)
        if let result = try await client.tolerant("SELECT \(settingColumns) FROM system.settings") {
            let settings = result.records.compactMap { record -> SettingEntry? in
                guard let name = record.raw("name") else { return nil }
                let summary = record.text("description").map { String(($0.split(separator: "\n").first ?? "").prefix(200)) }
                return SettingEntry(name: name, type: record.text("type"), value: record.raw("value"), summary: summary)
            }
            if !settings.isEmpty { vocabulary.settings = settings }
        }
        func names(_ sql: String) async throws -> [String]? {
            guard let result = try await client.tolerant(sql) else { return nil }
            let values = result.rows.compactMap { $0.first ?? nil }.filter { !$0.isEmpty }
            return values.isEmpty ? nil : values
        }
        vocabulary.formats = try await names("SELECT name FROM system.formats WHERE is_output") ?? vocabulary.formats
        vocabulary.engines = try await names("SELECT name FROM system.table_engines") ?? vocabulary.engines
        vocabulary.tableFunctions = try await names("SELECT name FROM system.table_functions") ?? vocabulary.tableFunctions
        vocabulary.dataTypes = try await names("SELECT name FROM system.data_type_families WHERE alias_to = ''") ?? vocabulary.dataTypes
        vocabulary.clusters = try await names("SELECT DISTINCT cluster FROM system.clusters") ?? []
        vocabulary.dictionaries = try await names("SELECT concat(database, if(database = '', '', '.'), name) FROM system.dictionaries") ?? []
        return vocabulary
    }
}

/// What completion knows about the schema. Built by the app from lazily loaded metadata; immutable,
/// so completion runs off the main actor without locks.
public struct SchemaSnapshot: Sendable {
    public struct ObjectEntry: Sendable, Hashable {
        public let name: String
        public let family: EngineFamily

        public init(name: String, family: EngineFamily) {
            self.name = name
            self.family = family
        }
    }

    public var currentDatabase: String?
    public var databases: [String]
    /// Objects per database (keys lower-cased).
    public var objectsByDatabase: [String: [ObjectEntry]]
    public var columnsByTable: [TableKey: [ColumnInfo]]
    public var vocabulary: ServerVocabulary

    public init(currentDatabase: String? = nil, databases: [String] = [], objectsByDatabase: [String: [ObjectEntry]] = [:],
                columnsByTable: [TableKey: [ColumnInfo]] = [:], vocabulary: ServerVocabulary = .fallback) {
        self.currentDatabase = currentDatabase
        self.databases = databases
        self.objectsByDatabase = Dictionary(objectsByDatabase.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { $1 })
        self.columnsByTable = columnsByTable
        self.vocabulary = vocabulary
    }

    public func objects(in database: String) -> [ObjectEntry]? {
        objectsByDatabase[database.lowercased()]
    }

    public func columns(database: String, table: String) -> [ColumnInfo]? {
        columnsByTable[TableKey(database: database, table: table)]
    }

    public func isDatabase(_ name: String) -> Bool {
        databases.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    public func object(named name: String, in database: String) -> ObjectEntry? {
        objects(in: database)?.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}
