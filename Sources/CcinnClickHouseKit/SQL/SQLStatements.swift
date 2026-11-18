import Foundation

/// One statement of a script. `range` is in UTF-16 offsets of the whole script and excludes the
/// terminating semicolon; `text` is trimmed.
public struct SQLStatement: Sendable, Equatable {
    public let text: String
    public let range: Range<Int>

    public init(text: String, range: Range<Int>) {
        self.text = text
        self.range = range
    }
}

public enum SQLStatementSplitter {
    /// Splits on semicolons outside strings, heredocs, quoted identifiers and comments. Statements made
    /// only of comments/whitespace are dropped.
    public static func split(_ script: String) -> [SQLStatement] {
        let lexer = SQLLexer(script)
        return split(lexer: lexer, tokens: lexer.tokens())
    }

    public static func split(lexer: SQLLexer, tokens: [SQLToken]) -> [SQLStatement] {
        var statements: [SQLStatement] = []
        var firstSignificant: Int?
        var lastSignificantEnd = 0
        func flush() {
            if let start = firstSignificant {
                let range = start..<lastSignificantEnd
                statements.append(SQLStatement(text: lexer.text(in: range), range: range))
            }
            firstSignificant = nil
        }
        for token in tokens {
            if token.kind == .punctuation, lexer.units[token.range.lowerBound] == 0x3B {
                flush()
                continue
            }
            if token.kind == .comment {
                if firstSignificant != nil { lastSignificantEnd = max(lastSignificantEnd, token.range.upperBound) }
                continue
            }
            if firstSignificant == nil { firstSignificant = token.range.lowerBound }
            lastSignificantEnd = token.range.upperBound
        }
        flush()
        return statements
    }

    /// The statement containing `offset` (UTF-16). A cursor right after a statement's `;` or in the
    /// blank space after it belongs to that statement.
    public static func statement(at offset: Int, in script: String) -> SQLStatement? {
        let statements = split(script)
        guard !statements.isEmpty else { return nil }
        if let containing = statements.first(where: { $0.range.lowerBound <= offset && offset <= $0.range.upperBound }) {
            return containing
        }
        return statements.last { $0.range.upperBound <= offset } ?? statements.first
    }
}

/// Significant tokens of one statement with upper-cased words, shared by the classifiers.
struct StatementWords {
    let lexer: SQLLexer
    let tokens: [SQLToken]
    /// Upper-cased text for keywords/identifiers, raw text otherwise.
    let words: [String]

    init(_ statement: String) {
        let lexer = SQLLexer(statement)
        let tokens = lexer.tokens().filter { $0.kind != .comment }
        self.lexer = lexer
        self.tokens = tokens
        words = tokens.map { token in
            token.kind == .keyword || token.kind == .identifier ? lexer.text(of: token).uppercased() : lexer.text(of: token)
        }
    }

    func isWord(_ index: Int) -> Bool {
        tokens.indices.contains(index) && (tokens[index].kind == .keyword || tokens[index].kind == .identifier)
    }

    func word(_ index: Int) -> String? { words.indices.contains(index) ? words[index] : nil }

    func isPunctuation(_ index: Int, _ text: String) -> Bool {
        tokens.indices.contains(index) && tokens[index].kind == .punctuation && words[index] == text
    }

    /// An identifier, keyword or quoted identifier (a possible column or setting name).
    func isName(_ index: Int) -> Bool {
        isWord(index) || (tokens.indices.contains(index) && tokens[index].kind == .quotedIdentifier)
    }

    /// The end of the statement (or its terminating `;`).
    func isEnd(_ index: Int) -> Bool { index >= tokens.count || isPunctuation(index, ";") }

    /// `SETTINGS name = …`: the clause, not a column called `settings` (`Settings['x']`, `t.settings`).
    func isSettingsClause(at index: Int) -> Bool {
        word(index) == "SETTINGS" && isWord(index) && !isPunctuation(index - 1, ".") && isName(index + 1)
            && tokens.indices.contains(index + 2) && tokens[index + 2].kind == .operator && words[index + 2] == "="
    }

    /// Words after a column reference: a `settings` followed by one of these is a column, not a clause.
    static let columnFollowers: Set<String> = ["FROM", "AS", "WHERE", "PREWHERE", "GROUP", "ORDER", "HAVING", "LIMIT", "UNION", "EXCEPT",
                                               "INTERSECT", "AND", "OR", "IS", "IN", "NOT", "LIKE", "ILIKE", "BETWEEN", "ASC", "DESC",
                                               "FORMAT", "INTO", "WINDOW", "QUALIFY", "NULLS", "COLLATE"]

