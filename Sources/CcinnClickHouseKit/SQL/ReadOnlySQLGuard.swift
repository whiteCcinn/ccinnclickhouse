import Foundation

/// Decides whether SQL is a single read-only statement (MCP read-only access and read-only profiles,
/// design D8/D11). Token-based (strings, quoted identifiers and comments cannot smuggle keywords) and
/// conservative (anything not clearly a read is rejected).
///
/// Read-only requests also carry `readonly=1`, but the app does not rely on it: some proxies (chproxy)
/// drop the parameter, and ClickHouse itself still runs `SYSTEM STOP MERGES` and `KILL` under
/// `readonly=1`. So the guard additionally refuses
/// - table functions outside an allow-list of local, side-effect-free ones (`url`, `file`, `remote`,
///   `s3`, `mysql`, … reach the network or the server's files: that is not "read-only" for an AI),
/// - external-access functions anywhere (also scalar `file()`),
/// - per-query `SETTINGS` clauses (they could lift `readonly` behind a proxy or widen limits).
public enum ReadOnlySQLGuard {
    /// `verb` followed by one of `objects` is a write wherever it appears (so `system.tables` or a column
    /// named `drop` stay allowed).
    static let forbiddenPairs: [String: Set<String>] = [
        "INSERT": ["INTO", "TABLE", "FUNCTION"],
        "ALTER": ["TABLE", "DATABASE", "USER", "ROLE", "QUOTA", "SETTINGS", "ROW", "POLICY", "NAMED", "TEMPORARY", "PROFILE", "SETTING"],
        "CREATE": ["TABLE", "DATABASE", "VIEW", "MATERIALIZED", "LIVE", "WINDOW", "DICTIONARY", "USER", "ROLE", "QUOTA", "SETTINGS", "ROW",
                   "POLICY", "FUNCTION", "TEMPORARY", "OR", "IF", "NAMED", "INDEX", "PROFILE", "SETTING"],
        "DROP": ["TABLE", "DATABASE", "VIEW", "DICTIONARY", "USER", "ROLE", "QUOTA", "SETTINGS", "ROW", "POLICY", "FUNCTION", "TEMPORARY",
                 "IF", "NAMED", "INDEX", "COLUMN", "PARTITION", "PART", "DETACHED", "PROJECTION", "CONSTRAINT", "PROFILE", "SETTING", "STATISTICS"],
        "TRUNCATE": ["TABLE", "DATABASE", "IF", "TEMPORARY", "ALL"],
        "OPTIMIZE": ["TABLE"],
        "KILL": ["QUERY", "MUTATION", "TRANSACTION"],
        "DELETE": ["FROM"],
        "ATTACH": ["TABLE", "DATABASE", "DICTIONARY", "PARTITION", "PART", "VIEW", "MATERIALIZED", "IF"],
        "DETACH": ["TABLE", "DATABASE", "DICTIONARY", "PARTITION", "PART", "VIEW", "IF"],
        "RENAME": ["TABLE", "DATABASE", "DICTIONARY", "COLUMN"],
        "EXCHANGE": ["TABLES", "DICTIONARIES"],
        "UNDROP": ["TABLE"],
        "REPLACE": ["TABLE", "DICTIONARY", "PARTITION"],
        "MOVE": ["PARTITION", "PART", "USER", "ROLE", "QUOTA"],
        "GRANT": [], "REVOKE": [], "BACKUP": [], "RESTORE": [],
    ]

    static let systemCommands: Set<String> = ["FLUSH", "RELOAD", "DROP", "STOP", "START", "SYNC", "RESTART", "KILL", "SHUTDOWN", "RESTORE",
                                              "UNFREEZE", "FREEZE", "WAIT", "ENABLE", "DISABLE", "REFRESH", "CANCEL", "LOAD", "UNLOAD",
                                              "PREWARM", "CLEAR", "SUSPEND", "NOTIFY", "RECONNECT"]

