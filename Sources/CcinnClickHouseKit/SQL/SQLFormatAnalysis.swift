import Foundation

/// How Format SQL reads a script: the role each keyword plays for the layout, which words ClickHouse can only read as
/// keywords where they stand, and the inline data of `INSERT … FORMAT` (design D2, D3 of add-sql-formatter).
///
/// ClickHouse has almost no reserved words: `select`, `from`, `end`, `case`, `desc`, `null` and `format` are valid
/// names in some positions, and names and functions are case-sensitive. So a word's letter case may change only where
/// the grammar leaves the server no other reading:
/// - the first words of a statement (`SELECT`, `CREATE TABLE IF NOT EXISTS`, `SHOW CREATE TABLE`);
/// - a clause or operator word right after a complete operand, where ClickHouse allows no implicit alias (WHERE, ORDER BY,
///   function arguments, …) or refuses that word as one (`neverColumnAlias`, `neverTableAlias`);
/// - the rest of a fixed phrase after such a word (`GROUP BY`, `IS NOT NULL`, `WITH TOTALS`, `LEFT ARRAY JOIN`);
/// - a CASE with its WHEN/THEN/ELSE once its END is found, only in a statement whose CASE…END structure is proven by
///   counting (`caseCountsBalanced`) and only when no other `end` stands inside it; a complete window frame,
///   `INTERVAL 1 DAY`, the literals `NULL`/`TRUE`/`FALSE`.
///
/// A word right before or after `.` is always a name (`end.a`, `t.case`): it never opens or closes a structure and never
/// changes case. Everything else keeps its exact text. The alias facts are verified against every supported server by
/// `FormatterIntegrationTests` (implicit-alias probes, `system.keywords`, and formatted queries returning the same results).
struct SQLFormatAnalysis: Sendable {
    enum Clause: Sendable, Equatable {
        case with, select, from, prewhere, `where`, groupBy, having, window, qualify, orderBy, limit, offset, settings, format,
             setOperation, values, set, into
    }

    enum Role: Sendable, Equatable {
        case none
        /// First word of a statement.
        case statement
        /// First word of a query clause.
        case clause(Clause)
        /// A word continuing the word before it: `BY`, `ALL` after UNION, `DISTINCT` after SELECT, the rest of a join.
        case continuation
        /// First word of a join operator.
        case join
        /// `ON` (true) or `USING` (false) after a join.
        case joinCondition(on: Bool)
        /// `AND` / `OR` joining the conditions of WHERE, PREWHERE, HAVING, QUALIFY or ON.
        case condition
        /// The `AND` of BETWEEN.
        case betweenAnd
        case caseStart, caseWhen, caseThen, caseElse, caseEnd
        /// `(` opening a subquery.
        case subqueryOpen
        /// `(` opening a CREATE TABLE / DICTIONARY column list.
        case columnListOpen
        /// A statement-level clause of CREATE: ENGINE, PARTITION BY, ORDER BY, PRIMARY KEY, SAMPLE BY, TTL, SETTINGS, …
        case definitionClause
        /// Any other recognised keyword.
        case keyword
    }

    /// A CASE whose END was found: the END and the number of WHEN / ELSE branches.
    struct CaseShape: Sendable, Equatable {
        let end: Int
        let branches: Int
    }

    var roles: [Role]
    /// Tokens whose letter case Format SQL may change.
    var changeable: [Bool]
    /// `INSERT … FORMAT name` data: the source after the format name token (key) up to the token at the value (`;` or
    /// the token count) is data, written verbatim.
    var data: [Int: Int]
    /// CASE token → its shape.
    var cases: [Int: CaseShape]
    /// Kind of the statement each token belongs to (by the statement's first word).
    var statementKinds: [StatementKind]
    /// The token follows a complete operand: an operator there is binary (`a - b`, `x = 1`, `2 * 3`), not a sign or `*`.
    var afterOperand: [Bool]
    /// For `(`, `[` and `{`: the index of the token that closes it, or -1 when nothing does before the statement ends.
    var matching: [Int]

    enum StatementKind: Sendable, Equatable {
        /// SELECT, WITH, `(`: queries; INSERT, DELETE, UPDATE, CREATE, EXPLAIN get clause layout too.
        case query, insert, delete, update, create, explain, other
        var hasLayout: Bool { self != .other }
    }

    var changeableIndices: Set<Int> {
        Set(changeable.indices.filter { changeable[$0] })
    }

    /// Source ranges (UTF-16) of the inline data of every `INSERT … FORMAT` statement.
    func dataRanges(tokens: [SQLToken], unitCount: Int) -> [Range<Int>] {
        data.keys.sorted().map { name in
            let end = data[name] ?? tokens.count
            let upper = end < tokens.count ? tokens[end].range.lowerBound : unitCount
            return tokens[name].range.upperBound..<max(tokens[name].range.upperBound, upper)
        }
    }

    static func analyze(lexer: SQLLexer, tokens: [SQLToken]) -> SQLFormatAnalysis {
        var analyzer = SQLFormatAnalyzer(lexer: lexer, tokens: tokens)
        analyzer.run()
        return analyzer.result
    }
}

// MARK: - Vocabulary

/// Facts about ClickHouse's parser that the analysis relies on. Every set here is checked against 22.8, 24.8 and 26.8
/// by `FormatterIntegrationTests`.
enum SQLFormatVocabulary {
    /// Refused as an implicit column alias (`SELECT 1 w`) by every supported server.
    static let neverColumnAlias: Set<String> = [
        "ALL", "AND", "ANTI", "ANY", "ARRAY", "AS", "ASOF", "BETWEEN", "CROSS", "ELSE", "EXCEPT", "FINAL", "FORMAT", "FROM", "FULL",
        "GLOBAL", "GROUP", "HAVING", "ILIKE", "IN", "INNER", "INTERSECT", "INTO", "JOIN", "LEFT", "LIKE", "LIMIT", "NOT", "OFFSET",
        "ON", "OR", "ORDER", "PREWHERE", "RIGHT", "SAMPLE", "SEMI", "SETTINGS", "UNION", "USING", "WHERE", "WINDOW", "WITH",
    ]

    /// Refused as an implicit table alias (`SELECT w.number FROM numbers(1) w`) by every supported server.
    static let neverTableAlias: Set<String> = [
        "ALL", "ANTI", "ANY", "ARRAY", "AS", "ASOF", "BETWEEN", "CROSS", "DISTINCT", "ELSE", "EXCEPT", "FALSE", "FINAL", "FORMAT",
        "FROM", "FULL", "GLOBAL", "GROUP", "HAVING", "ILIKE", "INNER", "INTERSECT", "INTO", "JOIN", "LEFT", "LIKE", "LIMIT", "NOT",
        "NULL", "OFFSET", "ON", "ORDER", "PREWHERE", "RIGHT", "SAMPLE", "SEMI", "SETTINGS", "TOP", "TRUE", "UNION", "USING",
        "WHERE", "WINDOW", "WITH",
    ]

    /// Keywords of ClickHouse's expression operators (`ExpressionListParsers.cpp`): a word after an operand that is one of
    /// these is never taken for an implicit alias.
    static let operatorWords: Set<String> = ["AND", "OR", "NOT", "IN", "GLOBAL", "LIKE", "ILIKE", "REGEXP", "BETWEEN", "IS", "DIV",
                                             "MOD", "AS"]

    /// Words that start a statement.
    static let statementWords: Set<String> = [
        "SELECT", "WITH", "INSERT", "DELETE", "UPDATE", "CREATE", "ATTACH", "DETACH", "DROP", "TRUNCATE", "UNDROP", "ALTER",
        "RENAME", "EXCHANGE", "OPTIMIZE", "SHOW", "DESCRIBE", "DESC", "EXISTS", "CHECK", "USE", "SET", "SYSTEM", "KILL", "EXPLAIN",
        "GRANT", "REVOKE", "BACKUP", "RESTORE", "WATCH", "BEGIN", "COMMIT", "ROLLBACK",
    ]

    /// Object kinds after CREATE, DROP, ATTACH, DETACH, EXISTS, SHOW CREATE, …
    static let objectKinds: Set<String> = ["TABLE", "VIEW", "DATABASE", "DICTIONARY", "FUNCTION"]

    /// `SHOW …` targets (all keywords, never names).
    static let showTargets: Set<String> = [
        "TABLES", "DATABASES", "DICTIONARIES", "PROCESSLIST", "CLUSTERS", "CLUSTER", "FUNCTIONS", "ENGINES", "GRANTS",
        "ROLES", "ACCESS", "MERGES", "PRIVILEGES", "COLUMNS", "INDEXES", "SETTINGS", "CHANGED", "FULL",
        "TEMPORARY",
    ]

