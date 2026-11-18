import Foundation

/// How `SQLFormatter` lays out SQL.
public struct SQLFormatOptions: Sendable, Equatable {
    public enum KeywordCase: String, Sendable, CaseIterable, Identifiable {
        case upper, lower, preserve
        public var id: String { rawValue }
    }

    /// `.preserve` by default: ClickHouse names and functions are case-sensitive and almost every keyword is also a valid
    /// name, so only words proven to be keywords where they stand ever change case (see `SQLFormatAnalysis`).
    public var keywordCase: KeywordCase
    /// Spaces per indent level, always 1…8: every assignment is clamped, so no option can make the layout trap.
    public var indentWidth: Int {
        get { clampedIndentWidth }
        set { clampedIndentWidth = Self.clamped(newValue) }
    }
    private var clampedIndentWidth: Int

    public init(keywordCase: KeywordCase = .preserve, indentWidth: Int = 2) {
        self.keywordCase = keywordCase
        clampedIndentWidth = Self.clamped(indentWidth)
    }

    static func clamped(_ width: Int) -> Int { min(max(width, 1), 8) }
}

/// Formats ClickHouse SQL by deciding the whitespace between the lexer's tokens (design D1–D5 of add-sql-formatter).
///
/// Only whitespace and the letter case of words proven to be keywords change. Names, functions, strings, heredocs,
/// quoted names, parameters, comments and `INSERT … FORMAT` data keep their exact text; tokens that touch in the input
/// keep touching unless an allow-list says whitespace there never matters (`a,b`, `x=1`). The result is re-lexed and
/// checked against the input; `nil` means it could not be formatted safely, and the caller changes nothing.
public enum SQLFormatter {
    /// Why Format SQL left the text as it was.
    public enum Refusal: Sendable, Equatable, Error {
        /// A token supported servers read differently, or where a word is split between two tokens (`1_000` is a name on
        /// 22.8 and a number later; `.5x` is `.5` and `x`): the re-lex check cannot catch a lexer mistake there.
        case ambiguousToken(String)
        /// An invisible character outside strings, quoted names and comments (U+00A0, U+200B, U+FEFF, …; the code point):
        /// servers skip some as whitespace and reject others.
        case invisibleCharacter(UInt32)
        /// The result would be more than `outputLimit` long (pathological nesting).
        case tooLarge
        /// The result failed the equivalence check (design D3).
        case notEquivalent
        /// The work was cancelled (a newer request or an edit).
        case cancelled
    }

    /// The longest result accepted for an input of `length` UTF-16 units; the layout stops as soon as it is passed.
    public static func outputLimit(forInputLength length: Int) -> Int {
        let (product, productOverflow) = max(0, length).multipliedReportingOverflow(by: 16)
        let (limit, sumOverflow) = product.addingReportingOverflow(65_536)
        return productOverflow || sumOverflow ? .max : limit
    }

    public static func format(_ text: String, options: SQLFormatOptions = SQLFormatOptions()) -> String? {
        try? formatted(text, options: options).get()
    }

    /// `format`, with the reason when the text is left alone.
    public static func formatted(_ text: String, options: SQLFormatOptions = SQLFormatOptions()) -> Result<String, Refusal> {
        let lexer = SQLLexer(text)
        let tokens = lexer.tokens()
        guard !tokens.isEmpty else { return .success("") }
        if let token = ambiguousToken(lexer: lexer, tokens: tokens) { return .failure(.ambiguousToken(token)) }
        if let invisible = lexer.invisibleCharacter(in: tokens) { return .failure(.invisibleCharacter(invisible.scalar.value)) }
        let analysis = SQLFormatAnalysis.analyze(lexer: lexer, tokens: tokens)
        guard !Task.isCancelled else { return .failure(.cancelled) }
        var layout = SQLFormatLayout(lexer: lexer, tokens: tokens, analysis: analysis, changeable: analysis.changeable, options: options,
                                     limit: outputLimit(forInputLength: lexer.units.count))
        let output: String
        switch layout.run(endOfText: true) {
        case let .success(text): output = text
        case let .failure(refusal): return .failure(refusal)
        }
        guard verify(lexer: lexer, tokens: tokens, analysis: analysis, changeable: analysis.changeable, output: output) else {
            return .failure(Task.isCancelled ? .cancelled : .notEquivalent)
        }
        return .success(output)
    }

    /// The first token of `text` that Format SQL will not trust, or `nil`.
    public static func ambiguousToken(in text: String) -> String? {
        let lexer = SQLLexer(text)
        return ambiguousToken(lexer: lexer, tokens: lexer.tokens())
    }

