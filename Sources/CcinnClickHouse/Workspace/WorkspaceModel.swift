import CcinnClickHouseKit
import ClickHouseKit
import Foundation
import Observation

struct Toast: Equatable, Identifiable {
    let id = UUID()
    let message: String
    let isError: Bool
}

/// One tab in the workspace.
struct WorkspaceTab: Identifiable, Equatable {
    enum Kind {
        case object(ObjectDetailModel)
        case sql(SQLTabModel)
        case operations(OperationsModel)
    }

    let id = UUID()
    let kind: Kind

    static func == (lhs: WorkspaceTab, rhs: WorkspaceTab) -> Bool { lhs.id == rhs.id }

    @MainActor var title: String {
        switch kind {
        case let .object(model): model.table.name
        case let .sql(model): model.title
        case .operations: "Operations"
        }
    }

    @MainActor var subtitle: String? {
        switch kind {
        case let .object(model): model.table.database
        case let .sql(model): model.database
        case .operations: nil
        }
    }

    @MainActor var icon: String {
        switch kind {
        case let .object(model): Theme.icon(for: model.table.family)
        case .sql: "chevron.left.forwardslash.chevron.right"
        case .operations: "waveform.path.ecg"
        }
    }
}

/// Everything a connected window shows: database tree, open tabs, and caches shared by tabs.
@MainActor
@Observable
final class WorkspaceModel {
    enum DatabaseState {
        case loading
        case loaded([TableInfo])
        case failed(String)
    }

    let profile: ConnectionProfile
    let client: ClickHouseClient
    let history: QueryHistoryStore

    var databases: [DatabaseInfo] = []
    var isLoadingDatabases = false
    var databasesError: String?
    var databaseStates: [String: DatabaseState] = [:]
    var expandedDatabases: Set<String> = []
    var sidebarFilter = ""
    var sidebarSelection: String?
    var showSystemDatabases = false

    var tabs: [WorkspaceTab] = []
    var selectedTabID: UUID?
    var toast: Toast?
    /// Server vocabulary for completion (functions, combinators, settings…), loaded once.
    private(set) var vocabulary: ServerVocabulary = .fallback
    private var vocabularyTask: Task<Void, Never>?

    /// Columns per table for completion and previews, plus a one-minute negative cache.
    private var columnCache: [TableKey: [ColumnInfo]] = [:]
    private var columnMisses: [TableKey: Date] = [:]
    private var columnLoads: [String: Task<Void, Never>] = [:]
    private var objectLoads: [String: Task<Void, Never>] = [:]
    private var objectLoadGenerations: [String: UInt64] = [:]
    private var objectLoadGeneration: UInt64 = 0
    private var databaseLoadGeneration: UInt64 = 0
    private var sqlTabCounter = 0
    private var toastTask: Task<Void, Never>?

    init(profile: ConnectionProfile, client: ClickHouseClient) {
        self.profile = profile
        self.client = client
        history = QueryHistoryStore(directory: AppServices.shared.historyDirectory, profileID: profile.id)
    }

    var serverInfo: ServerInfo { client.serverInfo }

    var versionLabel: String {
        serverInfo.version.map { "ClickHouse \($0.major).\($0.minor)" } ?? serverInfo.versionString
    }

    /// Cluster used for cluster-wide views: the profile's, if any.
    var cluster: String? { profile.defaultCluster?.trimmingCharacters(in: .whitespaces).isEmpty == false ? profile.defaultCluster : nil }

    var isReadOnly: Bool { client.configuration.readOnly || client.capabilities.settingsLocked || (serverInfo.readonlyLevel ?? 0) > 0 }

    // MARK: Lifecycle

    func start() {
        Task { await reloadDatabases() }
        vocabularyTask = Task {
            let client = client
            if let loaded = try? await ServerVocabulary.load(from: client) { vocabulary = loaded }
        }
    }

    func shutdown() {
        vocabularyTask?.cancel()
        for tab in tabs { closeResources(of: tab) }
        tabs.removeAll()
        let client = client
        Task.detached { await client.close() }
    }

    // MARK: Database tree

    var visibleDatabases: [DatabaseInfo] {
        showSystemDatabases ? databases : databases.filter { !$0.isSystem }
    }

