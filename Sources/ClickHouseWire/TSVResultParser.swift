import Foundation

/// A result column: name and ClickHouse type.
public struct ColumnDefinition: Sendable, Hashable {
    public let name: String
    public let type: ClickHouseType

    public init(name: String, type: ClickHouseType) {
        self.name = name
        self.type = type
    }

    public init(name: String, typeName: String) {
        self.init(name: name, type: ClickHouseType.parse(typeName))
    }
}

public enum TSVParseError: Error, Sendable, Equatable, CustomStringConvertible {
    /// A row has the wrong number of fields and no server exception explains it.
    case malformedRow(line: Int, detail: String)
    /// The stream ended inside a row.
    case truncated(line: Int)
    /// A single line exceeded the configured maximum.
    case lineTooLong(limit: Int)

    public var description: String {
        switch self {
        case let .malformedRow(line, detail): "Unexpected data in the result at line \(line): \(detail)"
        case let .truncated(line): "The result ended unexpectedly at line \(line)"
        case let .lineTooLong(limit): "A result row is larger than \(limit / (1024 * 1024)) MB"
        }
    }
}

/// Incremental parser for ClickHouse's `TabSeparatedWithNamesAndTypes` output (design D3, D4).
///
/// - Line 1: column names, line 2: type names, then one row per line, fields separated by raw tabs.
/// - `\N` is NULL; scalar fields are unescaped; composite fields (Array/Tuple/Map/Nested) are kept
///   verbatim because ClickHouse writes them in literal syntax.
/// - Exceptions that interrupt a streamed result are recognised in every server framing: the plain
///   `Code: N. DB::Exception: …` tail (22.x–25.x) and the `__exception__` block announced by
///   `X-ClickHouse-Exception-Tag` (26.x). The most recent line is held back while it could be the
///   start of such an exception, so partial results of failed queries are never returned as rows.
public struct TSVResultParser: Sendable {
    public private(set) var columns: [ColumnDefinition]?
    public let exceptionTag: String?
    public let maxLineBytes: Int
    /// Number of complete lines seen (header included), for error messages.
    public private(set) var lineNumber = 0

    private var names: [String]?
    private var composite: [Bool] = []
    private var pending: [UInt8] = []
    private var heldLine: [UInt8]?
    private var trailer: [UInt8]?
    /// The trailer started with a line the server never terminated (stream cut short).
    private var trailerIsUnterminated = false
    static let maxTrailerBytes = 64 * 1024

    public init(exceptionTag: String? = nil, maxLineBytes: Int = 64 * 1024 * 1024) {
        self.exceptionTag = exceptionTag?.isEmpty == true ? nil : exceptionTag
        self.maxLineBytes = max(16, maxLineBytes)
    }

    /// The stream switched to an exception/garbage trailer; no more rows will be produced.
    public var isInTrailer: Bool { trailer != nil }

    // MARK: Feeding

    public mutating func consume(_ data: Data) throws -> [[String?]] {
        try data.withUnsafeBytes { try consume($0) }
    }

    public mutating func consume(_ bytes: [UInt8]) throws -> [[String?]] {
        try bytes.withUnsafeBytes { try consume($0) }
    }

    /// Parses `bytes` and returns the rows completed by them.
    public mutating func consume(_ bytes: UnsafeRawBufferPointer) throws -> [[String?]] {
        var rows: [[String?]] = []
        guard let base = bytes.baseAddress, bytes.count > 0 else { return rows }
        if trailer != nil {
            appendTrailer(UnsafeRawBufferPointer(start: base, count: bytes.count))
            return rows
        }
        var start = 0
        while start < bytes.count {
            guard let found = memchr(base + start, 0x0A, bytes.count - start) else {
                pending.append(contentsOf: UnsafeRawBufferPointer(start: base + start, count: bytes.count - start))
                if pending.count > maxLineBytes { throw TSVParseError.lineTooLong(limit: maxLineBytes) }
                break
            }
            let end = base.distance(to: UnsafeRawPointer(found))
            if pending.isEmpty {
                try process(line: UnsafeRawBufferPointer(start: base + start, count: end - start), into: &rows)
            } else {
                pending.append(contentsOf: UnsafeRawBufferPointer(start: base + start, count: end - start))
                if pending.count > maxLineBytes { throw TSVParseError.lineTooLong(limit: maxLineBytes) }
                let line = pending
                pending.removeAll(keepingCapacity: true)
                try line.withUnsafeBytes { try process(line: $0, into: &rows) }
            }
            start = end + 1
            if trailer != nil {
                if start < bytes.count { appendTrailer(UnsafeRawBufferPointer(start: base + start, count: bytes.count - start)) }
                break
            }
        }
        return rows
    }

