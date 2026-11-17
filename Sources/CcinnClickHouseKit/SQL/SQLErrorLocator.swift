import ClickHouseWire
import Foundation

/// A ClickHouse statement error, parsed from its message (`ClickHouseError.message`, or raw
/// `Code: N. DB::Exception: …` text).
///
/// Shapes recorded on 22.8, 24.8 and 26.8: syntax errors carry a 1-based **UTF-8 byte** position
/// (`Syntax error: failed at position 15 ('t'): t. Expected one of: …`, plus `(line L, col C)` for
/// multi-line queries, columns in bytes); other errors carry none but usually name the culprit
/// (`Unknown expression identifier 'x' in scope …`, `Table shop.t doesn't exist`, …) and often echo the
/// whole query (`in scope …`, `while processing query: …`).
public struct SQLServerError: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case syntax
        case other
    }

    public var phase: Phase
    public var code: Int?
    /// Symbolic error name (`UNKNOWN_IDENTIFIER`).
    public var name: String?
    /// Where a syntax error points, in the executed text.
    public var position: ClickHouseServerException.ErrorPosition?
    /// `failed at position N (end of query)`.
    public var atEndOfQuery: Bool
    /// The whole message, without a stack trace or the `Code:` / `(NAME)` / `(version …)` framing.
    public var detail: String
    /// `detail` for display: a shortened `Expected one of` list, no echoed query, at most `summaryLimit`
    /// characters.
    public var summary: String
    /// Identifiers the message names (`'e.nosuch'` → `["e", "nosuch"]`), most specific first.
    public var names: [[String]]

    public static let summaryLimit = 500

    public init(phase: Phase, code: Int? = nil, name: String? = nil, position: ClickHouseServerException.ErrorPosition? = nil,
                atEndOfQuery: Bool = false, detail: String, summary: String? = nil, names: [[String]] = []) {
        self.phase = phase
        self.code = code
        self.name = name
        self.position = position
        self.atEndOfQuery = atEndOfQuery
        self.detail = detail
        self.summary = summary ?? Self.capped(detail)
        self.names = names
    }

    public static func parse(_ message: String, code: Int? = nil, name: String? = nil) -> SQLServerError {
        var text = withoutStackTrace(message.trimmingCharacters(in: .whitespacesAndNewlines))
        var code = code
        var name = name
        // Raw exception text (only when it starts with it: an echoed query may contain `Code: `).
        if text.hasPrefix("Code: "), let exception = ClickHouseServerException.parse(text) {
            text = exception.message
            code = code ?? exception.code
            name = name ?? exception.name
        }
        let echo = echoStart(in: text)
        let head = text[..<echo]
        let phase: Phase = code == 62 || name == "SYNTAX_ERROR" || head.prefix(1_024).contains("Syntax error") ? .syntax : .other
        // Positions only from the parser's own header, never from an echoed query.
        let header = String(head.prefix(1_024))
        let position = header.contains("failed at position") ? ClickHouseServerException.errorPosition(in: header) : nil
        let atEnd = header.contains(/failed at position \d+ \(end of query\)/)
        let summary = phase == .syntax ? syntaxSummary(text) ?? plainSummary(text, echo: echo) : plainSummary(text, echo: echo)
        return SQLServerError(phase: phase, code: code, name: name, position: position, atEndOfQuery: atEnd, detail: text,
                              summary: summary, names: names(in: String(head.prefix(4_096))))
    }

    /// "Syntax error", the error name in words ("Unknown identifier"), or "Error".
    public var kindLabel: String {
        if phase == .syntax { return "Syntax error" }
        guard let name, !name.isEmpty else { return "Error" }
        let words = name.lowercased().replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// The kind, with an **editor** position when one is known. The server's own position counts bytes
    /// of the executed statement (including an `EXPLAIN …` prefix), so it is never shown here.
    public func title(at position: SQLTextPosition?) -> String {
        guard let position else { return kindLabel }
        return "\(kindLabel) at line \(position.line), column \(position.column)"
    }

    // MARK: Cleaning

    /// Drops `Stack trace:` / `, Stack trace (when copying this message, …):` and what follows.
    static func withoutStackTrace(_ text: String) -> String {
        guard let marker = text.range(of: "Stack trace") else { return text }
        return trimmedEnd(text[..<marker.lowerBound])
    }

    /// Where the echoed query starts (`… in scope SELECT …`, `… while processing query: '…'`,
    /// `…: While processing x`), or the end of the text.
    /// ClickHouse writes single spaces there; literal spaces keep the search linear (`\s+` before a literal
    /// backtracks quadratically over a long run of whitespace in an echoed query).
    static func echoStart(in text: String) -> String.Index {
        text.firstMatch(of: #/\.? [Ii]n scope | while processing query|: While processing /#)?.range.lowerBound ?? text.endIndex
    }

    /// Without trailing whitespace and `.`, `:`, `,`, `;`.
    static func trimmedEnd(_ text: Substring) -> String {
        var end = text.endIndex
        while end > text.startIndex {
            let previous = text.index(before: end)
            guard text[previous].isWhitespace || ".:,;".contains(text[previous]) else { break }
            end = previous
        }
        return String(text[..<end])
    }

    static func capped(_ text: String) -> String {
        text.count > summaryLimit ? String(text.prefix(summaryLimit)) + "…" : text
    }

    // MARK: Summaries

    /// The message up to the echoed query, plus a `Maybe you meant: [...]` that came after it.
    static func plainSummary(_ text: String, echo: String.Index) -> String {
        var summary = trimmedEnd(text[..<echo])
        if summary.isEmpty { summary = trimmedEnd(Substring(text)) }
        if echo < text.endIndex, let hint = text[echo...].prefix(4_096).firstMatch(of: /[Mm]aybe you meant:?\s*\[[^\]\n]*\]/) {
            let suggestion = hint.output
            summary += ". " + suggestion.prefix(1).uppercased() + suggestion.dropFirst()
        }
        return capped(summary)
    }

    /// `Syntax error near 't'. Expected one of: a, b, …`, `Syntax error at end of query. …` or
    /// `Syntax error: Unmatched parentheses`; `nil` when the message has another shape.
    static func syntaxSummary(_ text: String) -> String? {
        let head = text.prefix(2_048)
        var location: String?
        if let match = head.firstMatch(of: #/failed at position \d+ \((.*?)\)(?: \(line \d+, col \d+\))?: /#.dotMatchesNewlines()) {
            var token = String(match.output.1)
            if token == "end of query" {
                location = "at end of query"
            } else {
                // 24.8 quotes the token (`('t')`), 26.8 does not (`(t)`).
                if token.count >= 2, token.hasPrefix("'"), token.hasSuffix("'") { token = String(token.dropFirst().dropLast()) }
                token = token.replacingOccurrences(of: "\n", with: " ")
                if token.count > 40 { token = String(token.prefix(40)) + "…" }
                location = "near '\(token)'"
            }
        }
        let prefix = location.map { "Syntax error \($0)" } ?? "Syntax error"
        if let list = text.range(of: "Expected one of: ", options: .backwards) {
            return capped("\(prefix). Expected one of: \(shortenedList(text[list.upperBound...]))")
        }
        if let description = head.firstMatch(of: /[A-Z][a-z]+(?: [a-z]+){0,3} is not closed|Unmatched parentheses|Unrecognized token/) {
            return "Syntax error: \(description.output)"
        }
        if let expected = text.range(of: ". Expected ", options: .backwards) {
            return capped("\(prefix). \(trimmedEnd(text[text.index(after: expected.lowerBound)...]).dropFirst())")
        }
        return location == nil ? nil : capped(prefix)
    }

    /// The first alternatives, up to about 100 characters, then `…`.
    static func shortenedList(_ list: Substring) -> String {
        let items = trimmedEnd(list.prefix(8_192)).components(separatedBy: ", ")
        var kept: [String] = []
        var length = 0
        for item in items {
            let added = item.count + (kept.isEmpty ? 0 : 2)
            if !kept.isEmpty, length + added > 100 { break }
            kept.append(item)
            length += added
        }
        return kept.joined(separator: ", ") + (kept.count < items.count ? ", …" : "")
    }

    // MARK: Names

    /// A name quoted as `'…'` (capture 1) or `` `a`.`b` `` (capture 2).
    private typealias QuotedPattern = Regex<(Substring, Substring?, Substring?)>
    private typealias PlainPattern = Regex<(Substring, Substring)>

    static func names(in head: String) -> [[String]] {
        // Patterns recorded from 22.8, 24.8 and 26.8 (both analyzers), most common first.
        // Each regex runs only when its literal words occur (a substring search is far cheaper); both lists
        // are built per call: `Regex` is not `Sendable`, so it cannot be a shared constant.
        let quoted: [(String, QuotedPattern)] = [
            ("Unknown expression", /Unknown expression (?:or function )?identifier (?:'([^'\n]+)'|(`(?:[^`\n]|``)+`(?:\.`(?:[^`\n]|``)+`)*))/),
            ("Unknown table expression", /Unknown table expression identifier (?:'([^'\n]+)'|(`(?:[^`\n]|``)+`(?:\.`(?:[^`\n]|``)+`)*))/),
            ("cannot be resolved", /Identifier (?:'([^'\n]+)'|(`(?:[^`\n]|``)+`(?:\.`(?:[^`\n]|``)+`)*)) cannot be resolved/),
            ("Missing columns", /Missing columns: (?:'([^'\n]+)'|(`(?:[^`\n]|``)+`(?:\.`(?:[^`\n]|``)+`)*))/),
            ("There's no column", /There's no column (?:'([^'\n]+)'|(`(?:[^`\n]|``)+`(?:\.`(?:[^`\n]|``)+`)*))/),
            ("Function with name", /Function with name (?:'([^'\n]+)'|(`(?:[^`\n]|``)+`)) does not exist/),
        ]
        let plain: [(String, PlainPattern)] = [
            ("function ", /Unknown (?:aggregate |table )?function (`(?:[^`\n]|``)+`|[^\s.:,;()'`]+)/),
            ("Table ", /Table (`(?:[^`\n]|``)+`(?:\.`(?:[^`\n]|``)+`)?|[^\s`']+?) (?:does not exist|doesn't exist)/),
            ("Database ", /Database (`(?:[^`\n]|``)+`|[^\s`']+?) (?:does not exist|doesn't exist)/),
            ("Unknown setting", /Unknown setting (\w+)/),
            ("is neither", /Setting (\w+) is neither/),
            ("No such column", /No such column (\S+?) in table/),
            ("Unknown data type", /Unknown data type family: (\w+)/),
            ("format", /Unknown (?:input |output )?format:? (\w+)/),
            ("Unknown table engine", /Unknown table engine (\w+)/),
        ]
        var names: [[String]] = []
        func add(_ raw: Substring?) {
            guard let raw, raw.count <= 512 else { return }
            let segments = nameSegments(String(raw))
            if !segments.isEmpty, !names.contains(segments) { names.append(segments) }
        }
        for (words, pattern) in quoted where head.contains(words) {
            guard let match = head.firstMatch(of: pattern) else { continue }
            add(match.output.1 ?? match.output.2)
        }
        for (words, pattern) in plain where head.contains(words) {
            add(head.firstMatch(of: pattern)?.output.1)
        }
        return names
    }

    /// `` `a`.`b` `` → `["a", "b"]` (doubled back-quotes unescaped); `shop.t` → `["shop", "t"]`.
    static func nameSegments(_ raw: String) -> [String] {
        let characters = Array(raw)
        var segments: [String] = []
        var current = ""
        var quoted = false
        var index = 0
        func flush() {
            let segment = quoted ? current : current.trimmingCharacters(in: .whitespaces)
            if !segment.isEmpty { segments.append(segment) }
            current = ""
        }
        while index < characters.count {
            let character = characters[index]
            if quoted {
                if character == "`" {
                    if index + 1 < characters.count, characters[index + 1] == "`" {
                        current.append("`")
                        index += 2
                        continue
                    }
                    quoted = false
                } else {
                    current.append(character)
                }
            } else if character == "`" {
                quoted = true
            } else if character == "." {
                flush()
            } else {
                current.append(character)
            }
            index += 1
        }
        flush()
        return segments
    }
}

