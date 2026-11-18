import Compression
import Foundation

/// Counters from `X-ClickHouse-Progress` / `X-ClickHouse-Summary` headers and `system.processes`.
/// Every value is clamped into `Int64` (servers send unsigned 64-bit numbers as strings).
public struct QueryProgress: Sendable, Equatable {
    public var readRows: Int64 = 0
    public var readBytes: Int64 = 0
    public var writtenRows: Int64 = 0
    public var writtenBytes: Int64 = 0
    public var totalRowsToRead: Int64 = 0
    public var resultRows: Int64 = 0
    public var resultBytes: Int64 = 0
    public var elapsedNanoseconds: Int64 = 0
    public var memoryUsage: Int64 = 0
    public var peakMemoryUsage: Int64 = 0

    public init() {}

    public var elapsedSeconds: Double { Double(elapsedNanoseconds) / 1e9 }

    /// Fraction of rows read, when the server knows the total.
    public var fractionDone: Double? {
        guard totalRowsToRead > 0 else { return nil }
        return min(1, max(0, Double(readRows) / Double(totalRowsToRead)))
    }

    /// Parses one header value (a flat JSON object).
    public init?(headerValue: String) {
        guard let data = headerValue.trimmingCharacters(in: .whitespaces).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func number(_ key: String) -> Int64 {
            switch object[key] {
            case let text as String: return Self.clamp(text)
            case let value as NSNumber where CFGetTypeID(value) != CFBooleanGetTypeID():
                let double = value.doubleValue
                guard double.isFinite else { return 0 }
                if double >= 9.2e18 { return .max }
                if double <= 0 { return 0 }
                return value.int64Value
            default: return 0
            }
        }
        readRows = number("read_rows")
        readBytes = number("read_bytes")
        writtenRows = number("written_rows")
        writtenBytes = number("written_bytes")
        totalRowsToRead = number("total_rows_to_read")
        resultRows = number("result_rows")
        resultBytes = number("result_bytes")
        elapsedNanoseconds = number("elapsed_ns")
        memoryUsage = number("memory_usage")
        peakMemoryUsage = number("peak_memory_usage")
    }

    /// Unsigned decimal text → Int64, saturating; anything else → 0.
    public static func clamp(_ text: String) -> Int64 {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let value = Int64(trimmed) { return max(0, value) }
        if !trimmed.isEmpty, trimmed.allSatisfy({ $0.isASCII && $0.isNumber }) { return .max }
        return 0
    }

    /// The most recent progress object from (possibly repeated, possibly comma-joined) header values.
    public static func latest(fromHeaderValues values: [String]) -> QueryProgress? {
        for value in values.reversed() {
            if let last = lastObject(in: value), let progress = QueryProgress(headerValue: last) { return progress }
        }
        return nil
    }

    static func lastObject(in text: String) -> String? {
        var depth = 0
        var start: String.Index?
        var last: Substring?
        var inString = false
        var escaped = false
        for index in text.indices {
            let character = text[index]
            if inString {
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
                continue
            }
            switch character {
            case "\"": inString = true
            case "{":
                if depth == 0 { start = index }
                depth += 1
            case "}":
                depth -= 1
                if depth == 0, let begin = start { last = text[begin...index] }
                if depth < 0 { depth = 0 }
            default: break
            }
        }
        return last.map(String.init)
    }
}