    /// Ends the stream. `abruptly` means the transport failed (connection dropped, broken chunking).
    /// Returns the last rows, or throws the server exception / a parse error.
    public mutating func finish(abruptly: Bool) throws -> [[String?]] {
        var rows: [[String?]] = []
        if trailer == nil, !pending.isEmpty {
            // ClickHouse terminates every row with a newline: an unterminated line is either an
            // exception tail or a row cut short.
            let line = pending
            pending.removeAll()
            if let held = heldLine {
                heldLine = nil
                trailer = held + [0x0A] + line.prefix(Self.maxTrailerBytes)
            } else {
                trailer = Array(line.prefix(Self.maxTrailerBytes))
            }
            trailerIsUnterminated = true
        }
        if let trailer {
            let text = String(decoding: trailer, as: UTF8.self)
            if let exception = Self.exception(inTrailer: text, tag: exceptionTag) { throw exception }
            if abruptly || trailerIsUnterminated { throw TSVParseError.truncated(line: lineNumber + 1) }
            throw TSVParseError.malformedRow(line: lineNumber + 1, detail: String(text.prefix(200)))
        }
        if let held = heldLine {
            heldLine = nil
            let text = String(decoding: held, as: UTF8.self)
            if let exception = ClickHouseServerException.parse(text), abruptly || text.contains("(version ") {
                throw exception
            }
            try held.withUnsafeBytes { try emitRow($0, into: &rows) }
        }
        if abruptly { throw TSVParseError.truncated(line: lineNumber + 1) }
        return rows
    }

    // MARK: Lines

    private mutating func process(line: UnsafeRawBufferPointer, into rows: inout [[String?]]) throws {
        lineNumber += 1
        guard let names else {
            if Self.startsWithCode(line) {
                enterTrailer(with: line)
                return
            }
            self.names = Self.splitFields(line).map { Self.unescape($0) }
            return
        }
        guard columns != nil else {
            let typeNames = Self.splitFields(line).map { Self.unescape($0) }
            guard typeNames.count == names.count else {
                enterTrailer(with: line)
                return
            }
            let definitions = zip(names, typeNames).map { ColumnDefinition(name: $0, typeName: $1) }
            columns = definitions
            composite = definitions.map(\.type.isComposite)
            return
        }
        if let held = heldLine {
            heldLine = nil
            if exceptionTag != nil, held == [0x0D], Self.equals(line, "__exception__\r") {
                trailer = held + [0x0A]
                appendTrailer(line)
                appendTrailerNewline()
                return
            }
            let ok = try held.withUnsafeBytes { try emitRowIfValid($0, into: &rows) }
            guard ok else {
                trailer = held + [0x0A]
                appendTrailer(line)
                appendTrailerNewline()
                return
            }
        }
        if shouldHold(line) {
            heldLine = Array(line)
            return
        }
        if try !emitRowIfValid(line, into: &rows) {
            enterTrailer(with: line)
        }
    }

    private func shouldHold(_ line: UnsafeRawBufferPointer) -> Bool {
        if exceptionTag != nil, line.count == 1, line[0] == 0x0D { return true }
        return Self.startsWithCode(line)
    }

    private static func startsWithCode(_ line: UnsafeRawBufferPointer) -> Bool {
        let prefix: [UInt8] = Array("Code: ".utf8)
        guard line.count > prefix.count + 2 else { return false }
        for (offset, byte) in prefix.enumerated() where line[offset] != byte { return false }
        let next = line[prefix.count]
        return next >= 0x30 && next <= 0x39
    }

    private static func equals(_ line: UnsafeRawBufferPointer, _ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard line.count == bytes.count else { return false }
        for index in bytes.indices where line[index] != bytes[index] { return false }
        return true
    }