    /// Table functions the editor may use: generators, inline data, and local ones that read tables by name (the
    /// connection's readonly=1 and the user's grants govern what they read). From the reviewed catalog.
    static let allowedTableFunctions: Set<String> = AIFunctionCatalog.allowedTableFunctions.union(AIFunctionCatalog.reviewedLocalTableFunctions)

    /// Functions that reach the network, the server's file system, external processes, libraries or LLMs: refused in
    /// read-only mode wherever they are named (a call, APPLY, a higher-order argument). From the reviewed catalog.
    static let externalAccessFunctions: Set<String> = AIFunctionCatalog.externalTableFunctions.union(
        AIFunctionCatalog.denied.filter { $0.value.hasPrefix("reaches outside") }.keys.map { $0.lowercased() })

    /// Clause keywords that end a FROM list.
    static let fromListEnds: Set<String> = ["WHERE", "PREWHERE", "GROUP", "ORDER", "LIMIT", "HAVING", "SETTINGS", "FORMAT", "UNION", "EXCEPT",
                                            "INTERSECT", "ON", "USING", "WINDOW", "QUALIFY", "SAMPLE", "FINAL", "ARRAY", "SELECT", "INTO"]
    /// Of those, the ones after which a comma continues the FROM list (`JOIN b USING (n), f()`, `ON a = b, f()`).
    static let fromListPauses: Set<String> = ["ON", "USING", "SAMPLE", "FINAL"]

    /// First verbs of read statements.
    static let readVerbs: Set<String> = ["SELECT", "WITH", "(", "SHOW", "DESC", "DESCRIBE", "EXISTS"]
    /// Words allowed between `EXPLAIN` and the query.
    static let explainKinds: Set<String> = ["AST", "SYNTAX", "QUERY", "TREE", "PLAN", "PIPELINE", "ESTIMATE", "TABLE", "OVERRIDE", "CURRENT"]

    /// Letters whose upper, lower or title case holds an ASCII letter (`ſ` → `S`, `ı` → `I`, `K` → `k`, `ﬁ` → `FI`):
    /// exactly these 19, derived from Unicode and pinned by a test.
    static let asciiFoldingLetters: Set<Unicode.Scalar> = ["ß", "İ", "ı", "ŉ", "ſ", "ǰ", "ẖ", "ẗ", "ẘ", "ẙ", "ẚ", "\u{212A}", "ﬀ", "ﬁ", "ﬂ", "ﬃ",
                                                           "ﬄ", "ﬅ", "ﬆ"]

    /// Who will run the statement. AI access (MCP) reads `system` only through an allow-list (no other sessions' SQL
    /// text, no credentials; the redacted tools serve those), table functions, SHOW forms and EXPLAIN kinds through
    /// allow-lists too, and never object definitions, on any version. `database` is the database unqualified names
    /// resolve in.
    public enum Audience: Sendable, Equatable {
        case editor
        case ai(database: String?)
    }

    public struct Refusal: Error, Equatable, Sendable {
        public let reason: String
    }

    /// A statement exactly as it will be sent.
    public struct Prepared: Sendable, Equatable {
        /// The text to send, unchanged after the check.
        public let text: String
        /// The automatic LIMIT, when one was added.
        public let limit: AutoLimit.Outcome?
    }