    /// `EXPLAIN` kinds.
    static let explainKinds: Set<String> = ["AST", "SYNTAX", "PLAN", "PIPELINE", "ESTIMATE"]

    /// Units of `INTERVAL n unit`.
    static let intervalUnits: Set<String> = ["NANOSECOND", "MICROSECOND", "MILLISECOND", "SECOND", "MINUTE", "HOUR", "DAY", "WEEK",
                                             "MONTH", "QUARTER", "YEAR"]

    /// Words a set operator's query starts with (ClickHouse has no VALUES query: `SELECT 1 UNION ALL VALUES (1)` is a
    /// syntax error on every supported server).
    static let queryStarts: Set<String> = ["SELECT", "WITH"]

    /// Words of a join operator before `JOIN` (`GLOBAL ANY LEFT OUTER JOIN`, `LEFT ARRAY JOIN`).
    static let joinWords: Set<String> = ["GLOBAL", "ANY", "ALL", "ASOF", "SEMI", "ANTI", "LEFT", "RIGHT", "INNER", "FULL", "CROSS",
                                         "OUTER", "PASTE", "ARRAY"]

    /// Every word whose case the analysis may change: each must be a ClickHouse keyword (`system.keywords`).
    static let changeableWords: Set<String> = {
        var words: Set<String> = [
            "SELECT", "DISTINCT", "ALL", "FROM", "PREWHERE", "WHERE", "GROUP", "BY", "HAVING", "WINDOW", "QUALIFY", "ORDER", "LIMIT",
            "OFFSET", "SETTINGS", "FORMAT", "UNION", "EXCEPT", "INTERSECT", "INTO", "OUTFILE", "AND", "STDOUT", "WITH", "TOTALS",
            "ROLLUP", "CUBE", "FILL", "TO", "STEP", "TIES", "ASC", "DESC", "ASCENDING", "DESCENDING", "NULLS", "FIRST", "LAST",
            "COLLATE", "JOIN", "ON", "USING", "FINAL", "SAMPLE", "OR", "NOT", "IN", "BETWEEN", "LIKE", "ILIKE", "IS", "NULL",
            "TRUE", "FALSE", "AS", "CASE", "WHEN", "THEN", "ELSE", "END", "INTERVAL", "OVER", "PARTITION", "ROWS", "RANGE",
            "UNBOUNDED", "PRECEDING", "FOLLOWING", "CURRENT", "ROW", "VALUES", "SET", "IF", "EXISTS", "CLUSTER", "REPLACE",
            "TEMPORARY", "MATERIALIZED", "LIVE", "ENGINE", "PRIMARY", "KEY", "TTL", "COMMENT", "SOURCE", "LAYOUT", "LIFETIME",
            "POPULATE", "QUERY", "MUTATION",
        ]
        words.formUnion(statementWords)
        words.formUnion(objectKinds)
        words.formUnion(showTargets)
        words.formUnion(explainKinds)
        words.formUnion(intervalUnits)
        words.formUnion(joinWords.subtracting(["PASTE"]))
        return words
    }()
}

// MARK: - Analyzer

private struct SQLFormatAnalyzer {
    typealias Role = SQLFormatAnalysis.Role
    typealias Clause = SQLFormatAnalysis.Clause
    typealias Vocabulary = SQLFormatVocabulary

    enum Context { case select, tables, expression, orderBy, window, settings, data, definition, unknown }
    enum Operand { case expected, complete, unknown }

    struct OpenCase {
        let start: Int
        var words: [Int]
        var whens = 0
        var branches = 0
        /// Another `end` stands inside this CASE (next to `.`, where a value or a name stands, after AS): servers may
        /// close the CASE there (24.8+ does at `else end`), so none of its words change case and it gets no layout.
        var ambiguous = false
    }

    struct Frame {
        enum Kind { case statement, subquery, call, parens, brackets, braces, window, columns }
        var kind: Kind
        var context: Context
        var operand: Operand = .expected
        /// An implicit alias followed the current operand.
        var aliased = false
        /// A SELECT query lives at this level.
        var query = false
        var clause: Clause?
        /// In a FROM clause (tables, joins, ON/USING conditions).
        var inFrom = false
        var joinPending = false
        var sawTableClause = false
        var betweenPending = 0
        var betweenChangeable: [Bool] = []
        var cases: [OpenCase] = []
        var fill = false
        var sampleOpen = false
        var afterAsterisk = false
        /// The next word starts a query (after UNION, an INSERT target, CREATE … AS).
        var expectQuery = false
        /// After `)` the next token starts a new item rather than following an operand (`DISTINCT ON (a) b`).
        var closesToExpected = false
        /// A call frame whose first token was not seen yet.
        var atCallStart = false
    }

    let lexer: SQLLexer
    let tokens: [SQLToken]
    /// Upper-cased ASCII text of word tokens (`keyword`, `identifier`); "" for names (a non-ASCII word, or a word next
    /// to `.`), which no keyword rule may match; raw text otherwise.
    let words: [String]
    /// A word that may be a keyword: ASCII and not next to `.`.
    let isWord: [Bool]
    /// A word that can only be a name: next to `.` (`end.a`, `t.case`, `db . select`).
    let isDotName: [Bool]
    /// Any word spelled `end`, names included (they make an enclosing CASE ambiguous).
    let isEnd: [Bool]
    /// Next non-comment token after each index (or `tokens.count`).
    let nextSignificant: [Int]
    /// See `SQLFormatAnalysis.matching`.
    let matching: [Int]
    /// The token's statement passes the CASE…END counting proof (see `caseCounts`).
    let caseCountsBalanced: [Bool]

    var roles: [Role]
    var changeable: [Bool]
    var data: [Int: Int] = [:]
    var cases: [Int: SQLFormatAnalysis.CaseShape] = [:]
    /// First word of a validated window frame → the `)` closing its window specification.
    var windowFrames: [Int: Int] = [:]
    var statementKinds: [SQLFormatAnalysis.StatementKind]
    var afterOperand: [Bool]

    var frames: [Frame] = []
    var statementKind: SQLFormatAnalysis.StatementKind = .other
    var statementStart: Int?
    /// After `.` or `::`, or after a keyword that names something next (`AS`, `FORMAT`): the next word is a name.
    var nameNext = false
    /// INSERT INTO FUNCTION: the table function's arguments come before the column list.
    var insertCallPending = false
    /// CREATE: right after the object name (a `(` here opens the column list).
    var createNameEnd = false
    var createKind = ""

    init(lexer: SQLLexer, tokens: [SQLToken]) {
        self.lexer = lexer
        self.tokens = tokens
        var words: [String] = []
        var isWord: [Bool] = []
        var isEnd: [Bool] = []
        words.reserveCapacity(tokens.count)
        isWord.reserveCapacity(tokens.count)
        isEnd.reserveCapacity(tokens.count)
        for token in tokens {
            let wordLike = token.kind == .keyword || token.kind == .identifier
            if wordLike, let upper = SQLLexer.asciiUppercased(lexer.units[token.range]) {
                words.append(upper)
                isWord.append(true)
                isEnd.append(upper == "END")
            } else {
                words.append(wordLike ? "" : lexer.text(of: token))
                isWord.append(false)
                isEnd.append(false)
            }
        }
        var next = [Int](repeating: tokens.count, count: tokens.count + 1)
        var cursor = tokens.count
        for index in stride(from: tokens.count - 1, through: 0, by: -1) {
            next[index] = cursor
            if tokens[index].kind != .comment { cursor = index }
        }
        nextSignificant = next
        // A word next to `.` is a name, whatever it spells.
        var isDotName = [Bool](repeating: false, count: tokens.count)
        var previous = -1
        for index in tokens.indices where tokens[index].kind != .comment {
            if tokens[index].kind == .punctuation, words[index] == "." {
                if previous >= 0, tokens[previous].kind == .keyword || tokens[previous].kind == .identifier { isDotName[previous] = true }
                let following = next[index]
                if following < tokens.count, tokens[following].kind == .keyword || tokens[following].kind == .identifier {
                    isDotName[following] = true
                }
            }
            previous = index
        }
        for index in tokens.indices where isDotName[index] {
            words[index] = ""
            isWord[index] = false
        }
        self.words = words
        self.isWord = isWord
        self.isDotName = isDotName
        self.isEnd = isEnd
        // Matching brackets, in one pass, so no look-ahead rescans nested text. `;` ends every open bracket, as it ends
        // the statement for the analysis and the layout.
        var matching = [Int](repeating: -1, count: tokens.count)
        var open: [Int] = []
        for index in tokens.indices where tokens[index].kind == .punctuation {
            switch words[index] {
            case "(", "[", "{": open.append(index)
            case ")", "]", "}": if let opener = open.popLast() { matching[opener] = index }
            case ";": open.removeAll(keepingCapacity: true)
            default: break
            }
        }
        self.matching = matching
        caseCountsBalanced = Self.caseCounts(tokens: tokens, words: words, units: lexer.units, isDotName: isDotName)
        roles = [Role](repeating: .none, count: tokens.count)
        changeable = [Bool](repeating: false, count: tokens.count)
        statementKinds = [SQLFormatAnalysis.StatementKind](repeating: .other, count: tokens.count)
        afterOperand = [Bool](repeating: false, count: tokens.count)
    }