    private mutating func enterTrailer(with line: UnsafeRawBufferPointer) {
        trailer = []
        appendTrailer(line)
        appendTrailerNewline()
    }

    private mutating func appendTrailerNewline() {
        if let count = trailer?.count, count < Self.maxTrailerBytes { trailer?.append(0x0A) }
    }

    private mutating func appendTrailer(_ bytes: UnsafeRawBufferPointer) {
        guard var current = trailer else { return }
        let room = Self.maxTrailerBytes - current.count
        if room > 0 { current.append(contentsOf: bytes.prefix(room)) }
        trailer = current
    }

    private mutating func emitRow(_ line: UnsafeRawBufferPointer, into rows: inout [[String?]]) throws {
        if try !emitRowIfValid(line, into: &rows) {
            throw TSVParseError.malformedRow(line: lineNumber, detail: String(decoding: line.prefix(200), as: UTF8.self))
        }
    }

    /// Appends the decoded row; `false` when the field count does not match the header.
    private func emitRowIfValid(_ line: UnsafeRawBufferPointer, into rows: inout [[String?]]) throws -> Bool {
        let fields = Self.splitFields(line)
        guard fields.count == composite.count else { return false }
        var row: [String?] = []
        row.reserveCapacity(fields.count)
        for (index, field) in fields.enumerated() {
            if field.count == 2, field[field.startIndex] == 0x5C, field[field.startIndex + 1] == 0x4E { // \N
                row.append(nil)
            } else if composite[index] {
                row.append(String(decoding: field, as: UTF8.self))
            } else {
                row.append(Self.unescape(field))
            }
        }
        rows.append(row)
        return true
    }

    // MARK: Fields

    static func splitFields(_ line: UnsafeRawBufferPointer) -> [Slice<UnsafeRawBufferPointer>] {
        var fields: [Slice<UnsafeRawBufferPointer>] = []
        var start = 0
        var index = 0
        while index < line.count {
            if line[index] == 0x09 {
                fields.append(line[start..<index])
                start = index + 1
            }
            index += 1
        }
        fields.append(line[start..<line.count])
        return fields
    }

    /// Reverses ClickHouse's TSV escaping. Unknown escapes yield the escaped character; a trailing
    /// lone backslash is kept.
    static func unescape<Bytes: Collection>(_ field: Bytes) -> String where Bytes.Element == UInt8 {
        guard field.contains(0x5C) else { return String(decoding: field, as: UTF8.self) }
        var output: [UInt8] = []
        output.reserveCapacity(field.count)
        var iterator = field.makeIterator()
        while let byte = iterator.next() {
            guard byte == 0x5C else {
                output.append(byte)
                continue
            }
            guard let next = iterator.next() else {
                output.append(0x5C)
                break
            }
            switch next {
            case UInt8(ascii: "t"): output.append(0x09)
            case UInt8(ascii: "n"): output.append(0x0A)
            case UInt8(ascii: "r"): output.append(0x0D)
            case UInt8(ascii: "0"): output.append(0x00)
            case UInt8(ascii: "b"): output.append(0x08)
            case UInt8(ascii: "f"): output.append(0x0C)
            case UInt8(ascii: "a"): output.append(0x07)
            case UInt8(ascii: "v"): output.append(0x0B)
            default: output.append(next)
            }
        }
        return String(decoding: output, as: UTF8.self)
    }

    // MARK: Exceptions

    /// Finds a server exception in the bytes after the last good row.
    static func exception(inTrailer text: String, tag: String?) -> ClickHouseServerException? {
        if let tag, let marker = text.range(of: "__exception__\r\n\(tag)\r\n") {
            var body = String(text[marker.upperBound...])
            if let end = body.range(of: " \(tag)\r\n__exception__", options: .backwards) {
                body = String(body[..<end.lowerBound])
                // Drop the trailing "<length>" token that precedes the tag.
                if let lastNewline = body.lastIndex(of: "\n") { body = String(body[..<lastNewline]) }
            }
            if let parsed = ClickHouseServerException.parse(body) { return parsed }
            return ClickHouseServerException(code: 0, name: nil, message: body.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return ClickHouseServerException.parse(text)
    }
}