    /// Tokens the re-lex check cannot vouch for, because it re-lexes with this same lexer:
    /// - a number supported servers read differently: with `_` (22.8 has no digit separators, so `1_000` is a name there
    ///   and `1_000.5` is `1_000`, `.`, `5`), or a `0x`/`0b` prefix without a valid digit after it (22.8 reads a number
    ///   prefix, 24.8+ a name: `0x.5`, `0b2.5`, `0xg`);
    /// - a heredoc whose tag is not letters, digits and `_` (`$a b$ … $a b$` is one string on 22.8 and 24.8, names on 26.8);
    /// - two tokens that touch between two word characters (`.5` `x`, `1` `é`): the server splits there too, but that is
    ///   exactly where lexers disagree.
    static func ambiguousToken(lexer: SQLLexer, tokens: [SQLToken]) -> String? {
        if let token = lexer.uncertainToken(in: tokens) { return lexer.text(of: token) }
        let units = lexer.units
        for index in tokens.indices {
            let token = tokens[index]
            if token.kind == .number, isVersionDependentNumber(units[token.range]) { return lexer.text(of: token) }

            guard index > 0 else { continue }
            let previous = tokens[index - 1]
            guard previous.range.upperBound == token.range.lowerBound, !previous.range.isEmpty, !token.range.isEmpty else { continue }
            if SQLLexer.isIdentifierPart(units[previous.range.upperBound - 1]), SQLLexer.isIdentifierPart(units[token.range.lowerBound]) {
                return lexer.text(of: previous) + lexer.text(of: token)
            }
        }
        return nil
    }

    /// A number supported servers read as different kinds or ranges: with `_` (22.8 has no separators) or an invalid
    /// `0x`/`0b` prefix (a number to 22.8, a name to 24.8+). Format SQL refuses all of them; the guard only those whose
    /// range differs (`SQLLexer.uncertainToken`).
    static func isVersionDependentNumber(_ units: ArraySlice<UInt16>) -> Bool {
        units.contains(0x5F) || SQLLexer.hasInvalidPrefix(units)
    }

    /// A formatted selection: the range it replaces (the selection snapped to whole tokens) and its new text.
    public struct FormattedSelection: Sendable, Equatable {
        public let range: NSRange
        public let text: String

        public init(range: NSRange, text: String) {
            self.range = range
            self.text = text
        }
    }

    /// Formats the tokens in `range` (UTF-16). A boundary inside a token (half a string, part of a name) is moved to the
    /// token's edge, so the replacement covers whole tokens. Keyword case is decided in the context of the whole text, and
    /// the whole text with the replacement is checked against the original; `nil` when that check fails.
    public static func formatSelection(in text: String, range: NSRange, options: SQLFormatOptions = SQLFormatOptions())
        -> FormattedSelection? {
        try? formattedSelection(in: text, range: range, options: options).get()
    }

    /// `formatSelection`, with the reason when the text is left alone.
    public static func formattedSelection(in text: String, range: NSRange, options: SQLFormatOptions = SQLFormatOptions())
        -> Result<FormattedSelection, Refusal> {
        let lexer = SQLLexer(text)
        let unitCount = lexer.units.count
        guard range.location != NSNotFound, range.location >= 0, range.length >= 0, NSMaxRange(range) <= unitCount else {
            return .failure(.notEquivalent)
        }
        let tokens = lexer.tokens()
        if let token = ambiguousToken(lexer: lexer, tokens: tokens) { return .failure(.ambiguousToken(token)) }
        if let invisible = lexer.invisibleCharacter(in: tokens) { return .failure(.invisibleCharacter(invisible.scalar.value)) }
        let lower = range.location
        let upper = NSMaxRange(range)
        // Tokens touching the selection (sorted by position).
        let firstCandidate = tokens.partitionIndex { $0.range.upperBound > lower }
        var last = firstCandidate - 1
        while last + 1 < tokens.count, tokens[last + 1].range.lowerBound < upper { last += 1 }
        guard firstCandidate < tokens.count, last >= firstCandidate else {
            return .success(FormattedSelection(range: range, text: (text as NSString).substring(with: range))) // only whitespace
        }
        let first = firstCandidate
        let snapped = tokens[first].range.lowerBound..<tokens[last].range.upperBound
        let fragment = lexer.text(in: snapped)
        let fragmentLexer = SQLLexer(fragment)
        let fragmentTokens = fragmentLexer.tokens()
        // The fragment must lex exactly as that part of the whole text (`t.5` vs a fragment starting at `.5`).
        let shift = snapped.lowerBound
        guard fragmentTokens.count == last - first + 1,
              zip(fragmentTokens, tokens[first...last]).allSatisfy({ $0.kind == $1.kind && $0.range.lowerBound + shift == $1.range.lowerBound
                  && $0.range.upperBound + shift == $1.range.upperBound }) else { return .failure(.notEquivalent) }
        let analysis = SQLFormatAnalysis.analyze(lexer: lexer, tokens: tokens)
        let fragmentAnalysis = SQLFormatAnalysis.analyze(lexer: fragmentLexer, tokens: fragmentTokens)
        // Case changes need the context of the whole statement: decided on the whole text.
        let fragmentChangeable = Array(analysis.changeable[first...last])
        // Line breaks follow the whole text's (CRLF stays CRLF).
        var layout = SQLFormatLayout(lexer: fragmentLexer, tokens: fragmentTokens, analysis: fragmentAnalysis,
                                     changeable: fragmentChangeable, options: options,
                                     limit: outputLimit(forInputLength: fragmentLexer.units.count),
                                     lineBreak: SQLFormatLayout.lineBreak(lexer: lexer, tokens: tokens))
        let formatted: String
        switch layout.run(endOfText: false) {
        case let .success(text): formatted = text
        case let .failure(refusal): return .failure(refusal)
        }
        let spliced = lexer.text(in: 0..<snapped.lowerBound) + formatted + lexer.text(in: snapped.upperBound..<unitCount)
        guard verify(lexer: lexer, tokens: tokens, analysis: analysis, changeable: analysis.changeable, output: spliced) else {
            return .failure(Task.isCancelled ? .cancelled : .notEquivalent)
        }
        return .success(FormattedSelection(range: NSRange(location: snapped.lowerBound, length: snapped.count), text: formatted))
    }