    /// Builds the exact text to send for one read-only statement — `prefix` (an EXPLAIN head) and the statement, with
    /// the automatic LIMIT when `autoLimit` is given — and checks THAT text. Every client-side rewrite happens here,
    /// before the check, so nothing can change between what the guard saw and what the server runs (a LIMIT inserted
    /// after a bare `#` once turned it into a comment). The statement as written is checked first, for clearer reasons.
    public static func prepare(_ statement: String, prefix: String? = nil, autoLimit: Int? = nil, audience: Audience = .editor)
        -> Result<Prepared, Refusal> {
        // `USE db` in the editor (ClickHouse allows it at readonly=1; it only switches the session's database): the same
        // checkpoint, sent exactly as written. AI access has no sessions and refuses it below.
        if audience == .editor, SQLStatementKind.of(statement) == .use {
            if let reason = lexicalRefusal(statement) ?? useRefusal(statement, prefix: prefix) { return .failure(Refusal(reason: reason)) }
            return .success(Prepared(text: statement, limit: nil))
        }
        if let reason = check(statement, audience: audience) { return .failure(Refusal(reason: reason)) }
        var text = prefix.map { "\($0) \(statement)" } ?? statement
        var limit: AutoLimit.Outcome?
        if let autoLimit, prefix == nil, SQLStatementKind.of(text) == .query {
            let outcome = AutoLimit.apply(to: text, limit: autoLimit)
            if outcome.applied {
                text = outcome.sql
                limit = outcome
            }
        }
        if let reason = check(text, audience: audience) {
            return .failure(Refusal(reason: "As sent (with the automatic LIMIT or EXPLAIN head), the statement is refused: \(reason)"))
        }
        return .success(Prepared(text: text, limit: limit))
    }

    /// `nil` when allowed; otherwise the reason it is rejected.
    public static func check(_ sql: String, audience: Audience = .editor) -> String? {
        let statements = SQLStatementSplitter.split(sql)
        guard let statement = statements.first else { return "The statement is empty." }
        guard statements.count == 1 else { return "Only one statement can be run at a time; send statements separately." }
        let words = StatementWords(statement.text)
        guard let first = words.words.first else { return "The statement is empty." }
        if let reason = lexicalRefusal(sql) { return reason }
        if case let .ai(database) = audience, let reason = aiRefusal(words, database: database) { return reason }

        var queryStart = 0
        if first == "EXPLAIN" {
            guard let start = explainQueryStart(words) else { return "Only EXPLAIN of a SELECT query is allowed in read-only mode." }
            queryStart = start
        } else if !readVerbs.contains(first) {
            return rejection(first)
        } else if first == "SHOW", words.word(1) == "CREATE" {
            queryStart = 2 // SHOW CREATE TABLE/USER/… only prints a definition
        }
        return scan(words, from: queryStart, audience: audience) ?? functionRefusal(words, audience: audience)
    }

    // MARK: Functions

    /// Every function the statement calls or names (`FunctionReferences`). The editor refuses those that reach outside
    /// ClickHouse; AI access calls only reviewed functions (`AIFunctionCatalog`): a newer server's new functions are
    /// refused until a CcinnClickHouse update reviews them.
    static func functionRefusal(_ words: StatementWords, audience: Audience) -> String? {
        let found = FunctionReferences(words)
        if let reason = found.unresolvable { return reason }
        for reference in found.references {
            let lower = reference.name.lowercased()
            if reference.kind != .aggregateName, externalAccessFunctions.contains(lower) {
                return "`\(reference.name)` reads data outside ClickHouse (network, files, external systems, libraries or LLMs) and is not allowed in read-only mode."
            }
            if reference.kind == .call, audience == .editor, AIFunctionCatalog.aiRefusedTableFunctions.contains(lower) {
                return "The table function `\(reference.name)()` is not allowed in read-only mode."
            }
        }
        guard audience != .editor else { return nil }
        if let reason = found.aiUnresolvable { return reason }
        for reference in found.references {
            let allowed: Bool = switch reference.kind {
            case .call: isAllowedFunction(reference.name) || aiTableFunctions.contains(reference.name.lowercased())
            case .transformer, .higherOrderArgument: isAllowedFunction(reference.name)
            case .aggregateName: isAllowedAggregate(reference.name)
            }
            guard !allowed else { continue }
            return aiFunctionReason(reference)
        }
        return nil
    }

