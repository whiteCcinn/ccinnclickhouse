import AppKit
import CcinnClickHouseKit
import ClickHouseKit
import ClickHouseWire
import Foundation
import Observation

/// Result of one executed statement.
@MainActor
@Observable
final class StatementOutcome: Identifiable {
    let id = UUID()
    let index: Int
    let sql: String
    let executedSQL: String
    let kind: SQLStatementKind
    let startedAt: Date
    var durationMilliseconds: Double = 0
    var result: QueryResult?
    var errorMessage: String?
    var errorCode: Int?
    var limitApplied: Int?
    var isRunning = true
    /// Live counters while running (polled from `system.processes`).
    var liveProgress: QueryProgress?
    var viewMode: ViewMode = .grid
    var chart: ChartState?

    enum ViewMode: String, CaseIterable, Identifiable {
        case grid = "Grid"
        case chart = "Chart"
        case plan = "Plan"
        var id: String { rawValue }
    }

    init(index: Int, sql: String, executedSQL: String, kind: SQLStatementKind) {
        self.index = index
        self.sql = sql
        self.executedSQL = executedSQL
        self.kind = kind
        startedAt = Date()
        if kind == .explain { viewMode = .plan }
    }

    /// The row set to display.
    var rowSet: QueryResult? { result?.hasRowSet == true ? result : nil }

    var summary: String {
        if isRunning { return "Running…" }
        if errorMessage != nil { return "Failed" }
        if let rowSet {
            let rows = Format.count(rowSet.rows.count)
            return rowSet.isTruncated ? "\(rows)+ rows" : "\(rows) row\(rowSet.rows.count == 1 ? "" : "s")"
        }
        if result?.rawText != nil { return result?.format ?? "Text" }
        if let written = result?.writtenRows, written > 0 { return "\(Format.count(written)) rows written" }
        return "OK"
    }

    /// Plain-text plan for EXPLAIN results (one column of lines).
    var planText: String? {
        guard let rowSet, kind == .explain else { return nil }
        return rowSet.rows.map { $0.compactMap { $0 }.joined(separator: "\t") }.joined(separator: "\n")
    }
}

/// Chart configuration and prepared data for one result.
@MainActor
@Observable
final class ChartState {
    var spec: ChartSpec { didSet { if spec != oldValue { rebuild() } } }
    let roles: [ColumnRole]
    private(set) var data: ChartData = .empty
    private(set) var isPreparing = false
    private let columns: [ColumnDefinition]
    private let rows: [[String?]]
    private var buildTask: Task<Void, Never>?
    private var buildGeneration: UInt64 = 0

    init?(result: QueryResult) {
        guard result.hasRowSet, !result.rows.isEmpty else { return nil }
        columns = result.columns
        rows = result.rows
        let roles = ChartSuggester.roles(columns: result.columns, rows: result.rows)
        self.roles = roles
        let numeric = roles.indices.first { roles[$0] == .numeric }
        guard let suggested = ChartSuggester.suggest(roles: roles, rows: result.rows)
            ?? numeric.map({ ChartSpec(kind: .bar, xColumn: 0, yColumns: [$0]) }) else { return nil }
        spec = suggested
        rebuild()
    }

    var columnNames: [String] { columns.map(\.name) }
    var numericColumns: [Int] { roles.indices.filter { roles[$0] == .numeric } }

    private func rebuild() {
        buildTask?.cancel()
        buildGeneration &+= 1
        let generation = buildGeneration
        isPreparing = true
        let (columns, rows, spec, roles) = (self.columns, self.rows, self.spec, self.roles)
        buildTask = Task { [weak self] in
            let data = await Task.detached(priority: .userInitiated) {
                ChartDataBuilder.build(columns: columns, rows: rows, spec: spec, roles: roles)
            }.value
            guard let self, !Task.isCancelled, self.buildGeneration == generation else { return }
            self.data = data
            self.isPreparing = false
        }
    }
}

/// One SQL editor tab: text, server session, execution of current/selected/all statements with live
/// progress, results and history.
@MainActor
@Observable
final class SQLTabModel {
    let title: String
    var text: String
    var selection = NSRange(location: 0, length: 0)
    private(set) var database: String?
    var outcomes: [StatementOutcome] = []
    var selectedOutcomeID: UUID?
    var isRunning = false
    var runStartedAt: Date?
    var errorOffset: Int?
    var inspected: InspectedValue?
    var pendingConfirmation: PendingConfirmation?
    var showHistory = false

    struct PendingConfirmation: Identifiable {
        let id = UUID()
        let statements: [String]
        let continuation: CheckedContinuation<Bool, Never>
    }

    enum ExplainKind: String, CaseIterable, Identifiable {
        case plan = "Plan"
        case planIndexes = "Plan with indexes"
        case planActions = "Plan with actions"
        case pipeline = "Pipeline"
        case estimate = "Estimate (rows/marks to read)"
        case ast = "AST"
        case syntax = "Syntax (optimized query)"
        var id: String { rawValue }

