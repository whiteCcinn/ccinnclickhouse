import ClickHouseKit
import ClickHouseWire
import Foundation

public struct CompletionItem: Sendable, Hashable, Identifiable {
    public enum Kind: Int, Sendable, Hashable {
        case column, alias, table, view, dictionary, database, setting, function, aggregate, tableFunction, format, engine, dataType,
             cluster, keyword
    }

    public let kind: Kind
    public let label: String
    public let insertText: String
    /// Secondary text: column type and table, function signature, setting description.
    public let detail: String?

    public init(kind: Kind, label: String, insertText: String, detail: String?) {
        self.kind = kind
        self.label = label
        self.insertText = insertText
        self.detail = detail
    }

    public var id: String { "\(kind.rawValue)\u{1F}\(label)\u{1F}\(detail ?? "")" }
}

public struct CompletionResult: Sendable {
    /// UTF-16 range in the editor text that the chosen item replaces.
    public let replacementRange: Range<Int>
    public let prefix: String
    public let items: [CompletionItem]
    /// Tables referenced by the statement whose columns are not in the snapshot yet.
    public let missingColumns: [TableKey]
    /// Databases whose object lists are needed but not loaded yet.
    public let missingDatabases: [String]
    /// Only a name from a known list can follow the cursor (a table after `FROM `, a database after `USE `, a format
    /// after `FORMAT ` …), so the editor may offer the list before anything is typed.
    public let expectsObjectName: Bool

    public init(replacementRange: Range<Int>, prefix: String, items: [CompletionItem], missingColumns: [TableKey] = [],
                missingDatabases: [String] = [], expectsObjectName: Bool = false) {
        self.replacementRange = replacementRange
        self.prefix = prefix
        self.items = items
        self.missingColumns = missingColumns
        self.missingDatabases = missingDatabases
        self.expectsObjectName = expectsObjectName
    }

    public var needsMoreSchema: Bool { !missingColumns.isEmpty || !missingDatabases.isEmpty }

    public static func empty(at cursor: Int) -> CompletionResult {
        CompletionResult(replacementRange: cursor..<cursor, prefix: "", items: [])
    }
}

/// Context-aware ClickHouse completion (design D12). Pure and synchronous; callers run it off the main actor.
public enum CompletionEngine {
    public static let defaultLimit = 200

    enum Context: Equatable {
        case statementStart
        case showTarget
        case tableName(allowTableFunctions: Bool)
        /// The name of the object a CREATE / ATTACH defines: existing tables are offered once typed, never on a space.
        case newTableName
        case afterTableReference
        case database
        case expression
        case setting
        case format
        case engine
        case dataType
        case cluster

        /// Only a name from a known list can follow. Not data types: a column definition may omit its type.
        var expectsName: Bool {
            switch self {
            case .tableName, .database, .setting, .format, .engine, .cluster: true
            case .statementStart, .showTarget, .afterTableReference, .expression, .dataType, .newTableName: false
            }
        }
    }

    struct ScopeTable {
        var alias: String?
        var database: String?
        var table: String
        var derivedColumns: [String]?
    }

