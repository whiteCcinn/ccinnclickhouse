import Foundation

/// One lexical token. Ranges are UTF-16 offsets so they map 1:1 onto `NSRange` in the editor.
public struct SQLToken: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case keyword
        case identifier
        /// `` `name` `` or `"name"` (quoted identifiers).
        case quotedIdentifier
        case string
        case number
        case comment
        case `operator`
        /// `( ) [ ] { } , ; .`
        case punctuation
        /// `{name:Type}` query parameter.
        case parameter
    }

    public let kind: Kind
    public let range: Range<Int>

    public init(kind: Kind, range: Range<Int>) {
        self.kind = kind
        self.range = range
    }

    public var nsRange: NSRange { NSRange(location: range.lowerBound, length: range.count) }
}

/// Tokenizer for ClickHouse SQL (design D11). Never fails: unterminated strings, heredocs and comments
/// extend to the end of the input, unknown characters become operators. Linear time over UTF-16 units.
///
/// ClickHouse specifics: nested block comments, `# `/`#!` line comments, double-quoted identifiers,
/// heredocs (`$$…$$`, `$tag$…$tag$`), binary/hex numbers with `_` separators, `{name:Type}`
/// parameters and the `::`, `->`, `||`, `<=>` operators.
public struct SQLLexer: Sendable {
    public let units: [UInt16]

    public init(_ text: String) {
        units = Array(text.utf16)
    }

    public static func tokenize(_ text: String) -> [SQLToken] {
        SQLLexer(text).tokens()
    }

    /// Source text of a token (quotes kept).
    public func text(of token: SQLToken) -> String {
        text(in: token.range)
    }

    public func text(in range: Range<Int>) -> String {
        let lower = max(0, min(range.lowerBound, units.count))
        let upper = max(lower, min(range.upperBound, units.count))
        return String(decoding: units[lower..<upper], as: UTF16.self)
    }

    /// Identifier value: quotes removed, backslash escapes and doubled quotes unescaped.
    public func identifierValue(of token: SQLToken) -> String {
        let raw = text(of: token)
        guard token.kind == .quotedIdentifier, let quote = raw.first else { return raw }
        var inner = Substring(raw.dropFirst())
        if inner.last == quote { inner = inner.dropLast() }
        var value = ""
        var iterator = inner.makeIterator()
        while let character = iterator.next() {
            if character == "\\", let next = iterator.next() {
                value.append(next)
            } else if character == quote {
                // doubled quote → one quote
                if let next = iterator.next(), next != quote { value.append(character); value.append(next) } else { value.append(character) }
            } else {
                value.append(character)
            }
        }
        return value
    }

    /// Value of a string literal (quotes removed, escapes resolved).
    public func stringValue(of token: SQLToken) -> String {
        let raw = text(of: token)
        guard token.kind == .string else { return raw }
        if raw.hasPrefix("$") {
            // $tag$body$tag$
            guard let secondDollar = raw.dropFirst().firstIndex(of: "$") else { return raw }
            let tag = raw[raw.startIndex...secondDollar]
            var body = raw[raw.index(after: secondDollar)...]
            if body.hasSuffix(tag) { body = body.dropLast(tag.count) }
            return String(body)
        }
        var inner = Substring(raw.dropFirst())
        if inner.last == "'" { inner = inner.dropLast() }
        var value = ""
        var iterator = inner.makeIterator()
        while let character = iterator.next() {
            guard character == "\\" else {
                if character == "'" { if let next = iterator.next(), next != "'" { value.append(next) } }
                value.append(character)
                continue
            }
            guard let next = iterator.next() else { break }
            switch next {
            case "n": value.append("\n")
            case "t": value.append("\t")
            case "r": value.append("\r")
            case "0": value.append("\0")
            default: value.append(next)
            }
        }
        return value
    }