        var prefix: String {
            switch self {
            case .plan: "EXPLAIN PLAN"
            case .planIndexes: "EXPLAIN indexes = 1"
            case .planActions: "EXPLAIN actions = 1"
            case .pipeline: "EXPLAIN PIPELINE"
            case .estimate: "EXPLAIN ESTIMATE"
            case .ast: "EXPLAIN AST"
            case .syntax: "EXPLAIN SYNTAX"
            }
        }
    }

    unowned let workspace: WorkspaceModel
    private let session: SQLSession
    private var runTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    /// Increases for every statement; a poll result for an older statement is discarded.
    private var progressGeneration: UInt64 = 0

    /// Rows kept per result (hard cap) and the default auto-limit for plain SELECTs.
    static let hardRowCap = 100_000
    var autoLimit: Int {
        get { UserDefaults.standard.object(forKey: "autoLimit") as? Int ?? 1000 }
        set { UserDefaults.standard.set(newValue, forKey: "autoLimit") }
    }

    init(title: String, text: String, database: String?, workspace: WorkspaceModel) {
        self.title = title
        self.text = text
        self.database = database
        self.workspace = workspace
        session = workspace.client.openSession(database: database)
        selection = NSRange(location: (text as NSString).length, length: 0)
    }

    var selectedOutcome: StatementOutcome? {
        outcomes.first { $0.id == selectedOutcomeID } ?? outcomes.last
    }

    // MARK: Running

    /// Selection if any, otherwise the statement under the cursor.
    func runCurrent() {
        let nsText = text as NSString
        if selection.length > 0, NSMaxRange(selection) <= nsText.length {
            let selected = nsText.substring(with: selection)
            run(SQLStatementSplitter.split(selected).map { ($0.text, selection.location + $0.range.lowerBound) })
            return
        }
        guard let statement = SQLStatementSplitter.statement(at: selection.location, in: text) else { return }
        run([(statement.text, statement.range.lowerBound)])
    }

    func runAll() {
        run(SQLStatementSplitter.split(text).map { ($0.text, $0.range.lowerBound) })
    }

    func explain(_ kind: ExplainKind = .planIndexes) {
        let nsText = text as NSString
        guard let statement = selection.length > 0 && NSMaxRange(selection) <= nsText.length
            ? SQLStatementSplitter.split(nsText.substring(with: selection)).first
            : SQLStatementSplitter.statement(at: selection.location, in: text) else { return }
        let body = statement.text
        let sql = SQLStatementKind.of(body) == .explain ? body : "\(kind.prefix) \(body)"
        run([(sql, nil)])
    }

    func stop() {
        guard isRunning else { return }
        Task { await session.cancel() }
    }

    /// Runs statements sequentially; stops at the first error.
    private func run(_ statements: [(text: String, offset: Int?)]) {
        guard !isRunning, !statements.isEmpty else { return }
        errorOffset = nil
        isRunning = true
        runStartedAt = Date()
        outcomes = []
        runTask = Task {
            defer {
                isRunning = false
                runStartedAt = nil
                stopProgress()
            }
            let texts = statements.map(\.text)
            if workspace.client.configuration.readOnly, let write = texts.first(where: { SQLStatementKind.of($0).isMutation }) {
                // The server would refuse it too (readonly=1); say so before sending anything.
                let outcome = StatementOutcome(index: 0, sql: write, executedSQL: write, kind: SQLStatementKind.of(write))
                outcome.errorMessage = "This connection is read-only: statements that change data, schema or server state are not sent."
                outcome.isRunning = false
                outcomes = [outcome]
                return
            }
            let mutations = texts.filter { SQLStatementKind.of($0).isMutation }
            if workspace.profile.confirmMutations, !mutations.isEmpty {
                let confirmed = await withCheckedContinuation { continuation in
                    pendingConfirmation = PendingConfirmation(statements: mutations, continuation: continuation)
                }
                guard confirmed else { return }
            }
            for (index, statement) in statements.enumerated() {
                let succeeded = await execute(statement.text, index: index, offset: statement.offset)
                if !succeeded || Task.isCancelled { break }
            }
        }
    }

    func resolveConfirmation(_ confirmed: Bool) {
        pendingConfirmation?.continuation.resume(returning: confirmed)
        pendingConfirmation = nil
    }