    public static func complete(text: String, cursor: Int, schema: SchemaSnapshot, limit: Int = defaultLimit) -> CompletionResult {
        let lexer = SQLLexer(text)
        let cursor = max(0, min(cursor, lexer.units.count))
        let allTokens = lexer.tokens()

        let isSemicolon: (SQLToken) -> Bool = { $0.kind == .punctuation && lexer.units[$0.range.lowerBound] == 0x3B }
        let statementStart = allTokens.last { isSemicolon($0) && $0.range.upperBound <= cursor }?.range.upperBound ?? 0
        let statementEnd = allTokens.first { isSemicolon($0) && $0.range.lowerBound >= cursor }?.range.lowerBound ?? lexer.units.count
        let tokens = allTokens.filter { $0.range.lowerBound >= statementStart && $0.range.upperBound <= statementEnd }

        // No completion inside strings, comments or parameters.
        if let enclosing = tokens.first(where: { $0.range.lowerBound < cursor && cursor < $0.range.upperBound }),
           enclosing.kind == .string || enclosing.kind == .comment || enclosing.kind == .parameter {
            return .empty(at: cursor)
        }
        // A `$tag$` opener before the cursor with no closing tag yet: the user is typing a heredoc string
        // (the lexer, like ClickHouse, treats an unterminated opener as a bare word).
        for token in tokens where token.range.upperBound <= cursor && (token.kind == .operator || token.kind == .identifier)
            && lexer.units[token.range.lowerBound] == 0x24 {
            if lexer.units[(token.range.lowerBound + 1)..<cursor].contains(0x24) { return .empty(at: cursor) }
        }
        if let ending = tokens.last(where: { $0.range.upperBound == cursor }) {
            if ending.kind == .comment, ["--", "//", "#"].contains(where: lexer.text(of: ending).hasPrefix) { return .empty(at: cursor) }
            if ending.kind == .string, !isTerminated(ending, lexer: lexer) { return .empty(at: cursor) }
        }

        let prefixToken = tokens.last {
            $0.range.upperBound == cursor && ($0.kind == .identifier || $0.kind == .keyword || $0.kind == .quotedIdentifier)
        }
        let replacementStart = prefixToken?.range.lowerBound ?? cursor
        let prefix: String = prefixToken.map { token in
            token.kind == .quotedIdentifier ? lexer.identifierValue(of: token) : lexer.text(of: token)
        } ?? ""
        let before = tokens.filter { $0.range.upperBound <= replacementStart && $0.kind != .comment }
        let significant = tokens.filter { $0.kind != .comment }
        let scope = scopeTables(tokens: significant, lexer: lexer)

        var candidates: [CompletionItem]
        var missing: [TableKey] = []
        var missingDatabases: [String] = []
        var expectsObjectName = false
        if let last = before.last, isDot(last, lexer) {
            let qualifier = qualifierChain(before: before, lexer: lexer)
            (candidates, missing) = memberCandidates(qualifier: qualifier, scope: scope, schema: schema)
            if let database = qualifier.first, qualifier.count == 1, schema.isDatabase(database), schema.objects(in: database) == nil {
                missingDatabases.append(database)
            }
        } else {
            let context = clauseContext(before: before, lexer: lexer)
            (candidates, missing) = contextCandidates(context, scope: scope, schema: schema, prefix: prefix)
            if case .tableName = context, let current = schema.currentDatabase, schema.objects(in: current) == nil {
                missingDatabases.append(current)
            }
            expectsObjectName = context.expectsName && opensOnSpace(context, before: before, lexer: lexer)
        }
        let ranked = rank(candidates, prefix: prefix, limit: limit)
        return CompletionResult(replacementRange: replacementStart..<cursor, prefix: prefix, items: ranked,
                                missingColumns: missing, missingDatabases: missingDatabases, expectsObjectName: expectsObjectName)
    }

    // MARK: Scope analysis

    static func isDot(_ token: SQLToken, _ lexer: SQLLexer) -> Bool {
        token.kind == .punctuation && lexer.units[token.range.lowerBound] == 0x2E
    }

    static func isTerminated(_ token: SQLToken, lexer: SQLLexer) -> Bool {
        let text = lexer.text(of: token)
        if text.hasPrefix("$"), let close = text.dropFirst().firstIndex(of: "$") {
            let tag = text[text.startIndex...close]
            return text.count >= tag.count * 2 && text.hasSuffix(tag)
        }
        guard token.range.count >= 2 else { return false }
        return lexer.units[token.range.upperBound - 1] == lexer.units[token.range.lowerBound]
    }

    static func isName(_ token: SQLToken) -> Bool {
        token.kind == .identifier || token.kind == .quotedIdentifier || token.kind == .keyword
    }

    static func qualifierChain(before: [SQLToken], lexer: SQLLexer) -> [String] {
        var parts: [String] = []
        var index = before.count - 1
        while index >= 1, isDot(before[index], lexer), isName(before[index - 1]),
              before[index - 1].range.upperBound == before[index].range.lowerBound {
            parts.insert(lexer.identifierValue(of: before[index - 1]), at: 0)
            index -= 2
        }
        return parts
    }

    static let aliasStopWords: Set<String> = SQLKeywords.reserved.union([
        "FINAL", "SAMPLE", "PREWHERE", "WHERE", "ON", "USING", "LIMIT", "SETTINGS", "FORMAT", "GLOBAL", "ANY", "ALL", "ASOF", "SEMI",
        "ANTI", "OUTER", "INNER", "ARRAY", "PARTITION", "GROUP", "ORDER", "HAVING", "UNION", "WINDOW", "QUALIFY",
    ])