    public func tokens() -> [SQLToken] {
        var tokens: [SQLToken] = []
        tokens.reserveCapacity(units.count / 4)
        var index = 0
        let count = units.count
        while index < count {
            let unit = units[index]
            let start = index
            switch unit {
            case 0x20, 0x09, 0x0A, 0x0D, 0x0B, 0x0C:
                index += 1
                continue
            case 0x2D where peek(index + 1) == 0x2D: // --
                index = endOfLine(from: index)
                tokens.append(SQLToken(kind: .comment, range: start..<index))
            case 0x23 where isHashComment(at: index): // `# ` or `#!`
                index = endOfLine(from: index)
                tokens.append(SQLToken(kind: .comment, range: start..<index))
            case 0x2F where peek(index + 1) == 0x2A: // /* (nested)
                index = endOfBlockComment(from: index)
                tokens.append(SQLToken(kind: .comment, range: start..<index))
            case 0x27: // '
                index = endOfQuoted(from: index, quote: unit)
                tokens.append(SQLToken(kind: .string, range: start..<index))
            case 0x60, 0x22: // ` or "
                index = endOfQuoted(from: index, quote: unit)
                tokens.append(SQLToken(kind: .quotedIdentifier, range: start..<index))
            case 0x24: // `$tag$ … $tag$`, a lone `$`, or a bare word such as `$a$` / `$1` (as ClickHouse lexes them)
                if let end = heredocEnd(from: index) {
                    index = end
                    tokens.append(SQLToken(kind: .string, range: start..<index))
                } else if let next = peek(index + 1), Self.isWordChar(next) {
                    while index < count, Self.isIdentifierPart(units[index]) || units[index] == 0x24 { index += 1 }
                    tokens.append(SQLToken(kind: .identifier, range: start..<index))
                } else {
                    index += 1
                    tokens.append(SQLToken(kind: .operator, range: start..<index))
                }
            case 0x7B where parameterEnd(from: index) != nil: // {name:Type}
                index = parameterEnd(from: index) ?? index + 1
                tokens.append(SQLToken(kind: .parameter, range: start..<index))
            case 0x30...0x39:
                index = endOfNumber(from: index)
                tokens.append(SQLToken(kind: .number, range: start..<index))
            case 0x2E where peek(index + 1).map(Self.isDigit) == true && !isMemberAccess(tokens, at: index):
                index = endOfNumber(from: index)
                tokens.append(SQLToken(kind: .number, range: start..<index))
            case 0x28, 0x29, 0x5B, 0x5D, 0x7B, 0x7D, 0x2C, 0x3B, 0x2E: // ( ) [ ] { } , ; .
                index += 1
                tokens.append(SQLToken(kind: .punctuation, range: start..<index))
            default:
                if Self.isIdentifierStart(unit) {
                    // ClickHouse bare words continue through `$` (`a$b`).
                    while index < count, Self.isIdentifierPart(units[index]) || units[index] == 0x24 { index += 1 }
                    let word = String(decoding: units[start..<index], as: UTF16.self).uppercased()
                    let kind: SQLToken.Kind = SQLKeywords.all.contains(word) ? .keyword : .identifier
                    tokens.append(SQLToken(kind: kind, range: start..<index))
                } else {
                    index += 1
                    // Multi-character operators: <= >= <> != == || && :: -> <=>
                    while index < count, index - start < 3, Self.continuesOperator(previous: units[index - 1], next: units[index]) { index += 1 }
                    tokens.append(SQLToken(kind: .operator, range: start..<index))
                }
            }
        }
        return tokens
    }

    // MARK: Scanners

    private func peek(_ index: Int) -> UInt16? { index >= 0 && index < units.count ? units[index] : nil }

    /// ClickHouse starts a `#` comment only at `# ` or `#!`.
    private func isHashComment(at index: Int) -> Bool {
        guard let next = peek(index + 1) else { return false }
        return next == 0x21 || next == 0x20
    }

    /// `t.5` is member access (tuple element), `.5` alone is a number.
    private func isMemberAccess(_ tokens: [SQLToken], at index: Int) -> Bool {
        guard let last = tokens.last, last.range.upperBound == index else { return false }
        return last.kind == .identifier || last.kind == .quotedIdentifier || last.kind == .keyword
            || (last.kind == .punctuation && (units[last.range.lowerBound] == 0x29 || units[last.range.lowerBound] == 0x5D))
    }

    /// Line comments run to `\n` (ClickHouse does not end them at a lone `\r`).
    private func endOfLine(from index: Int) -> Int {
        var index = index
        while index < units.count, units[index] != 0x0A { index += 1 }
        return index
    }

    /// Nested `/* … /* … */ … */` (ClickHouse follows the SQL standard).
    private func endOfBlockComment(from index: Int) -> Int {
        var index = index + 2
        var depth = 1
        while index < units.count {
            if units[index] == 0x2F, peek(index + 1) == 0x2A {
                depth += 1
                index += 2
            } else if units[index] == 0x2A, peek(index + 1) == 0x2F {
                depth -= 1
                index += 2
                if depth == 0 { return index }
            } else {
                index += 1
            }
        }
        return units.count
    }