    private func execute(_ sql: String, index: Int, offset: Int?) async -> Bool {
        let kind = SQLStatementKind.of(sql)
        var executed = sql
        var limitApplied: Int?
        if kind == .query, autoLimit > 0 {
            let outcome = AutoLimit.apply(to: sql, limit: autoLimit)
            if outcome.applied {
                executed = outcome.sql
                limitApplied = autoLimit
            }
        }
        let outcome = StatementOutcome(index: index, sql: sql, executedSQL: executed, kind: kind)
        outcome.limitApplied = limitApplied
        outcomes.append(outcome)
        selectedOutcomeID = outcome.id
        startProgress(for: outcome)

        let clock = ContinuousClock()
        let started = clock.now
        var historyEntry = QueryHistoryEntry(sql: sql, database: database, durationMilliseconds: 0)
        let idempotent = [.query, .show, .explain].contains(kind)
        do {
            let result = try await session.run(executed, limits: RowLimits(maxRows: Self.hardRowCap), idempotent: idempotent)
            outcome.result = result
            if let rowSet = outcome.rowSet { historyEntry.rowCount = rowSet.rows.count }
            historyEntry.affectedRows = UInt64(clamping: max(0, result.writtenRows))
            database = await session.database
            if result.sessionRecreated {
                workspace.showToast("The server session had expired; database and settings were restored (temporary tables are lost).")
            }
            if kind == .definition { refreshSidebar(after: sql) }
        } catch {
            outcome.errorMessage = describe(error)
            outcome.errorCode = (error as? ClickHouseError)?.code
            historyEntry.errorMessage = outcome.errorMessage
            if let offset, let message = (error as? ClickHouseError)?.message, let inner = SQLErrorLocator.offset(in: executed, message: message),
               inner <= (sql as NSString).length {
                errorOffset = offset + inner
            }
        }
        stopProgress()
        let elapsed = clock.now - started
        outcome.durationMilliseconds = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        outcome.isRunning = false
        historyEntry.durationMilliseconds = outcome.durationMilliseconds
        await workspace.history.append(historyEntry)
        return outcome.errorMessage == nil
    }

    // MARK: Live progress

    /// Polls `system.processes` for the running statement every 750 ms. Each statement gets a new
    /// generation, so a late poll never writes into a finished or newer outcome.
    private func startProgress(for outcome: StatementOutcome) {
        progressTask?.cancel()
        progressGeneration &+= 1
        let generation = progressGeneration
        let session = session
        let client = workspace.client
        let cluster = workspace.cluster
        progressTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(750))
            while !Task.isCancelled {
                guard let queryID = await session.runningQueryID else { return }
                let progress = try? await client.progress(of: queryID, cluster: cluster)
                guard let self, !Task.isCancelled, self.progressGeneration == generation, outcome.isRunning else { return }
                if let progress { outcome.liveProgress = progress }
                try? await Task.sleep(for: .milliseconds(750))
            }
        }
    }

    private func stopProgress() {
        progressGeneration &+= 1
        progressTask?.cancel()
        progressTask = nil
    }

    private func refreshSidebar(after sql: String) {
        guard let database else { return }
        workspace.loadObjects(database: database, force: true)
    }

    /// Changes the session database (`USE`).
    func use(database name: String) {
        guard !isRunning else { return }
        isRunning = true
        Task {
            defer { isRunning = false }
            do {
                _ = try await session.run("USE \(SQLText.quoteIdentifier(name))")
                database = await session.database
            } catch {
                workspace.showToast(describe(error), isError: true)
            }
        }
    }

    // MARK: Completion

    func completions(text: String, cursor: Int) async -> CompletionResult {
        let database = database
        var result = await Self.complete(text: text, cursor: cursor, schema: workspace.completionSnapshot(currentDatabase: database))
        if result.needsMoreSchema {
            await workspace.ensureSchema(columns: result.missingColumns, databases: result.missingDatabases)
            result = await Self.complete(text: text, cursor: cursor, schema: workspace.completionSnapshot(currentDatabase: database))
        }
        return result
    }

    /// Runs the (pure) completion engine off the main actor.
    private nonisolated static func complete(text: String, cursor: Int, schema: SchemaSnapshot) async -> CompletionResult {
        await Task.detached(priority: .userInitiated) {
            CompletionEngine.complete(text: text, cursor: cursor, schema: schema)
        }.value
    }

    // MARK: Export

    func export(_ result: QueryResult, format: ResultExport.Format) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == .csv ? .commaSeparatedText : .tabSeparatedText]
        panel.nameFieldStringValue = "\(title.replacingOccurrences(of: " ", with: "_")).\(format == .csv ? "csv" : "tsv")"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try ResultExport.write(to: url, result: result, format: format)
                }.value
                workspace.showToast("Exported \(Format.count(result.rows.count)) rows")
            } catch {
                workspace.showToast("Export failed: \(error.localizedDescription)", isError: true)
            }
        }
    }

    func copyTSV(_ result: QueryResult) {
        let (columns, rows) = (result.columns, result.rows)
        Task {
            let text = await Task.detached(priority: .userInitiated) { ResultExport.tsv(columns: columns, rows: rows) }.value
            Pasteboard.copy(text)
            workspace.showToast("Copied \(Format.count(rows.count)) rows")
        }
    }

    func close() {
        runTask?.cancel()
        stopProgress()
        if let pendingConfirmation { pendingConfirmation.continuation.resume(returning: false) }
        pendingConfirmation = nil
        let session = session
        Task { await session.close() }
    }
}