    /// The CASE…END counting proof, per statement. `end` is a valid name on every supported server (a column, an alias,
    /// a table alias, `end.a`), and `end.1` after a CASE is its END followed by tuple access, so no single `end` can be
    /// told apart by where it stands. Counting can: within each pair of brackets of a statement, every word `case`
    /// that can start a CASE (not one next to `.`, a name) needs one `end`, and EVERY word `end` counts as a candidate
    /// END. Equal counts everywhere mean no `end` is left over to be a name; otherwise the statement's CASE words keep
    /// their case and their layout. Quoted names are other tokens and do not count.
    static func caseCounts(tokens: [SQLToken], words: [String], units: [UInt16], isDotName: [Bool]) -> [Bool] {
        var balanced = [Bool](repeating: true, count: tokens.count)
        var counts: [Int: (cases: Int, ends: Int)] = [:] // enclosing bracket → counts; -1 is the statement itself
        var open: [Int] = []
        var statementStart = 0
        func finish(_ end: Int) {
            let proven = counts.values.allSatisfy { $0.cases == $0.ends }
            if !proven { for index in statementStart..<end { balanced[index] = false } }
            counts.removeAll(keepingCapacity: true)
            open.removeAll(keepingCapacity: true)
            statementStart = end
        }
        for index in tokens.indices {
            let token = tokens[index]
            if token.kind == .punctuation {
                switch words[index] {
                case "(", "[", "{": open.append(index)
                case ")", "]", "}": _ = open.popLast()
                case ";": finish(index + 1)
                default: break
                }
                continue
            }
            guard token.kind == .keyword || token.kind == .identifier,
                  let upper = SQLLexer.asciiUppercased(units[token.range]), upper == "CASE" || upper == "END" else { continue }
            let group = open.last ?? -1
            var count = counts[group] ?? (0, 0)
            if upper == "END" {
                count.ends += 1
            } else if !isDotName[index] {
                count.cases += 1
            }
            counts[group] = count
        }
        finish(tokens.count)
        return balanced
    }

    var result: SQLFormatAnalysis {
        SQLFormatAnalysis(roles: roles, changeable: changeable, data: data, cases: cases, statementKinds: statementKinds,
                          afterOperand: afterOperand, matching: matching)
    }

    // MARK: Helpers

    /// The innermost frame, modified in place (a get/set pair would copy its arrays on every change).
    var frame: Frame {
        get { frames[frames.count - 1] }
        _modify { yield &frames[frames.count - 1] }
    }

    func next(_ index: Int) -> Int? {
        let value = nextSignificant[min(max(0, index), tokens.count)]
        return value < tokens.count ? value : nil
    }

    func word(_ index: Int?) -> String? {
        guard let index, index >= 0, index < tokens.count, isWord[index] else { return nil }
        return words[index]
    }

    func isPunctuation(_ index: Int?, _ text: String) -> Bool {
        guard let index, index >= 0, index < tokens.count else { return false }
        return tokens[index].kind == .punctuation && words[index] == text
    }

    func isOperator(_ index: Int?, _ text: String) -> Bool {
        guard let index, index >= 0, index < tokens.count else { return false }
        return tokens[index].kind == .operator && words[index] == text
    }

    /// A token that can begin an operand: a name, literal, parameter, `(`, `[`.
    func startsOperand(_ index: Int?) -> Bool {
        guard let index, index < tokens.count else { return false }
        switch tokens[index].kind {
        case .identifier, .quotedIdentifier, .number, .string, .parameter, .keyword: return true
        case .punctuation: return words[index] == "(" || words[index] == "["
        default: return false
        }
    }

    /// A token that is plainly a value or a name (no keyword involved).
    func isPlainOperand(_ index: Int?) -> Bool {
        guard let index, index < tokens.count else { return false }
        switch tokens[index].kind {
        case .quotedIdentifier, .number, .string, .parameter: return true
        case .identifier, .keyword:
            return isDotName[index] || tokens[index].kind == .identifier && isWord[index] && !SQLKeywords.all.contains(words[index])
        default: return false
        }
    }

    /// The word can be followed by a name-like token (a name, quoted name, or parameter).
    func startsName(_ index: Int?) -> Bool {
        guard let index, index < tokens.count else { return false }
        switch tokens[index].kind {
        case .identifier, .quotedIdentifier, .parameter, .keyword: return true
        default: return false
        }
    }

    mutating func mark(_ index: Int, _ role: Role, changeable proven: Bool) {
        roles[index] = role
        if proven, Vocabulary.changeableWords.contains(words[index]) { changeable[index] = true }
    }

    /// The implicit aliases ClickHouse allows where the frame stands (nil: none).
    var aliasRefusals: Set<String>? {
        if !frame.cases.isEmpty { return Vocabulary.neverColumnAlias } // aliases inside CASE (24.8+)
        switch frame.context {
        case .select: return Vocabulary.neverColumnAlias
        case .tables: return Vocabulary.neverTableAlias
        case .unknown, .data: return []
        default: return nil
        }
    }

    /// A word right after a complete operand is a keyword when the server allows no implicit alias here or refuses this
    /// word as one.
    func isProvenAfterOperand(_ word: String) -> Bool {
        guard let refusals = aliasRefusals else { return true }
        return refusals.contains(word)
    }

    mutating func operandComplete() {
        frame.operand = .complete
        frame.aliased = false
        frame.afterAsterisk = false
    }

    mutating func expectOperand() {
        frame.operand = .expected
        frame.aliased = false
        frame.afterAsterisk = false
    }

    // MARK: Run

    mutating func run() {
        frames = [Frame(kind: .statement, context: .unknown)]
        var index = 0
        while index < tokens.count {
            if index & 0xFFF == 0, Task.isCancelled { return }
            if tokens[index].kind == .comment {
                index += 1
                continue
            }
            if isPunctuation(index, ";") {
                statementKinds[index] = statementKind
                endStatement()
                index += 1
                continue
            }
            if statementStart == nil {
                index = beginStatement(index)
                continue
            }
            let before = index
            let depth = frames.count
            afterOperand[index] = frame.operand == .complete
            index = step(index)
            for covered in before..<min(index, tokens.count) { statementKinds[covered] = statementKind }
            // An `end` that did not close the CASE around it (a name, a value, `end.a`) makes that CASE ambiguous.
            if isEnd[before], roles[before] != .caseEnd, depth <= frames.count, !frames[depth - 1].cases.isEmpty {
                frames[depth - 1].cases[frames[depth - 1].cases.count - 1].ambiguous = true
            }
        }
    }

    mutating func endStatement() {
        frames = [Frame(kind: .statement, context: .unknown)]
        statementStart = nil
        statementKind = .other
        nameNext = false
        insertCallPending = false
        createNameEnd = false
        createKind = ""
    }

    // MARK: Statements

    mutating func beginStatement(_ index: Int) -> Int {
        statementStart = index
        frames = [Frame(kind: .statement, context: .unknown)]
        let first = word(index)
        let end: Int
        if isPunctuation(index, "(") {
            statementKind = .query
            frame.query = true
            frame.context = .expression
            end = step(index)
        } else if let first, Vocabulary.statementWords.contains(first) {
            end = beginCommand(index, first)
        } else {
            statementKind = .other
            end = step(index)
        }
        for covered in index..<min(max(end, index + 1), tokens.count) { statementKinds[covered] = statementKind }
        return max(end, index + 1)
    }

