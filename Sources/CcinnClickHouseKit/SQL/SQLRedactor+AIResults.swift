import Foundation

/// Text after masking, and how many spans were masked.
public struct MaskedText: Sendable, Equatable {
    public let text: String
    public let count: Int
}

/// Masking of what AI tools return. Defence in depth under the guard, which keeps object definitions away from AI
/// access: precise on data (a value is altered only when it is clearly a credential, and every alteration is counted,
/// so the tool can say so), thorough on error texts.
extension SQLRedactor {
    /// A result value with its credentials masked:
    /// - the password of a URL (`scheme://user:password@`; a user alone stays);
    /// - the value of a `key=value` pair, and a string literal after a name (`PASSWORD '…'`, `password = '…'`,
    ///   `IDENTIFIED BY '…'`), when the key or name is a credential name (`isCredentialName`; never a bare `KEY`);
    /// - in definition-like text only (`CREATE TABLE …`, `ENGINE = …`), everything `redact` masks, including the
    ///   credential arguments of table functions and engines: as data, `s3('a', 'b', 'c')` is left alone.
    public static func maskSecrets(_ text: String) -> MaskedText {
        let literals = isDefinitionLike(text) ? redactCounting(text) : maskCredentialLiterals(text)
        let urls = maskURLPasswords(literals.text)
        let pairs = maskCredentialPairs(urls.text)
        return MaskedText(text: pairs.text, count: literals.count + urls.count + pairs.count)
    }

    /// An error text an AI tool returns, masked thoroughly (`redact`, URL users and passwords, connection-string
    /// secrets): server errors can echo a view's query (`while processing query: …`).
    public static func maskMessageSecrets(_ message: String) -> String {
        let literalsMasked = message.contains("'") || message.contains("$") ? redact(message) : message
        return maskURLCredentials(maskConnectionSecrets(literalsMasked))
    }

    // MARK: Credential names

    static let credentialNames: Set<String> = [
        "password", "passwd", "pwd", "secret", "secret_key", "secretkey", "secret_access_key", "access_key_id", "accesskeyid",
        "access_key", "accesskey", "token", "access_token", "refresh_token", "id_token", "session_token", "auth_token", "api_key",
        "apikey", "private_key", "privatekey", "client_secret", "credential", "credentials", "accountkey", "account_key",
        "sharedaccesskey", "sharedaccesssignature", "sig", "x-amz-signature", "x-amz-security-token", "x-amz-credential",
        "accesskeysecret",
    ]
    static let credentialSuffixes = ["_password", "_passwd", "_secret", "_token", "_api_key", "_private_key", "_secret_key", "_access_key",
                                     "_access_key_id", "_secret_access_key", "_credentials", "-password", "-secret", "-token"]

    /// A name that holds a credential (`password`, `aws_secret_access_key`, `kafka_sasl_password` …), quotes ignored.
    /// `key`, `author` or `primary_key` are not.
    static func isCredentialName(_ raw: String) -> Bool {
        let name = raw.trimmingCharacters(in: CharacterSet(charactersIn: "'\"`")).lowercased()
        guard !name.isEmpty, name.utf8.count <= 64 else { return false }
        return credentialNames.contains(name) || credentialSuffixes.contains { name.hasSuffix($0) }
    }

    /// A value the server or the masker already hid.
    static func isMaskedValue<Bytes: Collection<UInt8>>(_ value: Bytes) -> Bool {
        value.elementsEqual("***".utf8) || value.elementsEqual("[HIDDEN]".utf8)
    }

    // MARK: Definition-like text

    static let definitionVerbs: Set<String> = ["CREATE", "ATTACH", "ALTER", "REPLACE"]
    static let definitionObjects: Set<String> = ["TABLE", "VIEW", "MATERIALIZED", "LIVE", "WINDOW", "DICTIONARY", "DATABASE", "FUNCTION",
                                                 "USER", "ROLE", "NAMED", "QUOTA", "ROW", "POLICY", "SETTINGS", "PROFILE", "TEMPORARY", "OR",
                                                 "IF"]