    /// What Format SQL does to an editor: the selection (snapped to whole tokens) or, when nothing is selected, the
    /// whole text.
    public enum Edit: Sendable, Equatable {
        /// Already formatted, or nothing to format.
        case unchanged
        /// Could not be formatted safely (or the work was cancelled): leave the text alone.
        case refused(Refusal)
        /// Replace `range` with `text`, then select `selection`.
        case replace(range: NSRange, text: String, selection: NSRange)
    }

    public static func edit(for text: String, selection: NSRange, options: SQLFormatOptions = SQLFormatOptions()) -> Edit {
        let length = text.utf16.count
        if selection.location != NSNotFound, selection.location >= 0, selection.length > 0, NSMaxRange(selection) <= length {
            let formatted: FormattedSelection
            switch formattedSelection(in: text, range: selection, options: options) {
            case let .success(result): formatted = result
            case let .failure(refusal): return .refused(refusal)
            }
            guard formatted.text != (text as NSString).substring(with: formatted.range) else { return .unchanged }
            return .replace(range: formatted.range, text: formatted.text,
                            selection: NSRange(location: formatted.range.location, length: formatted.text.utf16.count))
        }
        let formatted: String
        switch self.formatted(text, options: options) {
        case let .success(result): formatted = result
        case let .failure(refusal): return .refused(refusal)
        }
        guard formatted != text else { return .unchanged }
        let cursor = selection.location == NSNotFound ? 0 : selection.location
        return .replace(range: NSRange(location: 0, length: length), text: formatted,
                        selection: NSRange(location: mapOffset(cursor, from: text, to: formatted), length: 0))
    }

    /// The offset in `formatted` that corresponds to `offset` in `original`: the position after the same number of
    /// non-whitespace UTF-16 units. Exact for formatter output, which only changes whitespace and letter case.
    public static func mapOffset(_ offset: Int, from original: String, to formatted: String) -> Int {
        let source = Array(original.utf16)
        let target = Array(formatted.utf16)
        let end = min(max(0, offset), source.count)
        let count = source[..<end].reduce(0) { $0 + (isWhitespace($1) ? 0 : 1) }
        var index = 0
        var seen = 0
        while index < target.count, seen < count {
            if !isWhitespace(target[index]) { seen += 1 }
            index += 1
        }
        return index
    }

    static func isWhitespace(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D || unit == 0x0B || unit == 0x0C
    }