    /// The first word of a statement (or of the statement after EXPLAIN) and its fixed head.
    mutating func beginCommand(_ index: Int, _ first: String) -> Int {
        switch first {
        case "SELECT":
            statementKind = statementKind == .explain ? .explain : .query
            return beginSelect(index, proven: true)
        case "WITH":
            statementKind = statementKind == .explain ? .explain : .query
            return beginWith(index, proven: true)
        case "INSERT":
            statementKind = .insert
            mark(index, .statement, changeable: true)
            var cursor = next(index)
            if word(cursor) == "INTO", let into = cursor {
                mark(into, .continuation, changeable: true)
                cursor = next(into)
                if let kind = cursor, word(kind) == "TABLE" || word(kind) == "FUNCTION", startsName(next(kind)) {
                    mark(kind, .continuation, changeable: true)
                    insertCallPending = word(kind) == "FUNCTION"
                    cursor = next(kind)
                }
            }
            frame.context = .expression
            expectOperand()
            nameNext = true
            return cursor ?? tokens.count
        case "DELETE":
            statementKind = .delete
            mark(index, .statement, changeable: true)
            var cursor = next(index)
            if word(cursor) == "FROM", let from = cursor {
                mark(from, .continuation, changeable: true)
                cursor = next(from)
            }
            frame.context = .expression
            expectOperand()
            nameNext = true
            return cursor ?? tokens.count
        case "UPDATE":
            statementKind = .update
            mark(index, .statement, changeable: true)
            frame.context = .expression
            expectOperand()
            nameNext = true
            return next(index) ?? tokens.count
        case "CREATE", "ATTACH", "DETACH", "DROP", "UNDROP", "EXISTS", "TRUNCATE", "ALTER", "RENAME", "OPTIMIZE", "CHECK",
             "DESCRIBE", "DESC", "SHOW":
            if first == "CREATE" || first == "ATTACH" { statementKind = .create } else if statementKind != .explain { statementKind = .other }
            mark(index, .statement, changeable: true)
            return objectHead(after: index, command: first)
        case "EXPLAIN":
            statementKind = .explain
            mark(index, .statement, changeable: true)
            return explainHead(after: index)
        case "KILL":
            statementKind = .other
            mark(index, .statement, changeable: true)
            frame.context = .expression
            var cursor = next(index)
            if let kind = cursor, word(kind) == "QUERY" || word(kind) == "MUTATION" {
                mark(kind, .continuation, changeable: true)
                cursor = next(kind)
                if let whereIndex = cursor, word(whereIndex) == "WHERE" {
                    mark(whereIndex, .clause(.where), changeable: true)
                    frame.clause = .where
                    cursor = next(whereIndex)
                }
            }
            expectOperand()
            return cursor ?? tokens.count
        default:
            // USE, SET, SYSTEM, GRANT, REVOKE, …: the first word only.
            if statementKind != .explain { statementKind = .other }
            mark(index, .statement, changeable: true)
            frame.context = .unknown
            expectOperand()
            nameNext = first == "USE"
            return next(index) ?? tokens.count
        }
    }

    /// `CREATE [OR REPLACE] [TEMPORARY] [MATERIALIZED|LIVE] TABLE [IF NOT EXISTS] name`, `DROP TABLE [IF EXISTS] name`,
    /// `SHOW CREATE TABLE name`, `SHOW TABLES`, `ALTER TABLE name`, …: the words before the name.
    mutating func objectHead(after index: Int, command: String) -> Int {
        var cursor = next(index)
        frame.context = command == "CREATE" || command == "ATTACH" ? .definition : .unknown
        expectOperand()
        if command == "SHOW" {
            if let target = cursor, word(target) == "CREATE" {
                mark(target, .continuation, changeable: true)
                cursor = next(target)
                if let temporary = cursor, word(temporary) == "TEMPORARY", startsName(next(temporary)) {
                    mark(temporary, .continuation, changeable: true)
                    cursor = next(temporary)
                }
            } else if let target = cursor, let targetWord = word(target), Vocabulary.showTargets.contains(targetWord) {
                mark(target, .continuation, changeable: true)
                frame.context = .unknown
                operandComplete()
                return next(target) ?? tokens.count
            } else {
                return cursor ?? tokens.count
            }
        }
        if command == "CREATE", let or = cursor, word(or) == "OR", let replace = next(or), word(replace) == "REPLACE" {
            mark(or, .continuation, changeable: true)
            mark(replace, .continuation, changeable: true)
            cursor = next(replace)
        }
        if let temporary = cursor, word(temporary) == "TEMPORARY", let after = next(temporary), word(after) != nil {
            mark(temporary, .continuation, changeable: true)
            cursor = after
        }
        if command == "CREATE" || command == "ATTACH", let modifier = cursor, word(modifier) == "MATERIALIZED" || word(modifier) == "LIVE",
           word(next(modifier)) == "VIEW" {
            mark(modifier, .continuation, changeable: true)
            cursor = next(modifier)
        }
        // The object kind is a keyword when a name (or IF [NOT] EXISTS) follows.
        if let kind = cursor, let kindWord = word(kind), Vocabulary.objectKinds.contains(kindWord), startsName(next(kind)) {
            mark(kind, .continuation, changeable: true)
            createKind = kindWord
            cursor = next(kind)
        }
        if let ifIndex = cursor, word(ifIndex) == "IF" {
            if let not = next(ifIndex), word(not) == "NOT", let exists = next(not), word(exists) == "EXISTS", startsName(next(exists)) {
                for phrase in [ifIndex, not, exists] { mark(phrase, .continuation, changeable: true) }
                cursor = next(exists)
            } else if let exists = next(ifIndex), word(exists) == "EXISTS", startsName(next(exists)) {
                for phrase in [ifIndex, exists] { mark(phrase, .continuation, changeable: true) }
                cursor = next(exists)
            }
        }
        nameNext = true
        createNameEnd = command == "CREATE" || command == "ATTACH"
        return cursor ?? tokens.count
    }

    /// `EXPLAIN [kind] [setting = value, …]` before the explained statement.
    mutating func explainHead(after index: Int) -> Int {
        var cursor = next(index)
        if let kind = cursor, let kindWord = word(kind), Vocabulary.explainKinds.contains(kindWord), !isOperator(next(kind), "=") {
            mark(kind, .continuation, changeable: true)
            cursor = next(kind)
        }
        // Settings: name = value pairs separated by commas.
        while let name = cursor, word(name) != nil, isOperator(next(name), "="), let value = next(next(name) ?? tokens.count) {
            cursor = next(value)
            if isPunctuation(cursor, ","), let comma = cursor { cursor = next(comma) }
        }
        guard let statement = cursor else { return tokens.count }
        if let first = word(statement), Vocabulary.statementWords.contains(first), first != "EXPLAIN" {
            frames = [Frame(kind: .statement, context: .unknown)]
            return beginCommand(statement, first)
        }
        if isPunctuation(statement, "(") {
            frame.query = true
            frame.context = .expression
            expectOperand()
        }
        return statement
    }

    // MARK: Queries

    mutating func beginSelect(_ index: Int, proven: Bool) -> Int {
        mark(index, .clause(.select), changeable: proven)
        frame.query = true
        frame.clause = .select
        frame.context = .select
        frame.inFrom = false
        frame.expectQuery = false
        frame.cases = []
        expectOperand()
        var cursor = next(index)
        if let modifier = cursor, word(modifier) == "DISTINCT" || word(modifier) == "ALL" {
            let after = next(modifier)
            if word(modifier) == "DISTINCT", word(after) == "ON", isPunctuation(next(after ?? tokens.count), "("), let on = after {
                mark(modifier, .continuation, changeable: proven)
                mark(on, .continuation, changeable: proven)
                cursor = next(on)
                if let open = cursor {
                    let end = step(open) // the ON list
                    frame.closesToExpected = true
                    return end
                }
            } else if startsOperand(after) || isOperator(after, "*") || isOperator(after, "-") {
                mark(modifier, .continuation, changeable: proven)
                cursor = after
            }
        }
        return cursor ?? tokens.count
    }

    mutating func beginWith(_ index: Int, proven: Bool) -> Int {
        mark(index, .clause(.with), changeable: proven)
        frame.query = true
        frame.clause = .with
        frame.context = .expression
        frame.expectQuery = false
        expectOperand()
        return next(index) ?? tokens.count
    }

    /// `(` followed by a query: `(SELECT …`, `(WITH x AS …`. A lone `(select)` or `(select, 1)` is a name in parentheses.
    func opensSubquery(_ open: Int) -> Bool {
        guard let first = next(open), let firstWord = word(first) else { return false }
        if isPunctuation(first, "(") { return false }
        let after = next(first)
        switch firstWord {
        case "SELECT":
            guard let after else { return false }
            if isOperator(after, "*") { return true }
            if word(after) == "DISTINCT" || word(after) == "ALL" { return true }
            switch tokens[after].kind {
            case .identifier, .quotedIdentifier, .number, .string, .parameter: return true
            case .keyword: return !Vocabulary.operatorWords.contains(words[after]) && !Vocabulary.neverColumnAlias.contains(words[after])
            case .punctuation: return words[after] == "(" || words[after] == "["
            default: return false
            }
        case "WITH":
            // A WITH list ends in the query's SELECT at this level.
            return withListEndsInSelect(first)
        default:
            return false
        }
    }