    /// Tables, derived tables and CTEs referenced anywhere in the statement, with their aliases.
    static func scopeTables(tokens: [SQLToken], lexer: SQLLexer) -> [ScopeTable] {
        var result: [ScopeTable] = []
        var ctes: [String: [String]] = [:]
        let words = tokens.map { $0.kind == .keyword || $0.kind == .identifier ? lexer.text(of: $0).uppercased() : "" }

        if words.first == "WITH" {
            var index = 1
            while index + 2 < tokens.count, isName(tokens[index]), words[index + 1] == "AS", lexer.text(of: tokens[index + 2]) == "(" {
                let name = lexer.identifierValue(of: tokens[index])
                let close = matchingParen(tokens: tokens, open: index + 2, lexer: lexer)
                ctes[name.lowercased()] = derivedColumns(tokens: Array(tokens[(index + 3)..<min(close, tokens.count)]), lexer: lexer)
                index = close + 1
                if index < tokens.count, lexer.text(of: tokens[index]) == "," { index += 1 } else { break }
            }
        }

        var index = 0
        while index < tokens.count {
            let word = words[index]
            let startsReference = ["FROM", "JOIN", "INTO", "TABLE", "UPDATE"].contains(word)
            index += 1
            guard startsReference else { continue }
            var parsingList = true
            while parsingList, index < tokens.count {
                parsingList = false
                if lexer.text(of: tokens[index]) == "(" {
                    let close = matchingParen(tokens: tokens, open: index, lexer: lexer)
                    let columns = derivedColumns(tokens: Array(tokens[(index + 1)..<min(close, tokens.count)]), lexer: lexer)
                    index = close + 1
                    if let (alias, next) = parseAlias(tokens: tokens, words: words, at: index, lexer: lexer) {
                        result.append(ScopeTable(alias: alias, database: nil, table: alias, derivedColumns: columns))
                        index = next
                    }
                } else if isName(tokens[index]), !aliasStopWords.contains(words[index]) || tokens[index].kind != .keyword {
                    var parts = [lexer.identifierValue(of: tokens[index])]
                    index += 1
                    while index + 1 < tokens.count, isDot(tokens[index], lexer), isName(tokens[index + 1]) {
                        parts.append(lexer.identifierValue(of: tokens[index + 1]))
                        index += 2
                    }
                    // A table function call: numbers(10) AS n
                    if index < tokens.count, lexer.text(of: tokens[index]) == "(" {
                        index = matchingParen(tokens: tokens, open: index, lexer: lexer) + 1
                        _ = parseAlias(tokens: tokens, words: words, at: index, lexer: lexer).map { index = $0.1 }
                        continue
                    }
                    let table = parts[parts.count - 1]
                    let database = parts.count >= 2 ? parts[parts.count - 2] : nil
                    var reference = ScopeTable(alias: nil, database: database, table: table, derivedColumns: nil)
                    if database == nil, let cteColumns = ctes[table.lowercased()] { reference.derivedColumns = cteColumns }
                    if index < tokens.count, words[index] == "FINAL" { index += 1 }
                    if let (alias, next) = parseAlias(tokens: tokens, words: words, at: index, lexer: lexer) {
                        reference.alias = alias
                        index = next
                    }
                    result.append(reference)
                }
                if index < tokens.count, lexer.text(of: tokens[index]) == ",", word == "FROM" {
                    index += 1
                    parsingList = true
                }
            }
        }
        return result
    }

    static func parseAlias(tokens: [SQLToken], words: [String], at index: Int, lexer: SQLLexer) -> (String, Int)? {
        var index = index
        if index < tokens.count, words[index] == "AS" { index += 1 }
        guard index < tokens.count, isName(tokens[index]) else { return nil }
        if tokens[index].kind != .quotedIdentifier, aliasStopWords.contains(words[index]) { return nil }
        return (lexer.identifierValue(of: tokens[index]), index + 1)
    }

    static func matchingParen(tokens: [SQLToken], open: Int, lexer: SQLLexer) -> Int {
        var depth = 0
        var index = open
        while index < tokens.count {
            let text = lexer.text(of: tokens[index])
            if tokens[index].kind == .punctuation {
                if text == "(" { depth += 1 }
                if text == ")" {
                    depth -= 1
                    if depth == 0 { return index }
                }
            }
            index += 1
        }
        return tokens.count
    }