/// How the text the server executed relates to the statement in the editor: the app may prepend
/// (`EXPLAIN indexes = 1 `) and insert (` LIMIT n`). Offsets are UTF-16.
public struct SQLExecutedTextMapping: Sendable, Equatable {
    public var prefixLength: Int
    /// Range of inserted text, in executed coordinates.
    public var insertion: Range<Int>?

    public static let identity = SQLExecutedTextMapping()

    public init(prefixLength: Int = 0, insertion: Range<Int>? = nil) {
        self.prefixLength = max(0, prefixLength)
        self.insertion = insertion
    }

    /// Source offset for an executed offset. Positions inside the insertion map to its start;
    /// positions inside the prefix map to 0. Never negative.
    public func sourceOffset(forExecuted offset: Int) -> Int {
        var value = max(0, offset)
        if let insertion {
            if value >= insertion.upperBound {
                value -= insertion.count
            } else if value > insertion.lowerBound {
                value = insertion.lowerBound
            }
        }
        return max(0, value - prefixLength)
    }
}

/// Finds the text a ClickHouse error refers to inside the statement that failed.
public enum SQLErrorLocator {
    /// UTF-16 offset of a syntax error's position in `statement` (clamped to it; no token expansion).
    public static func offset(in statement: String, message: String) -> Int? {
        guard let position = SQLServerError.parse(message).position else { return nil }
        return utf16Offset(of: position, in: Array(statement.utf8))
    }

