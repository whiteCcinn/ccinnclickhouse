import ClickHouseKit
import ClickHouseWire
import Foundation
import os
import Testing
@testable import CcinnClickHouseKit

// MARK: - JSON and framing

@Suite("MCP JSON and framing")
struct MCPJSONTests {
    @Test func parsesAndSerializesOnOneLine() throws {
        let value = try JSONValue.parse(#"{"a":[1,2.5,"x\ny",true,null],"b":{"c":"é🙂"}}"#)
        #expect(value["a"]?[0] == .int(1))
        #expect(value["a"]?[1] == .double(2.5))
        #expect(value["a"]?[3] == .bool(true))
        #expect(value["a"]?[4] == .null)
        let text = value.serialized()
        #expect(!text.contains("\n"))
        #expect(try JSONValue.parse(text) == value)
    }

    @Test func escapesControlCharactersAndQuotes() {
        #expect(JSONValue.string("a\"b\\c\u{01}\t\u{2028}").serialized() == "\"a\\\"b\\\\c\\u0001\\t\\u2028\"")
        #expect(JSONValue.double(.nan).serialized() == "null")
    }

    @Test func rejectsInvalidAndDeepJSON() {
        #expect(throws: (any Error).self) { try JSONValue.parse("{nope") }
        #expect(throws: (any Error).self) { try JSONValue.parse(String(repeating: "[", count: 500) + String(repeating: "]", count: 500)) }
    }

    @Test func framerSplitsLinesAndBoundsLength() {
        var framer = LineFramer(maxLineBytes: 16)
        #expect(framer.append(Array("{\"a\":1}\n{\"b\"".utf8)) == [.line("{\"a\":1}")])
        #expect(framer.append(Array(":2}\r\n".utf8)) == [.line("{\"b\":2}")])
        #expect(framer.append(Array(String(repeating: "x", count: 40).utf8)) == [.oversized])
        #expect(framer.append(Array("yyy\n{}\n".utf8)) == [.line("{}")])
        #expect(framer.append(Array("\n\n".utf8)).isEmpty)
    }
}

// MARK: - Protocol

private actor Transcript {
    private(set) var lines: [String] = []
    func append(_ line: String) { lines.append(line) }
    func messages() -> [JSONValue] { lines.compactMap { try? JSONValue.parse($0) } }
}

private struct FakeTools: MCPToolProvider {
    func tools() async -> [MCPTool] {
        [MCPTool(name: "echo", title: "Echo", description: "Echoes", inputSchema: .object(["type": "object"]), readOnly: true),
         MCPTool(name: "slow", title: "Slow", description: "Sleeps", inputSchema: .object(["type": "object"]), readOnly: true)]
    }

    func call(name: String, arguments: [String: JSONValue]) async -> MCPToolResult {
        switch name {
        case "echo": return .success(.object(["echo": arguments["text"] ?? .null]))
        case "slow":
            do {
                try await Task.sleep(for: .seconds(30))
                return .success(.string("done"))
            } catch {
                return .failure("cancelled")
            }
        default: return .failure("Unknown tool \(name)")
        }
    }
}

@Suite("MCP protocol")
struct MCPServerTests {
    private func makeServer() -> (MCPServer, Transcript) {
        let transcript = Transcript()
        let server = MCPServer(info: MCPServerInfo(name: "ccinnclickhouse", title: "CcinnClickHouse", version: "1.0.0", instructions: "Test"),
                               provider: FakeTools(), send: { await transcript.append($0) })
        return (server, transcript)
    }