    /// Output column names of `SELECT a, b AS c, t.d, count() AS n FROM …`.
    static func derivedColumns(tokens: [SQLToken], lexer: SQLLexer) -> [String] {
        guard let selectIndex = tokens.firstIndex(where: { lexer.text(of: $0).uppercased() == "SELECT" }) else { return [] }
        var columns: [String] = []
        var depth = 0
        var item: [SQLToken] = []
        func flushItem() {
            defer { item.removeAll() }
            guard let last = item.last, isName(last) else { return }
            columns.append(lexer.identifierValue(of: last))
        }
        for token in tokens[(selectIndex + 1)...] {
            let text = lexer.text(of: token)
            if token.kind == .punctuation {
                if text == "(" || text == "[" { depth += 1 }
                if text == ")" || text == "]" { depth -= 1 }
            }
            if depth == 0, token.kind == .keyword, text.uppercased() == "FROM" { break }
            if depth == 0, text == "," {
                flushItem()
                continue
            }
            if depth == 0, token.kind == .keyword, text.uppercased() == "DISTINCT", item.isEmpty { continue }
            item.append(token)
        }
        flushItem()
        return columns
    }

    /// Re-ranks `result`'s items for its prefix followed by `typed` (a keystroke that extends the word): the editor narrows
    /// the shown list at once, so Return never takes a name for the letters before. The next full result replaces it.
    public static func narrow(_ result: CompletionResult, appending typed: String) -> CompletionResult {
        let prefix = result.prefix + typed
        let end = result.replacementRange.upperBound + typed.utf16.count
        return CompletionResult(replacementRange: result.replacementRange.lowerBound..<end, prefix: prefix,
                                items: rank(result.items, prefix: prefix, limit: result.items.count), missingColumns: result.missingColumns,
                                missingDatabases: result.missingDatabases, expectsObjectName: result.expectsObjectName)
    }

    /// Words a clause keyword cannot follow: after them `engine` or `format` is a column, not a clause.
    static let expressionLeaders: Set<String> = ["SELECT", "WHERE", "PREWHERE", "ON", "HAVING", "BY", "AND", "OR", "NOT", "WHEN", "THEN", "ELSE",
                                                 "CASE", "DISTINCT", "IN", "LIKE", "ILIKE", "BETWEEN", "IS", "USING", "QUALIFY", "AS", ",", "(", "["]

    static func isColumnPosition(_ index: Int, words: [String], before: [SQLToken]) -> Bool {
        guard index > 0 else { return false }
        return expressionLeaders.contains(words[index - 1]) || before[index - 1].kind == .operator
    }

    static let definingVerbs: Set<String> = ["CREATE", "ATTACH", "REPLACE"]

    /// A space opens the list only where nothing but such a name can follow, and only a list of the right kind.
    static func opensOnSpace(_ context: Context, before: [SQLToken], lexer: SQLLexer) -> Bool {
        let words = before.map { lexer.text(of: $0).uppercased() }
        let firstWord = words.first ?? ""
        switch context {
        case .database:
            // `SHOW TABLES ` goes on with FROM / IN / LIKE; its databases are offered once a letter is typed.
            return words.last != "TABLES"
        case .setting:
            // The SETTINGS of a CREATE take MergeTree / engine settings, which the list does not hold.
            return !definingVerbs.contains(firstWord)
        case .engine:
            // CREATE DATABASE takes database engines, which the list does not hold.
            return !words.prefix(4).contains("DATABASE")
        default:
            return true
        }
    }

    /// `FROM` at `index` reads a table, unless it is the FROM of a function call (`extract(DAY FROM d)`, `trim(… FROM s)`):
    /// within its parenthesis level a SELECT comes first, or the level is the statement itself.
    static func fromNamesATable(at index: Int, words: [String], before: [SQLToken]) -> Bool {
        var depth = 0
        for position in stride(from: index - 1, through: 0, by: -1) {
            let word = words[position]
            if before[position].kind == .punctuation {
                if word == ")" || word == "]" { depth += 1 }
                if word == "(" || word == "[" {
                    if depth == 0 { return false }
                    depth -= 1
                }
                continue
            }
            if depth == 0, word == "SELECT" { return true }
        }
        return true
    }

    // MARK: Clause context