    /// A query starts at `index`: SELECT or WITH, possibly inside parentheses that open a subquery (`((SELECT 1))`).
    func startsQuery(_ index: Int?) -> Bool {
        guard var cursor = index else { return false }
        while isPunctuation(cursor, "("), let inner = next(cursor), isPunctuation(inner, "(") { cursor = inner }
        if isPunctuation(cursor, "(") { return opensSubquery(cursor) }
        guard let first = word(cursor), Vocabulary.queryStarts.contains(first) else { return false }
        return first == "SELECT" || withListEndsInSelect(cursor)
    }

    /// The WITH at `index` is followed, at its own level, by the SELECT of its query.
    func withListEndsInSelect(_ index: Int) -> Bool {
        var cursor = index
        while let following = next(cursor) {
            if tokens[following].kind == .punctuation {
                switch words[following] {
                case "(", "[", "{":
                    // Skip the nested text; nothing after an unclosed bracket is at this level.
                    guard matching[following] >= 0 else { return false }
                    cursor = matching[following]
                    continue
                case ")", "]", "}", ";":
                    return false
                default:
                    break
                }
            } else if word(following) == "SELECT" {
                return true
            }
            cursor = following
        }
        return false
    }

    func previousSignificant(_ index: Int) -> Int? {
        var cursor = index - 1
        while cursor >= 0 {
            if tokens[cursor].kind != .comment { return cursor }
            cursor -= 1
        }
        return nil
    }

    // MARK: Tokens

    mutating func step(_ index: Int) -> Int {
        switch tokens[index].kind {
        case .punctuation: return punctuation(index)
        case .operator: return operatorToken(index)
        case .keyword, .identifier:
            guard isWord[index] else {
                plainOperand()
                return index + 1
            }
            return wordToken(index)
        case .quotedIdentifier:
            if frame.operand == .complete, aliasRefusals != nil, !frame.aliased, !nameNext {
                frame.aliased = true // `SELECT 1 "x"`
                return index + 1
            }
            plainOperand()
            return index + 1
        case .number, .string, .parameter:
            plainOperand()
            return index + 1
        case .comment:
            return index + 1
        }
    }

    mutating func plainOperand() {
        nameNext = false
        frame.atCallStart = false
        if frame.operand == .expected { operandComplete() } else { frame.operand = .unknown }
    }

    mutating func punctuation(_ index: Int) -> Int {
        let text = words[index]
        nameNext = false
        switch text {
        case "(":
            let wasComplete = frame.operand == .complete
            let enclosing = frame
            var child: Frame
            if opensSubquery(index) {
                roles[index] = .subqueryOpen
                child = Frame(kind: .subquery, context: .expression)
            } else if createNameEnd, enclosing.kind == .statement, ["TABLE", "DICTIONARY", "VIEW"].contains(createKind) {
                roles[index] = .columnListOpen
                child = Frame(kind: .columns, context: .definition)
            } else if statementKind == .insert, enclosing.kind == .statement, !enclosing.query, enclosing.clause == nil, wasComplete,
                      !insertCallPending {
                // `INSERT INTO t (a, b)`: column names, whatever they spell.
                child = Frame(kind: .parens, context: .data)
            } else if wasComplete {
                child = Frame(kind: .call, context: Self.childContext(of: enclosing.context))
                child.atCallStart = true
            } else {
                child = Frame(kind: .parens, context: Self.childContext(of: enclosing.context))
            }
            createNameEnd = false
            if statementKind == .insert, enclosing.kind == .statement { insertCallPending = false }
            frames.append(child)
            if child.kind == .columns { nameNext = true } // a column (or INDEX, PROJECTION, …) name
            if child.kind == .subquery, let first = next(index) {
                return word(first) == "SELECT" ? beginSelect(first, proven: true) : beginWith(first, proven: true)
            }
            return index + 1
        case ")", "]", "}":
            guard frames.count > 1 else {
                frame.operand = .unknown
                return index + 1
            }
            // `DISTINCT ON (a) b`: the list after the parentheses starts a new item.
            if frames.removeLast().closesToExpected { expectOperand() } else { operandComplete() }
            return index + 1
        case "[":
            createNameEnd = false
            frames.append(Frame(kind: .brackets, context: Self.childContext(of: frame.context)))
            return index + 1
        case "{":
            createNameEnd = false
            frames.append(Frame(kind: .braces, context: .data))
            return index + 1
        case ",":
            createNameEnd = false
            expectOperand()
            // The next column definition, setting or window starts with its name.
            if frame.kind == .columns || frame.context == .settings || frame.clause == .window { nameNext = true }
            frame.fill = false
            frame.sampleOpen = false
            frame.betweenPending = 0
            frame.betweenChangeable = []
            if frame.kind == .statement || frame.kind == .subquery, frame.clause == .from { frame.joinPending = false }
            return index + 1
        case ".":
            nameNext = true
            frame.operand = frame.operand == .unknown ? .unknown : .expected
            return index + 1
        default:
            frame.operand = .unknown
            return index + 1
        }
    }

    /// Parentheses inside a statement not understood here stay not understood; data stays data.
    static func childContext(of context: Context) -> Context {
        switch context {
        case .unknown: .unknown
        case .data: .data
        default: .expression
        }
    }

    mutating func operatorToken(_ index: Int) -> Int {
        let text = words[index]
        nameNext = false
        createNameEnd = false
        frame.atCallStart = false
        switch text {
        case "*":
            if frame.operand == .expected {
                operandComplete()
                frame.afterAsterisk = true
            } else {
                expectOperand()
            }
        case "-", "+":
            if frame.operand != .expected { expectOperand() }
        case "::":
            expectOperand()
            nameNext = true
        case "=", "==", "!=", "<>", "<", ">", "<=", ">=", "<=>", "/", "%", "||", "->", "?", ":":
            expectOperand()
        default:
            frame.operand = .unknown
        }
        return index + 1
    }

    mutating func wordToken(_ index: Int) -> Int {
        let word = words[index]
        if nameNext {
            // After `.`, `::`, AS, FORMAT, a statement head: a name, whatever it spells.
            nameNext = false
            if frame.operand == .expected { operandComplete() } else { frame.operand = .unknown }
            return index + 1
        }
        if let close = windowFrames[index] {
            // A window frame validated by `markWindowFrame`.
            operandComplete()
            return close
        }
        switch frame.context {
        case .data:
            plainOperand()
            return index + 1
        case .unknown:
            return localWord(index, word)
        default:
            break
        }
        switch frame.operand {
        case .expected: return wordInOperandPosition(index, word)
        case .complete: return wordAfterOperand(index, word)
        case .unknown:
            if frame.expectQuery, word == "SELECT" { return beginSelect(index, proven: true) }
            return index + 1
        }
    }

    // MARK: Statements not understood

    /// In a statement whose structure is not modelled (ALTER, SYSTEM, GRANT, …) an operator word counts only between
    /// plain operands (a name that is not a keyword, a literal, a parameter), and never after FROM / JOIN, where a table
    /// alias could have been written (`and`, `or`, `in`, `is` are valid aliases).
    mutating func localWord(_ index: Int, _ word: String) -> Int {
        let following = next(index)
        // Only for spacing (`x=1` → `x = 1`); case decisions here use the neighbours directly.
        frame.operand = isPlainOperand(index) ? .complete : .unknown
        if word == "FROM" || word == "JOIN" { frame.sawTableClause = true }
        guard !frame.sawTableClause else { return index + 1 }
        let previous = previousSignificant(index)
        let between = isPlainOperand(previous) && isPlainOperand(following)
        // `ALTER TABLE t ON CLUSTER c …`
        if word == "ON", frame.kind == .statement, self.word(following) == "CLUSTER", let cluster = following,
           startsName(next(cluster)), previous.map({ startsName($0) || isPunctuation($0, ")") }) == true {
            mark(index, .keyword, changeable: true)
            mark(cluster, .continuation, changeable: true)
            nameNext = true
            return cluster + 1
        }
        switch word {
        case "AND", "OR", "IN", "LIKE", "ILIKE", "BETWEEN":
            if between || word == "IN" && isPlainOperand(previous) && isPunctuation(following, "(") {
                mark(index, .keyword, changeable: true)
            }
        case "NOT":
            if isPlainOperand(previous), let operatorIndex = following, let operatorWord = self.word(operatorIndex),
               ["IN", "LIKE", "ILIKE", "BETWEEN"].contains(operatorWord) {
                mark(index, .keyword, changeable: true)
                mark(operatorIndex, .continuation, changeable: true)
                return operatorIndex + 1
            }
        case "IS":
            guard isPlainOperand(previous) else { break }
            var cursor = following
            var phrase = [index]
            if self.word(cursor) == "NOT", let not = cursor {
                phrase.append(not)
                cursor = next(not)
            }
            if self.word(cursor) == "NULL", let null = cursor {
                for part in phrase + [null] { mark(part, part == index ? .keyword : .continuation, changeable: true) }
                return null + 1
            }
        case "INTERVAL":
            if !isPunctuation(previous, "."), let amount = following, [.number, .string, .parameter].contains(tokens[amount].kind),
               let unit = next(amount), let unitWord = self.word(unit), Vocabulary.intervalUnits.contains(unitWord) {
                mark(index, .keyword, changeable: true)
                mark(unit, .keyword, changeable: true)
                return unit + 1
            }
        default:
            break
        }
        return index + 1
    }

