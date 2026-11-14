import Foundation

/// An exception reported by ClickHouse: `Code: 60. DB::Exception: Table x does not exist. (UNKNOWN_TABLE) (version 24.8.14.39 (official build))`.
public struct ClickHouseServerException: Error, Sendable, Equatable, CustomStringConvertible {
    public let code: Int
    /// Symbolic error name (`UNKNOWN_TABLE`), when the server reports one (21.x+).
    public let name: String?
    /// Message without the `Code:` prefix, the `(NAME)` and the `(version …)` suffix.
    public let message: String
    public let version: String?

    public init(code: Int, name: String?, message: String, version: String? = nil) {
        self.code = code
        self.name = name
        self.message = message
        self.version = version
    }

    public var description: String { message }

    static let maxMessageLength = 16 * 1024

    /// Parses exception text (an HTTP error body or an in-band tail). `nil` when the text is not a
    /// ClickHouse exception (e.g. an HTML page from a proxy).
    public static func parse(_ text: String) -> ClickHouseServerException? {
        guard let start = text.range(of: "Code: ") else { return nil }
        var rest = text[start.upperBound...]
        let digits = rest.prefix(while: { $0.isASCII && $0.isNumber })
        guard !digits.isEmpty, digits.count <= 9, let code = Int(digits) else { return nil }
        rest = rest.dropFirst(digits.count)
        // `Code: 60. DB::Exception: …` (modern) or `Code: 62, e.displayText() = DB::Exception: …` (old).
        guard let marker = rest.range(of: "DB::Exception: "), rest.distance(from: rest.startIndex, to: marker.lowerBound) <= 32 else {
            return nil
        }
        var message = String(rest[marker.upperBound...].prefix(maxMessageLength)).trimmingCharacters(in: .whitespacesAndNewlines)
        var version: String?
        if let range = message.range(of: " (version ", options: .backwards), message.hasSuffix(")") {
            let inner = message[range.upperBound...]
            version = inner.prefix(while: { $0.isNumber || $0 == "." }).description
            message = String(message[..<range.lowerBound])
        }
        var name: String?
        if message.hasSuffix(")"), let open = message.range(of: " (", options: .backwards) {
            let candidate = message[open.upperBound..<message.index(before: message.endIndex)]
            if !candidate.isEmpty, candidate.allSatisfy({ ($0.isASCII && ($0.isUppercase || $0.isNumber)) || $0 == "_" }) {
                name = String(candidate)
                message = String(message[..<open.lowerBound])
            }
        }
        return ClickHouseServerException(code: code, name: name, message: message.trimmingCharacters(in: .whitespacesAndNewlines),
                                         version: version?.isEmpty == true ? nil : version)
    }

    /// Where a syntax error points.
    public enum ErrorPosition: Sendable, Equatable {
        /// 1-based line and column (columns count bytes on the line).
        case lineColumn(line: Int, column: Int)
        /// 1-based byte offset into the statement.
        case byteOffset(Int)
    }

    /// Extracts `(line L, col C)` or `failed at position N` from a syntax error message.
    public static func errorPosition(in message: String) -> ErrorPosition? {
        if let match = message.firstMatch(of: /\(line (\d{1,9}), col (\d{1,9})\)/), let line = Int(match.output.1), let column = Int(match.output.2),
           line >= 1, column >= 1 {
            return .lineColumn(line: line, column: column)
        }
        if let match = message.firstMatch(of: /failed at position (\d{1,9})(?!\d)/), let offset = Int(match.output.1), offset >= 1 {
            return .byteOffset(offset)
        }
        return nil
    }
}