    /// The range to mark in `statement`, for a message about that same text.
    public static func range(in statement: String, message: String) -> Range<Int>? {
        range(in: statement, error: SQLServerError.parse(message))
    }

    /// The range (UTF-16, in `source`) to mark for `error`. The byte position is resolved in `executed`
    /// (what the server saw; `source` when nil) and mapped back with `mapping`, then widened to its token:
    /// the `/*` of an unterminated comment, the opening quote of an unterminated string or quoted
    /// identifier, else the token containing it or the last one before it (end of query). Without a
    /// position the named identifier is searched. `nil` when nothing can be located.
    public static func range(in source: String, executed: String? = nil, mapping: SQLExecutedTextMapping = .identity,
                             error: SQLServerError) -> Range<Int>? {
        let lexer = SQLLexer(source)
        let allTokens = lexer.tokens()
        let tokens = allTokens.filter { $0.kind != .comment }
        guard !tokens.isEmpty else { return nil }
        let sourceLength = lexer.units.count

        if let position = error.position {
            guard let executedOffset = utf16Offset(of: position, in: Array((executed ?? source).utf8)) else { return nil }
            let start = min(mapping.sourceOffset(forExecuted: executedOffset), sourceLength)
            // ClickHouse rejects an unterminated `/*` where it starts (`Multiline comment is not closed`).
            if let comment = allTokens.last, comment.kind == .comment, lexer.isUnterminated(comment), comment.range.lowerBound <= start {
                return comment.range.lowerBound..<min(comment.range.lowerBound + 2, comment.range.upperBound)
            }
            let token = tokens[tokenIndex(at: start, in: tokens)]
            if token.kind == .string || token.kind == .quotedIdentifier, lexer.isUnterminated(token) {
                return token.range.lowerBound..<(token.range.lowerBound + 1)
            }
            return token.range
        }

        // Each name, then the whole dotted name as one identifier (`` `a.b` ``), then shorter suffixes
        // (`Table shop.t` for an unqualified `t`). Exact spelling first: identifiers are case-sensitive.
        var candidates: [[String]] = []
        for name in error.names {
            candidates.append(name)
            if name.count > 1 { candidates.append([name.joined(separator: ".")]) }
            var suffix = name.dropFirst()
            while !suffix.isEmpty {
                candidates.append(Array(suffix))
                suffix = suffix.dropFirst()
            }
        }
        for caseSensitive in [true, false] {
            for candidate in candidates {
                if let found = sequence(candidate, in: tokens, lexer: lexer, caseSensitive: caseSensitive) { return found }
            }
        }
        return nil
    }

