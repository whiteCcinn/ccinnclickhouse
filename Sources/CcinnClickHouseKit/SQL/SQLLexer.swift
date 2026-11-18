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
/// ClickHouse specifics: nested block comments, `# `/`#!`/`//` line comments, Unicode whitespace (U+00A0, U+FEFF, …),
/// double-quoted identifiers,
/// heredocs (`$$…$$`, `$tag$…$tag$`), binary/hex numbers with `_` separators, `{name:Type}`
/// parameters and the `::`, `->`, `||`, `<=>` operators.
public struct SQLLexer: Sendable {
    public let units: [UInt16]

    /// Closing tags of heredocs, found in one pass: a scan per `$` would be quadratic (`$0 + $1 + …`).
    private let heredocs: HeredocIndex?

    public init(_ text: String) {
        units = Array(text.utf16)
        heredocs = units.contains(0x24) ? HeredocIndex(units) : nil
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
            case _ where Self.isUnicodeWhitespace(unit):
                index += 1
                continue
            case 0x2D where peek(index + 1) == 0x2D, 0x2F where peek(index + 1) == 0x2F: // -- and //
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
                // After a dot every server reads digits and word characters only (`t.1e-x` is `t.1e` minus `x`).
                index = followsDot(tokens) ? endOfWord(from: index) : endOfNumber(from: index)
                tokens.append(SQLToken(kind: .number, range: start..<index))
            case 0x2E where peek(index + 1).map(Self.isDigit) == true && !followsOperand(tokens):
                index = endOfFraction(from: index)
                tokens.append(SQLToken(kind: .number, range: start..<index))
            case 0x28, 0x29, 0x5B, 0x5D, 0x7B, 0x7D, 0x2C, 0x3B, 0x2E: // ( ) [ ] { } , ; .
                index += 1
                tokens.append(SQLToken(kind: .punctuation, range: start..<index))
            default:
                if Self.isIdentifierStart(unit) {
                    // ClickHouse bare words continue through `$` (`a$b`).
                    while index < count, Self.isIdentifierPart(units[index]) || units[index] == 0x24 { index += 1 }
                    // Unicode upper-casing on purpose: the read-only guard must treat `ſettings` like SETTINGS (ClickHouse
                    // rejects such words; they are never keywords there). Format SQL matches keywords on ASCII only.
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

    /// The last token before this one, skipping comments, is a `.`.
    private func followsDot(_ tokens: [SQLToken]) -> Bool {
        guard let last = tokens.last(where: { $0.kind != .comment }) else { return false }
        return last.kind == .punctuation && units[last.range.lowerBound] == 0x2E
    }

    private func endOfWord(from start: Int) -> Int {
        var index = start
        while index < units.count, Self.isWordChar(units[index]) { index += 1 }
        return index
    }

    /// Whether a `.` here is a dot (tuple element, qualified name) rather than the start of a number: ClickHouse decides
    /// by the token before it, skipping whitespace and comments: a name, a number, `)` or `]` (`t.5`, `t .5`, `1.2.3`,
    /// `(1, 2) .1`, even `SELECT .5`). Anywhere else `.5` is a number.
    private func followsOperand(_ tokens: [SQLToken]) -> Bool {
        guard let last = tokens.last(where: { $0.kind != .comment }) else { return false }
        switch last.kind {
        case .identifier, .quotedIdentifier, .keyword, .number: return true
        case .punctuation: return units[last.range.lowerBound] == 0x29 || units[last.range.lowerBound] == 0x5D
        default: return false
        }
    }

    /// Line comments run to `\n` (ClickHouse does not end them at a lone `\r`).
    private func endOfLine(from index: Int) -> Int {
        var index = index
        while index < units.count, units[index] != 0x0A { index += 1 }
        return index
    }

    /// Nested `/* … /* … */ … */` (ClickHouse follows the SQL standard).
    private func endOfBlockComment(from index: Int) -> Int {
        scanBlockComment(from: index).end
    }

    private func scanBlockComment(from index: Int) -> (end: Int, closed: Bool) {
        var index = index + 2
        var depth = 1
        while index < units.count {
            if units[index] == 0x2F, peek(index + 1) == 0x2A {
                depth += 1
                index += 2
            } else if units[index] == 0x2A, peek(index + 1) == 0x2F {
                depth -= 1
                index += 2
                if depth == 0 { return (index, true) }
            } else {
                index += 1
            }
        }
        return (units.count, false)
    }

    private func endOfQuoted(from index: Int, quote: UInt16) -> Int {
        scanQuoted(from: index, quote: quote).end
    }

    private func scanQuoted(from index: Int, quote: UInt16) -> (end: Int, closed: Bool) {
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
                return (index + 1, true)
            }
            index += 1
        }
        return (units.count, false)
    }

