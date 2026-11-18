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

    /// Review: the AutoLimit `#` and `$` repros, and reads of other sessions' SQL, are refused through run_query and
    /// explain_query before any connection is opened (the registry here would fail with "offline").
    @Test func smugglingAndSensitiveSourcesAreRefusedBeforeConnecting() async {
        let tools = makeTools([Self.profiles[0]])
        let sqls = GuardedWireTextTests.repros + ["SELECT query FROM system.query_log", "SHOW PROCESSLIST", "SELECT * FROM system.users",
                                                  "SHOW CREATE TABLE shop.events", "SHOW TABLE shop.events", "SELECT create_table_query FROM system.tables",
                                                  "SELECT * FROM (EXPLAIN SYNTAX SELECT * FROM shop.v)", "SELECT count() FROM `\\x73ystem`.query_log"]
        for tool in ["run_query", "explain_query"] {
            for sql in sqls {
                let result = await tools.call(name: tool, arguments: ["sql": .string(sql)])
                #expect(result.isError, "\(tool) \(sql.debugDescription)")
                #expect(result.payload.stringValue?.contains("offline") == false, "\(tool) \(sql.debugDescription): refused before connecting")
            }
        }
        let inSystem = await tools.call(name: "run_query", arguments: ["sql": "SELECT query FROM query_log", "database": "system"])
        #expect(inSystem.isError && inSystem.payload.stringValue?.contains("offline") == false)
        let syntax = await tools.call(name: "explain_query", arguments: ["sql": "SELECT * FROM shop.v", "kind": "syntax"])
        #expect(syntax.isError && syntax.payload.stringValue?.contains("offline") == false, "EXPLAIN SYNTAX inlines view queries")
        let ddl = await tools.call(name: "describe_table", arguments: ["database": "shop", "table": "events", "include_ddl": true])
        #expect(ddl.isError && ddl.payload.stringValue?.contains("include_ddl") == true, "describe_table offers no DDL")
    }

    /// Cross-port rule: an argument other than `sql` holding a control character (Unicode Cc: NUL, C0, DEL, C1) is refused
    /// before anything is sent. A writer or quoting step that drops NUL would make the server read another name than
    /// the one checked (MySQL received information_schema for `information_schema\0x`).
    @Test func controlCharactersInNamesAreRefusedBeforeConnecting() async {
        for value in ["sys\0tem", "shop\u{1}", "shop\u{7F}", "shop\u{85}", "shop\u{9F}", "shop\n", "\tshop"] {
            for key in ["connection", "database", "table", "name_filter", "user"] {
                #expect(Arguments([key: .string(value), "sql": .string("SELECT 1")]).controlCharacterArgument() == key, "\(key) \(value.debugDescription)")
            }
        }
        #expect(Arguments(["sql": .string("SELECT\t1\n FROM t"), "database": .string("shop"), "limit": .int(5)]).controlCharacterArgument() == nil)
        #expect(Arguments(["database": .string("名前 café")]).controlCharacterArgument() == nil)
        let tools = makeTools([Self.profiles[0]])
        for (tool, arguments) in [("describe_table", ["database": JSONValue.string("sys\0tem"), "table": "processes"]),
                                  ("list_tables", ["database": "information_schema\0x"]),
                                  ("run_query", ["sql": "SELECT 1", "database": "sys\0tem"])] {
            let result = await tools.call(name: tool, arguments: arguments)
            #expect(result.isError && result.payload.stringValue?.contains("control character") == true, "\(tool): \(result.payload.stringValue ?? "")")
        }
    }

    /// Defence in depth: every string of a tool result has its credentials masked, and EXPLAIN results their quoted
    /// strings (26.8 plans print the literals of the views a query reads).
    @Test func toolResultsAreMasked() {
        let result: JSONValue = ["rows": [["CREATE VIEW v AS SELECT * FROM url('http://u:zzurlsecret@h/x', CSV)", 42], ["password=zzpairsecret"]],
                                 "nested": ["ddl": "ENGINE = MySQL('h:3306', 'db', 't', 'u', 'zzmysqlsecret')"], "count": 2]
        let maskedValue = ClickHouseMCPTools.maskingSecrets(result)
        let masked = maskedValue.serialized()
        for secret in ["zzurlsecret", "zzpairsecret", "zzmysqlsecret"] { #expect(!masked.contains(secret), "\(secret) in \(masked)") }
        #expect(masked.contains("42") && masked.contains("\"count\":2"))
        // The AI learns that values were altered, and how many.
        #expect(maskedValue["masked"] == .int(4), "\(masked)")
        let clean: JSONValue = ["rows": [["ssh://git@github.com:22/x", "PRIMARY KEY 'id'"], ["s3('a','b','c')"]]]
        #expect(ClickHouseMCPTools.maskingSecrets(clean) == clean, "legitimate data is unchanged and not flagged")
        // The echoed statement is masked but not counted: `masked` counts altered result values only.
        let echoed = ClickHouseMCPTools.maskingSecrets(["statement": "SELECT 'http://u:zzpw@h/x'", "rows": [["plain"]]])
        #expect(echoed["masked"] == nil && echoed["statement"]?.stringValue?.contains("zzpw") == false, "\(echoed.serialized())")
        let plan = ClickHouseMCPTools.maskingPlanLiterals(["rows": [["Filter column: notEquals(s, 'zzwheresecret')"], ["Granules: 3/10"]]])
        #expect(JSONValue.object(plan).serialized() == #"{"rows":[["Filter column: notEquals(s, '?')"],["Granules: 3/10"]]}"#)
    }

    /// Review (A): what `SHOW GRANTS` (recorded from 22.8 and 26.8) says a user may do beyond reading tables. No text
    /// guard stops a privileged account (file(), url(), SYSTEM, access management), so such users get no read-only AI
    /// access unless the connection opts in.
    @Test func privilegeReportsFromRecordedGrants() {
        let admin228 = MCPPrivilegeReport(grants: ["GRANT ALL ON *.* TO ccinn WITH GRANT OPTION"])
        #expect(admin228.risks == [.all, .grantOption])
        let reader228 = MCPPrivilegeReport(grants: [
            "GRANT SHOW, SELECT, INSERT, ALTER, CREATE, DROP, TRUNCATE, OPTIMIZE, BACKUP, KILL QUERY, KILL TRANSACTION, MOVE PARTITION BETWEEN SHARDS, SYSTEM, dictGet, INTROSPECTION, SOURCES, CLUSTER ON *.* TO reader",
        ])
        #expect(reader228.risks == [.sources, .system, .introspection])
        let reader268 = MCPPrivilegeReport(grants: [
            "GRANT SOURCES ON *.* TO reader", "GRANT TABLE ENGINE ON * TO reader",
            "GRANT CHECK, SHOW, SELECT, INSERT, SHOW HANDLERS, SYSTEM, dictGet, displaySecretsInShowAndSelect, INTROSPECTION, CLUSTER, FILE, URL, REMOTE, S3, AI FUNCTIONS ON *.* TO reader",
            "GRANT SET DEFINER ON * TO reader",
        ])
        #expect(reader268.risks == [.sources, .system, .accessManagement, .introspection])
        let admin268 = MCPPrivilegeReport(grants: ["GRANT CREATE USER, ALTER USER, DROP USER, CREATE ROLE, ALTER ROLE, DROP ROLE, IMPERSONATE ON * TO ccinn WITH GRANT OPTION"])
        #expect(admin268.risks == [.accessManagement, .grantOption])
        // A plain SELECT user, with column lists and quoted names.
        let plain = MCPPrivilegeReport(grants: ["GRANT SELECT ON shop.* TO ai_reader", "GRANT SELECT(a, b) ON `my db`.`t, ON` TO ai_reader",
                                                "GRANT SHOW TABLES ON shop.* TO ai_reader"])
        #expect(plain.isPlain)
        // Roles hide their privileges from SHOW GRANTS: not provably plain.
        #expect(MCPPrivilegeReport(grants: ["GRANT SELECT ON shop.* TO u", "GRANT analysts TO u"]).risks == [.roles])
        #expect(MCPPrivilegeReport(grants: ["GRANT SYSTEM RELOAD DICTIONARY ON *.* TO u"]).risks == [.system])
        #expect(MCPPrivilegeReport(grants: ["GRANT NAMED COLLECTION ON c TO u"]).risks == [.accessManagement])
        #expect(MCPPrivilegeReport(grants: ["GRANT EXECUTABLE ON *.* TO u"]).risks == [.sources])
        #expect(MCPPrivilegeReport(grants: ["REVOKE SELECT ON secret.* FROM u", "GRANT SELECT ON *.* TO u"]).isPlain)
        // Nothing to read is not "plain": fail closed.
        #expect(MCPPrivilegeReport(failure: "boom").risks == [.unknown("boom")])
    }

    /// Review (C): individual AI grants (`GRANT aiGenerate ON *.*`) were rated plain; only the AI FUNCTIONS group was
    /// flagged. A privilege is risky when it or any ancestor in system.privileges is, so a future child of a risky group
    /// is covered; a privilege the hierarchy does not know is risky.
    @Test func privilegesAreJudgedWithTheirAncestors() {
        #expect(MCPPrivilegeReport(grants: ["GRANT aiGenerate ON *.* TO u"]).risks == [.sources])
        #expect(MCPPrivilegeReport(grants: ["GRANT AITRANSLATE, SELECT ON *.* TO u"]).risks == [.sources])
        #expect(MCPPrivilegeReport(grants: ["GRANT SHOW USERS ON *.* TO u"]).risks == [.accessManagement])
        #expect(MCPPrivilegeReport(grants: ["GRANT SHOW NAMED COLLECTIONS SECRETS ON * TO u"]).risks == [.accessManagement])
        #expect(MCPPrivilegeReport(grants: ["GRANT SYSTEM FLUSH LOGS ON *.* TO u"]).risks == [.system])
        #expect(MCPPrivilegeReport(grants: ["GRANT addressToLine ON *.* TO u"]).risks == [.introspection])
        #expect(MCPPrivilegeReport(grants: ["GRANT dictGet, SHOW TABLES, SELECT, CREATE TEMPORARY TABLE ON *.* TO u"]).isPlain)
        #expect(MCPPrivilegeReport(grants: ["GRANT SOMETHING NEW ON *.* TO u"]).risks == [.unknown("“SOMETHING NEW” is not a privilege this server's hierarchy knows")])
        // The server's own hierarchy (system.privileges rows): a child the pinned list never saw inherits its group's risk.
        let live = PrivilegeHierarchy(rows: [["ALL", "[]", nil], ["SOURCES", "[]", "ALL"], ["LAKEHOUSE", "['LAKE']", "SOURCES"], ["SELECT", "[]", "ALL"]])
        #expect(live != nil)
        #expect(MCPPrivilegeReport(grants: ["GRANT LAKE ON *.* TO u"], hierarchy: live ?? .pinned).risks == [.sources])
        #expect(MCPPrivilegeReport(grants: ["GRANT SELECT ON *.* TO u"], hierarchy: live ?? .pinned).isPlain)
        #expect(PrivilegeHierarchy(rows: [["only one column"]]) == nil)
    }

    /// Review (A): read-only AI tools refuse a privileged user unless the connection opts in; read & write is the
    /// user's explicit choice and is not checked.
    @Test func privilegedUsersGetNoReadOnlyAIAccessByDefault() async {
        let profile = ConnectionProfile(name: "Prod", host: "127.0.0.1", port: 1, username: "ccinn", mcpAccess: .readOnly)
        var allowed = profile
        allowed.mcpAllowPrivilegedUser = true
        let refusal = MCPPrivilegeReport(grants: ["GRANT ALL ON *.* TO ccinn"]).refusal(for: profile, user: "ccinn")
        #expect(refusal?.contains("ccinn") == true && refusal?.contains("ALL") == true)
        #expect(MCPPrivilegeReport(grants: ["GRANT ALL ON *.* TO ccinn"]).refusal(for: allowed, user: "ccinn") == nil)
        #expect(MCPPrivilegeReport(grants: ["GRANT SELECT ON shop.* TO r"]).refusal(for: profile, user: "r") == nil)
        let decoded = try? JSONDecoder().decode(ConnectionProfile.self, from: JSONEncoder().encode(allowed))
        #expect(decoded?.mcpAllowPrivilegedUser == true)
        let legacy = #"{"id":"7B0A9E6C-3C3A-4B8E-9C5B-1D6F2E0A4A11","name":"Old","host":"h","port":8123,"createdAt":0}"#
        #expect((try? JSONDecoder().decode(ConnectionProfile.self, from: Data(legacy.utf8)))?.mcpAllowPrivilegedUser == false)
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
        let cache = makeCache(log, delay: .seconds(30))
        let call = Task { try await cache.value(id: UUID(), key: "slow") }
        try await Task.sleep(for: .milliseconds(100))
        let started = ContinuousClock.now
        call.cancel()
        await #expect(throws: ClickHouseError.self) { _ = try await call.value }
        // Below the 30 s open whose absence it proves; generous, because CI scheduling adds seconds.
        #expect(ContinuousClock.now - started < .seconds(25), "the cancelled call returned without waiting for the open")
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

/// The timeout only bounds a failure: a passing condition returns at once. Generous, because a busy CI runner delays
/// scheduling by seconds.
func eventually(timeout: Duration = .seconds(10), _ condition: () -> Bool) async -> Bool {
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