    private static func aiFunctionReason(_ reference: FunctionReferences.Reference) -> String {
        let name = reference.name
        let lower = name.lowercased()
        if aiRefusedTableFunctions.contains(lower) {
            return "`\(lower)()` reads other tables or databases by name; AI access may use only \(aiTableFunctions.sorted().joined(separator: ", "))."
        }
        if reference.kind == .aggregateName {
            return "`\(name)` is not a reviewed aggregate function; AI access names only reviewed aggregates in arrayReduce, arrayReduceInRanges and initializeAggregation."
        }
        if let reason = AIFunctionCatalog.denied.first(where: { $0.key.lowercased() == lower })?.value {
            return "AI access may not call `\(name)`: it \(reason)."
        }
        return "AI access calls only functions CcinnClickHouse has reviewed, and `\(name)` is not one of them (a newer server's functions are refused until an update reviews them)."
    }

    /// Longest function name worth looking up (combinator chains included); longer names are refused.
    static let maxFunctionNameLength = 128
    /// SQL-standard forms the parser accepts in any case though the function itself is case-sensitive.
    static let syntaxFunctions: Set<String> = ["extract", "trim"]

    /// Whether AI access may call `name`: a reviewed function (respecting case sensitivity), or a reviewed aggregate with
    /// any chain of combinator suffixes (`uniqArrayIfOrNull`).
    static func isAllowedFunction(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= maxFunctionNameLength else { return false }
        if AIFunctionCatalog.allowedCaseSensitive.contains(name) || AIFunctionCatalog.allowedCaseInsensitive.contains(name.lowercased())
            || syntaxFunctions.contains(name.lowercased()) {
            return true
        }
        return isAllowedAggregate(name)
    }

    /// A reviewed aggregate function, after stripping combinator suffixes (every reachable base is tried once).
    static func isAllowedAggregate(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= maxFunctionNameLength else { return false }
        var pending = [name]
        var seen: Set<String> = [name]
        while let candidate = pending.popLast() {
            if AIFunctionCatalog.aggregatesCaseSensitive.contains(candidate) || AIFunctionCatalog.aggregatesCaseInsensitive.contains(candidate.lowercased()) {
                return true
            }
            for combinator in AIFunctionCatalog.combinators where candidate.count > combinator.count && candidate.hasSuffix(combinator) {
                let base = String(candidate.dropLast(combinator.count))
                if seen.insert(base).inserted { pending.append(base) }
            }
        }
        return false
    }

    /// A data type family name (for `CAST(x AS T(…))` and `x::T(…)`).
    static func isDataType(_ name: String) -> Bool {
        AIFunctionCatalog.dataTypesCaseSensitive.contains(name) || AIFunctionCatalog.dataTypesCaseInsensitive.contains(name.lowercased())
    }

    /// `USE <name>` and nothing else (comments aside; a trailing `;` is fine).
    static func useRefusal(_ statement: String, prefix: String?) -> String? {
        guard prefix == nil else { return "Only EXPLAIN of a SELECT query is allowed in read-only mode." }
        let words = StatementWords(statement)
        var count = words.tokens.count
        if count == 3, words.isPunctuation(2, ";") { count = 2 }
        guard count == 2, words.word(0) == "USE", words.isName(1) else {
            return "On a read-only connection, USE takes exactly one database name: `USE db`."
        }
        return nil
    }