    /// The safety check (design D3): the output has the same tokens with the same texts (letter case may differ only
    /// where `changeable` says so), the same `INSERT … FORMAT` data byte for byte, and whitespace was added or removed
    /// between two tokens only where `SQLFormatSpacing` allows it.
    static func verify(lexer: SQLLexer, tokens: [SQLToken], analysis: SQLFormatAnalysis, changeable: [Bool], output: String) -> Bool {
        let outLexer = SQLLexer(output)
        let outTokens = outLexer.tokens()
        guard outTokens.count == tokens.count, changeable.count == tokens.count else { return false }
        let spacing = SQLFormatSpacing(lexer: lexer, tokens: tokens, afterOperand: analysis.afterOperand)
        for index in tokens.indices {
            if index & 0xFFF == 0, Task.isCancelled { return false }
            let original = tokens[index]
            let formatted = outTokens[index]
            guard original.kind == formatted.kind, original.range.count == formatted.range.count else { return false }
            if !lexer.units[original.range].elementsEqual(outLexer.units[formatted.range]) {
                guard changeable[index], asciiCaseInsensitiveEqual(lexer.units[original.range], outLexer.units[formatted.range]) else {
                    return false
                }
            }
            guard index > 0 else { continue }
            let wasAdjacent = tokens[index - 1].range.upperBound == original.range.lowerBound
            let isAdjacent = outTokens[index - 1].range.upperBound == formatted.range.lowerBound
            if wasAdjacent, !isAdjacent, !spacing.mayInsertSpace(index - 1, index) { return false }
            if !wasAdjacent, isAdjacent, !spacing.mayRemoveSpace(index - 1, index) { return false }
        }
        guard !analysis.data.isEmpty else { return true }
        let outAnalysis = SQLFormatAnalysis.analyze(lexer: outLexer, tokens: outTokens)
        let originalData = analysis.dataRanges(tokens: tokens, unitCount: lexer.units.count).map { lexer.units[$0] }
        let outputData = outAnalysis.dataRanges(tokens: outTokens, unitCount: outLexer.units.count).map { outLexer.units[$0] }
        return originalData.count == outputData.count && zip(originalData, outputData).allSatisfy { $0.elementsEqual($1) }
    }

    static func asciiCaseInsensitiveEqual(_ lhs: ArraySlice<UInt16>, _ rhs: ArraySlice<UInt16>) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { left, right in
            guard left != right else { return true }
            guard left < 0x80, right < 0x80 else { return false }
            return (left | 0x20) == (right | 0x20) && (left | 0x20) >= 0x61 && (left | 0x20) <= 0x7A
        }
    }
}

private extension Array {
    /// The first index whose element satisfies `predicate`, for a predicate that is false then true over the array.
    func partitionIndex(where predicate: (Element) -> Bool) -> Int {
        var low = 0
        var high = count
        while low < high {
            let middle = (low + high) / 2
            if predicate(self[middle]) { high = middle } else { low = middle + 1 }
        }
        return low
    }
}

// MARK: - Spacing

/// Where whitespace between two tokens may be added or dropped (design D4). Everything else keeps the input's choice:
/// tokens that touch keep touching (`x'41'`, `arr[1]`, `'1'::UInt8`, `t.1`, `-1`, `f(x)`, `quantile(0.5)(x)`,
/// `{'a':1}`), separated tokens stay separated (`f (x)`, `- 1`).
struct SQLFormatSpacing {
    let lexer: SQLLexer
    let tokens: [SQLToken]
    /// From the analysis: the token follows a complete operand.
    let afterOperand: [Bool]
    /// The text of each punctuation and operator token ("" for others), made once: the rules ask for it many times.
    let symbols: [String]

    static let binaryOperators: Set<String> = ["=", "==", "!=", "<>", "<", ">", "<=", ">=", "<=>", "*", "/", "%", "||", "+", "-", "->"]

    init(lexer: SQLLexer, tokens: [SQLToken], afterOperand: [Bool]) {
        self.lexer = lexer
        self.tokens = tokens
        self.afterOperand = afterOperand
        symbols = tokens.map { $0.kind == .punctuation || $0.kind == .operator ? lexer.text(of: $0) : "" }
    }

    func text(_ index: Int) -> String { symbols[index] }

    func isPunctuation(_ index: Int, _ texts: Set<String>) -> Bool {
        tokens[index].kind == .punctuation && texts.contains(text(index))
    }

    func isWord(_ index: Int) -> Bool { tokens[index].kind == .keyword || tokens[index].kind == .identifier }

    /// An operator used between two operands (never `-1`, `count(*)`, `SELECT *`).
    func isBinaryOperator(_ index: Int) -> Bool {
        guard tokens[index].kind == .operator, Self.binaryOperators.contains(text(index)) else { return false }
        return text(index) == "->" || afterOperand.indices.contains(index) && afterOperand[index]
    }

    /// `*` standing for all columns.
    func isAsterisk(_ index: Int) -> Bool {
        tokens[index].kind == .operator && text(index) == "*" && !isBinaryOperator(index)
    }

