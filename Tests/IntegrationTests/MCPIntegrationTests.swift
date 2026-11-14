import ClickHouseKit
import Foundation
import Testing
@testable import CcinnClickHouseKit

/// Drives the real `CcinnClickHouse mcp` subprocess over stdio against the test server.
/// Requires `swift build` first (the test uses `.build/debug/CcinnClickHouse`).
@Suite("MCP server subprocess", .enabled(if: ITEnvironment.enabled && MCPProcess.binaryExists), .serialized)
struct MCPIntegrationTests {
    @Test func fullSessionOverStdio() async throws {
        let process = try MCPProcess(access: .readOnly)
        defer { process.terminate() }

        let initialize = try await process.request(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                                    "params": ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "it", "version": "1"]]])
        #expect(initialize["result"]?["serverInfo"]?["name"] == .string("ccinnclickhouse"))
        #expect(initialize["result"]?["protocolVersion"] == .string("2025-06-18"))
        try process.send(["jsonrpc": "2.0", "method": "notifications/initialized"])

        let tools = try await process.request(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        let names = tools["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
        #expect(names.contains("run_query") && names.contains("get_parts") && names.contains("analyze_query_log"))
        #expect(!names.contains("execute_statement"), "the test profile is read-only")

        let connections = try await process.call(id: 3, "list_connections", [:])
        #expect(connections["connections"]?[0]?["access"] == .string("read_only"))

        let tables = try await process.call(id: 4, "list_tables", ["database": "shop"])
        let families = Dictionary(uniqueKeysWithValues: (tables["tables"]?.arrayValue ?? []).compactMap { table -> (String, String)? in
            guard let name = table["name"]?.stringValue, let family = table["family"]?.stringValue else { return nil }
            return (name, family)
        })
        #expect(families["events"] == "mergetree")
        #expect(families["daily_revenue_mv"] == "materialized_view")
        #expect(families["country_dict"] == "dictionary")

        let describe = try await process.call(id: 5, "describe_table", ["database": "shop", "table": "events", "include_ddl": false])
        #expect(describe["sorting_key"] == .string("event_type, user_id, event_time"))
        #expect(describe["skipping_indexes"]?.arrayValue?.count == 2)
        #expect(describe["columns"]?.arrayValue?.contains { $0["name"] == .string("payload") && $0["ttl"] != nil } == true)

        let parts = try await process.call(id: 6, "get_parts", ["database": "shop", "table": "tiny_parts"])
        #expect(parts["warnings"]?[0]?["level"] == .string("warning"))

        let query = try await process.call(id: 7, "run_query", ["sql": "SELECT number FROM system.numbers", "limit": 25])
        #expect(query["row_count"] == .int(25))
        #expect(query["truncated"] == .bool(true))
        #expect(query["limit_applied"] == .bool(true))

        // The app refuses writes before sending them…
        let rejected = try await process.request(["jsonrpc": "2.0", "id": 8, "method": "tools/call",
                                                  "params": ["name": "run_query", "arguments": ["sql": "DROP TABLE shop.events"]]])
        #expect(rejected["result"]?["isError"] == .bool(true))
        // …and ClickHouse enforces readonly=1 for what passes the guard (table functions are refused server-side).
        let serverSide = try await process.request(["jsonrpc": "2.0", "id": 9, "method": "tools/call",
                                                    "params": ["name": "run_query", "arguments": ["sql": "SELECT * FROM url('http://127.0.0.1:1/x', CSV, 'a String')"]]])
        #expect(serverSide["result"]?["isError"] == .bool(true))
        #expect(serverSide["result"]?["content"]?[0]?["text"]?.stringValue?.contains("164") == true)

        let explain = try await process.call(id: 10, "explain_query", ["sql": "SELECT count() FROM shop.events WHERE user_id = 1", "kind": "plan_indexes"])
        #expect(explain["plan"]?.stringValue?.contains("Indexes") == true)

        _ = try await process.call(id: 11, "analyze_query_log", ["analysis": "by_user", "hours": 1])
        _ = try await process.call(id: 12, "get_cluster", [:])
        _ = try await process.call(id: 13, "get_storage", [:])

        // Cancelling a long query must stop it on the server and produce no response for that id.
        try process.send(["jsonrpc": "2.0", "id": 14, "method": "tools/call",
                          "params": ["name": "run_query", "arguments": ["sql": "SELECT count() FROM system.numbers_mt WHERE NOT ignore(sipHash64(number))",
                                                                         "timeout_seconds": 60]]])
        try await Task.sleep(for: .milliseconds(1500))
        try process.send(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 14]])
        let ping = try await process.request(["jsonrpc": "2.0", "id": 15, "method": "ping"])
        #expect(ping["result"] == .object([:]))
        try await Task.sleep(for: .seconds(2))
        #expect(process.responses(for: 14).isEmpty)
        let client = try await ITEnvironment.connect()
        defer { Task { await client.close() } }
        let gone = try await waitUntil(.seconds(8)) {
            try await client.run("SELECT count() FROM system.processes WHERE query LIKE '%ignore(sipHash64(number))%' AND query_id LIKE 'ccinnch-mcp-%'").scalar == "0"
        }
        #expect(gone)

        // The audit log recorded the calls without the password.
        let audit = try String(contentsOf: process.directory.appendingPathComponent("mcp-audit.jsonl"), encoding: .utf8)
        #expect(audit.contains("\"tool\":\"run_query\""))
        #expect(!audit.contains(ITEnvironment.password))
    }

    @Test func readWriteProfileCanExecute() async throws {
        let process = try MCPProcess(access: .readWrite)
        defer { process.terminate() }
        _ = try await process.request(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-03-26"]])
        let tools = try await process.request(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        #expect(tools["result"]?["tools"]?.arrayValue?.contains { $0["name"] == .string("execute_statement") } == true)
        let created = try await process.request(["jsonrpc": "2.0", "id": 3, "method": "tools/call",
                                                 "params": ["name": "execute_statement", "arguments": ["sql": "CREATE TABLE IF NOT EXISTS shop.mcp_scratch (a UInt8) ENGINE = Memory"]]])
        #expect(created["result"]?["isError"] == .bool(false))
        _ = try await process.request(["jsonrpc": "2.0", "id": 4, "method": "tools/call",
                                       "params": ["name": "execute_statement", "arguments": ["sql": "DROP TABLE IF EXISTS shop.mcp_scratch"]]])
        // 2025-03-26 clients get no structuredContent.
        #expect(created["result"]?["structuredContent"] == nil)
    }
}

/// A running MCP server subprocess with a temporary profile directory and a test-only password source.
final class MCPProcess: @unchecked Sendable {
    static var binary: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/debug/CcinnClickHouse")
    }

    static var binaryExists: Bool { FileManager.default.isExecutableFile(atPath: binary.path) }

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    let directory: URL
    private let lock = NSLock()
    private var buffer = Data()
    private var messages: [JSONValue] = []

    init(access: MCPAccess) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ccinnch-mcp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuration = ITEnvironment.configuration()
        let profile = ConnectionProfile(name: "IT", host: configuration.endpoint.host, port: configuration.endpoint.port, username: ITEnvironment.user,
                                        defaultDatabase: "shop", connectTimeout: 30, mcpAccess: access)
        try ProfileRepository(directory: directory, secrets: InMemorySecretStore()).save([profile])

        process.executableURL = Self.binary
        process.arguments = ["mcp"]
        var environment = ProcessInfo.processInfo.environment
        environment["CCINNCLICKHOUSE_PROFILE_DIR"] = directory.path
        environment[EnvironmentTestSecretStore.prefix + profile.id.uuidString.uppercased()] = ITEnvironment.password
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.lock.lock()
            self.buffer.append(data)
            while let newline = self.buffer.firstIndex(of: 0x0A) {
                let line = self.buffer[self.buffer.startIndex..<newline]
                self.buffer.removeSubrange(self.buffer.startIndex...newline)
                if let message = try? JSONValue.parse(Data(line)) { self.messages.append(message) }
            }
            self.lock.unlock()
        }
        try process.run()
    }

    func send(_ message: JSONValue) throws {
        try input.fileHandleForWriting.write(contentsOf: Data((message.serialized() + "\n").utf8))
    }

    func responses(for id: Int64) -> [JSONValue] {
        lock.lock()
        defer { lock.unlock() }
        return messages.filter { $0["id"] == .int(id) }
    }

    func request(_ message: JSONValue, timeout: Duration = .seconds(90)) async throws -> JSONValue {
        try send(message)
        guard let id = message["id"]?.intValue else { return .null }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let response = responses(for: id).first { return response }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw MCPToolError("No response to request \(id)")
    }

    /// Calls a tool and returns its structured result, failing the test on tool errors.
    func call(id: Int64, _ name: String, _ arguments: JSONValue) async throws -> JSONValue {
        let response = try await request(["jsonrpc": "2.0", "id": .int(id), "method": "tools/call", "params": ["name": .string(name), "arguments": arguments]])
        let result = response["result"]
        if result?["isError"] == .bool(true) {
            throw MCPToolError("\(name) failed: \(result?["content"]?[0]?["text"]?.stringValue ?? "?")")
        }
        return result?["structuredContent"] ?? .null
    }

    func terminate() {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        try? FileManager.default.removeItem(at: directory)
    }
}