    /// Text the guard cannot read the way every supported server does — unterminated strings, quoted names and
    /// comments, invisible characters, a bare `#` or lone `$`, tokens a server could read with different bounds — is
    /// refused before anything else: a construct servers tokenize differently must make the guard stricter, never weaker.
    static func lexicalRefusal(_ sql: String) -> String? {
        let lexer = SQLLexer(sql)
        let tokens = lexer.tokens()
        if let last = tokens.last, lexer.isUnterminated(last) {
            return "The statement has an unterminated string, quoted name or comment."
        }
        // Servers skip U+00A0, U+FEFF, U+200B and more as whitespace: `1,\u{FEFF}file(` calls `file()`. Refused anywhere
        // outside strings, quoted names and comments, whatever the lexer makes of it.
        if let invisible = lexer.invisibleCharacter(in: tokens) {
            let code = String(invisible.scalar.value, radix: 16, uppercase: true)
            return "The statement contains an invisible character (U+\(String(repeating: "0", count: max(0, 4 - code.count)) + code)) outside strings, quoted names and comments; ClickHouse may read it as a space."
        }
        // `#` that starts no comment (no space or `!` after it) and `$` that opens no heredoc mean something else as soon
        // as text is added after them (`# ` is a comment, `$ …$` a heredoc).
        if let stray = tokens.first(where: { $0.kind == .operator && ["#", "$"].contains(lexer.text(of: $0)) }) {
            return "A bare `\(lexer.text(of: stray))` outside strings and comments is not allowed in read-only mode: its meaning depends on what follows it."
        }
        // ClickHouse does not fold `ı`, `ſ`, `İ`, `K` or `ﬁ`; Swift's case mapping (every name rule here) turns them into
        // ASCII letters, so `` system.`ſettings` `` would be judged as `settings`.
        let nameKinds: [SQLToken.Kind] = [.identifier, .keyword, .quotedIdentifier]
        if let folding = tokens.first(where: { nameKinds.contains($0.kind) && lexer.text(of: $0).unicodeScalars.contains(where: asciiFoldingLetters.contains) }) {
            let name = lexer.text(of: folding)
            let letter = name.unicodeScalars.first(where: asciiFoldingLetters.contains).map { String(Character($0)) } ?? ""
            return "The name \(name.prefix(40)) contains `\(letter)`, which case mapping turns into an ASCII letter and ClickHouse does not; write the name in ASCII."
        }
        // Servers decode `\xHH` and `\N` in quoted names (`` `\x66ile`('x') `` calls file()); every name rule here
        // compares names as written, so a quoted name with any escape is refused rather than decoded.
        if let escaped = tokens.first(where: { $0.kind == .quotedIdentifier && lexer.text(of: $0).contains("\\") }) {
            return "The quoted name \(lexer.text(of: escaped).prefix(40)) contains a backslash; escape sequences in names are not allowed in read-only mode (ClickHouse decodes them, so the name it reads could differ). Write the name without escapes."
        }
        if let token = lexer.uncertainToken(in: tokens) {
            if lexer.isVersionDependentHeredoc(token) {
                return "Heredocs with a tag other than letters, digits and `_` are read differently by ClickHouse versions (26.8 reads no string there); use `$$ … $$` or a plain tag."
            }
            return "`\(lexer.text(of: token))` may be read differently by the server (a malformed or version-dependent number); write it plainly."
        }
        return nil
    }

    /// The first statement of an editor batch on a read-only connection that the guard refuses. `USE`
    /// is allowed there: it only switches the session's database (ClickHouse allows it at readonly=1).
    public static func firstRefusal(in statements: [String]) -> (sql: String, reason: String)? {
        for statement in statements where SQLStatementKind.of(statement) != .use {
            if let reason = check(statement) { return (statement, reason) }
        }
        return nil
    }

    /// Index of the query after `EXPLAIN [kind] [setting = value, …]`; `nil` when no SELECT follows.
    static func explainQueryStart(_ words: StatementWords) -> Int? {
        var index = 1
        while let word = words.word(index) {
            if ["SELECT", "WITH", "("].contains(word) { return index }
            if explainKinds.contains(word) || word == "," || word == "=" || words.tokens[index].kind == .number
                || (words.isWord(index) && words.word(index + 1) == "=") {
                index += 1
                continue
            }
            return nil
        }
        return nil
    }