    static func clauseContext(before: [SQLToken], lexer: SQLLexer) -> Context {
        guard !before.isEmpty else { return .statementStart }
        let words = before.map { $0.kind == .keyword || $0.kind == .identifier ? lexer.text(of: $0).uppercased() : lexer.text(of: $0) }
        let firstWord = words.first ?? ""
        let last = words[words.count - 1]
        let previous = words.count >= 2 ? words[words.count - 2] : ""

        if last == "SHOW" { return .showTarget }
        if last == "USE" { return .database }
        if last == "FORMAT", !isColumnPosition(words.count - 1, words: words, before: before) { return .format }
        // ENGINE is a clause of CREATE / ATTACH only; elsewhere `engine` is a column (system.tables, system.databases).
        if definingVerbs.contains(firstWord) {
            if last == "ENGINE", !isColumnPosition(words.count - 1, words: words, before: before) { return .engine }
            if last == "=", previous == "ENGINE", !isColumnPosition(words.count - 2, words: words, before: before) { return .engine }
        }
        if last == "CLUSTER" && previous == "ON" { return .cluster }
        if last == "::" { return .dataType }
        if firstWord == "SET", last == "SET" || (last == "," && words.count >= 2) { return isInsideSettingsValue(words) ? .expression : .setting }
        if firstWord == "SHOW", last == "FROM" || last == "IN" {
            // `SHOW COLUMNS FROM t [FROM db]`: the first FROM names a table.
            let namesTable = words.dropFirst().prefix(3).contains { ["COLUMNS", "FIELDS", "INDEX", "INDEXES", "INDICES", "KEYS"].contains($0) }
            let earlierFrom = words.dropLast().contains { $0 == "FROM" || $0 == "IN" }
            return namesTable && !earlierFrom ? .tableName(allowTableFunctions: false) : .database
        }
        if last == ",", isInSettingsList(words: words) { return .setting }

        // Walk back within the current parenthesis level to the nearest clause keyword.
        var depth = 0
        var distance = 0
        var sawComma = false
        for index in stride(from: before.count - 1, through: 0, by: -1) {
            let token = before[index]
            let text = words[index]
            if token.kind == .punctuation {
                if text == ")" || text == "]" { depth += 1 }
                if text == "(" || text == "[" {
                    if depth == 0 {
                        // `CAST(x AS ` → type; column list of CREATE TABLE → type after a column name.
                        if index > 0, words[index - 1] == "CAST", last == "AS" { return .dataType }
                        if isColumnDefinitionPosition(words: words, openIndex: index, before: before) { return .dataType }
                        return .expression
                    }
                    depth -= 1
                }
                if depth == 0, text == ",", distance == 0 { sawComma = true }
            }
            guard depth == 0 else { continue }
            switch text {
            case "DESC" where index > 0, "DESCRIBE" where index > 0:
                break // `ORDER BY x DESC`: a sort direction; only a statement-leading DESC describes a table.
            case "EXISTS" where index > 0 && words[index - 1] != "IF":
                break // `WHERE EXISTS (…)`: a subquery follows; `EXISTS t` and `IF [NOT] EXISTS t` name a table.
            case "SETTINGS":
                return distance == 0 || (sawComma && last == ",") ? .setting : .expression
            case "JOIN" where index > 0 && words[index - 1] == "ARRAY":
                return .expression // `ARRAY JOIN arr`: an array expression follows
            case "FROM" where !fromNamesATable(at: index, words: words, before: before):
                return .expression // `extract(DAY FROM d)`
            case "INTO" where firstWord != "INSERT":
                return .expression // `INTO OUTFILE`
            case "FROM", "JOIN":
                if distance == 0 || sawComma { return .tableName(allowTableFunctions: true) }
                return .afterTableReference
            case "INTO", "TABLE", "DESCRIBE", "DESC", "EXISTS", "TABLES":
                guard distance == 0 else { return .expression }
                if text == "TABLES" { return .database }
                return definingVerbs.contains(firstWord) && (text == "TABLE" || text == "EXISTS") ? .newTableName : .tableName(allowTableFunctions: false)
            case "SELECT", "WHERE", "PREWHERE", "ON", "HAVING", "BY", "AND", "OR", "NOT", "WHEN", "THEN", "ELSE", "CASE", "DISTINCT",
                 "IN", "LIKE", "ILIKE", "BETWEEN", "IS", "USING", "OVER", "PARTITION", "VALUES", "QUALIFY", "LIMIT", "OFFSET":
                return .expression
            case "USE":
                return .database
            default:
                break
            }
            if token.kind == .operator { return .expression }
            if token.kind != .punctuation || text != "." { distance += 1 }
        }
        return .expression
    }