    func reloadDatabases() async {
        databaseLoadGeneration &+= 1
        let generation = databaseLoadGeneration
        isLoadingDatabases = true
        defer { if databaseLoadGeneration == generation { isLoadingDatabases = false } }
        do {
            let loaded = try await client.databases()
            guard databaseLoadGeneration == generation else { return }
            databases = loaded
            databasesError = nil
            if expandedDatabases.isEmpty {
                let names = loaded.map(\.name)
                let preferred = profile.defaultDatabase.flatMap { name in names.first { $0 == name } }
                    ?? loaded.first { !$0.isSystem && $0.name != "default" }?.name ?? loaded.first { !$0.isSystem }?.name
                if let preferred { setExpanded(preferred, true) }
            }
            for database in expandedDatabases where loaded.contains(where: { $0.name == database }) {
                loadObjects(database: database, force: true)
            }
        } catch {
            guard databaseLoadGeneration == generation else { return }
            databasesError = describe(error)
        }
    }

    func refreshAll() {
        columnCache.removeAll()
        columnMisses.removeAll()
        Task { await reloadDatabases() }
    }

    func setExpanded(_ database: String, _ expanded: Bool) {
        if expanded {
            expandedDatabases.insert(database)
            if databaseStates[database] == nil { loadObjects(database: database) }
        } else {
            expandedDatabases.remove(database)
        }
    }

    func loadObjects(database: String, force: Bool = false) {
        if !force, let state = databaseStates[database], case .loaded = state { return }
        if objectLoads[database] != nil, !force { return }
        if databaseStates[database] == nil { databaseStates[database] = .loading }
        objectLoadGeneration &+= 1
        let generation = objectLoadGeneration
        objectLoads[database]?.cancel()
        objectLoadGenerations[database] = generation
        objectLoads[database] = Task {
            // Only the newest load for this database may publish its result or clear the slot.
            defer { if objectLoadGenerations[database] == generation { objectLoads[database] = nil } }
            do {
                let tables = try await client.tables(database: database)
                guard objectLoadGenerations[database] == generation else { return }
                databaseStates[database] = .loaded(tables)
            } catch {
                guard objectLoadGenerations[database] == generation, !Task.isCancelled else { return }
                databaseStates[database] = .failed(describe(error))
            }
        }
    }

    func awaitObjects(database: String) async -> [TableInfo]? {
        if case let .loaded(tables)? = databaseStates[database] { return tables }
        loadObjects(database: database)
        while let task = objectLoads[database] {
            await task.value
            if objectLoads[database] == task { break }
        }
        if case let .loaded(tables)? = databaseStates[database] { return tables }
        return nil
    }

    func objects(in database: String) -> [TableInfo]? {
        if case let .loaded(tables)? = databaseStates[database] { return tables }
        return nil
    }

    // MARK: Completion schema

    func completionSnapshot(currentDatabase: String?) -> SchemaSnapshot {
        var objectsByDatabase: [String: [SchemaSnapshot.ObjectEntry]] = [:]
        for (database, state) in databaseStates {
            if case let .loaded(tables) = state {
                objectsByDatabase[database] = tables.filter { !$0.isInnerTable }.map { SchemaSnapshot.ObjectEntry(name: $0.name, family: $0.family) }
            }
        }
        return SchemaSnapshot(currentDatabase: currentDatabase ?? serverInfo.defaultDatabase, databases: databases.map(\.name),
                              objectsByDatabase: objectsByDatabase, columnsByTable: columnCache, vocabulary: vocabulary)
    }