    private static func scan(_ words: StatementWords, from start: Int, audience: Audience) -> String? {
        let tableFunctions = audience == .editor ? allowedTableFunctions : aiTableFunctions
        let list = words.words
        let depths = words.depths
        // FROM-list state per parenthesis depth: a call directly after FROM/JOIN (or a comma inside a
        // FROM list) is a table function.
        enum FromState { case list, paused }
        var inFromList: [Int: FromState] = [:]
        for index in list.indices.dropFirst(start) {
            let token = words.tokens[index]
            let depth = depths[index]
            let word = list[index]
            let isName = words.isWord(index) || token.kind == .quotedIdentifier
            if token.kind == .punctuation, word == ",", inFromList[depth] == .paused { inFromList[depth] = .list }
            // Each bracket is a scope of its own: `EXTRACT(DAY FROM d)` leaves no FROM list behind for a sibling call.
            if token.kind == .punctuation, ["(", "[", "{"].contains(word) { inFromList[depth + 1] = nil }
            if token.kind == .punctuation, [")", "]", "}"].contains(word) { inFromList[depth] = nil }
            if words.isWord(index) {
                if word == "FROM" || word == "JOIN" {
                    inFromList[depth] = .list
                } else if fromListEnds.contains(word) {
                    inFromList[depth] = fromListPauses.contains(word) && inFromList[depth] != nil ? .paused : nil
                }
                if words.mayBeSettingsClause(at: index) {
                    return "Per-query SETTINGS are not allowed in read-only mode: they could lift `readonly` or widen the limits of the query."
                }
                if word == "INTO", words.word(index + 1) == "OUTFILE" { return "SELECT … INTO OUTFILE is not allowed in read-only mode." }
                if word == "SYSTEM", let next = words.word(index + 1), systemCommands.contains(next), words.isWord(index + 1) {
                    return "`SYSTEM \(next)` is not allowed in a read-only query."
                }
                if word == "UPDATE", words.isWord(index + 1), words.word(index + 2) == "SET" || words.word(index + 2) == "." {
                    return "`UPDATE` is not allowed in a read-only query."
                }
                if let objects = forbiddenPairs[word] {
                    if objects.isEmpty, index == start { return "`\(word)` is not allowed in a read-only query." }
                    if let next = words.word(index + 1), objects.contains(next), words.isWord(index + 1) {
                        return "`\(word) \(next)` is not allowed in a read-only query."
                    }
                }
            }
            // Function calls: `name(` (also quoted names).
            guard isName, index + 1 < list.count, words.tokens[index + 1].kind == .punctuation, list[index + 1] == "(" else { continue }
            let name = words.lexer.identifierValue(of: token).lowercased()
            if externalAccessFunctions.contains(name) {
                return "`\(name)()` reads data outside ClickHouse (network, files or external systems) and is not allowed in read-only mode."
            }
            let previous = index > start ? list[index - 1] : ""
            let afterTableKeyword = index > start && words.isWord(index - 1) && (previous == "FROM" || previous == "JOIN")
            let afterComma = previous == "," && inFromList[depth] != nil
            if (afterTableKeyword || afterComma) && !tableFunctions.contains(name) {
                return "The table function `\(name)()` is not allowed in read-only mode (allowed: numbers, zeros, generateRandom, values, view, merge, cluster, clusterAllReplicas, …)."
            }
        }
        return nil
    }

    // MARK: AI access

    /// The `system` tables AI access may read, for schema browsing and diagnostics. None holds other sessions' SQL text
    /// or credentials; the definition columns of tables, databases and functions are refused separately.
    static let aiReadableSystemTables: Set<String> = [
        // Schema: names, engines, keys, sizes, columns, indexes, projections.
        "databases", "tables", "columns", "data_skipping_indices", "projections",
        // Storage and its health: parts, merges (no SQL), replication, disks.
        "parts", "parts_columns", "projection_parts", "detached_parts", "merges", "replicas", "disks", "storage_policies",
        // Topology and counters.
        "clusters", "macros", "metrics", "events", "asynchronous_metrics",
        // The server's vocabulary and setting values (no credentials).
        "functions", "table_functions", "table_engines", "database_engines", "formats", "data_type_families",
        "aggregate_function_combinators", "time_zones", "collations", "keywords", "settings", "merge_tree_settings",
        // Generators.
        "one", "numbers", "numbers_mt", "zeros", "zeros_mt",
    ]