    /// The input had no whitespace between `previous` and `current`; may the output have some?
    func mayInsertSpace(_ previous: Int, _ current: Int) -> Bool {
        if isPunctuation(previous, [",", ";", "(", "["]) { return true }
        if tokens[previous].kind == .comment || tokens[current].kind == .comment { return true } // comments are whitespace to ClickHouse
        if isPunctuation(current, [")", "]"]) { return true }
        if isPunctuation(current, [".", "(", "[", "{", "}", ","]) || isPunctuation(previous, [".", "{", "}"]) {
            return isPunctuation(current, ["(", "["]) && isBinaryOperator(previous)
        }
        if isBinaryOperator(previous) || isBinaryOperator(current) { return true }
        if isAsterisk(previous) { return isWord(current) }
        if isAsterisk(current) { return tokens[previous].kind == .keyword }
        if isPunctuation(previous, [")", "]"]) { return isWord(current) }
        return false
    }

    /// The input had whitespace between `previous` and `current`; may the output have none?
    func mayRemoveSpace(_ previous: Int, _ current: Int) -> Bool {
        guard tokens[previous].kind != .comment, tokens[current].kind != .comment else { return false }
        return isPunctuation(current, [",", ";", ")", "]"]) || isPunctuation(previous, ["(", "["])
    }
}

// MARK: - Layout

/// Decides the whitespace between tokens from the roles the analysis found (design D4).
struct SQLFormatLayout {
    typealias Role = SQLFormatAnalysis.Role
    typealias Clause = SQLFormatAnalysis.Clause

    /// Deeper nesting is not indented further.
    static let maximumIndentLevel = 16

    struct Frame {
        enum Kind { case statement, subquery, list, paren }
        var kind: Kind
        var indent: Int
        var openIndent: Int
        var clause: Clause?
        var listBreak = false
        var hasContent = false
        var cases: [Case] = []

        var allowsClauses: Bool { kind == .statement || kind == .subquery }
    }

    struct Case {
        var multiline: Bool
        var indent: Int
        var end: Int
    }

    enum Want { case none, space, keep }

    let lexer: SQLLexer
    let tokens: [SQLToken]
    let analysis: SQLFormatAnalysis
    let changeable: [Bool]
    let options: SQLFormatOptions
    let spacing: SQLFormatSpacing
    /// The output is refused once it is longer than this (UTF-16 units).
    let limit: Int
    /// `"\r\n"` for CRLF input, `"\n"` otherwise.
    let lineBreak: String
    private(set) var endedInData = false

    private var output = ""
    /// `output.utf16.count`, kept as text is appended.
    private var outputLength = 0
    private var exceededLimit = false
    /// The last token written started its line (after a line comment, for instance).
    private var wroteAtLineStart = false
    private var lineIndent = 0
    private var atLineStart = true
    private var pendingBreak: (indent: Int, blank: Bool)?
    /// Comments that started their own line, by line, written before the next token at that token's indent.
    private var heldLines: [[Int]] = []
    private var frames: [Frame] = [Frame(kind: .statement, indent: 0, openIndent: 0)]
    private var layout = true
    private var statementStarted = false
    /// Only `EXPLAIN [kind]` was written so far in this statement.
    private var explainHeadOnly = false
    private var listHeadEnd: Int?
    /// The next token follows verbatim data and is written without whitespace.
    private var afterData = false

    init(lexer: SQLLexer, tokens: [SQLToken], analysis: SQLFormatAnalysis, changeable: [Bool], options: SQLFormatOptions,
         limit: Int = .max, lineBreak: String? = nil) {
        self.lexer = lexer
        self.tokens = tokens
        self.analysis = analysis
        self.changeable = changeable
        self.options = options
        self.limit = limit
        self.lineBreak = lineBreak ?? Self.lineBreak(lexer: lexer, tokens: tokens)
        spacing = SQLFormatSpacing(lexer: lexer, tokens: tokens, afterOperand: analysis.afterOperand)
    }

    /// The input's line break: the first one between two tokens (or after the last) decides; breaks inside strings
    /// and comments do not count. A `--` comment's `\r` belongs to the comment token, so `-- c\r\n` counts as CRLF.
    static func lineBreak(lexer: SQLLexer, tokens: [SQLToken]) -> String {
        let units = lexer.units
        var gapStart = 0
        for index in 0...tokens.count {
            let gapEnd = index < tokens.count ? tokens[index].range.lowerBound : units.count
            if gapStart < gapEnd, let newline = units[gapStart..<gapEnd].firstIndex(of: 0x0A) {
                return newline > 0 && units[newline - 1] == 0x0D ? "\r\n" : "\n"
            }
            if index < tokens.count { gapStart = tokens[index].range.upperBound }
        }
        return "\n"
    }

