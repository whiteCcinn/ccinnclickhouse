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
    /// `errorMessage` parsed once, off the main actor.
    var serverError: SQLServerError?
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
    /// Edits made in the editor arrive through `editorDidEdit` first; any other assignment (History →
    /// Open) replaces the text, which makes every diagnostic stale.
    var text: String {
        didSet {
            // A format computed for the old text no longer applies.
            formatRunner.textDidChange()
            if editorEditPending {
                editorEditPending = false
                if lineIndexIsStale { rebuildLineIndex() }
            } else {
                textWasReplaced()
            }
            scheduleLint()
        }
    }
    var selection = NSRange(location: 0, length: 0)
    private(set) var database: String?
    var outcomes: [StatementOutcome] = []
    var selectedOutcomeID: UUID?
    var isRunning = false
    var runStartedAt: Date?
    /// Errors of the last run, anchored to the statements that failed.
    private(set) var serverDiagnostics: [SQLDiagnostic] = []
    /// Local checks of the current text (refreshed shortly after typing stops).
    private(set) var localDiagnostics: [SQLDiagnostic] = []
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
    private var lintTask: Task<Void, Never>?
    private var editorEditPending = false
    /// Line starts of `text`, maintained edit by edit (positions without scanning the text).
    @ObservationIgnored private var lineIndex: SQLLineIndex
    @ObservationIgnored private var lineIndexIsStale = false
    /// Editor ranges of the statements in the running batch, by index; `nil` once a statement was edited.
    private var runAnchors: [Range<Int>?] = []

    /// A statement to execute: `sql` is sent as is (before the auto-LIMIT); `editorOffset` is where its
    /// source starts in the editor (nil when unknown) and `prefixLength` the units the app prepended
    /// (`EXPLAIN indexes = 1 `).
    private struct PlannedStatement {
        let sql: String
        let editorOffset: Int?
        var prefixLength = 0
    }

    /// Rows kept per result (hard cap) and the default auto-limit for plain SELECTs.
    static let hardRowCap = 100_000
    var autoLimit: Int {
        get { UserDefaults.standard.object(forKey: "autoLimit") as? Int ?? 1000 }
        set { UserDefaults.standard.set(newValue, forKey: "autoLimit") }
    }

    // MARK: Formatting

    /// Format SQL for this tab's editor; its notices show in the status line under the editor.
    let formatRunner = SQLFormatRunner()
    /// The editor of this tab, for edits that must be undoable (formatting).
    var editorController: SQLEditorController { formatRunner.editor }
    var isFormatting: Bool { formatRunner.isRunning }

    /// Settings ▸ General ▸ Format SQL. Keyword case defaults to unchanged: see `SQLFormatOptions`.
    static var formatOptions: SQLFormatOptions {
        let defaults = UserDefaults.standard
        let keywordCase = defaults.string(forKey: "sqlFormatKeywordCase").flatMap(SQLFormatOptions.KeywordCase.init(rawValue:)) ?? .preserve
        let indent = defaults.object(forKey: "sqlFormatIndent") as? Int ?? 2
        return SQLFormatOptions(keywordCase: keywordCase, indentWidth: indent)
    }

    /// Formats the selection, or the whole script when nothing is selected (⌥⌘L): see `SQLFormatRunner`.
    func formatSQL() {
        formatRunner.format(options: Self.formatOptions, fallback: (text, selection)) { [weak self] expected, range, replacement, newSelection in
            // No editor yet (a tab opened from launch arguments): replace the model's text, if it is still the same.
            guard let self, self.text.utf16.elementsEqual(expected.utf16) else { return false } // code units, not canonical equality
            self.text = (expected as NSString).replacingCharacters(in: range, with: replacement)
            self.selection = newSelection
            return true
        }
    }

    init(title: String, text: String, database: String?, workspace: WorkspaceModel) {
        self.title = title
        self.text = text
        lineIndex = SQLLineIndex(text)
        self.database = database
        self.workspace = workspace
        session = workspace.client.openSession(database: database)
        selection = NSRange(location: (text as NSString).length, length: 0)
        scheduleLint(after: .zero)
    }

    var selectedOutcome: StatementOutcome? {
        outcomes.first { $0.id == selectedOutcomeID } ?? outcomes.last
    }

    // MARK: Diagnostics

    /// Server and local diagnostics, in text order.
    var diagnostics: [SQLDiagnostic] {
        guard !localDiagnostics.isEmpty else { return serverDiagnostics }
        guard !serverDiagnostics.isEmpty else { return localDiagnostics }
        // Server first on ties, so the order is deterministic and the editor does not re-highlight needlessly.
        return (serverDiagnostics + localDiagnostics).sorted {
            ($0.range.lowerBound, $0.source == .server ? 0 : 1, $0.range.upperBound) < ($1.range.lowerBound, $1.source == .server ? 0 : 1, $1.range.upperBound)
        }
    }

    /// The marker of a result's error, while it is still valid.
    func serverDiagnostic(for outcome: StatementOutcome) -> SQLDiagnostic? {
        serverDiagnostics.first { $0.origin == outcome.id }
    }

    /// Called by the editor before it writes the edited text: keeps markers, run anchors and the line
    /// index on their text.
    func editorDidEdit(_ edits: [SQLTextEdit]) {
        editorEditPending = true
        guard !edits.isEmpty else { return }
        for edit in edits where !lineIndexIsStale {
            if !lineIndex.apply(edit) { lineIndexIsStale = true }
        }
        let server = SQLDiagnosticTracker.apply(edits, to: serverDiagnostics)
        if server != serverDiagnostics { serverDiagnostics = server }
        let local = SQLDiagnosticTracker.apply(edits, to: localDiagnostics)
        if local != localDiagnostics { localDiagnostics = local }
        if !runAnchors.isEmpty { runAnchors = SQLDiagnosticTracker.apply(edits, to: runAnchors) }
    }

    /// Selects a diagnostic's text in the editor (which scrolls to it).
    func reveal(_ diagnostic: SQLDiagnostic) {
        let length = (text as NSString).length
        let lower = min(max(0, diagnostic.range.lowerBound), length)
        let upper = min(max(lower, diagnostic.range.upperBound), length)
        selection = NSRange(location: lower, length: upper - lower)
    }

    /// 1-based line and column of an offset in `text` (O(log lines + line length)).
    func position(of offset: Int) -> SQLTextPosition {
        lineIndex.position(of: offset, in: text as NSString)
    }

    private func rebuildLineIndex() {
        lineIndex = SQLLineIndex(text)
        lineIndexIsStale = false
    }

    private func textWasReplaced() {
        rebuildLineIndex()
        if !serverDiagnostics.isEmpty { serverDiagnostics = [] }
        if !localDiagnostics.isEmpty { localDiagnostics = [] }
        runAnchors = runAnchors.map { _ in nil }
    }

    /// Re-checks the text off the main actor once typing pauses; a newer edit cancels the check.
    private func scheduleLint(after delay: Duration = .milliseconds(300)) {
        lintTask?.cancel()
        let snapshot = text
        lintTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            let found = await Task.detached(priority: .utility) { SQLLinter.diagnose(snapshot) }.value
            // Any edit since the snapshot cancelled this task (both run on the main actor).
            guard let self, !Task.isCancelled else { return }
            if found != self.localDiagnostics { self.localDiagnostics = found }
        }
    }

    // MARK: Running

    /// Selection if any, otherwise the statement under the cursor.
    func runCurrent() {
        if let selected = selectedText {
            run(SQLStatementSplitter.split(selected).map { PlannedStatement(sql: $0.text, editorOffset: selection.location + $0.range.lowerBound) })
            return
        }
        guard let statement = SQLStatementSplitter.statement(at: selection.location, in: text) else { return }
        run([PlannedStatement(sql: statement.text, editorOffset: statement.range.lowerBound)])
    }

    func runAll() {
        run(SQLStatementSplitter.split(text).map { PlannedStatement(sql: $0.text, editorOffset: $0.range.lowerBound) })
    }

    func explain(_ kind: ExplainKind = .planIndexes) {
        let selected = selectedText
        guard let statement = selected.map({ SQLStatementSplitter.split($0).first })
            ?? SQLStatementSplitter.statement(at: selection.location, in: text) else { return }
        let base = selected == nil ? 0 : selection.location
        let body = statement.text
        guard SQLStatementKind.of(body) != .explain else {
            return run([PlannedStatement(sql: body, editorOffset: base + statement.range.lowerBound)])
        }
        let prefix = "\(kind.prefix) "
        run([PlannedStatement(sql: prefix + body, editorOffset: base + statement.range.lowerBound, prefixLength: prefix.utf16.count)])
    }

    /// The selected text, when the selection is non-empty and inside the text.
    private var selectedText: String? {
        let nsText = text as NSString
        guard selection.length > 0, selection.location >= 0, NSMaxRange(selection) <= nsText.length else { return nil }
        return nsText.substring(with: selection)
    }

    /// Cancels the running batch synchronously. The cancellation reaches the statement through the
    /// task (SQLSession aborts the request and kills its query id), so a Stop pressed as a statement
    /// finishes still ends "Run all", and it can never land on a statement started later.
    func stop() {
        guard isRunning else { return }
        runTask?.cancel()
        if let pendingConfirmation {
            self.pendingConfirmation = nil
            pendingConfirmation.continuation.resume(returning: false)
        }
    }

    /// Runs statements sequentially; stops at the first error.
    private func run(_ statements: [PlannedStatement]) {
        guard !isRunning, !statements.isEmpty else { return }
        serverDiagnostics = []
        runAnchors = statements.map { statement in
            statement.editorOffset.map { $0..<($0 + max(0, statement.sql.utf16.count - statement.prefixLength)) }
        }
        isRunning = true
        runStartedAt = Date()
        outcomes = []
        runTask = Task {
            defer {
                isRunning = false
                runStartedAt = nil
                runAnchors = []
                stopProgress()
            }
            let texts = statements.map(\.sql)
            if workspace.client.configuration.readOnly, let refusal = ReadOnlySQLGuard.firstRefusal(in: texts) {
                // The server refuses these too (readonly=1, verified at connect); say so before sending anything.
                let outcome = StatementOutcome(index: 0, sql: refusal.sql, executedSQL: refusal.sql, kind: SQLStatementKind.of(refusal.sql))
                outcome.errorMessage = "This connection is read-only. \(refusal.reason)"
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
                if Task.isCancelled { break }
                let succeeded = await execute(statement, index: index)
                if !succeeded || Task.isCancelled { break }
            }
        }
    }

    func resolveConfirmation(_ confirmed: Bool) {
        pendingConfirmation?.continuation.resume(returning: confirmed)
        pendingConfirmation = nil
    }

    private func execute(_ statement: PlannedStatement, index: Int) async -> Bool {
        let sql = statement.sql
        let kind = SQLStatementKind.of(sql)
        var executed = sql
        var limitApplied: Int?
        var mapping = SQLExecutedTextMapping(prefixLength: statement.prefixLength)
        if kind == .query, autoLimit > 0 {
            let outcome = AutoLimit.apply(to: sql, limit: autoLimit)
            if outcome.applied {
                executed = outcome.sql
                limitApplied = autoLimit
                mapping.insertion = outcome.insertion
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
        var failure: (message: String, code: Int?, name: String?)?
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
            let serverError = error as? ClickHouseError
            failure = (serverError?.message ?? describe(error), serverError?.code, serverError?.name)
        }
        stopProgress()
        // Measured before locating the error, which is not part of the statement's run time.
        let elapsed = clock.now - started
        outcome.durationMilliseconds = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        historyEntry.durationMilliseconds = outcome.durationMilliseconds
        if let failure {
            let (parsed, diagnostic) = await diagnose(failure, statement: statement, executed: executed, mapping: mapping,
                                                      index: index, origin: outcome.id)
            outcome.serverError = parsed
            if let diagnostic { serverDiagnostics.append(diagnostic) }
        }
        outcome.isRunning = false
        await workspace.history.append(historyEntry)
        return outcome.errorMessage == nil
    }

    /// Parses a failure and, unless the statement was edited while it ran, its editor marker. Both run
    /// off the main actor: messages can echo a huge statement, and locating lexes it.
    private func diagnose(_ failure: (message: String, code: Int?, name: String?), statement: PlannedStatement, executed: String,
                          mapping: SQLExecutedTextMapping, index: Int, origin: UUID) async -> (SQLServerError, SQLDiagnostic?) {
        let wantsMarker = runAnchors.indices.contains(index) && runAnchors[index] != nil
        let sql = statement.sql
        let prefixLength = statement.prefixLength
        let (parsed, located) = await Task.detached(priority: .userInitiated) { () -> (SQLServerError, Range<Int>?) in
            let parsed = SQLServerError.parse(failure.message, code: failure.code, name: failure.name)
            guard wantsMarker else { return (parsed, nil) }
            let units = Array(sql.utf16)
            let source = String(decoding: units[min(max(0, prefixLength), units.count)...], as: UTF16.self)
            return (parsed, SQLErrorLocator.range(in: source, executed: executed, mapping: mapping, error: parsed))
        }.value
        // Re-read the anchor: the user may have typed while the statement was being located.
        guard let range = located, runAnchors.indices.contains(index), let anchor = runAnchors[index],
              range.upperBound <= anchor.count else { return (parsed, nil) }
        let marked = (anchor.lowerBound + range.lowerBound)..<(anchor.lowerBound + range.upperBound)
        return (parsed, SQLDiagnostic(range: marked, scope: anchor, severity: .error, source: .server, message: parsed.summary, origin: origin))
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
        lintTask?.cancel()
        stopProgress()
        if let pendingConfirmation { pendingConfirmation.continuation.resume(returning: false) }
        pendingConfirmation = nil
        let session = session
        Task { await session.close() }
    }
}