    /// Table functions AI access may use: generators and inline data. Everything that reads other tables or databases by
    /// name (merge, loop, cluster, clusterAllReplicas, mergeTreeIndex, dictionary, …), and any new one, is refused.
    static let aiTableFunctions: Set<String> = AIFunctionCatalog.allowedTableFunctions

    /// Table functions that read other tables or databases by name: refused for AI access wherever they appear.
    static let aiRefusedTableFunctions: Set<String> = AIFunctionCatalog.reviewedLocalTableFunctions
        .union(AIFunctionCatalog.aiRefusedTableFunctions).union(["remote", "remotesecure"])

    /// Columns holding object definitions — DDL, engine arguments, view queries, SQL function bodies. They carry
    /// credentials (22.8 prints them all; 24.8 still prints the ones in URLs), so AI access never reads them.
    static let definitionColumns: Set<String> = ["CREATE_TABLE_QUERY", "ENGINE_FULL", "AS_SELECT", "CREATE_QUERY", "VIEW_DEFINITION",
                                                 "ROUTINE_DEFINITION", "CREATE_DATABASE_QUERY"]

    /// `system` tables with definition columns: a query that reads one (or information_schema) may use no `*` but `count(*)`.
    static let definitionTables: Set<String> = ["TABLES", "DATABASES", "FUNCTIONS", "PROJECTIONS"]
    /// Definition columns with a name too common to refuse everywhere: refused where their table is read
    /// (`system.projections.query`, 26.8).
    static let definitionColumnsByTable: [String: Set<String>] = ["PROJECTIONS": ["QUERY"]]

    /// The `SHOW` forms AI access may run: names, columns, indexes, engines, clusters and settings. `SHOW TABLE x` and
    /// `SHOW VIEW x` (24.8+) are SHOW CREATE, SHOW FUNCTIONS prints SQL function bodies, the rest print other sessions'
    /// queries or access definitions, and a new form is refused until it is known.
    static let aiShowTargets: Set<String> = ["TABLES", "DATABASES", "DICTIONARIES", "COLUMNS", "FIELDS", "INDEX", "INDEXES", "INDICES", "KEYS",
                                             "ENGINES", "CLUSTERS", "CLUSTER", "SETTINGS", "MERGES"]
    /// Words before the SHOW target.
    static let showModifiers: Set<String> = ["FULL", "EXTENDED", "TEMPORARY", "CHANGED"]

    /// EXPLAIN kinds AI access may run. 22.8 and 24.8 inline each view's query into EXPLAIN SYNTAX, literals included,
    /// and QUERY TREE is not needed; plans (quoted strings masked in the result) and the query's own AST stay.
    static let aiRefusedExplainKinds: Set<String> = ["SYNTAX", "QUERY", "TABLE", "CURRENT"]

