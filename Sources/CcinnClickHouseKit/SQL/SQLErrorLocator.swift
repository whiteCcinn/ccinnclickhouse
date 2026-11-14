import ClickHouseWire
import Foundation

/// Maps ClickHouse syntax-error positions (`failed at position 19 (line 2, col 9)`: 1-based, counted in
/// UTF-8 bytes) to a UTF-16 offset inside the statement text, clamped to the text.
public enum SQLErrorLocator {
    public static func offset(in statement: String, message: String) -> Int? {
        guard let position = ClickHouseServerException.errorPosition(in: message) else { return nil }
        let bytes = Array(statement.utf8)
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
}
