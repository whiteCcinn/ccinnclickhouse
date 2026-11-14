import Foundation

/// Decides whether SQL is a single read-only statement (MCP read-only access and read-only profiles,
/// design D8/D11). Token-based (strings, quoted identifiers and comments cannot smuggle keywords),
/// conservative (anything not clearly a read is rejected), and only defence in depth: read-only
/// requests are also sent with `readonly=1`, which ClickHouse enforces itself.
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
        for index in list.indices.dropFirst(start) where words.isWord(index) {
            let word = list[index]
            if word == "INTO", words.word(index + 1) == "OUTFILE" { return "SELECT … INTO OUTFILE is not allowed in read-only mode." }
            if word == "SYSTEM", let next = words.word(index + 1), systemCommands.contains(next), words.isWord(index + 1) {
                return "`SYSTEM \(next)` is not allowed in a read-only query."
            }
            if word == "UPDATE", words.isWord(index + 1), words.word(index + 2) == "SET" || words.word(index + 2) == "." {
                return "`UPDATE` is not allowed in a read-only query."
            }
            guard let objects = forbiddenPairs[word] else { continue }
            if objects.isEmpty, index == start { return "`\(word)` is not allowed in a read-only query." }
            if let next = words.word(index + 1), objects.contains(next), words.isWord(index + 1) {
                return "`\(word) \(next)` is not allowed in a read-only query."
            }
        }
        return nil
    }

    private static func rejection(_ keyword: String) -> String {
        "Only read-only statements (SELECT, WITH, SHOW, DESCRIBE, EXISTS, EXPLAIN) are allowed; `\(keyword)` statements need a connection with read-write access."
    }
}
