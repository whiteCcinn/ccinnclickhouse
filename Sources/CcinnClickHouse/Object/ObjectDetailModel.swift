import CcinnClickHouseKit
import ClickHouseKit
import Foundation
import Observation

enum Loadable<Value> {
    case idle
    case loading
    case loaded(Value)
    case failed(String)

    var value: Value? {
        if case let .loaded(value) = self { return value }
        return nil
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

/// State of one table tab. Sections load lazily and independently; every load carries a generation
/// token so a slower, superseded request never overwrites a newer result.
@MainActor
@Observable
final class ObjectDetailModel {
    enum Section: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case columns = "Columns"
        case parts = "Parts"
        case indexes = "Indexes"
        case mutations = "Mutations"
        case replication = "Replication"
        case ddl = "DDL"
        case data = "Data"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .overview: "info.circle"
            case .columns: "list.bullet.rectangle"
            case .parts: "square.stack.3d.down.forward"
            case .indexes: "line.3.horizontal.decrease.circle"
            case .mutations: "wand.and.stars"
            case .replication: "arrow.triangle.2.circlepath"
            case .ddl: "doc.plaintext"
            case .data: "tablecells"
            }
        }
    }

    private(set) var table: TableInfo
    unowned let workspace: WorkspaceModel
    private(set) var section: Section = .overview

    var details: Loadable<TableInfo> = .idle
    var columns: Loadable<[ColumnInfo]> = .idle
    var partitions: Loadable<[PartitionSummary]> = .idle
    var limits: MergeTreeLimits?
    var parts: Loadable<[PartInfo]> = .idle
    var partsPartition: String? { didSet { if partsPartition != oldValue { loadParts() } } }
    var indices: Loadable<[SkippingIndex]> = .idle
    var projections: Loadable<[ProjectionInfo]> = .idle
    var mutations: Loadable<[MutationInfo]> = .idle
    var merges: Loadable<[MergeInfo]> = .idle
    var replica: Loadable<ReplicaStatus?> = .idle
    var queue: Loadable<[ReplicationQueueEntry]> = .idle
    var distributionQueue: Loadable<[DistributionQueueEntry]> = .idle
    var dictionary: Loadable<DictionaryInfo?> = .idle
    var ddl: Loadable<String> = .idle
    var preview: Loadable<QueryResult> = .idle
    var previewID = UUID()
    var actionInFlight = false
    var inspected: InspectedValue?
    var pendingKill: MutationInfo?

    private var generations: [String: UInt64] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    init(table: TableInfo, workspace: WorkspaceModel) {
        self.table = table
        self.workspace = workspace
        load(.overview)
    }

    var client: ClickHouseClient { workspace.client }
    var classification: EngineClassification { table.classification }
    var definition: EngineDefinition? { (details.value ?? table).engineDefinition }
    var createDetails: CreateStatementDetails? { details.value?.createTableQuery.map(CreateStatementDetails.parse) }

    var availableSections: [Section] {
        switch table.family {
        case .mergeTree, .sharedMergeTree: [.overview, .columns, .parts, .indexes, .mutations, .ddl, .data]
        case .replicatedMergeTree: [.overview, .columns, .parts, .indexes, .mutations, .replication, .ddl, .data]
        case .streaming: [.overview, .columns, .ddl]
        default: [.overview, .columns, .ddl, .data]
        }
    }

    var partWarnings: [PartHealth.Warning] {
        guard let partitions = partitions.value, let limits else { return [] }
        return PartHealth.warnings(partitions: partitions, limits: limits)
    }

    func select(_ section: Section) {
        guard availableSections.contains(section) else { return }
        self.section = section
        load(section)
    }

    func reload() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        details = .idle
        columns = .idle
        partitions = .idle
        parts = .idle
        indices = .idle
        projections = .idle
        mutations = .idle
        merges = .idle
        replica = .idle
        queue = .idle
        distributionQueue = .idle
        dictionary = .idle
        ddl = .idle
        preview = .idle
        if let refreshed = workspace.objects(in: table.database)?.first(where: { $0.name == table.name }) { table = refreshed }
        load(section)
    }

    func close() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
    }

    func load(_ section: Section) {
        switch section {
        case .overview:
            if case .idle = details { loadDetails() }
            if table.family.hasParts {
                loadPartitions()
                if case .idle = columns { loadColumns() }
            }
            if table.family == .distributed, case .idle = distributionQueue { loadDistributionQueue() }
            if table.family == .dictionary, case .idle = dictionary { loadDictionary() }
            if classification.isReplicated, case .idle = replica { loadReplication() }
        case .columns:
            if case .idle = details { loadDetails() }
            if case .idle = columns { loadColumns() }
        case .parts:
            loadPartitions()
            loadParts()
        case .indexes:
            if case .idle = details { loadDetails() }
            if case .idle = indices { loadIndexes() }
        case .mutations:
            loadMutations()
        case .replication:
            loadReplication()
        case .ddl:
            if case .idle = ddl { loadDDL() }
        case .data:
            if case .idle = preview { loadPreview() }
        }
    }

    // MARK: Loaders

    /// Runs `body` and publishes its outcome through `assign` only if no newer load of `key` started meanwhile.
    private func run<Value>(_ key: String, _ assign: @escaping (Loadable<Value>) -> Void, _ body: @escaping @MainActor () async throws -> Value) {
        let generation = (generations[key] ?? 0) &+ 1
        generations[key] = generation
        tasks[key]?.cancel()
        assign(.loading)
        tasks[key] = Task { [weak self] in
            let outcome: Loadable<Value>
            do {
                outcome = .loaded(try await body())
            } catch {
                guard !Task.isCancelled else { return }
                outcome = .failed(describe(error))
            }
            guard let self, self.generations[key] == generation else { return }
            assign(outcome)
            self.tasks[key] = nil
        }
    }

    func loadDetails() {
        let table = table
        run("details", { self.details = $0 }) {
            guard let details = try await self.client.table(database: table.database, name: table.name) else {
                throw ClickHouseError(.server, "\(table.database).\(table.name) no longer exists")
            }
            return details
        }
    }

    func loadColumns() {
        let table = table
        run("columns", { self.columns = $0 }) {
            var columns = try await self.client.columns(database: table.database, table: table.name)
            let create = try await self.client.table(database: table.database, name: table.name)?.createTableQuery
            let ttls = create.map(CreateStatementDetails.parse)?.columnTTLs ?? [:]
            for index in columns.indices { columns[index].ttl = ttls[columns[index].name] }
            return columns
        }
    }

    func loadPartitions() {
        guard table.family.hasParts else { return }
        let table = table
        run("partitions", { self.partitions = $0 }) {
            async let partitions = self.client.partitions(database: table.database, table: table.name)
            async let limits = self.client.mergeTreeLimits()
            let resolvedLimits = try await limits
            let definition = try await self.client.table(database: table.database, name: table.name)?.engineDefinition
            self.limits = resolvedLimits.overridden(by: definition)
            return try await partitions
        }
    }

    func loadParts() {
        guard table.family.hasParts else { return }
        let (table, partition) = (table, partsPartition)
        run("parts", { self.parts = $0 }) {
            try await self.client.parts(database: table.database, table: table.name, partitionID: partition, limit: 5_000)
        }
    }

    func loadIndexes() {
        let table = table
        run("indices", { self.indices = $0 }) { try await self.client.skippingIndices(database: table.database, table: table.name) }
        run("projections", { self.projections = $0 }) {
            let create = try await self.client.table(database: table.database, name: table.name)?.createTableQuery
            return try await self.client.projections(database: table.database, table: table.name, createStatement: create)
        }
    }

    func loadMutations() {
        let table = table
        run("mutations", { self.mutations = $0 }) { try await self.client.mutations(database: table.database, table: table.name, limit: 500) }
        run("merges", { self.merges = $0 }) { try await self.client.merges(database: table.database, table: table.name) }
    }

    func loadReplication() {
        let table = table
        run("replica", { self.replica = $0 }) { try await self.client.replicas(database: table.database, table: table.name).first }
        run("queue", { self.queue = $0 }) { try await self.client.replicationQueue(database: table.database, table: table.name, limit: 1_000) }
    }

    func loadDistributionQueue() {
        let table = table
        run("distribution", { self.distributionQueue = $0 }) { try await self.client.distributionQueue(database: table.database, table: table.name) }
    }

    func loadDictionary() {
        let table = table
        run("dictionary", { self.dictionary = $0 }) {
            try await self.client.dictionaries(database: table.database).first { $0.name == table.name }
        }
    }

    func loadDDL() {
        let table = table
        run("ddl", { self.ddl = $0 }) { try await self.client.ddl(database: table.database, name: table.name, isDictionary: table.family == .dictionary) }
    }

    func loadPreview() {
        let sql = "SELECT * FROM \(table.qualifiedName) LIMIT 200"
        run("preview", { [weak self] state in
            self?.preview = state
            self?.previewID = UUID()
        }) {
            try await self.client.run(sql, options: QueryOptions(purpose: "sql", limits: RowLimits(maxRows: 200), timeout: 60, idempotent: true))
        }
    }

    // MARK: Actions

    func killMutation(_ mutation: MutationInfo) {
        actionInFlight = true
        let client = client
        Task {
            defer { actionInFlight = false }
            do {
                let killed = try await client.killMutation(database: mutation.database, table: mutation.table, mutationID: mutation.mutationID)
                workspace.showToast(killed > 0 ? "Mutation \(mutation.mutationID) killed" : "Mutation \(mutation.mutationID) had already finished")
                loadMutations()
            } catch {
                workspace.showToast(describe(error), isError: true)
            }
        }
    }

    func reloadDictionary() {
        guard let dictionary = dictionary.value ?? nil else { return }
        actionInFlight = true
        let client = client
        Task {
            defer { actionInFlight = false }
            do {
                try await client.reloadDictionary(dictionary)
                workspace.showToast("Dictionary reloaded")
                loadDictionary()
            } catch {
                workspace.showToast(describe(error), isError: true)
            }
        }
    }

    // MARK: Shortcuts

    func openQuery() {
        workspace.openSQL(text: "SELECT *\nFROM \(table.qualifiedName)\nLIMIT 100", database: table.database, run: true)
    }

    func showParts(partition: String?) {
        partsPartition = partition
        select(.parts)
    }
}