    // MARK: Operand position

    mutating func wordInOperandPosition(_ index: Int, _ word: String) -> Int {
        let following = next(index)
        let atCallStart = frame.atCallStart
        frame.atCallStart = false
        if frame.expectQuery {
            if word == "SELECT" { return beginSelect(index, proven: true) }
            if word == "WITH" { return beginWith(index, proven: true) }
        }
        // `CASE WHEN`: the first WHEN directly after CASE.
        if word == "WHEN", let open = frame.cases.last, open.words.count == 1, previousSignificant(index) == open.start,
           let end = caseWord(index, word) {
            return end
        }
        if frame.kind == .window, let end = windowWord(index, word, following: following) { return end }
        // A table, a table function or a join's table: a name, whatever it spells.
        if frame.context == .tables {
            operandComplete()
            return index + 1
        }
        switch word {
        case "NOT":
            // `NOT a`: the operator (ClickHouse tries it before a name); `not(x)` / `not (x)` keep their spelling.
            mark(index, .keyword, changeable: isPlainOperand(following))
            return index + 1
        case "CASE":
            if self.word(following) == "WHEN" || isPlainOperand(following) || isPunctuation(following, "(") {
                frame.cases.append(OpenCase(start: index, words: [index]))
                expectOperand()
                return index + 1
            }
        case "INTERVAL":
            if let amount = following, [.number, .string, .parameter].contains(tokens[amount].kind),
               let unit = next(amount), let unitWord = self.word(unit), Vocabulary.intervalUnits.contains(unitWord) {
                mark(index, .keyword, changeable: true)
                mark(unit, .keyword, changeable: true)
                operandComplete()
                return unit + 1
            }
        case "NULL", "TRUE", "FALSE":
            if !isPunctuation(following, "("), !isPunctuation(following, ".") {
                mark(index, .keyword, changeable: true)
                operandComplete()
                return index + 1
            }
        case "DISTINCT", "ALL":
            // `count(DISTINCT x)`; `count(distinct)` is a column.
            if atCallStart, isPlainOperand(following) {
                mark(index, .keyword, changeable: true)
                return index + 1
            }
        default:
            break
        }
        // A name, a function or a literal keyword used as a value.
        operandComplete()
        return index + 1
    }

    // MARK: After an operand

    mutating func wordAfterOperand(_ index: Int, _ word: String) -> Int {
        let following = next(index)
        let proven = isProvenAfterOperand(word)

        if let end = caseWord(index, word) { return end }

        // The AND of BETWEEN.
        if word == "AND", frame.betweenPending > 0 {
            frame.betweenPending -= 1
            let betweenProven = frame.betweenChangeable.popLast() ?? false
            mark(index, .betweenAnd, changeable: betweenProven)
            expectOperand()
            return index + 1
        }

        if word == "OVER", let end = over(index, following: following) { return end }
        if frame.kind == .window, let end = windowWord(index, word, following: following) { return end }
        if frame.query, let end = queryClause(index, word, following: following, proven: proven) { return end }
        if let end = statementClause(index, word, following: following) { return end }
        if let end = operatorWord(index, word, following: following, proven: proven) { return end }

        // An implicit alias (`SELECT count() c`, `FROM t x`).
        if let refusals = aliasRefusals, frame.context != .unknown, frame.context != .data, !frame.aliased,
           !refusals.contains(word), !Vocabulary.operatorWords.contains(word) {
            frame.aliased = true
            return index + 1
        }
        // Not understood: nothing after it is judged until the structure is clear again.
        frame.operand = .unknown
        return index + 1
    }

    /// WHEN / THEN / ELSE / END of the innermost CASE of this frame. Committed when the END is found.
    mutating func caseWord(_ index: Int, _ word: String) -> Int? {
        guard var open = frame.cases.last else { return nil }
        switch word {
        case "WHEN":
            open.whens += 1
            open.branches += 1
            roles[index] = .caseWhen
        case "THEN":
            roles[index] = .caseThen
        case "ELSE":
            open.branches += 1
            roles[index] = .caseElse
        case "END":
            frame.cases.removeLast()
            roles[index] = .caseEnd
            // A CASE that closes inside an ambiguous one may close a different one on some server: ambiguous too.
            if open.ambiguous, !frame.cases.isEmpty { frame.cases[frame.cases.count - 1].ambiguous = true }
            if open.whens > 0, !open.ambiguous, caseCountsBalanced[index] {
                roles[open.start] = .caseStart
                for caseIndex in open.words + [index] where Vocabulary.changeableWords.contains(words[caseIndex]) {
                    changeable[caseIndex] = true
                }
                cases[open.start] = SQLFormatAnalysis.CaseShape(end: index, branches: open.branches)
            } else {
                for caseIndex in open.words + [index] { roles[caseIndex] = .none }
            }
            operandComplete()
            return index + 1
        default:
            return nil
        }
        open.words.append(index)
        frame.cases[frame.cases.count - 1] = open
        frame.betweenPending = 0
        frame.betweenChangeable = []
        expectOperand()
        return index + 1
    }

    /// Operators after an operand: AND, OR, [NOT] IN/LIKE/ILIKE/BETWEEN, GLOBAL [NOT] IN, IS [NOT] NULL, AS.
    mutating func operatorWord(_ index: Int, _ word: String, following: Int?, proven: Bool) -> Int? {
        // Where a table alias may stand, `and`, `or`, `in`, `is` are valid aliases (and no operator applies).
        let inTables = frame.context == .tables && frame.cases.isEmpty
        // In statements not understood here, an operator only counts between plain operands, and never where a
        // table alias could have been written (a FROM was seen).
        let local = frame.context == .unknown || frame.context == .definition
        let localProof = !frame.sawTableClause && isPlainOperand(previousSignificant(index)) && startsOperand(following)
        let operatorProven = proven && (!local || localProof)
        switch word {
        case "AND", "OR":
            guard !inTables else { return nil }
            let conditionClauses: [Clause] = [.where, .prewhere, .having, .qualify]
            let inCondition = frame.clause.map(conditionClauses.contains) ?? (frame.inFrom && frame.joinPending)
            mark(index, frame.cases.isEmpty && frame.betweenPending == 0 && inCondition ? .condition : .keyword, changeable: operatorProven)
            expectOperand()
            return index + 1
        case "IN", "LIKE", "ILIKE":
            guard !inTables || word != "IN" else { return nil }
            mark(index, .keyword, changeable: operatorProven)
            expectOperand()
            return index + 1
        case "BETWEEN":
            mark(index, .keyword, changeable: operatorProven)
            frame.betweenPending += 1
            frame.betweenChangeable.append(operatorProven)
            expectOperand()
            return index + 1
        case "NOT":
            guard let operatorIndex = following, let operatorText = self.word(operatorIndex),
                  ["IN", "LIKE", "ILIKE", "BETWEEN"].contains(operatorText) else { return nil }
            mark(index, .keyword, changeable: operatorProven)
            mark(operatorIndex, .continuation, changeable: operatorProven)
            if operatorText == "BETWEEN" {
                frame.betweenPending += 1
                frame.betweenChangeable.append(operatorProven)
            }
            expectOperand()
            return operatorIndex + 1
        case "GLOBAL":
            guard let afterGlobal = following else { return nil }
            if self.word(afterGlobal) == "IN" {
                mark(index, .keyword, changeable: operatorProven)
                mark(afterGlobal, .continuation, changeable: operatorProven)
                expectOperand()
                return afterGlobal + 1
            }
            if self.word(afterGlobal) == "NOT", let inIndex = next(afterGlobal), self.word(inIndex) == "IN" {
                for phrase in [index, afterGlobal, inIndex] { mark(phrase, phrase == index ? .keyword : .continuation, changeable: operatorProven) }
                expectOperand()
                return inIndex + 1
            }
            return nil
        case "IS":
            // `IS [NOT] NULL`, `IS [NOT] DISTINCT FROM`: `is` alone is a valid alias.
            var cursor = following
            var phrase = [index]
            if self.word(cursor) == "NOT", let not = cursor {
                phrase.append(not)
                cursor = next(not)
            }
            if self.word(cursor) == "NULL", let null = cursor {
                phrase.append(null)
                for part in phrase { mark(part, part == index ? .keyword : .continuation, changeable: !local || localProof) }
                operandComplete()
                return null + 1
            }
            if self.word(cursor) == "DISTINCT", let distinct = cursor, let from = next(distinct), self.word(from) == "FROM" {
                phrase += [distinct, from]
                for part in phrase { mark(part, part == index ? .keyword : .continuation, changeable: !local || localProof) }
                expectOperand()
                return from + 1
            }
            return nil
        case "AS":
            mark(index, .keyword, changeable: local ? !frame.sawTableClause : proven)
            expectOperand()
            if let open = following, isPunctuation(open, "(") {
                // `WINDOW w AS (…)`; a CTE's `x AS (SELECT …)` opens as a subquery.
                if frame.clause == .window { return openWindow(open) }
            } else {
                nameNext = true
            }
            return index + 1
        case "DIV", "MOD", "REGEXP":
            roles[index] = .keyword
            expectOperand()
            return index + 1
        default:
            return nil
        }
    }