    /// The cursor follows a comma inside a trailing `SETTINGS a = 1, …` list.
    static func isInSettingsList(words: [String]) -> Bool {
        let stops: Set<String> = ["SELECT", "FROM", "WHERE", "PREWHERE", "GROUP", "ORDER", "LIMIT", "FORMAT", "HAVING", "JOIN", "ON", "USING", "(", ")"]
        for word in words.reversed() {
            if word == "SETTINGS" { return true }
            if stops.contains(word) { return false }
        }
        return false
    }

    /// `SET a = 1, b` → after the comma we are at a setting name; `SET a = ` → value.
    static func isInsideSettingsValue(_ words: [String]) -> Bool {
        words.last == "="
    }

    /// `CREATE TABLE t (a ` / `(a UInt8, b ` → a column type is expected.
    static func isColumnDefinitionPosition(words: [String], openIndex: Int, before: [SQLToken]) -> Bool {
        guard words.first == "CREATE" || words.first == "ALTER", openIndex + 1 < words.count else { return false }
        // The token right before the cursor is a column name directly after `(` or `,` of the column list.
        let lastIndex = words.count - 1
        guard lastIndex >= 1, before[lastIndex].kind == .identifier || before[lastIndex].kind == .quotedIdentifier else { return false }
        let separator = words[lastIndex - 1]
        return (separator == "(" && lastIndex - 1 == openIndex) || separator == ","
    }

    // MARK: Candidates

    static func memberCandidates(qualifier: [String], scope: [ScopeTable], schema: SchemaSnapshot) -> ([CompletionItem], [TableKey]) {
        guard let head = qualifier.first else { return ([], []) }
        let current = schema.currentDatabase
        switch qualifier.count {
        case 1:
            if let table = scope.first(where: { $0.alias?.caseInsensitiveCompare(head) == .orderedSame }) {
                return columnCandidates(of: [table], schema: schema)
            }
            if schema.isDatabase(head) {
                return (objectCandidates(database: head, schema: schema), [])
            }
            if let table = scope.first(where: { $0.alias == nil && $0.table.caseInsensitiveCompare(head) == .orderedSame }) {
                return columnCandidates(of: [table], schema: schema)
            }
            if let current, schema.object(named: head, in: current) != nil {
                return columnCandidates(of: [ScopeTable(alias: nil, database: current, table: head, derivedColumns: nil)], schema: schema)
            }
            return ([], [])
        default:
            return columnCandidates(of: [ScopeTable(alias: nil, database: qualifier[qualifier.count - 2], table: qualifier[qualifier.count - 1],
                                                    derivedColumns: nil)], schema: schema)
        }
    }

