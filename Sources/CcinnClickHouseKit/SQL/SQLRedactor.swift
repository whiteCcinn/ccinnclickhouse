import Foundation

/// Removes credentials from SQL before it is written to history or audit logs. String literals become
/// `'***'` when they are:
/// - after `IDENTIFIED [WITH method] BY|AS`, after `PASSWORD`, `KEY`, `SECRET`, `TOKEN` (dictionary sources),
/// - values of credential-like `name = 'value'` pairs (named collections, settings),
/// - credential positions of table functions and engines (`mysql(host, db, table, user, password)`,
///   `remote(…, user, password)`, `s3(url, key, secret, …)`, …),
/// and user:password in URLs is masked in every literal.
public enum SQLRedactor {
    static let sensitiveKeyFragments = ["password", "passwd", "secret", "access_key", "accesskey", "account_key", "token", "credential",
                                        "private_key", "privatekey", "sas", "auth", "_key_id"]
    static let credentialKeywords: Set<String> = ["PASSWORD", "SECRET", "TOKEN", "KEY"]

    /// Function/engine name (lower-cased) → index of the first string argument that may hold a credential.
    static let credentialArguments: [String: Int] = [
        "mysql": 3, "postgresql": 3, "mongodb": 3, "redis": 2, "materializedpostgresql": 3, "materializedmysql": 3,
        "remote": 2, "remotesecure": 2,
        "s3": 1, "s3cluster": 2, "gcs": 1, "oss": 1, "cosn": 1, "azureblobstorage": 1, "azureblobstoragecluster": 2,
        "deltalake": 1, "iceberg": 1, "icebergs3": 1, "hudi": 1, "s3queue": 1, "azurequeue": 1,
    ]

    public static func redact(_ sql: String) -> String {
        let lexer = SQLLexer(sql)
        let tokens = lexer.tokens().filter { $0.kind != .comment }
        var redactions: [Range<Int>: String] = [:]
        for (index, token) in tokens.enumerated() where token.kind == .string {
            if isSecretLiteral(at: index, tokens: tokens, lexer: lexer) {
                redactions[token.range] = "'***'"
            } else {
                let text = lexer.text(of: token)
                let masked = maskURLCredentials(text)
                if masked != text { redactions[token.range] = masked }
            }
        }
        guard !redactions.isEmpty else { return sql }
        var units = lexer.units
        for range in redactions.keys.sorted(by: { $0.lowerBound > $1.lowerBound }) {
            guard let replacement = redactions[range] else { continue }
            units.replaceSubrange(range, with: Array(replacement.utf16))
        }
        return String(decoding: units, as: UTF16.self)
    }

    static func isSecretLiteral(at index: Int, tokens: [SQLToken], lexer: SQLLexer) -> Bool {
        func word(_ offset: Int) -> String? {
            let position = index + offset
            guard tokens.indices.contains(position) else { return nil }
            return lexer.text(of: tokens[position]).uppercased()
        }
        // IDENTIFIED BY '…' / IDENTIFIED WITH method BY|AS '…' (also `SALT '…'` after a hash)
        if word(-1) == "BY" || word(-1) == "AS" {
            if word(-2) == "IDENTIFIED" || word(-4) == "IDENTIFIED" { return true }
        }
        if word(-1) == "SALT" { return true }
        // PASSWORD '…', PASSWORD = '…', KEY '…' (dictionary sources), SECRET '…'
        if let previous = word(-1), credentialKeywords.contains(previous) { return true }
        if word(-1) == "=", let key = word(-2), credentialKeywords.contains(key) { return true }
        // name = 'value' with a credential-like name (named collections, settings, engine properties)
        if word(-1) == "=", index >= 2 {
            let key = lexer.text(of: tokens[index - 2]).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "'\"`"))
            if sensitiveKeyFragments.contains(where: { key.contains($0) }) { return true }
        }
        // Positional credentials of table functions / engines.
        if let (function, argument) = enclosingCall(of: index, tokens: tokens, lexer: lexer),
           let firstSecret = credentialArguments[function.lowercased()], argument >= firstSecret {
            return true
        }
        return false
    }

    /// Name of the function whose argument list contains token `index`, and the argument position.
    static func enclosingCall(of index: Int, tokens: [SQLToken], lexer: SQLLexer) -> (String, Int)? {
        var depth = 0
        var argument = 0
        var position = index - 1
        while position >= 0 {
            let text = lexer.text(of: tokens[position])
            if tokens[position].kind == .punctuation {
                switch text {
                case ")", "]": depth += 1
                case "(", "[":
                    if depth == 0 {
                        guard text == "(", position > 0, tokens[position - 1].kind == .identifier || tokens[position - 1].kind == .keyword else { return nil }
                        return (lexer.text(of: tokens[position - 1]), argument)
                    }
                    depth -= 1
                case "," where depth == 0:
                    argument += 1
                default: break
                }
            }
            position -= 1
        }
        return nil
    }

    /// `'https://user:pass@host/…'` → `'https://***@host/…'`.
    static func maskURLCredentials(_ literal: String) -> String {
        guard literal.contains("@"), literal.contains("://") else { return literal }
        return literal.replacingOccurrences(of: #"([A-Za-z][A-Za-z0-9+.\-]*://)[^/@\s']+@"#, with: "$1***@", options: .regularExpression)
    }
}