    @Test func negotiatesKnownAndUnknownVersions() async throws {
        let (server, transcript) = makeServer()
        await server.receive(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#)
        await server.receive(#"{"jsonrpc":"2.0","id":"two","method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#)
        await server.receive(#"{"jsonrpc":"2.0","id":3,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}"#)
        let messages = await transcript.messages()
        #expect(messages[0]["result"]?["protocolVersion"] == .string("2025-03-26"))
        #expect(messages[0]["result"]?["capabilities"]?["tools"]?["listChanged"] == .bool(false))
        #expect(messages[0]["result"]?["serverInfo"]?["name"] == .string("ccinnclickhouse"))
        #expect(messages[0]["result"]?["serverInfo"]?["title"] == .string("CcinnClickHouse"))
        #expect(messages[1]["id"] == .string("two"))
        #expect(messages[1]["result"]?["protocolVersion"] == .string("2025-06-18"))
        #expect(messages[2]["result"]?["protocolVersion"] == .string("2024-11-05"))
    }

    @Test func listsAndCallsToolsWithStructuredContentOnlyForNewProtocol() async throws {
        let (server, transcript) = makeServer()
        await server.receive(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#)
        await server.receive(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        await server.receive(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        await server.receive(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hi"}}}"#)
        await server.waitForIdle()
        let messages = await transcript.messages()
        #expect(messages.count == 3)
        #expect(messages[1]["result"]?["tools"]?[0]?["annotations"]?["readOnlyHint"] == .bool(true))
        #expect(messages[1]["result"]?["tools"]?[0]?["annotations"]?["openWorldHint"] == .bool(false))
        let call = messages[2]["result"]
        #expect(call?["isError"] == .bool(false))
        #expect(call?["structuredContent"]?["echo"] == .string("hi"))

        let (old, oldTranscript) = makeServer()
        await old.receive(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}"#)
        await old.receive(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hi"}}}"#)
        await old.waitForIdle()
        #expect(await oldTranscript.messages()[1]["result"]?["structuredContent"] == nil)
    }

    @Test func protocolErrorsAndEmptyLists() async throws {
        let (server, transcript) = makeServer()
        await server.receive("{not json")
        await server.receive(#"{"jsonrpc":"2.0","id":7,"method":"no/such"}"#)
        await server.receive(#"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"arguments":{}}}"#)
        await server.receive(#"[{"jsonrpc":"2.0","id":9,"method":"ping"}]"#)
        await server.receive(#"{"jsonrpc":"2.0","id":10,"method":"ping"}"#)
        await server.receive(#"{"jsonrpc":"2.0","id":11,"method":"resources/list"}"#)
        await server.receive(#"{"jsonrpc":"2.0","id":12,"method":"prompts/list"}"#)
        await server.receive(#"{"jsonrpc":"2.0","id":13,"method":"resources/templates/list"}"#)
        await server.receive(#"{"jsonrpc":"2.0","id":14,"method":"tools/call","params":{"name":"echo","arguments":[1]}}"#)
        let messages = await transcript.messages()
        #expect(messages[0]["error"]?["code"] == .int(-32700))
        #expect(messages[1]["error"]?["code"] == .int(-32601))
        #expect(messages[2]["error"]?["code"] == .int(-32602))
        #expect(messages[3]["error"]?["code"] == .int(-32600))
        #expect(messages[4]["result"] == .object([:]))
        #expect(messages[5]["result"]?["resources"] == .array([]))
        #expect(messages[6]["result"]?["prompts"] == .array([]))
        #expect(messages[7]["result"]?["resourceTemplates"] == .array([]))
        #expect(messages[8]["error"]?["code"] == .int(-32602))
    }

    @Test func cancelledCallsGetNoResponse() async throws {
        let (server, transcript) = makeServer()
        await server.receive(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"slow"}}"#)
        try await Task.sleep(for: .milliseconds(50))
        await server.receive(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":5,"reason":"user"}}"#)
        await server.waitForIdle()
        #expect(await transcript.messages().isEmpty)
    }
}

// MARK: - Profiles, results and tool routing

@Suite("MCP profiles, results and tools")
struct MCPToolTests {
    static let profiles = [
        ConnectionProfile(name: "Prod", host: "127.0.0.1", port: 1, mcpAccess: .readOnly),
        ConnectionProfile(name: "Dev", host: "127.0.0.1", port: 1, mcpAccess: .readWrite),
        ConnectionProfile(name: "Secret", host: "127.0.0.1", port: 1),
    ]

    @Test func legacyProfilesDecodeWithMCPDisabled() throws {
        let json = #"[{"id":"7B0A9E6C-3C3A-4B8E-9C5B-1D6F2E0A4A11","name":"Old","host":"h","port":8123,"username":"default","createdAt":0}]"#
        let decoded = try JSONDecoder().decode([ConnectionProfile].self, from: Data(json.utf8))
        #expect(decoded.first?.mcpAccess == .disabled)
        #expect(decoded.first?.compression == true)
        #expect(decoded.first?.readOnly == false)
    }

    @Test func resolvesExplicitDefaultAndSingleProfile() throws {
        let resolver = MCPProfileResolver(profiles: Self.profiles, defaultProfile: nil, forceReadOnly: false)
        #expect(try resolver.resolve("prod").profile.name == "Prod")
        #expect(try resolver.resolve(Self.profiles[1].id.uuidString).access == .readWrite)
        #expect(throws: MCPToolError.self) { try resolver.resolve(nil) }
        #expect(throws: MCPToolError.self) { try resolver.resolve("Secret") }
        #expect(throws: MCPToolError.self) { try resolver.resolve("nope") }
        #expect(resolver.enabledProfiles.map(\.name) == ["Dev", "Prod"])
        let capped = MCPProfileResolver(profiles: Self.profiles, defaultProfile: "Dev", forceReadOnly: true)
        #expect(try capped.resolve(nil).access == .readOnly)
        #expect(!capped.anyWritable)
        let single = MCPProfileResolver(profiles: [Self.profiles[0], Self.profiles[2]], defaultProfile: nil, forceReadOnly: false)
        #expect(try single.resolve(nil).profile.name == "Prod")
    }

    @Test func encodesClickHouseTypes() {
        let columns = [ColumnDefinition(name: "id", typeName: "UInt64"), ColumnDefinition(name: "big", typeName: "UInt64"),
                       ColumnDefinition(name: "ratio", typeName: "Float64"), ColumnDefinition(name: "ok", typeName: "Bool"),
                       ColumnDefinition(name: "price", typeName: "Decimal(12, 2)"), ColumnDefinition(name: "tags", typeName: "Array(String)"),
                       ColumnDefinition(name: "maybe", typeName: "Nullable(Int32)")]
        let rows: [[String?]] = [["1", "18446744073709551615", "nan", "true", "12.50", "['a']", nil]]
        let encoded = MCPResultEncoder.rows(columns: columns, rows: rows, truncatedByServer: false)
        let row = encoded["rows"]?[0]
        #expect(row?[0] == .int(1))
        #expect(row?[1] == .string("18446744073709551615"), "beyond Int64 stays exact")
        #expect(row?[2] == .string("nan"))
        #expect(row?[3] == .bool(true))
        #expect(row?[4] == .string("12.50"))
        #expect(row?[5] == .string("['a']"))
        #expect(row?[6] == .null)
        #expect(encoded["columns"]?[4]?["type"] == .string("Decimal(12, 2)"))
    }

    @Test func truncatesBySize() {
        let columns = [ColumnDefinition(name: "s", typeName: "String")]
        let rows: [[String?]] = (0..<5_000).map { _ in [String(repeating: "k", count: 100)] }
        let encoded = MCPResultEncoder.rows(columns: columns, rows: rows, truncatedByServer: false, maxBytes: 64 * 1024)
        #expect(encoded["truncated"] == .bool(true))
        #expect(encoded.serialized().utf8.count <= 64 * 1024 + 512)
    }

    func makeTools(_ profiles: [ConnectionProfile] = profiles, forceReadOnly: Bool = false, audit: MCPAuditLog? = nil) -> ClickHouseMCPTools {
        let registry = MCPClientRegistry { _, _ in throw ClickHouseError(.network, "offline in unit tests") }
        return ClickHouseMCPTools(resolver: MCPProfileResolver(profiles: profiles, defaultProfile: nil, forceReadOnly: forceReadOnly),
                                  registry: registry, audit: audit)
    }

    @Test func toolListSchemasAreStrict() async {
        let tools = await makeTools().tools()
        #expect(tools.map(\.name).contains("execute_statement"))
        for tool in tools {
            #expect(tool.inputSchema["type"] == .string("object"))
            #expect(tool.inputSchema["additionalProperties"] == .bool(false), "\(tool.name)")
            #expect(tool.inputSchema["properties"]?.objectValue != nil)
            if tool.name != "list_connections" { #expect(tool.inputSchema["properties"]?["connection"] != nil) }
        }
        let readOnly = await makeTools(forceReadOnly: true).tools()
        #expect(!readOnly.map(\.name).contains("execute_statement"))
        #expect(await makeTools().tools().first { $0.name == "execute_statement" }?.destructive == true)
    }

    @Test func listConnectionsNeverExposesSecretsOrDisabledProfiles() async throws {
        let result = await makeTools().call(name: "list_connections", arguments: [:])
        #expect(!result.isError)
        let names = result.payload["connections"]?.arrayValue?.compactMap { $0["name"]?.stringValue }
        #expect(names == ["Dev", "Prod"])
        #expect(!result.payload.serialized().lowercased().contains("password"))
    }

    @Test func argumentValidationAndReadOnlyRejection() async {
        let tools = makeTools([Self.profiles[0]])
        let unknown = await tools.call(name: "run_query", arguments: ["sql": "SELECT 1", "bogus": 1])
        #expect(unknown.isError)
        #expect(unknown.payload.stringValue?.contains("bogus") == true)
        let missing = await tools.call(name: "describe_table", arguments: ["database": "shop"])
        #expect(missing.isError)
        #expect(missing.payload.stringValue?.contains("table") == true)
        let wrongType = await tools.call(name: "run_query", arguments: ["sql": "SELECT 1", "limit": "lots"])
        #expect(wrongType.isError)
        let badEnum = await tools.call(name: "analyze_query_log", arguments: ["analysis": "fastest"])
        #expect(badEnum.isError)
        // Writes are refused before any connection is opened (the registry would fail with "offline").
        let write = await tools.call(name: "run_query", arguments: ["sql": "ALTER TABLE t DELETE WHERE 1"])
        #expect(write.isError)
        #expect(write.payload.stringValue?.contains("offline") == false)
        let execute = await tools.call(name: "execute_statement", arguments: ["sql": "DROP TABLE t"])
        #expect(execute.isError)
        #expect(await tools.call(name: "no_such_tool", arguments: [:]).isError)
    }

    @Test func connectionFailuresAreIsErrorResults() async {
        let result = await makeTools([Self.profiles[0]]).call(name: "list_databases", arguments: [:])
        #expect(result.isError)
        #expect(result.payload.stringValue?.contains("offline") == true)
    }

    @Test func auditLogRedactsAndIsPrivate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ccinnch-audit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let audit = MCPAuditLog(directory: directory)
        await audit.record(tool: "execute_statement", connection: "Dev", statement: "CREATE USER u IDENTIFIED BY 'hunter2'",
                           durationMilliseconds: 1.5, rows: 0, error: nil)
        let text = try String(contentsOf: audit.fileURL, encoding: .utf8)
        #expect(!text.contains("hunter2"))
        #expect(text.contains("'***'"))
        #expect(text.contains("\"source\":\"mcp\""))
        let permissions = try FileManager.default.attributesOfItem(atPath: audit.fileURL.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }

    @Test func auditLogRedactsErrorText() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ccinnch-audit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let audit = MCPAuditLog(directory: directory)
        await audit.record(tool: "run_query", connection: "Dev", statement: "SELECT 1", durationMilliseconds: 1, rows: nil,
                           error: "Syntax error: failed at position 20 ('ERRSECRET') (line 1, col 20): 'ERRSECRET'. Expected one of: token")
        await audit.record(tool: "run_query", connection: "Dev", statement: "SELECT 1", durationMilliseconds: 1, rows: nil,
                           error: "While processing s3('https://b/x.csv', 'AKIA', 'S3ERRSECRET')")
        let text = try String(contentsOf: audit.fileURL, encoding: .utf8)
        #expect(!text.contains("ERRSECRET"))
        #expect(text.contains("failed at position 20"))
    }
}

@Suite("MCP client cache and profile revocation", .serialized)
struct MCPRevocationTests {
    final class Opened: @unchecked Sendable {
        let lock = OSAllocatedUnfairLock<(opened: [String], closed: [String])>(initialState: ([], []))
    }

    final class Resource: Sendable {
        let name: String
        let healthy = OSAllocatedUnfairLock(initialState: true)
        init(name: String) { self.name = name }
    }

    func makeCache(_ log: Opened, delay: Duration = .zero) -> KeyedResourceCache<String, Resource> {
        KeyedResourceCache(opener: { key in
            if delay > .zero { try await Task.sleep(for: delay) }
            log.lock.withLock { $0.opened.append(key) }
            return Resource(name: key)
        }, isHealthy: { $0.healthy.withLock { $0 } }, close: { resource in log.lock.withLock { $0.closed.append(resource.name) } },
        supersededGrace: .milliseconds(50))
    }

    @Test func aChangedKeyOpensANewValueAndClosesTheOld() async throws {
        let log = Opened()
        let cache = makeCache(log)
        let id = UUID()
        let first = try await cache.value(id: id, key: "read-write")
        #expect(try await cache.value(id: id, key: "read-write") === first)
        let downgraded = try await cache.value(id: id, key: "read-only")
        #expect(downgraded !== first)
        #expect(await eventually { log.lock.withLock { $0.closed } == ["read-write"] })
        #expect(log.lock.withLock { $0.opened } == ["read-write", "read-only"])
    }

    @Test func unhealthyOrEvictedValuesAreReopened() async throws {
        let log = Opened()
        let cache = makeCache(log)
        let id = UUID()
        let first = try await cache.value(id: id, key: "k")
        first.healthy.withLock { $0 = false } // e.g. the SSH tunnel process exited
        let second = try await cache.value(id: id, key: "k")
        #expect(second !== first)
        await cache.evict(id: id)
        let third = try await cache.value(id: id, key: "k")
        #expect(third !== second)
        #expect(log.lock.withLock { $0.opened.count } == 3)
    }

    @Test func aCancelledCallerCancelsAnOpenNobodyElseWaitsFor() async throws {
        let log = Opened()
        let cache = makeCache(log, delay: .seconds(5))
        let call = Task { try await cache.value(id: UUID(), key: "slow") }
        try await Task.sleep(for: .milliseconds(100))
        let started = ContinuousClock.now
        call.cancel()
        await #expect(throws: ClickHouseError.self) { _ = try await call.value }
        #expect(ContinuousClock.now - started < .seconds(2), "the cancelled call returned without waiting for the open")
        #expect(log.lock.withLock { $0.opened }.isEmpty)
    }

    @Test func runningServerSeesAccessChangesWithoutRestart() async throws {
        var writable = MCPToolTests.profiles[1]
        writable.mcpAccess = .readWrite
        let current = OSAllocatedUnfairLock(initialState: [writable])
        let source = MCPProfileSource(defaultProfile: nil, forceReadOnly: false, load: { current.withLock { $0 } })
        let tools = ClickHouseMCPTools(profiles: source, registry: MCPClientRegistry { _, _ in throw ClickHouseError(.network, "offline") },
                                       audit: nil)
        #expect(await tools.tools().contains { $0.name == "execute_statement" })
        // The user switches the connection to Read-only in Settings while the server runs.
        current.withLock { $0[0].mcpAccess = .readOnly }
        #expect(await !tools.tools().contains { $0.name == "execute_statement" })
        let refused = await tools.call(name: "execute_statement", arguments: ["sql": "DROP TABLE t"])
        #expect(refused.isError)
        // … and then Off.
        current.withLock { $0[0].mcpAccess = .disabled }
        let off = await tools.call(name: "list_databases", arguments: [:])
        #expect(off.isError)
        #expect(off.payload.stringValue?.contains("AI access") == true)
        // An unreadable connections file means no connections (fail closed).
        let broken = ClickHouseMCPTools(profiles: MCPProfileSource(defaultProfile: nil, forceReadOnly: false, load: { throw CocoaError(.fileReadCorruptFile) }),
                                        registry: MCPClientRegistry { _, _ in throw ClickHouseError(.network, "offline") }, audit: nil)
        #expect(await broken.call(name: "list_databases", arguments: [:]).isError)
    }
}

func eventually(timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

@Suite("MCP byte caps")
struct MCPByteCapTests {
    @Test func prefixCountsUTF8BytesAndKeepsCharactersWhole() {
        let cjk = String(repeating: "数据库", count: 200_000) // 3 bytes per character
        let cut = MCPResultEncoder.prefix(cjk, maxBytes: MCPResultEncoder.defaultMaxBytes)
        #expect(cut.utf8.count <= MCPResultEncoder.defaultMaxBytes)
        #expect(cut.utf8.count > MCPResultEncoder.defaultMaxBytes - 4)
        #expect(cjk.hasPrefix(cut))
        let emoji = String(repeating: "👩‍👩‍👧", count: 10) // multi-scalar grapheme clusters
        let emojiCut = MCPResultEncoder.prefix(emoji, maxBytes: 30)
        #expect(emojiCut.utf8.count <= 30)
        #expect(emoji.hasPrefix(emojiCut))
        #expect(MCPResultEncoder.prefix("short", maxBytes: 100) == "short")
        #expect(MCPResultEncoder.prefix("abc", maxBytes: 0) == "")
    }

    @Test func rawTextResultsAreCappedInBytes() {
        let raw = String(repeating: "列", count: 200_000)
        let result = QueryResult(columns: [], rows: [], queryID: "q", format: "TSVRaw", rawText: raw)
        let encoded = ClickHouseMCPTools.encode(result: result, limit: 10)
        #expect((encoded["text"]?.stringValue?.utf8.count ?? .max) <= MCPResultEncoder.defaultMaxBytes)
        #expect(encoded["truncated"] == .bool(true))
    }
}

@Suite("Recommended read-only setup")
struct ReadOnlyAdviceTests {
    @Test func setupSQLIsThreeAdministrativeStatementsWithARedactablePassword() {
        let statements = SQLStatementSplitter.split(ReadOnlyAdvice.setupSQL)
        #expect(statements.count == 3)
        #expect(statements.allSatisfy { SQLStatementKind.of($0.text).isMutation })
        #expect(statements[0].text.contains("readonly = 1"))
        #expect(statements[2].text.hasPrefix("GRANT SELECT"))
        #expect(!SQLRedactor.redact(ReadOnlyAdvice.setupSQL).contains("choose-a-password"))
        #expect(ReadOnlyAdvice.summary.contains("SELECT grants only"))
    }

    @Test func connectionNotes() {
        #expect(ReadOnlyAdvice.connectionNote(profileIsReadOnly: true, enforcedByUserProfile: true)?.contains("recommended") == true)
        #expect(ReadOnlyAdvice.connectionNote(profileIsReadOnly: false, enforcedByUserProfile: true) != nil)
        #expect(ReadOnlyAdvice.connectionNote(profileIsReadOnly: true, enforcedByUserProfile: false)?.contains("readonly=1") == true)
        #expect(ReadOnlyAdvice.connectionNote(profileIsReadOnly: false, enforcedByUserProfile: false) == nil)
    }
}