    /// Clause words of a query after an operand.
    mutating func queryClause(_ index: Int, _ word: String, following: Int?, proven: Bool) -> Int? {
        let followingWord = self.word(following)
        // The main query after a WITH list.
        if frame.clause == .with, frame.cases.isEmpty {
            if word == "SELECT" { return beginSelect(index, proven: true) }
        }
        if frame.inFrom, let end = fromClause(index, word, following: following, proven: proven) { return end }
        if frame.clause == .orderBy, let end = orderModifier(index, word, following: following) { return end }

        switch word {
        case "FROM":
            if frame.fill { return nil }
            startClause(index, .from, context: .tables, proven: proven)
            frame.inFrom = true
            frame.sawTableClause = true
            return index + 1
        case "PREWHERE", "WHERE", "HAVING", "QUALIFY":
            let clause: Clause = word == "PREWHERE" ? .prewhere : word == "WHERE" ? .where : word == "HAVING" ? .having : .qualify
            startClause(index, clause, context: .expression, proven: proven)
            return index + 1
        case "GROUP", "ORDER":
            guard followingWord == "BY", let by = following else { return nil }
            startClause(index, word == "GROUP" ? .groupBy : .orderBy, context: word == "GROUP" ? .expression : .orderBy, proven: proven)
            mark(by, .continuation, changeable: proven)
            return by + 1
        case "LIMIT":
            startClause(index, .limit, context: .expression, proven: proven)
            return index + 1
        case "BY":
            guard frame.clause == .limit else { return nil }
            mark(index, .continuation, changeable: true)
            expectOperand()
            return index + 1
        case "OFFSET":
            startClause(index, .offset, context: .expression, proven: proven)
            return index + 1
        case "SETTINGS":
            startClause(index, .settings, context: .settings, proven: proven)
            return index + 1
        case "FORMAT":
            startClause(index, .format, context: .expression, proven: proven)
            return formatName(after: index)
        case "UNION", "EXCEPT", "INTERSECT":
            if word == "EXCEPT", frame.afterAsterisk, isPunctuation(following, "(") && !opensSubquery(following ?? 0) || isPlainOperand(following) {
                mark(index, .keyword, changeable: proven) // `* EXCEPT (a)`: a column transformer
                frame.operand = .expected
                frame.closesToExpected = false
                return index + 1
            }
            // A set operator needs a query after it: `from (select 1 a) except (x)` is no set operation.
            let modifier = followingWord == "ALL" || followingWord == "DISTINCT" ? following : nil
            guard startsQuery(modifier.flatMap(next) ?? following) else { return nil }
            startClause(index, .setOperation, context: .expression, proven: proven)
            var end = index + 1
            if let modifier {
                mark(modifier, .continuation, changeable: proven)
                end = modifier + 1
            }
            frame.query = true
            frame.expectQuery = true
            frame.inFrom = false
            return end
        case "WINDOW":
            startClause(index, .window, context: .expression, proven: proven)
            return index + 1
        case "INTO":
            guard followingWord == "OUTFILE", let outfile = following else { return nil }
            startClause(index, .into, context: .expression, proven: proven)
            mark(outfile, .continuation, changeable: proven)
            return outfile + 1
        case "AND":
            guard frame.clause == .into, followingWord == "STDOUT", let stdout = following else { return nil }
            mark(index, .keyword, changeable: true)
            mark(stdout, .continuation, changeable: true)
            operandComplete()
            return stdout + 1
        case "WITH":
            guard let modifier = following, let modifierWord = followingWord else { return nil }
            switch modifierWord {
            case "TOTALS", "ROLLUP", "CUBE":
                guard frame.clause == .groupBy || frame.clause == .select || frame.clause == .having || frame.clause == .where
                    || frame.inFrom else { return nil }
            case "FILL":
                guard frame.clause == .orderBy else { return nil }
                frame.fill = true
            case "TIES":
                guard frame.clause == .limit else { return nil }
            default:
                return nil
            }
            mark(index, .keyword, changeable: proven)
            mark(modifier, .continuation, changeable: proven)
            operandComplete()
            return modifier + 1
        default:
            return nil
        }
    }

    /// `f(x) OVER (…)` / `f(x) OVER w`: `over` alone after a value would be an alias.
    mutating func over(_ index: Int, following: Int?) -> Int? {
        guard isPunctuation(previousSignificant(index), ")") else { return nil }
        if isPunctuation(following, "("), let open = following {
            mark(index, .keyword, changeable: true)
            return openWindow(open)
        }
        if isPlainOperand(following), let name = following {
            mark(index, .keyword, changeable: true)
            operandComplete()
            return name + 1
        }
        return nil
    }

    /// PARTITION BY, ORDER BY and ORDER BY modifiers inside a window specification.
    mutating func windowWord(_ index: Int, _ word: String, following: Int?) -> Int? {
        if word == "PARTITION" || word == "ORDER", self.word(following) == "BY", let by = following {
            mark(index, .keyword, changeable: true)
            mark(by, .continuation, changeable: true)
            frame.clause = word == "ORDER" ? .orderBy : nil
            expectOperand()
            return by + 1
        }
        if frame.clause == .orderBy, frame.operand == .complete { return orderModifier(index, word, following: following) }
        return nil
    }

    mutating func startClause(_ index: Int, _ clause: Clause, context: Context, proven: Bool) {
        mark(index, .clause(clause), changeable: proven)
        frame.clause = clause
        frame.context = context
        frame.inFrom = false
        frame.joinPending = false
        frame.fill = false
        frame.sampleOpen = false
        frame.betweenPending = 0
        frame.betweenChangeable = []
        expectOperand()
        // A setting or a window definition starts with its name.
        if clause == .settings || clause == .window { nameNext = true }
    }

    /// The format name after FORMAT, and the inline data of an INSERT after it.
    mutating func formatName(after index: Int) -> Int {
        guard let name = next(index), startsName(name) else { return index + 1 }
        operandComplete()
        guard statementKind == .insert, !frame.query else { return name + 1 }
        var end = name + 1
        while end < tokens.count, !isPunctuation(end, ";") { end += 1 }
        data[name] = end
        return end
    }

    /// Tables, joins, ON / USING, FINAL, SAMPLE in a FROM clause.
    mutating func fromClause(_ index: Int, _ word: String, following: Int?, proven: Bool) -> Int? {
        if Vocabulary.joinWords.contains(word) || word == "JOIN", let end = joinEnd(from: index) {
            let chainProven = proven && word != "PASTE"
            mark(index, .join, changeable: chainProven)
            var cursor = index
            while cursor < end, let following = next(cursor) {
                cursor = following
                mark(following, .continuation, changeable: chainProven)
            }
            frame.clause = .from
            frame.context = .tables
            frame.joinPending = true
            frame.sampleOpen = false
            expectOperand()
            if words[index] == "ARRAY" || words[index] == "LEFT" && self.word(next(index)) == "ARRAY" {
                frame.context = .expression // ARRAY JOIN items: expressions with AS
            }
            return end + 1
        }
        switch word {
        case "ON", "USING":
            guard frame.joinPending else { return nil }
            mark(index, .joinCondition(on: word == "ON"), changeable: proven)
            frame.context = .expression
            frame.clause = nil
            frame.inFrom = true
            expectOperand()
            return index + 1
        case "FINAL":
            guard frame.context == .tables else { return nil }
            mark(index, .keyword, changeable: proven)
            operandComplete()
            frame.aliased = true
            return index + 1
        case "SAMPLE":
            guard frame.context == .tables else { return nil }
            mark(index, .keyword, changeable: proven)
            frame.sampleOpen = true
            expectOperand()
            frame.context = .expression
            return index + 1
        case "OFFSET":
            guard frame.sampleOpen else { return nil }
            mark(index, .keyword, changeable: proven)
            frame.sampleOpen = false
            expectOperand()
            return index + 1
        default:
            return nil
        }
    }