    /// Lays the tokens out. `endOfText`: the tokens run to the end of the text, so a line break after the last one is
    /// kept (data keeps its own); a selection keeps none.
    mutating func run(endOfText: Bool) -> Result<String, SQLFormatter.Refusal> {
        var index = 0
        while index < tokens.count {
            if index & 0x3FF == 0, Task.isCancelled { return .failure(.cancelled) }
            if exceededLimit { return .failure(.tooLarge) }
            if tokens[index].kind == .comment {
                comment(index)
                index += 1
                continue
            }
            token(index)
            if let end = analysis.data[index] {
                writeData(after: index, until: end)
                index = max(end, index + 1)
                continue
            }
            index += 1
        }
        flushHeldComments(final: true)
        if endOfText, !endedInData, let last = tokens.last,
           lexer.units[last.range.upperBound...].contains(where: { $0 == 0x0A || $0 == 0x0D }) {
            appendLineBreak()
        }
        if exceededLimit { return .failure(.tooLarge) }
        return .success(output)
    }

    /// The innermost frame, modified in place (a get/set pair would copy its arrays on every change).
    private var frame: Frame {
        get { frames[frames.count - 1] }
        _modify { yield &frames[frames.count - 1] }
    }

    /// Appends to the output, tracking its length against the limit.
    private mutating func append(_ text: String) {
        output += text
        outputLength += text.utf16.count
        if outputLength > limit { exceededLimit = true }
    }

    /// A line break; after a `--` comment that ends in `\r` (CRLF input), that `\r` is already half of it.
    private mutating func appendLineBreak() {
        append(lineBreak == "\r\n" && output.utf16.last == 0x0D ? "\n" : lineBreak)
    }

    private func role(_ index: Int) -> Role { analysis.roles[index] }

    private func text(_ index: Int) -> String { lexer.text(of: tokens[index]) }

    private func isPunctuation(_ index: Int, _ value: String) -> Bool {
        tokens[index].kind == .punctuation && spacing.symbols[index] == value
    }

    private func nextSignificant(after index: Int) -> Int? {
        var cursor = index + 1
        while cursor < tokens.count {
            if tokens[cursor].kind != .comment { return cursor }
            cursor += 1
        }
        return nil
    }

    // MARK: Writing

    private mutating func requestBreak(_ indent: Int, blank: Bool = false) {
        guard !output.isEmpty else { return }
        pendingBreak = (indent, blank || (pendingBreak?.blank ?? false))
    }

    private mutating func newline(indent: Int, blank: Bool) {
        guard !output.isEmpty else { return }
        let level = min(max(0, indent), Self.maximumIndentLevel)
        appendLineBreak()
        if blank { appendLineBreak() }
        append(String(repeating: " ", count: level * SQLFormatOptions.clamped(options.indentWidth)))
        lineIndent = level
        atLineStart = true
    }

    private func isAdjacentInInput(_ index: Int) -> Bool {
        index > 0 && tokens[index - 1].range.upperBound == tokens[index].range.lowerBound
    }

    private mutating func write(_ index: Int, _ want: Want) {
        flushHeldComments()
        wroteAtLineStart = pendingBreak != nil || atLineStart
        if afterData {
            afterData = false
            pendingBreak = nil
        } else if !output.isEmpty, index > 0 {
            let adjacent = isAdjacentInInput(index)
            let mayAddWhitespace = !adjacent || spacing.mayInsertSpace(index - 1, index)
            if let pending = pendingBreak {
                pendingBreak = nil
                if mayAddWhitespace { newline(indent: pending.indent, blank: pending.blank) }
            } else if !atLineStart {
                switch want {
                case .space: if mayAddWhitespace { append(" ") }
                case .none: if !adjacent, !spacing.mayRemoveSpace(index - 1, index) { append(" ") }
                case .keep: if !adjacent { append(" ") }
                }
            }
        }
        append(caseText(index))
        atLineStart = false
        frame.hasContent = true
    }

    /// The token's text, with ASCII letters re-cased when it is a proven keyword (only ASCII words ever are).
    private func caseText(_ index: Int) -> String {
        let units = lexer.units[tokens[index].range]
        guard changeable[index], options.keywordCase != .preserve else { return String(decoding: units, as: UTF16.self) }
        let upper = options.keywordCase == .upper
        return String(decoding: units.map { unit in
            if upper, unit >= 0x61, unit <= 0x7A { return unit - 0x20 }
            if !upper, unit >= 0x41, unit <= 0x5A { return unit + 0x20 }
            return unit
        }, as: UTF16.self)
    }

    /// The source after the format name of `INSERT … FORMAT name`, up to the `;` (or the end), as it is.
    private mutating func writeData(after name: Int, until end: Int) {
        let upper = end < tokens.count ? tokens[end].range.lowerBound : lexer.units.count
        append(lexer.text(in: tokens[name].range.upperBound..<upper))
        atLineStart = false
        afterData = true
        endedInData = end >= tokens.count
    }