    /// Fail-closed variant for the read-only guard: anything that is not clearly a column named
    /// `settings` counts as the clause.
    func mayBeSettingsClause(at index: Int) -> Bool {
        guard word(index) == "SETTINGS", isWord(index), !isPunctuation(index - 1, ".") else { return false }
        if isSettingsClause(at: index) || isEnd(index + 1) { return isSettingsClause(at: index) }
        if ["[", ",", ")", ".", "]", "}"].contains(where: { isPunctuation(index + 1, $0) }) { return false }
        if isWord(index + 1), let next = word(index + 1), Self.columnFollowers.contains(next) { return false }
        return true
    }

    /// `FORMAT name` at the end of the statement (optionally followed by a SETTINGS clause), not a
    /// column called `format`.
    func isFormatClause(at index: Int) -> Bool {
        guard word(index) == "FORMAT", isWord(index), !isPunctuation(index - 1, "."), isName(index + 1) else { return false }
        return isEnd(index + 2) || isSettingsClause(at: index + 2)
    }

    /// `OFFSET n [ROWS]` (a number or a query parameter follows), not a column called `offset`.
    func isOffsetClause(at index: Int) -> Bool {
        guard word(index) == "OFFSET", isWord(index), !isPunctuation(index - 1, "."), tokens.indices.contains(index + 1) else { return false }
        return tokens[index + 1].kind == .number || tokens[index + 1].kind == .parameter || isPunctuation(index + 1, "(")
    }

    /// Parenthesis/bracket depth before each token.
    var depths: [Int] {
        var depth = 0
        return tokens.indices.map { index in
            let current = depth
            if tokens[index].kind == .punctuation {
                switch words[index] {
                case "(", "[", "{": depth += 1
                case ")", "]", "}": depth = max(0, depth - 1)
                default: break
                }
            }
            return current
        }
    }
}

/// What kind of statement a text is; drives auto-limit, history and confirmation UI.
public enum SQLStatementKind: Sendable, Equatable {
    case query
    case explain
    case show
    case use
    case set
    case dataModification
    case definition
    case administration
    case other

    public static func of(_ statement: String) -> SQLStatementKind {
        of(StatementWords(statement))
    }

    static func of(_ statement: StatementWords) -> SQLStatementKind {
        let words = statement.words
        guard let first = words.first else { return .other }
        func next(_ offset: Int) -> String { statement.word(offset) ?? "" }
        switch first {
        case "SELECT", "WITH", "(":
            // `SELECT … INTO OUTFILE` writes a file; `WITH … INSERT` is not a query either.
            if containsTopLevel(statement, "INTO", followedBy: "OUTFILE") { return .other }
            if first == "WITH", let verb = mainVerb(afterWith: statement), verb != "SELECT", verb != "(" {
                return verb == "INSERT" ? .dataModification : .other
            }
            return .query
        case "EXPLAIN": return .explain
        case "SHOW", "DESC", "DESCRIBE", "EXISTS", "CHECK": return .show
        case "USE": return .use
        case "SET":
            return ["ROLE", "DEFAULT", "TRANSACTION"].contains(next(1)) ? .administration : .set
        case "INSERT", "DELETE", "UPDATE", "TRUNCATE": return .dataModification
        case "ALTER":
            // ALTER TABLE … UPDATE/DELETE (mutations) change data; everything else changes schema.
            let depths = statement.depths
            for index in words.indices.dropFirst() where depths[index] == 0 && statement.isWord(index) {
                if words[index] == "UPDATE" || words[index] == "DELETE" { return .dataModification }
            }
            return .definition
        case "CREATE", "DROP", "RENAME", "EXCHANGE", "ATTACH", "DETACH", "UNDROP", "REPLACE": return .definition
        case "KILL", "SYSTEM", "GRANT", "REVOKE", "OPTIMIZE", "BACKUP", "RESTORE", "MOVE", "BEGIN", "COMMIT", "ROLLBACK": return .administration
        default: return .other
        }
    }

    /// The statement verb after a `WITH` list: the first SELECT/INSERT/… or `(` at depth 0 that
    /// follows a closing parenthesis or an expression alias.
    static func mainVerb(afterWith statement: StatementWords) -> String? {
        let depths = statement.depths
        for index in statement.words.indices.dropFirst() where depths[index] == 0 {
            let word = statement.words[index]
            if ["SELECT", "INSERT", "UPDATE", "DELETE", "ALTER", "CREATE", "DROP"].contains(word), statement.isWord(index) { return word }
            if word == "(", index > 0, statement.words[index - 1] == ")" { return "(" }
        }
        return nil
    }

    static func containsTopLevel(_ statement: StatementWords, _ word: String, followedBy next: String) -> Bool {
        let depths = statement.depths
        for index in statement.words.indices where depths[index] == 0 && statement.words[index] == word {
            if statement.word(index + 1) == next { return true }
        }
        return false
    }