    /// The `JOIN` that completes a join operator starting at `index`.
    func joinEnd(from index: Int) -> Int? {
        if words[index] == "JOIN" { return index }
        var cursor = index
        var count = 0
        while let following = next(cursor), count < 6 {
            guard let followingWord = word(following) else { return nil }
            if followingWord == "JOIN" { return following }
            guard Vocabulary.joinWords.contains(followingWord) else { return nil }
            cursor = following
            count += 1
        }
        return nil
    }

    /// ASC / DESC, NULLS FIRST|LAST, COLLATE, WITH FILL FROM / TO / STEP after an ORDER BY item.
    mutating func orderModifier(_ index: Int, _ word: String, following: Int?) -> Int? {
        switch word {
        case "ASC", "DESC", "ASCENDING", "DESCENDING":
            mark(index, .keyword, changeable: true)
            return index + 1
        case "NULLS":
            guard let position = following, self.word(position) == "FIRST" || self.word(position) == "LAST" else { return nil }
            mark(index, .keyword, changeable: true)
            mark(position, .continuation, changeable: true)
            return position + 1
        case "COLLATE":
            guard frame.kind != .window, following.map({ tokens[$0].kind == .string }) == true else { return nil }
            mark(index, .keyword, changeable: true)
            expectOperand()
            return index + 1
        case "FROM", "TO", "STEP":
            guard frame.fill else { return nil }
            mark(index, .keyword, changeable: true)
            expectOperand()
            return index + 1
        default:
            return nil
        }
    }

    /// `OVER (…)` and `WINDOW w AS (…)`: PARTITION BY, ORDER BY with modifiers, and a complete frame.
    mutating func openWindow(_ open: Int) -> Int {
        var window = Frame(kind: .window, context: .window)
        window.clause = nil
        frames.append(window)
        guard let close = matchingClose(open) else { return open + 1 }
        // The frame (`ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`), all or nothing.
        markWindowFrame(open: open, close: close)
        return open + 1
    }

    func matchingClose(_ open: Int) -> Int? {
        open >= 0 && open < matching.count && matching[open] >= 0 ? matching[open] : nil
    }

    mutating func markWindowFrame(open: Int, close: Int) {
        // Find ROWS / RANGE at the window specification's own level (nested brackets are skipped whole).
        var cursor = open + 1
        var start: Int?
        while cursor < close {
            if tokens[cursor].kind == .punctuation, ["(", "[", "{"].contains(words[cursor]) {
                guard let inner = matchingClose(cursor) else { return }
                cursor = inner + 1
                continue
            }
            if let text = word(cursor), text == "ROWS" || text == "RANGE" {
                let previous = previousSignificant(cursor)
                let afterOperand = previous.map { isPlainOperand($0) || isPunctuation($0, ")") || isPunctuation($0, "]")
                    || ["ASC", "DESC", "ASCENDING", "DESCENDING", "FIRST", "LAST"].contains(word($0) ?? "") } ?? false
                if afterOperand || previous == open { start = cursor }
            }
            cursor += 1
        }
        guard let start else { return }
        var marked = [start]
        var position = next(start)
        func bound(_ index: Int?) -> (marks: [Int], end: Int)? {
            guard let index else { return nil }
            if word(index) == "UNBOUNDED", let direction = next(index), word(direction) == "PRECEDING" || word(direction) == "FOLLOWING" {
                return ([index, direction], direction)
            }
            if word(index) == "CURRENT", let row = next(index), word(row) == "ROW" { return ([index, row], row) }
            if isPlainOperand(index), let direction = next(index), word(direction) == "PRECEDING" || word(direction) == "FOLLOWING" {
                return ([direction], direction)
            }
            return nil
        }
        if word(position) == "BETWEEN", let between = position {
            marked.append(between)
            guard let lower = bound(next(between)), let and = next(lower.end), word(and) == "AND",
                  let upper = bound(next(and)) else { return }
            marked += lower.marks + [and] + upper.marks
            position = next(upper.end)
        } else {
            guard let single = bound(position) else { return }
            marked += single.marks
            position = next(single.end)
        }
        guard position == close else { return }
        windowFrames[start] = close
        for index in marked {
            roles[index] = .keyword
            if Vocabulary.changeableWords.contains(words[index]) { changeable[index] = true }
        }
    }

    // MARK: Statement clauses

    /// Words after an operand that belong to the statement rather than to a query: INSERT's SETTINGS / VALUES / FORMAT /
    /// query, CREATE's definition clauses, DELETE / UPDATE / ALTER heads, `ON CLUSTER`.
    mutating func statementClause(_ index: Int, _ word: String, following: Int?) -> Int? {
        let followingWord = self.word(following)
        guard frame.kind == .statement else { return nil }
        if word == "ON", followingWord == "CLUSTER", startsName(next(following ?? tokens.count)), let cluster = following,
           statementKind != .query, !frame.query {
            mark(index, .keyword, changeable: true)
            mark(cluster, .continuation, changeable: true)
            nameNext = true
            expectOperand()
            return cluster + 1
        }
        switch statementKind {
        case .insert where !frame.query:
            switch word {
            case "SETTINGS":
                startClause(index, .settings, context: .settings, proven: true)
                return index + 1
            case "VALUES":
                startClause(index, .values, context: .data, proven: true)
                return index + 1
            case "FORMAT":
                startClause(index, .format, context: .expression, proven: true)
                return formatName(after: index)
            case "SELECT":
                return beginSelect(index, proven: true)
            case "WITH":
                return beginWith(index, proven: true)
            default:
                return nil
            }
        case .delete, .update:
            switch word {
            case "WHERE":
                startClause(index, .where, context: .expression, proven: true)
                return index + 1
            case "SET" where statementKind == .update:
                startClause(index, .set, context: .expression, proven: true)
                return index + 1
            case "SETTINGS":
                startClause(index, .settings, context: .settings, proven: true)
                return index + 1
            default:
                return nil
            }
        case .create:
            return definitionClause(index, word, following: following)
        default:
            return nil
        }
    }

    /// Statement-level clauses of CREATE TABLE / VIEW / DICTIONARY / DATABASE.
    mutating func definitionClause(_ index: Int, _ word: String, following: Int?) -> Int? {
        let followingWord = self.word(following)
        var phrase = [index]
        switch word {
        case "ENGINE":
            // `ENGINE = Null`: the engine is a name (never the NULL literal).
            mark(index, .definitionClause, changeable: true)
            frame.context = .definition
            frame.clause = nil
            expectOperand()
            nameNext = true
            return isOperator(following, "=") ? (following ?? index) + 1 : index + 1
        case "PARTITION", "ORDER", "SAMPLE":
            guard followingWord == "BY", let by = following else { return nil }
            phrase.append(by)
        case "PRIMARY":
            guard followingWord == "KEY", let key = following else { return nil }
            phrase.append(key)
        case "TTL", "COMMENT", "SETTINGS":
            break
        case "TO", "POPULATE":
            // `CREATE MATERIALIZED VIEW mv TO dst …`, `… POPULATE AS SELECT`: written inline.
            guard createKind == "VIEW", word == "POPULATE" || startsName(following) else { return nil }
            mark(index, .keyword, changeable: true)
            expectOperand()
            if word == "TO" { nameNext = true } else { operandComplete() }
            return index + 1
        case "SOURCE", "LAYOUT", "LIFETIME", "RANGE":
            guard createKind == "DICTIONARY", isPunctuation(following, "(") else { return nil }
        case "AS":
            guard let target = following else { return nil }
            mark(index, .keyword, changeable: true)
            if followingWord == "SELECT" { return beginSelect(target, proven: true) }
            if followingWord == "WITH" { return beginWith(target, proven: true) }
            expectOperand()
            if !isPunctuation(target, "(") { nameNext = true }
            return index + 1
        default:
            return nil
        }
        mark(index, .definitionClause, changeable: true)
        for continuation in phrase.dropFirst() { mark(continuation, .continuation, changeable: true) }
        frame.context = .definition
        frame.clause = nil
        expectOperand()
        return (phrase.last ?? index) + 1
    }
}