    // MARK: Positions

    /// UTF-16 offset of a byte position (`failed at position N`, or `(line L, col C)` with the column in
    /// bytes), clamped to the text. `nil` when the line does not exist.
    static func utf16Offset(of position: ClickHouseServerException.ErrorPosition, in bytes: [UInt8]) -> Int? {
        let byteOffset: Int
        switch position {
        case let .byteOffset(offset):
            byteOffset = min(max(0, offset - 1), bytes.count)
        case let .lineColumn(line, column):
            var currentLine = 1
            var lineStart = 0
            var index = 0
            while currentLine < line, index < bytes.count {
                if bytes[index] == 0x0A {
                    currentLine += 1
                    lineStart = index + 1
                }
                index += 1
            }
            guard currentLine == line else { return nil }
            var lineEnd = lineStart
            while lineEnd < bytes.count, bytes[lineEnd] != 0x0A { lineEnd += 1 }
            byteOffset = lineStart + min(max(0, column - 1), lineEnd - lineStart)
        }
        return utf16Offset(ofByte: byteOffset, in: bytes)
    }

    /// UTF-16 offset of the character containing UTF-8 byte `byteOffset`.
    static func utf16Offset(ofByte byteOffset: Int, in bytes: [UInt8]) -> Int {
        var units = 0
        var index = 0
        while index < byteOffset, index < bytes.count {
            let byte = bytes[index]
            let length: Int
            switch byte {
            case 0..<0x80: length = 1
            case 0xC0..<0xE0: length = 2
            case 0xE0..<0xF0: length = 3
            case 0xF0..<0xF8: length = 4
            default: length = 1
            }
            if index + length > byteOffset { break }
            units += length == 4 ? 2 : 1
            index += length
        }
        return units
    }