    /// A string, quoted identifier or `/* */` comment that runs to the end of the input without its
    /// closing delimiter (nested comments count their depth). Only the last token can be unterminated,
    /// so this rescans at most once. Heredoc strings are always terminated: an opener without its closing
    /// tag is not lexed as a heredoc (see `unterminatedHeredocOpener(at:)`).
    public func isUnterminated(_ token: SQLToken) -> Bool {
        let start = token.range.lowerBound
        guard token.range.upperBound >= units.count, start >= 0, start < units.count else { return false }
        switch token.kind {
        case .string, .quotedIdentifier:
            guard units[start] != 0x24 else { return false } // `$tag$…$tag$`
            return !scanQuoted(from: start, quote: units[start]).closed
        case .comment:
            guard units[start] == 0x2F, peek(start + 1) == 0x2A else { return false } // `--`, `//`, `#` comments end at the line end
            return !scanBlockComment(from: start).closed
        default:
            return false
        }
    }

    /// A heredoc whose tag has a character other than an ASCII letter, digit or `_` (`$a b$ … $a b$`): 22.8 and
    /// 24.8 read one string, 26.8 reads names and whatever stands between them (a SETTINGS clause, a `;`). The
    /// read-only guard refuses such text and Format SQL leaves it alone: neither may see less than a server does.
    public func isVersionDependentHeredoc(_ token: SQLToken) -> Bool {
        let start = token.range.lowerBound
        guard token.kind == .string, start >= 0, start < units.count, units[start] == 0x24 else { return false }
        var index = start + 1
        while index < token.range.upperBound, index < units.count, units[index] != 0x24 {
            if !Self.isWordChar(units[index]) { return true }
            index += 1
        }
        return false
    }

    /// The opener (`$$` or `$tag$`, a tag of word characters) of a heredoc that is never closed, when
    /// one starts at `index`. ClickHouse then lexes `$` and bare words instead of a string, so the rest
    /// of the text is not what the user meant. Other `$` uses (`$1 + $2`) are not heredocs.
    public func unterminatedHeredocOpener(at index: Int) -> Range<Int>? {
        guard index >= 0, index < units.count, units[index] == 0x24 else { return nil }
        var tagEnd = index + 1
        while tagEnd < units.count, units[tagEnd] != 0x24 {
            guard Self.isWordChar(units[tagEnd]), tagEnd - index <= 64 else { return nil }
            tagEnd += 1
        }
        guard tagEnd < units.count, heredocEnd(from: index) == nil else { return nil }
        return index..<(tagEnd + 1)
    }

