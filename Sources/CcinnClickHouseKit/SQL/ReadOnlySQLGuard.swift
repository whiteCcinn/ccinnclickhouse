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

    /// Table functions that only read local data or generate data.
    static let allowedTableFunctions: Set<String> = [
        "numbers", "numbers_mt", "zeros", "zeros_mt", "generaterandom", "values", "null", "view", "viewifpermitted", "viewexplain",
        "cluster", "clusterallreplicas", "merge", "format", "generate_series", "generateseries", "loop", "mergetreeindex",
        "mergetreeprojection", "dictionary", "fuzzjson",
    ]

    /// Functions that reach the network, the server's file system or external processes.
    static let externalAccessFunctions: Set<String> = [
        "url", "urlcluster", "file", "filecluster", "remote", "remotesecure", "s3", "s3cluster", "gcs", "oss", "cosn", "hdfs", "hdfscluster",
        "mysql", "postgresql", "jdbc", "odbc", "mongodb", "redis", "sqlite", "executable", "input", "azureblobstorage",
        "azureblobstoragecluster", "iceberg", "icebergs3", "icebergazure", "iceberghdfs", "iceberglocal", "icebergcluster",
        "icebergs3cluster", "icebergazurecluster", "iceberghdfscluster", "deltalake", "deltalakes3", "deltalakeazure", "deltalakelocal",
        "deltalakecluster", "deltalakes3cluster", "deltalakeazurecluster", "hudi", "hudicluster", "hive", "paimon", "paimons3",
        "paimonazure", "paimonhdfs", "paimonlocal", "ytsaurus", "arrowflight", "arrowflightsql", "prometheusquery", "prometheusqueryrange",
        "timeseriesdata", "timeseriestags", "timeseriesmetrics", "timeseriesselector",
    ]

    /// Clause keywords that end a FROM list.
    static let fromListEnds: Set<String> = ["WHERE", "PREWHERE", "GROUP", "ORDER", "LIMIT", "HAVING", "SETTINGS", "FORMAT", "UNION", "EXCEPT",
                                            "INTERSECT", "ON", "USING", "WINDOW", "QUALIFY", "SAMPLE", "FINAL", "ARRAY", "SELECT", "INTO"]

    /// First verbs of read statements.
    static let readVerbs: Set<String> = ["SELECT", "WITH", "(", "SHOW", "DESC", "DESCRIBE", "EXISTS"]
    /// Words allowed between `EXPLAIN` and the query.
    static let explainKinds: Set<String> = ["AST", "SYNTAX", "QUERY", "TREE", "PLAN", "PIPELINE", "ESTIMATE", "TABLE", "OVERRIDE", "CURRENT"]

    /// `nil` when allowed; otherwise the reason it is rejected.
    public static func check(_ sql: String) -> String? {
        let statements = SQLStatementSplitter.split(sql)
        guard let statement = statements.first else { return "The statement is empty." }
        guard statements.count == 1 else { return "Only one statement can be run at a time; send statements separately." }
        let words = StatementWords(statement.text)
        guard let first = words.words.first else { return "The statement is empty." }

        var queryStart = 0
        if first == "EXPLAIN" {
            guard let start = explainQueryStart(words) else { return "Only EXPLAIN of a SELECT query is allowed in read-only mode." }
            queryStart = start
        } else if !readVerbs.contains(first) {
            return rejection(first)
        } else if first == "SHOW", words.word(1) == "CREATE" {
            queryStart = 2 // SHOW CREATE TABLE/USER/… only prints a definition
        }
        return scan(words, from: queryStart)
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

    private static func scan(_ words: StatementWords, from start: Int) -> String? {
        let list = words.words
        let depths = words.depths
        // FROM-list state per parenthesis depth: a call directly after FROM/JOIN (or a comma inside a
        // FROM list) is a table function.
        var inFromList: [Int: Bool] = [:]
        for index in list.indices.dropFirst(start) {
            let token = words.tokens[index]
            let depth = depths[index]
            let word = list[index]
            let isName = words.isWord(index) || token.kind == .quotedIdentifier
            if words.isWord(index) {
                if word == "FROM" || word == "JOIN" { inFromList[depth] = true } else if fromListEnds.contains(word) { inFromList[depth] = false }
                if word == "SETTINGS" {
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
            let afterComma = previous == "," && inFromList[depth] == true
            if (afterTableKeyword || afterComma) && !allowedTableFunctions.contains(name) {
                return "The table function `\(name)()` is not allowed in read-only mode (allowed: numbers, zeros, generateRandom, values, view, merge, cluster, clusterAllReplicas, …)."
            }
        }
        return nil
    }

    private static func rejection(_ keyword: String) -> String {
        "Only read-only statements (SELECT, WITH, SHOW, DESCRIBE, EXISTS, EXPLAIN) are allowed; `\(keyword)` statements need a connection with read-write access."
    }
}