    /// The token containing `offset`, else the last token ending at or before it, else the first.
    static func tokenIndex(at offset: Int, in tokens: [SQLToken]) -> Int {
        // First token that ends after `offset` (binary search).
        var low = 0
        var high = tokens.count
        while low < high {
            let mid = (low + high) / 2
            if tokens[mid].range.upperBound <= offset { low = mid + 1 } else { high = mid }
        }
        if low < tokens.count, tokens[low].range.lowerBound <= offset { return low }
        return max(0, low - 1)
    }

    // MARK: Names

    /// Tokens spelling `a . b . c` (identifier values; quotes removed).
    static func sequence(_ segments: [String], in tokens: [SQLToken], lexer: SQLLexer, caseSensitive: Bool) -> Range<Int>? {
        guard !segments.isEmpty else { return nil }
        let wanted = caseSensitive ? segments : segments.map { $0.lowercased() }
        let span = segments.count * 2 - 1
        guard tokens.count >= span else { return nil }
        func isName(_ token: SQLToken) -> Bool {
            token.kind == .identifier || token.kind == .quotedIdentifier || token.kind == .keyword
        }
        for start in 0...(tokens.count - span) {
            var matches = true
            for (offset, name) in wanted.enumerated() {
                let token = tokens[start + offset * 2]
                guard isName(token) else { matches = false; break }
                let value = lexer.identifierValue(of: token)
                guard (caseSensitive ? value : value.lowercased()) == name else { matches = false; break }
                if offset > 0 {
                    let dot = tokens[start + offset * 2 - 1]
                    guard dot.kind == .punctuation, lexer.units[dot.range.lowerBound] == 0x2E else { matches = false; break }
                }
            }
            if matches { return tokens[start].range.lowerBound..<tokens[start + span - 1].range.upperBound }
        }
        return nil
    }
}