    /// End (exclusive) of a heredoc starting at `index` (`$`): the tag is everything up to the next `$`
    /// (22.8 and 24.8 accept any text there) and the heredoc ends after the next occurrence of the tag.
    /// `nil` when there is no closing tag. 26.8 accepts only letters, digits and `_` in a tag: see
    /// `isVersionDependentHeredoc`.
    private func heredocEnd(from index: Int) -> Int? {
        heredocs?.end(from: index, units: units)
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

    /// Where a number starting with a digit ends, as ClickHouse's lexer decides (src/Parsers/Lexer.cpp): a literal — an
    /// optional `0x`/`0b` prefix, digits with `_` between two digits, a fraction, an exponent (`e`, or `p` after `0x`)
    /// with its sign — after which word characters run on as part of the token: `1abc`, `1e2x` and `0x1g` are names,
    /// `1.5x` and `1.end` malformed numbers, never a number followed by a word.
    ///
    /// Where supported versions differ, this takes the longer token (Format SQL refuses such text, see
    /// `SQLFormatter.ambiguousToken`): 22.8 reads every `0x`/`0b` as a prefix (`0x.5` is one number; 24.8 reads `0x`, `.`,
    /// `5`) and has no `_` separators (`1_000.5` is `1_000`, `.`, `5` there). It also assumes text follows, as it does
    /// when the app sends a statement with a FORMAT clause (`1e+` is one token).
    private func endOfNumber(from start: Int) -> Int {
        var index = start
        var hex = false
        if units[index] == 0x30, let marker = peek(index + 1), (marker | 0x20) == 0x78 || (marker | 0x20) == 0x62 { // 0x 0X 0b 0B
            hex = (marker | 0x20) == 0x78
            index += 2
        }
        index = endOfDigits(from: index, hex: hex)
        if peek(index) == 0x2E { index = endOfDigits(from: index + 1, hex: hex) }
        index = endOfExponent(from: index, hex: hex)
        while index < units.count, Self.isWordChar(units[index]) { index += 1 }
        return index
    }

    /// Where a number starting with `.` ends: digits and an exponent, but no word characters (`.5x` is `.5` and `x`,
    /// `.5end` is `.5e` and `nd`, as ClickHouse reads them).
    private func endOfFraction(from start: Int) -> Int {
        endOfExponent(from: endOfDigits(from: start + 1, hex: false), hex: false)
    }

    /// Digits (hexadecimal ones after `0x`), with `_` allowed between two digits.
    private func endOfDigits(from start: Int, hex: Bool) -> Int {
        var index = start
        while index < units.count {
            let unit = units[index]
            if hex ? Self.isHexDigit(unit) : Self.isDigit(unit) {
                index += 1
            } else if unit == 0x5F, index > start, let next = peek(index + 1), hex ? Self.isHexDigit(next) : Self.isDigit(next) {
                index += 1
            } else {
                break
            }
        }
        return index
    }

    /// An exponent: `e`/`E` (`p`/`P` after `0x`), then a sign only when a digit follows it, then decimal digits.
    /// Servers take the sign even without digits (`1e-x` is one malformed number to them): `uncertainToken` refuses that
    /// text instead, so a sign never hides what follows it.
    private func endOfExponent(from index: Int, hex: Bool) -> Int {
        guard let marker = peek(index), (marker | 0x20) == (hex ? 0x70 : 0x65) else { return index }
        var end = index + 1
        if let sign = peek(end), sign == 0x2B || sign == 0x2D, let digit = peek(end + 1), Self.isDigit(digit) { end += 1 }
        return endOfDigits(from: end, hex: false)
    }

    /// The first token whose range a supported server could read differently, so that it could hide a token from the
    /// read-only guard (or invent one):
    /// - a heredoc whose tag is not letters, digits and `_` (`isVersionDependentHeredoc`);
    /// - a number with `_` or an invalid `0x`/`0b` prefix that goes on past a word (`1_000.5`, `0x.5`, `1_0e-5`): 22.8
    ///   has no separators and 24.8+ reads such a prefix as a name, so the number ends early there;
    /// - a number ending in an exponent marker right before `+`/`-` (`1e-x`, `.5e+x`): servers take the sign into it.
    /// A digit-led token after a dot is digits and word characters on every server, so it is never uncertain.
    public func uncertainToken(in tokens: [SQLToken]) -> SQLToken? {
        var previous: SQLToken?
        for (position, token) in tokens.enumerated() {
            defer { if token.kind != .comment { previous = token } }
            if isVersionDependentHeredoc(token) { return token }
            guard token.kind == .number, !token.range.isEmpty else { continue }
            if let previous, previous.kind == .punctuation, units[previous.range.lowerBound] == 0x2E { continue }
            let text = units[token.range]
            if text.contains(0x5F) || Self.hasInvalidPrefix(text), text.contains(where: { !Self.isWordChar($0) }) { return token }
            if endsInExponentMarker(text), position + 1 < tokens.count {
                let next = tokens[position + 1]
                if next.range.lowerBound == token.range.upperBound, next.kind == .operator,
                   units[next.range.lowerBound] == 0x2B || units[next.range.lowerBound] == 0x2D {
                    return token
                }
            }
        }
        return nil
    }

    /// `0x`/`0b` without a valid digit after it: a number prefix to 22.8, a name to 24.8+.
    static func hasInvalidPrefix(_ text: ArraySlice<UInt16>) -> Bool {
        var cursor = text.startIndex
        guard cursor < text.endIndex, text[cursor] == 0x30 else { return false }
        cursor += 1
        guard cursor < text.endIndex else { return false }
        let marker = text[cursor] | 0x20
        guard marker == 0x78 || marker == 0x62 else { return false }
        cursor += 1
        guard cursor < text.endIndex else { return true }
        let digit = text[cursor]
        return marker == 0x78 ? !isHexDigit(digit) : !(digit == 0x30 || digit == 0x31)
    }

    /// The number ends in an exponent marker with no digits (`1e`, `1.e`, `.5E`, `0x1p`), not in a word (`1abe`).
    private func endsInExponentMarker(_ text: ArraySlice<UInt16>) -> Bool {
        guard text.count >= 2, let last = text.last else { return false }
        let before = text[text.endIndex - 2]
        let hex = text.count > 2 && text[text.startIndex] == 0x30 && (text[text.startIndex + 1] | 0x20) == 0x78
        if hex { return (last | 0x20) == 0x70 && (Self.isHexDigit(before) || before == 0x2E) }
        return (last | 0x20) == 0x65 && (Self.isDigit(before) || before == 0x2E)
    }

    /// The upper-cased text of an ASCII word; `nil` when it has any other character.
    static func asciiUppercased(_ units: ArraySlice<UInt16>) -> String? {
        guard units.allSatisfy({ $0 < 0x80 }) else { return nil }
        return String(decoding: units.map { $0 >= 0x61 && $0 <= 0x7A ? $0 - 0x20 : $0 }, as: UTF16.self)
    }

    static func isDigit(_ unit: UInt16) -> Bool { unit >= 0x30 && unit <= 0x39 }

    static func isHexDigit(_ unit: UInt16) -> Bool {
        isDigit(unit) || (unit >= 0x41 && unit <= 0x46) || (unit >= 0x61 && unit <= 0x66)
    }

    static func isIdentifierStart(_ unit: UInt16) -> Bool {
        (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A) || unit == 0x5F || (unit >= 0x80 && !isUnicodeWhitespace(unit))
    }

    /// Characters ClickHouse skips as whitespace besides ASCII whitespace: the same on 22.8, 24.8 and 26.8, checked
    /// against every code point by `FormatterIntegrationTests.serverWhitespaceIsExactlyTheLexers`.
    public static let unicodeWhitespace: [ClosedRange<UInt16>] = [
        0x85...0x85, 0xA0...0xA0, 0x180E...0x180E, 0x2000...0x200D, 0x2028...0x2029, 0x202F...0x202F, 0x205F...0x2060,
        0x3000...0x3000, 0xFEFF...0xFEFF,
    ]

    static func isUnicodeWhitespace(_ unit: UInt16) -> Bool {
        guard unit >= 0x85 else { return false }
        return unicodeWhitespace.contains { $0.contains(unit) }
    }

    /// The first character outside strings, quoted names and comments that is Unicode whitespace, a separator, a format
    /// character (U+200B, U+2060, U+FEFF, bidi controls, …) or a control character other than ASCII whitespace. Such text
    /// is invisible, and servers skip some of these as whitespace and reject the others: the read-only guard and Format
    /// SQL refuse it rather than rely on modelling each one.
    public func invisibleCharacter(in tokens: [SQLToken]) -> (offset: Int, scalar: Unicode.Scalar)? {
        var literal = tokens.filter { $0.kind == .string || $0.kind == .quotedIdentifier || $0.kind == .comment }.map(\.range)[...]
        var index = 0
        while index < units.count {
            while let first = literal.first, first.upperBound <= index { literal = literal.dropFirst() }
            if let first = literal.first, first.contains(index) {
                index = first.upperBound
                continue
            }
            let unit = units[index]
            var width = 1
            var value = UInt32(unit)
            if UTF16.isLeadSurrogate(unit), index + 1 < units.count, UTF16.isTrailSurrogate(units[index + 1]) {
                value = 0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(units[index + 1]) - 0xDC00)
                width = 2
            }
            if unit >= 0x80 || (unit < 0x20 && ![0x09, 0x0A, 0x0B, 0x0C, 0x0D].contains(unit)) || unit == 0x7F,
               let scalar = Unicode.Scalar(value) {
                switch scalar.properties.generalCategory {
                case .spaceSeparator, .lineSeparator, .paragraphSeparator, .format, .control:
                    return (index, scalar)
                default:
                    if Self.isUnicodeWhitespace(unit) { return (index, scalar) }
                }
            }
            index += width
        }
        return nil
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

/// Where each heredoc closes, for every `$` at once. A tag has no `$` inside, so `$tag$` occurrences are exactly the
/// pairs of consecutive `$` positions; the heredoc opened by the pair at `a` closes at the first later pair (`b ≥ a + 2`,
/// after the opener) with the same tag. Built in one pass; each lookup is two binary searches.
private struct HeredocIndex: Sendable {
    /// Positions of every `$`.
    let dollars: [Int]
    /// Tag text → indices `m` of the pairs (`dollars[m]`, `dollars[m + 1]`) that enclose it, ascending.
    let pairs: [ArraySlice<UInt16>: [Int]]

    init(_ units: [UInt16]) {
        var dollars: [Int] = []
        for (index, unit) in units.enumerated() where unit == 0x24 { dollars.append(index) }
        var pairs: [ArraySlice<UInt16>: [Int]] = [:]
        if dollars.count > 1 {
            for m in 0..<(dollars.count - 1) { pairs[units[(dollars[m] + 1)..<dollars[m + 1]], default: []].append(m) }
        }
        self.dollars = dollars
        self.pairs = pairs
    }

    func end(from index: Int, units: [UInt16]) -> Int? {
        let a = Self.firstIndex(in: dollars) { $0 >= index }
        guard a + 1 < dollars.count, dollars[a] == index else { return nil }
        guard let list = pairs[units[(dollars[a] + 1)..<dollars[a + 1]]] else { return nil }
        let b = Self.firstIndex(in: list) { $0 >= a + 2 }
        guard b < list.count, list[b] + 1 < dollars.count else { return nil }
        return dollars[list[b] + 1] + 1
    }

    /// The first index whose element satisfies `predicate` (false then true over the array).
    static func firstIndex(in array: [Int], where predicate: (Int) -> Bool) -> Int {
        var low = 0
        var high = array.count
        while low < high {
            let middle = (low + high) / 2
            if predicate(array[middle]) { high = middle } else { low = middle + 1 }
        }
        return low
    }
}