    /// Loads what completion reported as missing: table lists, and columns of the referenced tables.
    /// Tables that do not exist are remembered for a minute so typing does not re-query them.
    func ensureSchema(columns keys: [TableKey], databases missingDatabases: [String]) async {
        for database in Set(missingDatabases) where databases.contains(where: { $0.name.caseInsensitiveCompare(database) == .orderedSame }) {
            _ = await awaitObjects(database: database)
        }
        let now = Date()
        let wanted = Set(keys).filter { key in
            columnCache[key] == nil && (columnMisses[key].map { now.timeIntervalSince($0) > 60 } ?? true)
        }
        for (database, group) in Dictionary(grouping: wanted, by: \.database) {
            let tables = group.map(\.table)
            let loadKey = database + "\u{1F}" + tables.sorted().joined(separator: ",")
            if let running = columnLoads[loadKey] {
                await running.value
                continue
            }
            let client = client
            let realDatabase = databases.first { $0.name.lowercased() == database }?.name ?? database
            let realTables = tables.map { lowered in objects(in: realDatabase)?.first { $0.name.lowercased() == lowered }?.name ?? lowered }
            let task = Task {
                let loaded = try? await client.columnsByTable(database: realDatabase, tables: realTables)
                var found = Set<TableKey>()
                for (table, list) in loaded ?? [:] {
                    let key = TableKey(database: realDatabase, table: table)
                    columnCache[key] = list
                    found.insert(key)
                }
                for key in group where !found.contains(key) { columnMisses[key] = Date() }
            }
            columnLoads[loadKey] = task
            await task.value
            columnLoads[loadKey] = nil
        }
    }

    // MARK: Tabs

    var selectedTab: WorkspaceTab? { tabs.first { $0.id == selectedTabID } }

    func openObject(_ table: TableInfo, section: ObjectDetailModel.Section? = nil) {
        if let existing = tabs.first(where: { if case let .object(model) = $0.kind { model.table.id == table.id } else { false } }) {
            selectedTabID = existing.id
            if let section, case let .object(model) = existing.kind { model.select(section) }
            return
        }
        let model = ObjectDetailModel(table: table, workspace: self)
        if let section { model.select(section) }
        let tab = WorkspaceTab(kind: .object(model))
        tabs.append(tab)
        selectedTabID = tab.id
    }

    @discardableResult
    func openSQL(text: String = "", database: String? = nil, run: Bool = false) -> SQLTabModel {
        sqlTabCounter += 1
        let model = SQLTabModel(title: "Query \(sqlTabCounter)", text: text, database: database ?? contextDatabase(), workspace: self)
        let tab = WorkspaceTab(kind: .sql(model))
        tabs.append(tab)
        selectedTabID = tab.id
        if run { model.runAll() }
        return model
    }

    func openOperations(section: OperationsModel.Section = .running) {
        if let existing = tabs.first(where: { if case .operations = $0.kind { true } else { false } }) {
            selectedTabID = existing.id
            if case let .operations(model) = existing.kind { model.section = section }
            return
        }
        let model = OperationsModel(workspace: self, section: section)
        let tab = WorkspaceTab(kind: .operations(model))
        tabs.append(tab)
        selectedTabID = tab.id
    }

    func close(_ tab: WorkspaceTab) {
        guard let index = tabs.firstIndex(of: tab) else { return }
        closeResources(of: tab)
        tabs.remove(at: index)
        if selectedTabID == tab.id {
            selectedTabID = tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id
        }
    }

    func closeSelectedTab() {
        if let selectedTab { close(selectedTab) }
    }

    func selectTab(offset: Int) {
        guard !tabs.isEmpty else { return }
        let current = tabs.firstIndex { $0.id == selectedTabID } ?? 0
        selectedTabID = tabs[(current + offset + tabs.count) % tabs.count].id
    }

    func moveTab(_ id: UUID, to target: UUID) {
        guard let from = tabs.firstIndex(where: { $0.id == id }), let to = tabs.firstIndex(where: { $0.id == target }), from != to else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: to)
    }

    private func closeResources(of tab: WorkspaceTab) {
        switch tab.kind {
        case let .sql(model): model.close()
        case let .operations(model): model.close()
        case let .object(model): model.close()
        }
    }

    /// Database for new SQL tabs: the open object's, the current tab's, or the sidebar's.
    private func contextDatabase() -> String? {
        if case let .object(model)? = selectedTab?.kind { return model.table.database }
        if case let .sql(model)? = selectedTab?.kind { return model.database }
        let names = databases.map(\.name)
        if let preferred = profile.defaultDatabase, names.contains(preferred) { return preferred }
        return expandedDatabases.sorted().first
    }

    // MARK: Feedback

    func showToast(_ message: String, isError: Bool = false) {
        toast = Toast(message: message, isError: isError)
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(isError ? 5 : 2.5))
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }
}