    static func contextCandidates(_ context: Context, scope: [ScopeTable], schema: SchemaSnapshot, prefix: String) -> ([CompletionItem], [TableKey]) {
        let vocabulary = schema.vocabulary
        switch context {
        case .statementStart:
            return (SQLKeywords.statementStarters.map(keywordItem), [])
        case .showTarget:
            return (SQLKeywords.showTargets.map(keywordItem), [])
        case .database:
            return (databaseCandidates(schema), [])
        case .newTableName:
            return contextCandidates(.tableName(allowTableFunctions: false), scope: scope, schema: schema, prefix: prefix)
        case let .tableName(allowTableFunctions):
            var items: [CompletionItem] = []
            if let current = schema.currentDatabase { items += objectCandidates(database: current, schema: schema) }
            items += databaseCandidates(schema)
            if allowTableFunctions {
                items += vocabulary.tableFunctions.map { CompletionItem(kind: .tableFunction, label: $0, insertText: $0 + "(", detail: "table function") }
            }
            return (items, [])
        case .afterTableReference:
            let keywords = ["WHERE", "PREWHERE", "FINAL", "SAMPLE", "JOIN", "LEFT JOIN", "INNER JOIN", "ANY LEFT JOIN", "ASOF JOIN", "ARRAY JOIN",
                            "LEFT ARRAY JOIN", "GLOBAL JOIN", "CROSS JOIN", "ON", "USING", "AS", "GROUP BY", "ORDER BY", "HAVING", "LIMIT",
                            "SETTINGS", "FORMAT", "UNION ALL"]
            return (keywords.map(keywordItem), [])
        case .setting:
            return (vocabulary.settings.map { setting in
                let detail = [setting.type, setting.value.map { "= \($0)" }, setting.summary].compactMap { $0 }.joined(separator: " · ")
                return CompletionItem(kind: .setting, label: setting.name, insertText: setting.name, detail: detail.isEmpty ? nil : detail)
            }, [])
        case .format:
            return (vocabulary.formats.map { CompletionItem(kind: .format, label: $0, insertText: $0, detail: "format") }, [])
        case .engine:
            return (vocabulary.engines.map { CompletionItem(kind: .engine, label: $0, insertText: $0, detail: "table engine") }, [])
        case .dataType:
            return (vocabulary.dataTypes.map { CompletionItem(kind: .dataType, label: $0, insertText: $0, detail: "data type") }, [])
        case .cluster:
            return (vocabulary.clusters.map { CompletionItem(kind: .cluster, label: $0, insertText: quoteIfNeeded($0), detail: "cluster") }, [])
        case .expression:
            let (columns, missing) = columnCandidates(of: scope, schema: schema)
            let aliases = scope.compactMap(\.alias).map { CompletionItem(kind: .alias, label: $0, insertText: quoteIfNeeded($0), detail: "alias") }
            let functions = vocabulary.functions.map { function in
                CompletionItem(kind: function.isAggregate ? .aggregate : .function, label: function.name, insertText: function.name + "(",
                               detail: function.signature ?? function.summary ?? (function.isAggregate ? "aggregate function" : "function"))
            }
            return (columns + aliases + functions + combinatorCandidates(prefix: prefix, vocabulary: vocabulary)
                        + SQLKeywords.clauseKeywords.map(keywordItem), missing)
        }
    }

    /// Aggregate functions extended with combinator chains: `sumI` → `sumIf`, `uniqMer` → `uniqMerge`,
    /// `avgOrNullI` → `avgOrNullIf`.
    static func combinatorCandidates(prefix: String, vocabulary: ServerVocabulary, limit: Int = 60) -> [CompletionItem] {
        guard prefix.count >= 2 else { return [] }
        let lowered = prefix.lowercased()
        let combinators = vocabulary.combinators
        var items: [CompletionItem] = []
        for aggregate in vocabulary.aggregateFunctionNames where lowered.hasPrefix(aggregate.lowercased()) {
            var built = aggregate
            var rest = Substring(prefix.dropFirst(aggregate.count))
            // Consume complete combinators already typed.
            var progressed = true
            while progressed, !rest.isEmpty {
                progressed = false
                for combinator in combinators.sorted(by: { $0.count > $1.count }) where rest.lowercased().hasPrefix(combinator.lowercased()) {
                    built += combinator
                    rest = rest.dropFirst(combinator.count)
                    progressed = true
                    break
                }
            }
            let partial = rest.lowercased()
            for combinator in combinators where combinator.lowercased().hasPrefix(partial) {
                let name = built + combinator
                items.append(CompletionItem(kind: .aggregate, label: name, insertText: name + "(", detail: "\(aggregate) with -\(combinator)"))
                if items.count >= limit { return items }
            }
        }
        return items
    }

    static func columnCandidates(of tables: [ScopeTable], schema: SchemaSnapshot) -> ([CompletionItem], [TableKey]) {
        var items: [CompletionItem] = []
        var missing: [TableKey] = []
        var seen = Set<String>()
        for table in tables {
            let source = table.alias ?? table.table
            if let derived = table.derivedColumns {
                for column in derived where seen.insert("\(source).\(column)").inserted {
                    items.append(CompletionItem(kind: .column, label: column, insertText: quoteIfNeeded(column), detail: source))
                }
                continue
            }
            guard let database = table.database ?? schema.currentDatabase else { continue }
            guard let columns = schema.columns(database: database, table: table.table) else {
                if schema.object(named: table.table, in: database) != nil || table.database != nil {
                    missing.append(TableKey(database: database, table: table.table))
                }
                continue
            }
            for column in columns where seen.insert("\(source).\(column.name)").inserted {
                items.append(CompletionItem(kind: .column, label: column.name, insertText: quoteIfNeeded(column.name),
                                            detail: "\(column.type) · \(table.table)"))
            }
        }
        return (items, missing)
    }