    /// Statements that may change data, schema or server state (confirmed on profiles that ask for it).
    /// Unknown statements are treated as mutations.
    public var isMutation: Bool {
        switch self {
        case .dataModification, .definition, .administration, .other: true
        case .query, .explain, .show, .use, .set: false
        }
    }
}

/// Adds `LIMIT n` to top-level queries without one (design D9).
public enum AutoLimit {
    public struct Outcome: Sendable, Equatable {
        public let sql: String
        public let applied: Bool
        /// UTF-16 range of the inserted text (with its spacing) in `sql`.
        public let insertion: Range<Int>?

        public init(sql: String, applied: Bool, insertion: Range<Int>? = nil) {
            self.sql = sql
            self.applied = applied
            self.insertion = insertion
        }

        /// Maps a UTF-16 offset in the executed text (e.g. a server error position) back to the text the
        /// user wrote; an offset inside the inserted LIMIT maps to where it was inserted.
        public func originalOffset(ofExecuted offset: Int) -> Int {
            SQLExecutedTextMapping(insertion: insertion).sourceOffset(forExecuted: offset)
        }
    }

    /// Clause keywords that end a `LIMIT n [OFFSET m]` clause.
    static let clauseEnds: Set<String> = ["SETTINGS", "FORMAT", "UNION", "EXCEPT", "INTERSECT", "INTO", "LIMIT"]

    public static func apply(to sql: String, limit: Int) -> Outcome {
        guard limit > 0 else { return Outcome(sql: sql, applied: false) }
        let statement = StatementWords(sql)
        guard let first = statement.words.first, ["SELECT", "WITH", "("].contains(first), SQLStatementKind.of(statement) == .query else {
            return Outcome(sql: sql, applied: false)
        }
        let words = statement.words
        let depths = statement.depths
        var insertBefore: Int?
        var lastSignificant: Int?
        for index in words.indices {
            if words[index] == ";", statement.tokens[index].kind == .punctuation { break }
            lastSignificant = index
            guard depths[index] == 0, statement.isWord(index) else { continue }
            // Inside a SETTINGS clause, `limit = 3` or `offset = 1` name settings, not clauses.
            if insertBefore != nil, statement.word(index + 1) == "=" { continue }
            switch words[index] {
            case "UNION", "EXCEPT", "INTERSECT":
                // The limit would only apply to the last SELECT; leave compound queries alone.
                return Outcome(sql: sql, applied: false)
            case "TOP", "FETCH", "OUTFILE":
                return Outcome(sql: sql, applied: false)
            case "LIMIT":
                if !isLimitBy(statement, depths: depths, at: index) { return Outcome(sql: sql, applied: false) }
            case "OFFSET":
                // `OFFSET n` without LIMIT: `LIMIT n OFFSET m ROWS` is not valid everywhere, so leave it.
                if statement.isOffsetClause(at: index) { return Outcome(sql: sql, applied: false) }
            case "SETTINGS":
                if insertBefore == nil, statement.isSettingsClause(at: index) { insertBefore = index }
            case "FORMAT":
                if insertBefore == nil, statement.isFormatClause(at: index) { insertBefore = index }
            default:
                break
            }
        }
        let units = statement.lexer.units
        let offset: Int
        if let insertBefore, insertBefore > 0 {
            // Right after the last token before SETTINGS / FORMAT, on a line of its own: no comment before it can absorb
            // it, and it never starts one (a `#` or `$` before it stays what it was).
            offset = statement.tokens[insertBefore - 1].range.upperBound
            let head = String(decoding: units[0..<offset], as: UTF16.self)
            let tail = String(decoding: units[offset...], as: UTF16.self)
            let inserted = "\nLIMIT \(limit)" + (tail.first.map { $0.isWhitespace } == true ? "" : " ")
            return Outcome(sql: head + inserted + tail, applied: true, insertion: offset..<(offset + inserted.utf16.count))
        }
        guard let lastSignificant else { return Outcome(sql: sql, applied: false) }
        offset = statement.tokens[lastSignificant].range.upperBound
        let head = String(decoding: units[0..<offset], as: UTF16.self)
        let tail = String(decoding: units[offset...], as: UTF16.self)
        let inserted = "\nLIMIT \(limit)"
        return Outcome(sql: head + inserted + tail, applied: true, insertion: offset..<(offset + inserted.utf16.count))
    }

    /// `LIMIT n [, m] [OFFSET k] BY expr` limits rows per group, not the result.
    static func isLimitBy(_ statement: StatementWords, depths: [Int], at index: Int) -> Bool {
        var position = index + 1
        while position < statement.words.count {
            let word = statement.words[position]
            if depths[position] == 0, statement.isWord(position) {
                if word == "BY" { return true }
                if clauseEnds.contains(word) || word == "WITH" { return false }
            }
            position += 1
        }
        return false
    }
}