    /// DDL or an engine clause, where table-function and engine arguments are credentials by position.
    static func isDefinitionLike(_ text: String) -> Bool {
        let words = text.prefix(120).split(whereSeparator: { $0.isWhitespace || $0 == "(" }).prefix(3).map { $0.uppercased() }
        if let first = words.first, definitionVerbs.contains(first), words.dropFirst().contains(where: definitionObjects.contains) {
            return true
        }
        return text.range(of: "engine", options: .caseInsensitive) != nil
            && text.range(of: #"(?i)\bENGINE\s*="#, options: .regularExpression) != nil
    }

    // MARK: Maskers

    /// String literals after a credential name, `name =` / `name:` with a credential name, or `IDENTIFIED … BY|AS`.
    static func maskCredentialLiterals(_ text: String) -> MaskedText {
        guard text.contains("'") || text.contains("$") else { return MaskedText(text: text, count: 0) }
        let lexer = SQLLexer(text)
        let tokens = lexer.tokens().filter { $0.kind != .comment }
        var ranges: [Range<Int>] = []
        for (index, token) in tokens.enumerated() where token.kind == .string && isCredentialLiteral(at: index, tokens: tokens, lexer: lexer) {
            let value = lexer.stringValue(of: token)
            if !value.isEmpty, !isMaskedValue(value.utf8) { ranges.append(token.range) }
        }
        guard !ranges.isEmpty else { return MaskedText(text: text, count: 0) }
        var units = lexer.units
        for range in ranges.reversed() { units.replaceSubrange(range, with: Array("'***'".utf16)) }
        return MaskedText(text: String(decoding: units, as: UTF16.self), count: ranges.count)
    }

    static func isCredentialLiteral(at index: Int, tokens: [SQLToken], lexer: SQLLexer) -> Bool {
        func text(_ offset: Int) -> String? {
            tokens.indices.contains(index + offset) ? lexer.text(of: tokens[index + offset]) : nil
        }
        guard let previous = text(-1) else { return false }
        if tokens[index - 1].kind != .operator, tokens[index - 1].kind != .punctuation, isCredentialName(previous) { return true }
        if previous == "=" || previous == ":", let key = text(-2), isCredentialName(key) { return true }
        if ["BY", "AS"].contains(previous.uppercased()) {
            return tokens[..<index].contains { ($0.kind == .keyword || $0.kind == .identifier) && lexer.text(of: $0).uppercased() == "IDENTIFIED" }
        }
        return false
    }

    /// `scheme://user:password@host` → `scheme://user:***@host`.
    static func maskURLPasswords(_ text: String) -> MaskedText {
        guard text.contains("://"), text.contains("@") else { return MaskedText(text: text, count: 0) }
        let bytes = Array(text.utf8)
        let colon = UInt8(ascii: ":"), slash = UInt8(ascii: "/"), at = UInt8(ascii: "@")
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var count = 0
        var index = 0
        while index < bytes.count {
            let opensAuthority = bytes[index] == colon && index > 0 && isSchemeByte(bytes[index - 1])
                && index + 2 < bytes.count && bytes[index + 1] == slash && bytes[index + 2] == slash
            guard opensAuthority else {
                output.append(bytes[index])
                index += 1
                continue
            }
            let userStart = index + 3
            var end = userStart
            var passwordStart: Int?
            while end < bytes.count, !isAuthorityEnd(bytes[end]) {
                if bytes[end] == colon, passwordStart == nil { passwordStart = end + 1 }
                end += 1
            }
            output.append(contentsOf: bytes[index..<userStart])
            if end < bytes.count, bytes[end] == at, let start = passwordStart, start < end, !isMaskedValue(bytes[start..<end]) {
                output.append(contentsOf: bytes[userStart..<start])
                output.append(contentsOf: "***".utf8)
                count += 1
                index = end
            } else {
                index = userStart
            }
        }
        return count == 0 ? MaskedText(text: text, count: 0) : MaskedText(text: String(decoding: output, as: UTF8.self), count: count)
    }

    /// `key=value` with a credential-named key (connection strings, URL queries) → `key=***`.
    static func maskCredentialPairs(_ text: String) -> MaskedText {
        guard text.contains("=") else { return MaskedText(text: text, count: 0) }
        let bytes = Array(text.utf8)
        let equals = UInt8(ascii: "=")
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var count = 0
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            output.append(byte)
            index += 1
            guard byte == equals else { continue }
            let keyEnd = index - 1
            var keyStart = keyEnd
            while keyStart > 0, isKeyByte(bytes[keyStart - 1]) { keyStart -= 1 }
            guard keyStart < keyEnd, isCredentialName(String(decoding: bytes[keyStart..<keyEnd], as: UTF8.self)) else { continue }
            var valueEnd = index
            while valueEnd < bytes.count, !isValueEnd(bytes[valueEnd]) { valueEnd += 1 }
            guard index < valueEnd, !isMaskedValue(bytes[index..<valueEnd]) else { continue }
            output.append(contentsOf: "***".utf8)
            count += 1
            index = valueEnd
        }
        return count == 0 ? MaskedText(text: text, count: 0) : MaskedText(text: String(decoding: output, as: UTF8.self), count: count)
    }

    private static func isSchemeByte(_ byte: UInt8) -> Bool {
        (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x30 && byte <= 0x39) || byte == 0x2B || byte == 0x2D || byte == 0x2E
    }

    /// The end of a URL's user information: `/ ? # @`, whitespace, quotes and angle brackets.
    private static func isAuthorityEnd(_ byte: UInt8) -> Bool {
        [0x2F, 0x3F, 0x23, 0x40, 0x20, 0x09, 0x0A, 0x0D, 0x27, 0x22, 0x60, 0x3C, 0x3E].contains(byte)
    }

    private static func isKeyByte(_ byte: UInt8) -> Bool {
        (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x30 && byte <= 0x39) || byte == 0x5F || byte == 0x2D
    }

    /// The end of a pair's value: `;`, `&`, quotes and whitespace.
    private static func isValueEnd(_ byte: UInt8) -> Bool {
        [0x3B, 0x26, 0x27, 0x22, 0x20, 0x09, 0x0A, 0x0D].contains(byte)
    }
}