    private func endOfQuoted(from index: Int, quote: UInt16) -> Int {
        var index = index + 1
        while index < units.count {
            let unit = units[index]
            if unit == 0x5C {
                index += 2
                continue
            }
            if unit == quote {
                if peek(index + 1) == quote {
                    index += 2
                    continue
                }
                return index + 1
            }
            index += 1
        }
        return units.count
    }

    /// End (exclusive) of a heredoc starting at `index` (`$`): the tag is everything up to the next `$`
    /// (ClickHouse accepts any text there) and the heredoc ends after the next occurrence of the tag.
    /// `nil` when there is no closing tag.
    private func heredocEnd(from index: Int) -> Int? {
        var tagEnd = index + 1
        while tagEnd < units.count, units[tagEnd] != 0x24 { tagEnd += 1 }
        guard tagEnd < units.count else { return nil }
        let tagLength = tagEnd + 1 - index
        var position = tagEnd + 1
        while position + tagLength <= units.count {
            if units[position] == 0x24 {
                var matches = true
                for offset in 1..<tagLength where units[position + offset] != units[index + offset] {
                    matches = false
                    break
                }
                if matches { return position + tagLength }
            }
            position += 1
        }
        return nil
    }

    /// End (exclusive) of `{name:Type}` starting at `index`.
    private func parameterEnd(from index: Int) -> Int? {
        var position = index + 1
        while position < units.count, units[position] == 0x20 { position += 1 }
        guard position < units.count, Self.isIdentifierStart(units[position]) else { return nil }
        while position < units.count, Self.isIdentifierPart(units[position]) { position += 1 }
        while position < units.count, units[position] == 0x20 { position += 1 }
        guard position < units.count, units[position] == 0x3A, peek(position + 1) != 0x3A else { return nil }
        var depth = 0
        position += 1
        while position < units.count, position - index < 512 {
            switch units[position] {
            case 0x28: depth += 1
            case 0x29: depth -= 1
            case 0x7D where depth <= 0: return position + 1
            case 0x0A, 0x3B, 0x7B: return nil
            default: break
            }
            position += 1
        }
        return nil
    }

    private func endOfNumber(from index: Int) -> Int {
        var index = index
        if units[index] == 0x30, let next = peek(index + 1), next == 0x78 || next == 0x58 || next == 0x62 || next == 0x42 { // 0x… 0b…
            index += 2
            while index < units.count, Self.isHexDigit(units[index]) || units[index] == 0x5F { index += 1 }
            return index
        }
        while index < units.count, Self.isDigit(units[index]) || units[index] == 0x5F { index += 1 }
        if peek(index) == 0x2E, peek(index + 1) != 0x2E {
            index += 1
            while index < units.count, Self.isDigit(units[index]) || units[index] == 0x5F { index += 1 }
        }
        if let e = peek(index), e == 0x65 || e == 0x45 {
            var lookahead = index + 1
            if let sign = peek(lookahead), sign == 0x2B || sign == 0x2D { lookahead += 1 }
            if let digit = peek(lookahead), Self.isDigit(digit) {
                index = lookahead
                while index < units.count, Self.isDigit(units[index]) { index += 1 }
            }
        }
        // `1abc` lexes as one token in ClickHouse terms (an error later); keep it together.
        while index < units.count, Self.isIdentifierPart(units[index]) { index += 1 }
        return index
    }

    static func isDigit(_ unit: UInt16) -> Bool { unit >= 0x30 && unit <= 0x39 }

    static func isHexDigit(_ unit: UInt16) -> Bool {
        isDigit(unit) || (unit >= 0x41 && unit <= 0x46) || (unit >= 0x61 && unit <= 0x66)
    }

    static func isIdentifierStart(_ unit: UInt16) -> Bool {
        (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A) || unit == 0x5F || unit >= 0x80
    }

    static func isIdentifierPart(_ unit: UInt16) -> Bool {
        isIdentifierStart(unit) || isDigit(unit)
    }

    /// ClickHouse's `isWordCharASCII`.
    static func isWordChar(_ unit: UInt16) -> Bool {
        (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A) || unit == 0x5F || isDigit(unit)
    }

    static func continuesOperator(previous: UInt16, next: UInt16) -> Bool {
        switch (previous, next) {
        case (0x3C, 0x3D), (0x3E, 0x3D), (0x3C, 0x3E), (0x21, 0x3D), (0x3D, 0x3D), (0x7C, 0x7C), (0x26, 0x26), (0x3A, 0x3A), (0x2D, 0x3E):
            return true // <= >= <> != == || && :: ->
        case (0x3D, 0x3E): // the `=>` of `<=>`
            return true
        default:
            return false
        }
    }
}
