import Foundation

/// Removes credentials from SQL before it is written to history or audit logs. String literals become
/// `'***'` when they are:
/// - after `IDENTIFIED [WITH method] BY|AS`, after `PASSWORD`, `KEY`, `SECRET`, `TOKEN` (dictionary sources),
/// - values of credential-like `name = 'value'` pairs (named collections, settings),
/// - credential positions of table functions and engines (`mysql(host, db, table, user, password)`,
///   `remote(…, user, password)`, `s3(url, key, secret, …)`, …),
/// and user:password in URLs plus credential-like `key=value` pairs (connection strings, JDBC/ODBC strings,
/// URL query parameters) are masked in every literal. `redactMessage` cleans server error text, which can
/// echo the statement.
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
        redactCounting(sql).text
    }

    /// `redact`, with the number of literals it masked.
    static func redactCounting(_ sql: String) -> MaskedText {
        let lexer = SQLLexer(sql)
        let tokens = lexer.tokens().filter { $0.kind != .comment }
        var redactions: [Range<Int>: String] = [:]
        for (index, token) in tokens.enumerated() where token.kind == .string {
            if isSecretLiteral(at: index, tokens: tokens, lexer: lexer) {
                redactions[token.range] = "'***'"
            } else {
                let text = lexer.text(of: token)
                let masked = maskConnectionSecrets(maskURLCredentials(text))
                if masked != text { redactions[token.range] = masked }
            }
        }
        guard !redactions.isEmpty else { return MaskedText(text: sql, count: 0) }
        var units = lexer.units
        for range in redactions.keys.sorted(by: { $0.lowerBound > $1.lowerBound }) {
            guard let replacement = redactions[range] else { continue }
            units.replaceSubrange(range, with: Array(replacement.utf16))
        }
        return MaskedText(text: String(decoding: units, as: UTF16.self), count: redactions.count)
    }

    static func isSecretLiteral(at index: Int, tokens: [SQLToken], lexer: SQLLexer) -> Bool {
        func word(_ offset: Int) -> String? {
            let position = index + offset
            guard tokens.indices.contains(position) else { return nil }
            return lexer.text(of: tokens[position]).uppercased()
        }
        // IDENTIFIED BY '…' / IDENTIFIED WITH method BY|AS '…' [, method BY '…' …] (also `SALT '…'`):
        // every BY/AS literal after IDENTIFIED is a secret.
        if word(-1) == "BY" || word(-1) == "AS" {
            if tokens[..<index].contains(where: { $0.kind == .keyword || $0.kind == .identifier ? lexer.text(of: $0).uppercased() == "IDENTIFIED" : false }) {
                return true
            }
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

    /// Credential-like `key=value` pairs in connection strings (`AccountKey=…;`, `PWD=…;`), JDBC URLs and
    /// URL query strings (`?password=…&`, `access_token=…`, `X-Amz-Signature=…`).
    static let connectionSecretPattern = #"(?i)\b(AccountKey|SharedAccessKey|SharedAccessSignature|sig|PWD|Password|Passwd|Secret|SecretKey|"#
        + #"Token|access_token|refresh_token|id_token|api_key|apikey|client_secret|private_key|X-Amz-Signature|X-Amz-Security-Token|"#
        + #"aws_secret_access_key|AccessKeySecret)=([^;&'\s"]+)"#

    static func maskConnectionSecrets(_ text: String) -> String {
        guard text.contains("=") else { return text }
        return text.replacingOccurrences(of: connectionSecretPattern, with: "$1=***", options: .regularExpression)
    }

    /// Server error text without credentials: the statement echo of syntax errors (`failed at position N
    /// ('…') (line L, col C): …`) is dropped, string literals are redacted like SQL (`While processing
    /// s3('url', 'key', 'secret')`), and URL credentials and connection-string secrets are masked.
    public static func redactMessage(_ message: String) -> String {
        var text = message.replacingOccurrences(of: #"(failed at position \d+)[^\n]*?(?=Expected|\n|$)"#, with: "$1 (statement text omitted). ",
                                                options: .regularExpression)
        text = redact(text)
        text = maskURLCredentials(maskConnectionSecrets(text))
        return text
    }

    /// Other sessions' SQL as AI access may see it, digest style: every string literal (heredocs included), every number,
    /// every double-quoted name (in ClickHouse almost always a mistaken string: `WHERE x = "secret"`) and every
    /// unterminated token (string, quoted name, heredoc: the rest of the text) becomes `?`, and comments are dropped.
    /// Bare words, backticked names, keywords, operators and layout stay. What a literal holds is the reason the raw
    /// sources (query_log, processes, mutations) are closed to AI access, credentials or not.
    public static func digest(_ sql: String) -> String {
        digest(sql, masksQuotedNames: false)
    }

    /// Server error text about other sessions' statements, digest style: the statement echoes dropped (`failed at
    /// position …`, `in scope SELECT …`, `while processing query: …`, the data after `here:` / `before:`), then every
    /// literal and quoted name replaced as in `digest`: errors quote the values they echo as names (`` `secret` ``).
    public static func digestMessage(_ message: String) -> String {
        digest(omittingStatementEchoes(redactMessage(message)), masksQuotedNames: true)
    }

    /// `digestMessage` for the error of `statements` (a query and its exception, a mutation and its fail reason). Server
    /// errors repeat some literal values unquoted (`Cannot parse uuid …`, `Unknown setting …`, throwIf messages), so
    /// every occurrence of the statements' `literalValues` becomes `?` first, longest first.
    public static func digestMessage(_ message: String, statements: [String]) -> String {
        digestMessage(maskingLiteralValues(of: statements, in: message))
    }

    /// The values of `sql` that an error may repeat: string literals (as written and decoded) and heredoc bodies, quoted
    /// names and the rest of the text after an unclosed heredoc, of 3 characters or more, and numbers with 4 or more
    /// digits. Shorter values would erase the error itself (`ab`, `12`).
    public static func literalValues(of sql: String) -> Set<String> {
        let lexer = SQLLexer(sql)
        var values: Set<String> = []
        func add(_ value: String) {
            if value.count >= 3 { values.insert(value) }
        }
        for token in lexer.tokens() {
            if let opener = lexer.unterminatedHeredocOpener(at: token.range.lowerBound) {
                add(lexer.text(in: opener.upperBound..<lexer.units.count))
                break
            }
            switch token.kind {
            case .string:
                add(lexer.stringValue(of: token))
                let raw = lexer.text(of: token)
                if raw.hasPrefix("'") { add(String(raw.dropFirst().dropLast(raw.count > 1 && raw.hasSuffix("'") ? 1 : 0))) }
            case .quotedIdentifier:
                add(lexer.identifierValue(of: token))
            case .number:
                let text = lexer.text(of: token)
                if text.utf8.filter({ $0 >= 0x30 && $0 <= 0x39 }).count >= 4 { values.insert(text) }
            default:
                break
            }
        }
        return values
    }

    /// `message` with every occurrence of the statements' literal values replaced by `?`, longest first. Values whose
    /// first three bytes never occur in the message are skipped without a search, so a statement with thousands of
    /// literals costs one pass over each.
    static func maskingLiteralValues(of statements: [String], in message: String) -> String {
        let bytes = Array(message.utf8)
        guard bytes.count >= 3, !statements.isEmpty else { return message }
        func trigram<Bytes: Collection<UInt8>>(_ prefix: Bytes) -> UInt32 {
            prefix.prefix(3).reduce(0) { $0 << 8 | UInt32($1) }
        }
        var trigrams = Set<UInt32>(minimumCapacity: bytes.count)
        for index in 0...(bytes.count - 3) { trigrams.insert(trigram(bytes[index..<(index + 3)])) }
        var candidates: Set<String> = []
        for statement in statements {
            for value in literalValues(of: statement) where trigrams.contains(trigram(value.utf8)) { candidates.insert(value) }
        }
        var text = message
        let longestFirst = candidates.sorted { $0.utf8.count != $1.utf8.count ? $0.utf8.count > $1.utf8.count : $0 < $1 }
        for value in longestFirst where text.contains(value) {
            text = value.count < wholeTokenThreshold ? replacingWholeTokens(of: value, in: text) : text.replacingOccurrences(of: value, with: "?")
        }
        return text
    }

    /// Values shorter than this are replaced only as whole tokens: `'par'` must not turn "Cannot parse" into "Cannot ?se".
    static let wholeTokenThreshold = 6

    /// `text` with every occurrence of `value` that has no letter or digit on either side replaced by `?`.
    static func replacingWholeTokens(of value: String, in text: String) -> String {
        func isAlphanumeric(_ character: Character?) -> Bool { character.map { $0.isLetter || $0.isNumber } ?? false }
        var result = ""
        var copied = text.startIndex
        var searchFrom = text.startIndex
        while searchFrom < text.endIndex, let found = text.range(of: value, options: .literal, range: searchFrom..<text.endIndex) {
            let before = found.lowerBound > text.startIndex ? text[text.index(before: found.lowerBound)] : nil
            let after = found.upperBound < text.endIndex ? text[found.upperBound] : nil
            if !isAlphanumeric(before), !isAlphanumeric(after) {
                result += text[copied..<found.lowerBound]
                result += "?"
                copied = found.upperBound
            }
            searchFrom = found.upperBound > found.lowerBound ? found.upperBound : text.index(after: found.lowerBound)
        }
        return result + text[copied...]
    }

    /// `masksQuotedNames`: backticked names become `?` too.
    private static func digest(_ text: String, masksQuotedNames: Bool) -> String {
        let lexer = SQLLexer(text)
        let doubleQuote: UInt16 = 0x22
        var output = ""
        var position = 0
        for token in lexer.tokens() {
            output += lexer.text(in: position..<token.range.lowerBound)
            // An unclosed heredoc: ClickHouse reads names there, but the rest of the text is what was meant as its body.
            if lexer.unterminatedHeredocOpener(at: token.range.lowerBound) != nil { return output + "?" }
            switch token.kind {
            case .string, .number: output += "?"
            case .comment: break
            case .quotedIdentifier where masksQuotedNames || lexer.units[token.range.lowerBound] == doubleQuote || lexer.isUnterminated(token):
                output += "?"
            default: output += lexer.text(of: token)
            }
            position = token.range.upperBound
        }
        return output + lexer.text(in: position..<lexer.units.count)
    }

    /// Echoes of a statement or its data in server errors, dropped up to the error name that ends the message (or to
    /// the end): 24.8+ prints the whole statement after `in scope`, where a double-quoted value appears unquoted.
    static let statementEchoPattern = #"((?i:\bin scope |\bwhile processing query: |\bhere: |\bbefore: ))[\s\S]*?"#
        + #"(?=\.? \([A-Z][A-Z0-9_]+\)(?: \(version [\s\S]*)?$|$)"#

    static func omittingStatementEchoes(_ message: String) -> String {
        message.replacingOccurrences(of: statementEchoPattern, with: "$1(statement text omitted)", options: .regularExpression)
    }

    /// EXPLAIN output as AI access may see it: every single-quoted string becomes `'?'` (backslash escapes and doubled
    /// quotes included; an unterminated one runs to the end of the text). Plans carry the literals of the views a query
    /// reads (`Filter column: notEquals(s, 'secret')` on 26.8); their numbers (granules, rows, marks) stay.
    public static func maskStringLiterals(_ text: String) -> String {
        let quote = UInt8(ascii: "'"), backslash = UInt8(ascii: "\\")
        let bytes = Array(text.utf8)
        guard bytes.contains(quote) else { return text }
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            guard bytes[index] == quote else {
                output.append(bytes[index])
                index += 1
                continue
            }
            var end = index + 1
            var closed = false
            while end < bytes.count {
                if bytes[end] == backslash {
                    end += 2
                } else if bytes[end] == quote, end + 1 < bytes.count, bytes[end + 1] == quote {
                    end += 2
                } else if bytes[end] == quote {
                    closed = true
                    break
                } else {
                    end += 1
                }
            }
            output.append(contentsOf: closed ? Array("'?'".utf8) : Array("'?".utf8))
            index = closed ? end + 1 : bytes.count
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// `'https://user:pass@host/…'` → `'https://***@host/…'`.
    static func maskURLCredentials(_ literal: String) -> String {
        guard literal.contains("@"), literal.contains("://") else { return literal }
        return literal.replacingOccurrences(of: #"([A-Za-z][A-Za-z0-9+.\-]*://)[^/@\s']+@"#, with: "$1***@", options: .regularExpression)
    }
}