/// Safe construction of identifiers and literals for statements the app builds itself.
public enum SQLText {
    /// Back-quoted identifier with backslash escapes. C0 control characters and DEL become `\xHH`, which ClickHouse
    /// decodes back: nothing is dropped, so the server reads exactly the name given (a dropped NUL would name another).
    public static func quoteIdentifier(_ name: String) -> String {
        var escaped = "`"
        for scalar in name.unicodeScalars {
            switch scalar {
            case "\\": escaped += "\\\\"
            case "`": escaped += "\\`"
            case _ where scalar.value < 0x20 || scalar.value == 0x7F: escaped += String(format: "\\x%02X", scalar.value)
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped + "`"
    }

    /// `` `a`.`b` `` from the non-empty parts.
    public static func qualified(_ parts: String?...) -> String {
        parts.compactMap { $0 }.filter { !$0.isEmpty }.map(quoteIdentifier).joined(separator: ".")
    }

    /// Single-quoted string literal. `'` is doubled (`''`), never backslash-escaped: under a dialect without backslash
    /// escapes (polyglot/postgresql) a `\'` would end the string early. `\` and control characters keep their backslash
    /// escapes, which ClickHouse SQL reads back exactly.
    public static func literal(_ value: String) -> String {
        var escaped = "'"
        escaped.reserveCapacity(value.utf8.count + 2)
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": escaped += "\\\\"
            case "'": escaped += "''"
            case "\0": escaped += "\\0"
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped + "'"
    }
}

/// Builds request URLs with strictly percent-encoded query parameters.
public enum QueryURL {
    static let unreserved: Set<UInt8> = Set(Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".utf8))

    public static func encode(_ text: String) -> String {
        var output = ""
        output.reserveCapacity(text.utf8.count)
        for byte in text.utf8 {
            if unreserved.contains(byte) {
                output.unicodeScalars.append(Unicode.Scalar(byte))
            } else {
                output += String(format: "%%%02X", byte)
            }
        }
        return output
    }

    /// `base` (scheme, host, port, optional path prefix) plus the encoded parameters, in order.
    public static func build(base: URL, parameters: [(String, String)]) -> URL? {
        var text = base.absoluteString
        if let query = text.firstIndex(of: "?") { text = String(text[..<query]) }
        if base.path.isEmpty, !text.hasSuffix("/") { text += "/" }
        guard !parameters.isEmpty else { return URL(string: text) }
        text += "?" + parameters.map { encode($0.0) + "=" + encode($0.1) }.joined(separator: "&")
        return URL(string: text)
    }
}

/// CRC-32 (IEEE 802.3, reflected, as used by gzip).
public struct CRC32: Sendable {
    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var crc = UInt32(index)
        for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        return crc
    }

    private var state: UInt32 = 0xFFFF_FFFF

    public init() {}

    public mutating func update<Bytes: Sequence>(_ bytes: Bytes) where Bytes.Element == UInt8 {
        var crc = state
        for byte in bytes {
            crc = Self.table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        state = crc
    }

    public var value: UInt32 { state ^ 0xFFFF_FFFF }

    public static func checksum<Bytes: Sequence>(_ bytes: Bytes) -> UInt32 where Bytes.Element == UInt8 {
        var crc = CRC32()
        crc.update(bytes)
        return crc.value
    }
}

/// gzip (RFC 1952) encoder for request bodies, using the Compression framework's raw DEFLATE.
public enum Gzip {
    public static func compress(_ input: Data) -> Data? {
        let capacity = max(64, input.count + input.count / 8 + 1024)
        var deflated = [UInt8](repeating: 0, count: capacity)
        let written: Int = input.withUnsafeBytes { source -> Int in
            deflated.withUnsafeMutableBufferPointer { destination -> Int in
                guard let destinationBase = destination.baseAddress else { return 0 }
                guard let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else {
                    // Empty input: an empty final stored block.
                    destination[0] = 0x03
                    destination[1] = 0x00
                    return 2
                }
                return compression_encode_buffer(destinationBase, destination.count, sourceBase, source.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        var output = Data([0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF])
        output.append(contentsOf: deflated.prefix(written))
        let crc = CRC32.checksum(input)
        let size = UInt32(truncatingIfNeeded: input.count)
        for shift in stride(from: 0, to: 32, by: 8) { output.append(UInt8(truncatingIfNeeded: crc >> UInt32(shift))) }
        for shift in stride(from: 0, to: 32, by: 8) { output.append(UInt8(truncatingIfNeeded: size >> UInt32(shift))) }
        return output
    }
}