    // MARK: Comments

    private mutating func comment(_ index: Int) {
        let startsLine = index == 0 || lexer.units[tokens[index - 1].range.upperBound..<tokens[index].range.lowerBound]
            .contains(where: { $0 == 0x0A || $0 == 0x0D })
        if startsLine, !output.isEmpty {
            heldLines.append([index])
            return
        }
        if !heldLines.isEmpty {
            // A second comment on a held comment's line stays after it.
            heldLines[heldLines.count - 1].append(index)
            return
        }
        // Inline: stays on the current line, whatever break is pending for the next token.
        if !output.isEmpty, !atLineStart, !afterData, !isAdjacentInInput(index) { append(" ") }
        afterData = false
        append(text(index))
        atLineStart = false
        if isLineComment(index) {
            requestBreak(pendingBreak?.indent ?? continuationIndent, blank: pendingBreak?.blank ?? false)
        }
    }

    private func isLineComment(_ index: Int) -> Bool {
        let start = tokens[index].range.lowerBound // block comments start with `/*`; `--`, `//`, `#` comments run to the line end
        return !(lexer.units[start] == 0x2F && start + 1 < lexer.units.count && lexer.units[start + 1] == 0x2A)
    }

    private var continuationIndent: Int {
        !statementStarted ? frame.openIndent : frame.indent + (frame.kind == .list || frame.kind == .paren ? 0 : 1)
    }

    private mutating func flushHeldComments(final: Bool = false) {
        guard !heldLines.isEmpty else { return }
        let indent = pendingBreak?.indent ?? continuationIndent
        let blank = pendingBreak?.blank ?? false
        pendingBreak = nil
        newline(indent: indent, blank: blank)
        for (position, line) in heldLines.enumerated() {
            if position > 0 { newline(indent: indent, blank: false) }
            for (offset, index) in line.enumerated() {
                if offset > 0, !isAdjacentInInput(index) { append(" ") }
                append(text(index))
            }
            atLineStart = false
        }
        heldLines.removeAll()
        if !final { requestBreak(indent) }
    }

    // MARK: Tokens

    private mutating func token(_ index: Int) {
        if !statementStarted {
            statementStarted = true
            layout = analysis.statementKinds[index].hasLayout
            explainHeadOnly = analysis.statementKinds[index] == .explain
        }
        if isPunctuation(index, ";") {
            write(index, .none)
            endStatement()
            return
        }
        let current = role(index)
        defer {
            if explainHeadOnly, current != .statement, current != .continuation { explainHeadOnly = false }
        }
        if tokens[index].kind == .punctuation {
            switch spacing.symbols[index] {
            case "(", "[", "{": openParen(index)
            case ")", "]", "}": closeParen(index)
            case ",": comma(index)
            default: write(index, want(index))
            }
            return
        }
        switch current {
        case let .clause(clause):
            self.clause(index, clause)
        case .join:
            if layout, frame.allowsClauses { requestBreak(frame.indent) }
            write(index, .space)
        case let .joinCondition(on):
            if layout, frame.allowsClauses, on { requestBreak(frame.indent + 1) }
            write(index, .space)
        case .condition:
            if layout, frame.allowsClauses, frame.cases.isEmpty { requestBreak(frame.indent + 1) }
            write(index, .space)
        case .caseStart:
            beginCase(index)
        case .caseWhen, .caseElse:
            if let info = frame.cases.last, info.multiline { requestBreak(info.indent + 1) }
            write(index, .space)
        case .caseEnd:
            if let info = frame.cases.last, info.end == index {
                if info.multiline { requestBreak(info.indent) }
                frame.cases.removeLast()
            }
            write(index, .space)
        case .definitionClause:
            if layout, frame.kind == .statement { requestBreak(frame.indent) }
            write(index, .space)
        default:
            write(index, want(index))
        }
        finishListHead(index)
    }

    private mutating func endStatement() {
        frames = [Frame(kind: .statement, indent: 0, openIndent: 0)]
        statementStarted = false
        listHeadEnd = nil
        requestBreak(0, blank: true)
    }