    static func objectCandidates(database: String, schema: SchemaSnapshot) -> [CompletionItem] {
        (schema.objects(in: database) ?? []).map { object in
            let kind: CompletionItem.Kind = switch object.family {
            case .view, .materializedView: .view
            case .dictionary: .dictionary
            default: .table
            }
            return CompletionItem(kind: kind, label: object.name, insertText: quoteIfNeeded(object.name), detail: object.family.groupTitle)
        }
    }

    static func databaseCandidates(_ schema: SchemaSnapshot) -> [CompletionItem] {
        schema.databases.map { CompletionItem(kind: .database, label: $0, insertText: quoteIfNeeded($0), detail: "database") }
    }

    static func keywordItem(_ keyword: String) -> CompletionItem {
        CompletionItem(kind: .keyword, label: keyword, insertText: keyword.replacingOccurrences(of: " … ", with: " "), detail: nil)
    }

    /// Back-quotes identifiers that are reserved words or contain unusual characters.
    public static func quoteIfNeeded(_ name: String) -> String {
        let simple = !name.isEmpty && name.utf16.enumerated().allSatisfy { offset, unit in
            offset == 0 ? SQLLexer.isIdentifierStart(unit) && unit < 0x80 : SQLLexer.isIdentifierPart(unit) && unit < 0x80
        }
        if simple, !SQLKeywords.reserved.contains(name.uppercased()) { return name }
        return SQLText.quoteIdentifier(name)
    }

    // MARK: Ranking

    /// Prefix matches first (case-sensitive exact casing preferred), then word-boundary and camel-case
    /// matches (`gu` → `groupUniqArray`), then subsequences.
    static func rank(_ items: [CompletionItem], prefix: String, limit: Int) -> [CompletionItem] {
        let needle = prefix.lowercased()
        var scored: [(item: CompletionItem, score: Int, order: Int)] = []
        scored.reserveCapacity(items.count)
        var seen = Set<String>()
        for item in items where seen.insert(item.id).inserted {
            let score = matchScore(label: item.label, needle: needle, original: prefix)
            if score > 0 { scored.append((item, score, scored.count)) }
        }
        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.item.kind != rhs.item.kind { return lhs.item.kind.rawValue < rhs.item.kind.rawValue }
            // Without a prefix keep the curated order (statement starters, keyword lists).
            if needle.isEmpty { return lhs.order < rhs.order }
            if lhs.item.label.count != rhs.item.label.count { return lhs.item.label.count < rhs.item.label.count }
            return lhs.item.label.localizedStandardCompare(rhs.item.label) == .orderedAscending
        }
        return scored.prefix(max(0, limit)).map(\.item)
    }

    static func matchScore(label: String, needle: String, original: String) -> Int {
        if needle.isEmpty { return 1 }
        let lowered = label.lowercased()
        if label == original { return 7 }
        if lowered == needle { return 6 }
        if label.hasPrefix(original) { return 5 }
        if lowered.hasPrefix(needle) { return 4 }
        let words = splitWords(label)
        if words.dropFirst().contains(where: { $0.lowercased().hasPrefix(needle) }) { return 3 }
        let initials = String(words.compactMap(\.first)).lowercased()
        if initials.hasPrefix(needle) { return 2 }
        var remaining = Substring(needle)
        for character in lowered where character == remaining.first {
            remaining = remaining.dropFirst()
            if remaining.isEmpty { return 1 }
        }
        return 0
    }

    /// `max_threads` → [max, threads]; `groupUniqArray` → [group, Uniq, Array].
    static func splitWords(_ label: String) -> [Substring] {
        var words: [Substring] = []
        var start = label.startIndex
        var index = label.startIndex
        while index < label.endIndex {
            let character = label[index]
            if character == "_" || character == "." || character == " " {
                if start < index { words.append(label[start..<index]) }
                start = label.index(after: index)
            } else if character.isUppercase, index > start, let previous = label[..<index].last, previous.isLowercase {
                words.append(label[start..<index])
                start = index
            }
            index = label.index(after: index)
        }
        if start < label.endIndex { words.append(label[start...]) }
        return words
    }
}