    /// Why AI access may not run `words`, if it reads outside the allow-lists or reads object definitions.
    static func aiRefusal(_ words: StatementWords, database: String?) -> String? {
        let allowed = "AI access reads system tables only for schema and diagnostics (\(aiReadableSystemTables.sorted().joined(separator: ", "))); the running-queries, query-log and replication tools serve the rest, redacted."
        let withheld = "AI access never receives object definitions (DDL, engine arguments, view queries, SQL function bodies): they can carry credentials."
        let databaseName = database?.uppercased()
        if databaseName == "SYSTEM" { return "Choose another database for AI access and qualify system tables (system.tables). " + allowed }
        let list = words.words
        switch list.first {
        case "SHOW":
            var position = 1
            while let word = words.word(position), showModifiers.contains(word) { position += 1 }
            guard let target = words.word(position), aiShowTargets.contains(target), words.isWord(position),
                  !(target == "SETTINGS" && words.word(position + 1) == "PROFILES") else {
                return "AI access runs SHOW only to list names, columns, indexes, engines, clusters and settings (SHOW TABLES, SHOW COLUMNS FROM t, …). "
                    + withheld + " Use describe_table for a table's columns, keys and engine."
            }
        case "EXPLAIN":
            if let kind = words.word(1), aiRefusedExplainKinds.contains(kind), words.isWord(1) {
                return "AI access runs EXPLAIN PLAN, PIPELINE, ESTIMATE and AST only: EXPLAIN SYNTAX prints the queries of the views a query reads. " + withheld
            }
        default:
            break
        }
        func name(_ index: Int) -> String? {
            guard words.isName(index) else { return nil }
            return words.lexer.identifierValue(of: words.tokens[index]).uppercased()
        }
        var readsDefinitions = databaseName == "INFORMATION_SCHEMA"
        var namesUsed: Set<String> = []
        var systemTablesRead: Set<String> = []
        for index in list.indices {
            guard let value = name(index) else { continue }
            if definitionColumns.contains(value) { return "`\(value.lowercased())` holds object definitions. " + withheld + " Use describe_table." }
            namesUsed.insert(value)
            if words.isPunctuation(index - 1, ".") { continue }
            // 24.8+ runs EXPLAIN as a subquery (`SELECT * FROM (EXPLAIN SYNTAX …)`), past the kind check and the masking
            // of EXPLAIN results.
            if value == "EXPLAIN", index > 0, words.isWord(index) {
                return "AI access runs EXPLAIN only as the whole statement, not inside another query. " + withheld
            }
            // The masking of tool results needs text: `FORMAT Parquet` compresses a plan's literals past it.
            if value == "FORMAT", words.isWord(index), !words.isPunctuation(index + 1, "(") {
                return "AI access receives results in the tool's own format, where credentials and plan literals are masked; remove the FORMAT clause (quote a column named format: \"format\")."
            }
            if value == "SYSTEM" {
                guard words.isPunctuation(index + 1, "."), let table = name(index + 2), aiReadableSystemTables.contains(table.lowercased()) else {
                    return allowed
                }
                if definitionTables.contains(table) { readsDefinitions = true }
                systemTablesRead.insert(table)
                continue
            }
            if value == "INFORMATION_SCHEMA", words.isPunctuation(index + 1, ".") { readsDefinitions = true }
            if words.isPunctuation(index + 1, "("), aiRefusedTableFunctions.contains(value.lowercased()) {
                return "`\(value.lowercased())()` reads other tables or databases by name; AI access may use only \(aiTableFunctions.sorted().joined(separator: ", "))."
            }
        }
        for table in systemTablesRead {
            if let column = definitionColumnsByTable[table]?.first(where: namesUsed.contains) {
                return "`\(column.lowercased())` of system.\(table.lowercased()) holds object definitions. " + withheld
            }
        }
        // `*` in any position (`t.*`, `tuple(*)`, `[*]`, `formatRow('TSV', *)`, multiplication too) and `COLUMNS(…)` would
        // reach the definition columns without naming them; `count(*)` is the one exception.
        if readsDefinitions {
            for index in list.indices {
                let isAsterisk = words.tokens[index].kind == .operator && list[index] == "*"
                let isCountAll = isAsterisk && name(index - 2) == "COUNT" && words.isPunctuation(index - 1, "(") && words.isPunctuation(index + 1, ")")
                if (isAsterisk && !isCountAll) || (name(index) == "COLUMNS" && words.isPunctuation(index + 1, "(")) {
                    return "A query that reads system.tables, system.databases, system.functions or information_schema may not use `*` (except count(*)) or COLUMNS(…): name the columns you need. "
                        + withheld
                }
            }
        }
        return nil
    }

    private static func rejection(_ keyword: String) -> String {
        "Only read-only statements (SELECT, WITH, SHOW, DESCRIBE, EXISTS, EXPLAIN) are allowed; `\(keyword)` statements need a connection with read-write access."
    }
}