    /// The whitespace this token wants before it (subject to `SQLFormatSpacing`).
    private func want(_ index: Int) -> Want {
        guard index > 0 else { return .none }
        let previous = index - 1
        if tokens[previous].kind == .comment { return .space }
        let currentText = spacing.symbols[index]
        let previousText = spacing.symbols[previous]
        if [")", "]", ",", ";"].contains(currentText) { return .none }
        if ["(", "["].contains(previousText) { return .none }
        if [".", "::", ":", "?", "{", "}"].contains(currentText) || [".", "::", ":", "?", "{", "}"].contains(previousText) { return .keep }
        if currentText == "(" || currentText == "[" {
            return previousText == "," || spacing.isBinaryOperator(previous) ? .space : .keep
        }
        if ["-", "+"].contains(previousText), !spacing.isBinaryOperator(previous) { return .keep } // a sign
        if tokens[previous].kind == .operator, !SQLFormatSpacing.binaryOperators.contains(previousText) { return .keep }
        if tokens[index].kind == .operator, !SQLFormatSpacing.binaryOperators.contains(currentText) { return .keep }
        return .space
    }

    // MARK: Parentheses, commas

    private mutating func openParen(_ index: Int) {
        write(index, want(index))
        switch role(index) {
        case .subqueryOpen where layout:
            frames.append(Frame(kind: .subquery, indent: lineIndent + 1, openIndent: lineIndent))
            requestBreak(lineIndent + 1)
        case .columnListOpen where layout:
            frames.append(Frame(kind: .list, indent: lineIndent + 1, openIndent: lineIndent))
            requestBreak(lineIndent + 1)
        default:
            frames.append(Frame(kind: .paren, indent: lineIndent + 1, openIndent: lineIndent))
        }
    }

    private mutating func closeParen(_ index: Int) {
        guard frames.count > 1 else {
            write(index, .none) // unbalanced: nothing to close
            return
        }
        let closing = frames.removeLast()
        if closing.kind == .subquery || closing.kind == .list { requestBreak(closing.openIndent) }
        write(index, .none)
    }

    private mutating func comma(_ index: Int) {
        write(index, .none)
        // A comma that had to start its line (after a `--` comment) is followed by its item on that line: `, b`.
        guard !wroteAtLineStart else { return }
        switch frame.kind {
        case .list:
            requestBreak(frame.indent)
        case .statement, .subquery:
            guard layout, frame.cases.isEmpty else { return }
            if frame.clause == .with {
                requestBreak(frame.indent)
            } else if frame.listBreak {
                requestBreak(frame.indent + 1)
            }
        case .paren:
            break
        }
    }

    // MARK: Clauses

    private mutating func clause(_ index: Int, _ clause: Clause) {
        guard layout, frame.allowsClauses, frame.cases.isEmpty else {
            write(index, want(index))
            return
        }
        // No break before the first clause of a statement or subquery, or after `EXPLAIN [kind]`.
        let first = !frame.hasContent || explainHeadOnly
        if !first { requestBreak(frame.indent) }
        write(index, .space)
        frame.clause = clause
        frame.listBreak = false
        listHeadEnd = nil
        switch clause {
        case .select:
            var head = index
            if let next = nextSignificant(after: index), role(next) == .continuation { head = next }
            startList(head: head)
        case .groupBy, .orderBy:
            startList(head: nextSignificant(after: index) ?? index)
        case .set, .values:
            startList(head: index)
        default:
            break
        }
    }

    private mutating func startList(head: Int) {
        frame.listBreak = topLevelCommas(after: head) > 0
        listHeadEnd = head
    }

    /// After the last word of a list clause head (SELECT [DISTINCT], GROUP BY, …): break before the first item.
    private mutating func finishListHead(_ index: Int) {
        guard let head = listHeadEnd, head == index, frame.allowsClauses else { return }
        listHeadEnd = nil
        if frame.listBreak { requestBreak(frame.indent + 1) }
    }

    /// Commas at this nesting level until the clause ends; nested brackets are skipped whole, so the work is linear.
    private func topLevelCommas(after index: Int) -> Int {
        var commas = 0
        var cursor = index + 1
        while cursor < tokens.count {
            if tokens[cursor].kind == .punctuation {
                let unit = lexer.units[tokens[cursor].range.lowerBound]
                switch unit {
                case 0x28, 0x5B, 0x7B: // ( [ {
                    // Nothing after an unclosed bracket is at this level.
                    let close = analysis.matching[cursor]
                    guard close >= 0 else { return commas }
                    cursor = close + 1
                    continue
                case 0x29, 0x5D, 0x7D, 0x3B: return commas // ) ] } ;
                case 0x2C: commas += 1
                default: break
                }
            } else {
                switch role(cursor) {
                case .clause, .join, .definitionClause: return commas
                default: break
                }
            }
            cursor += 1
        }
        return commas
    }

    // MARK: CASE

    private mutating func beginCase(_ index: Int) {
        let shape = analysis.cases[index]
        let multiline = layout && frame.kind != .paren && (shape?.branches ?? 0) >= 2
        write(index, want(index))
        if let shape { frame.cases.append(Case(multiline: multiline, indent: lineIndent, end: shape.end)) }
    }
}
