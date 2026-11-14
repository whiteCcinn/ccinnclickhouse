import ClickHouseWire
import Foundation
import os
import Testing
@testable import ClickHouseKit

@Suite("SQL sessions", .serialized)
struct SessionTests {
    /// A fake that keeps per-session state like ClickHouse: database and settings live in the session.
    final class SessionState: @unchecked Sendable {
        let lock = OSAllocatedUnfairLock<[String: (database: String?, settings: [String: String])]>(initialState: [:])
        let expireNext = OSAllocatedUnfairLock(initialState: false)

        func handle(_ request: FakeClickHouseServer.Request) -> FakeClickHouseServer.Response {
            if let answer = FakeAnswers.standard(request) { return answer }
            guard let id = request.parameters["session_id"] else {
                return .tsv("db\tthreads\nString\tString\n\(request.parameters["database"] ?? "default")\t\(request.parameters["max_threads"] ?? "0")\n")
            }
            if expireNext.withLock({ value -> Bool in defer { value = false }; return value }) {
                lock.withLock { $0[id] = nil }
            }
            if request.parameters["session_check"] == "1", lock.withLock({ $0[id] == nil }) {
                return .exception(code: 372, name: "SESSION_NOT_FOUND", message: "Session \(id) not found", status: 404)
            }
            lock.withLock { state in
                if state[id] == nil { state[id] = (nil, [:]) }
                if let database = request.parameters["database"] { state[id]?.database = database }
            }
            let sql = request.sql
            if sql.hasPrefix("USE ") {
                lock.withLock { $0[id]?.database = String(sql.dropFirst(4)) }
                return .empty()
            }
            if sql.hasPrefix("SET ") {
                let assignment = sql.dropFirst(4).split(separator: "=").map { $0.trimmingCharacters(in: .whitespaces) }
                lock.withLock { $0[id]?.settings[assignment[0]] = assignment[1] }
                return .empty()
            }
            let session = lock.withLock { $0[id] }
            return .tsv("db\tthreads\nString\tString\n\(session?.database ?? "default")\t\(session?.settings["max_threads"] ?? "0")\n")
        }
    }

    @Test func sessionParametersAndContextTracking() async throws {
        let state = SessionState()
        let server = try await FakeClickHouseServer { state.handle($0) }
        defer { server.stop() }
        let client = try await ClickHouseClient.connect(configuration(port: server.port))
        defer { Task { await client.close() } }
        let session = client.openSession()
        _ = try await session.run("USE shop")
        _ = try await session.run("SET max_threads = 2")
        let result = try await session.run("SELECT currentDatabase(), getSetting('max_threads')")
        #expect(result.rows == [["shop", "2"]])
        #expect(await session.database == "shop")
        let statements = server.requests.filter { $0.parameters["session_id"] != nil }
        #expect(statements.first?.parameters["session_check"] == nil)
        #expect(statements.dropFirst().allSatisfy { $0.parameters["session_check"] == "1" })
        #expect(statements.allSatisfy { $0.parameters["session_timeout"] == "1800" })
        #expect(statements.last?.parameters["database"] == "shop")
    }

    @Test func expiredSessionIsRecreatedWithSettings() async throws {
        let state = SessionState()
        let server = try await FakeClickHouseServer { state.handle($0) }
        defer { server.stop() }
        let client = try await ClickHouseClient.connect(configuration(port: server.port))
        defer { Task { await client.close() } }
        let session = client.openSession()
        _ = try await session.run("USE shop")
        _ = try await session.run("SET max_threads = 2")
        state.expireNext.withLock { $0 = true }
        let result = try await session.run("SELECT currentDatabase(), getSetting('max_threads')")
        #expect(result.rows == [["shop", "2"]])
        #expect(result.sessionRecreated)
        // The settings were replayed into the new session before the retry.
        #expect(server.requests(containing: "SET max_threads = 2").count == 2)
    }

    @Test func sessionTimeoutFallsBackToServerDefault() async throws {
        let server = try await FakeClickHouseServer { request in
            if let answer = FakeAnswers.standard(request) { return answer }
            if request.parameters["session_timeout"] != nil {
                return .exception(code: 374, name: "INVALID_SESSION_TIMEOUT", message: "Session timeout '1800' is larger than max_session_timeout: 600")
            }
            return .tsv("x\nUInt8\n1\n")
        }
        defer { server.stop() }
        let client = try await ClickHouseClient.connect(configuration(port: server.port))
        defer { Task { await client.close() } }
        let session = client.openSession()
        #expect(try await session.run("SELECT 1").rows == [["1"]])
        #expect(try await session.run("SELECT 1").rows == [["1"]])
        #expect(server.requests.last?.parameters["session_timeout"] == nil)
    }

    @Test func lockedSessionIsRetried() async throws {
        let failures = OSAllocatedUnfairLock(initialState: 2)
        let server = try await FakeClickHouseServer { request in
            if let answer = FakeAnswers.standard(request) { return answer }
            if failures.withLock({ value -> Bool in defer { value -= 1 }; return value > 0 }) {
                return .exception(code: 373, name: "SESSION_IS_LOCKED", message: "Session is locked by a concurrent client")
            }
            return .tsv("x\nUInt8\n1\n")
        }
        defer { server.stop() }
        let client = try await ClickHouseClient.connect(configuration(port: server.port))
        defer { Task { await client.close() } }
        #expect(try await client.openSession().run("SELECT 1").rows == [["1"]])
    }

    @Test func proxyWithoutSessionsFallsBackToPerRequestSettings() async throws {
        let server = try await FakeClickHouseServer { request in
            if let answer = FakeAnswers.standard(request) { return answer }
            if request.parameters["session_id"] != nil {
                return FakeClickHouseServer.Response(status: 400, headers: [:], chunks: [Data("[ Id: 1 ] session_id is not supported by this proxy".utf8)])
            }
            return .tsv("db\tthreads\nString\tString\n\(request.parameters["database"] ?? "default")\t\(request.parameters["max_threads"] ?? "0")\n")
        }
        defer { server.stop() }
        let client = try await ClickHouseClient.connect(configuration(port: server.port))
        defer { Task { await client.close() } }
        let session = client.openSession()
        _ = try await session.run("USE shop")
        _ = try await session.run("SET max_threads = 4")
        let result = try await session.run("SELECT currentDatabase(), getSetting('max_threads')")
        #expect(result.rows == [["shop", "4"]])
        #expect(await session.sessionsSupported == false)
    }

    @Test func oneStatementAtATime() async throws {
        let server = try await FakeClickHouseServer { request in
            if let answer = FakeAnswers.standard(request) { return answer }
            var response = FakeClickHouseServer.Response.tsv("x\nUInt8\n1\n")
            response.headDelay = .milliseconds(600)
            return response
        }
        defer { server.stop() }
        let client = try await ClickHouseClient.connect(configuration(port: server.port))
        defer { Task { await client.close() } }
        let session = client.openSession()
        let first = Task { try await session.run("SELECT 1") }
        try await Task.sleep(for: .milliseconds(150))
        do {
            _ = try await session.run("SELECT 2")
            Issue.record("expected busy")
        } catch let error as ClickHouseError {
            #expect(error.kind == .busy)
        }
        #expect(try await first.value.rows == [["1"]])
    }

    @Test func cancelStopsTheRunningStatementAndKillsItsQueryID() async throws {
        let server = try await FakeClickHouseServer { request in
            if let answer = FakeAnswers.standard(request) { return answer }
            var response = FakeClickHouseServer.Response.tsv("x\nUInt8\n1\n")
            if request.sql.contains("slow") { response.headDelay = .seconds(10) }
            return response
        }
        defer { server.stop() }
        let client = try await ClickHouseClient.connect(configuration(port: server.port))
        defer { Task { await client.close() } }
        let session = client.openSession()
        let slow = Task { try await session.run("SELECT slow") }
        try await Task.sleep(for: .milliseconds(200))
        let queryID = try #require(await session.runningQueryID)
        await session.cancel()
        await #expect(throws: ClickHouseError.cancelled()) { _ = try await slow.value }
        #expect(await eventually { !server.requests(containing: "query_id = '\(queryID)'").isEmpty })
        // The session keeps working afterwards.
        #expect(try await session.run("SELECT fast").rows == [["1"]])
    }

    @Test func lateCancelDoesNotTouchTheNextStatement() async throws {
        let server = try await FakeClickHouseServer { request in
            if let answer = FakeAnswers.standard(request) { return answer }
            var response = FakeClickHouseServer.Response.tsv("x\nUInt8\n1\n")
            response.headDelay = .milliseconds(300)
            return response
        }
        defer { server.stop() }
        let client = try await ClickHouseClient.connect(configuration(port: server.port))
        defer { Task { await client.close() } }
        let session = client.openSession()
        _ = try await session.run("SELECT first")
        // A cancel issued for the finished statement arrives late, then the next statement runs.
        await session.cancel()
        #expect(try await session.run("SELECT second").rows == [["1"]])
        #expect(server.requests(containing: "KILL QUERY").isEmpty)
    }

    @Test func contextChangeParsing() {
        #expect(SessionContextChange.parse("USE shop;") == .use("shop"))
        #expect(SessionContextChange.parse("use `my db`") == .use("my db"))
        #expect(SessionContextChange.parse("USE \"x\"") == .use("x"))
        #expect(SessionContextChange.parse("USE a b") == nil)
        #expect(SessionContextChange.parse("SET max_threads = 4, log_comment = 'a\\'b'")
            == .settings(statement: "SET max_threads = 4, log_comment = 'a\\'b'",
                         pairs: [.init("max_threads", "4"), .init("log_comment", "a'b")]))
        #expect(SessionContextChange.parse("SET ROLE admin") == nil)
        #expect(SessionContextChange.parse("SET DEFAULT ROLE r TO u") == nil)
        #expect(SessionContextChange.parse("/* c */ SET x = -1") == .settings(statement: "/* c */ SET x = -1", pairs: [.init("x", "-1")]))
        #expect(SessionContextChange.parse("SELECT 1") == nil)
        if case let .settings(_, pairs)? = SessionContextChange.parse("SET x = 1 +") { #expect(pairs.isEmpty) }
    }
}

@Suite("Session cancellation between attempts", .serialized)
struct SessionCancellationTests {
    /// Answers SESSION_IS_LOCKED once to the statement, then would run it.
    static func lockedOnce() -> (@Sendable (FakeClickHouseServer.Request) -> FakeClickHouseServer.Response) {
        let answered = OSAllocatedUnfairLock(initialState: false)
        return { request in
            if let answer = FakeAnswers.standard(request) { return answer }
            guard request.sql.contains("DELETE WHERE") else { return .empty() }
            if answered.withLock({ value -> Bool in defer { value = true }; return !value }) {
                return .exception(code: 373, name: "SESSION_IS_LOCKED", message: "Session is locked by a concurrent client")
            }
            return .empty()
        }
    }

    @Test func cancelDuringLockedWaitStopsTheRetry() async throws {
        let server = try await FakeClickHouseServer(handler: Self.lockedOnce())
        defer { server.stop() }
        let client = try await ClickHouseClient.connect(configuration(port: server.port))
        defer { Task { await client.close() } }
        let session = client.openSession()
        let run = Task { try await session.run("ALTER TABLE t DELETE WHERE 1") }
        #expect(await eventually { server.requests(containing: "DELETE WHERE").count == 1 })
        try await Task.sleep(for: .milliseconds(80))
        await session.cancel()
        await #expect(throws: ClickHouseError.self) { _ = try await run.value }
        try await Task.sleep(for: .milliseconds(400))
        #expect(server.requests(containing: "DELETE WHERE").count == 1, "the cancelled statement was not re-sent")
    }

    @Test func cancellingTheCallerDuringLockedWaitStopsTheRetry() async throws {
        let server = try await FakeClickHouseServer(handler: Self.lockedOnce())
        defer { server.stop() }
        let client = try await ClickHouseClient.connect(configuration(port: server.port))
        defer { Task { await client.close() } }
        let session = client.openSession()
        let run = Task { try await session.run("ALTER TABLE t DELETE WHERE 1") }
        #expect(await eventually { server.requests(containing: "DELETE WHERE").count == 1 })
        try await Task.sleep(for: .milliseconds(80))
        run.cancel()
        do {
            _ = try await run.value
            Issue.record("expected a cancellation")
        } catch let error as ClickHouseError {
            #expect(error.kind == .cancelled)
        }
        try await Task.sleep(for: .milliseconds(400))
        #expect(server.requests(containing: "DELETE WHERE").count == 1)
        // The session is free again.
        #expect(try await session.run("SELECT 1").rows.isEmpty)
    }

    @Test func cancelDuringSettingsReplayStopsTheRetry() async throws {
        let expired = OSAllocatedUnfairLock(initialState: false)
        let server = try await FakeClickHouseServer { request in
            if let answer = FakeAnswers.standard(request) { return answer }
            if request.sql.hasPrefix("SET ") {
                // The replay (after the session expired) is slow, so a cancel lands during it.
                if expired.withLock({ $0 }) {
                    var response = FakeClickHouseServer.Response.empty()
                    response.headDelay = .milliseconds(500)
                    return response
                }
                return .empty()
            }
            if request.sql.contains("ALTER"), request.parameters["session_check"] == "1", !expired.withLock({ $0 }) {
                expired.withLock { $0 = true }
                return .exception(code: 372, name: "SESSION_NOT_FOUND", message: "Session not found", status: 404)
            }
            return .empty()
        }
        defer { server.stop() }
        let client = try await ClickHouseClient.connect(configuration(port: server.port))
        defer { Task { await client.close() } }
        let session = client.openSession()
        _ = try await session.run("SET max_threads = 2")
        _ = try await session.run("SET max_memory_usage = 1000000000")
        let run = Task { try await session.run("ALTER TABLE t DELETE WHERE 1") }
        #expect(await eventually { server.requests(containing: "SET max_threads").count == 2 })
        await session.cancel()
        await #expect(throws: ClickHouseError.self) { _ = try await run.value }
        try await Task.sleep(for: .milliseconds(700))
        #expect(server.requests(containing: "ALTER TABLE t").count == 1, "the statement was not re-sent after a cancelled replay")
        #expect(server.requests(containing: "SET max_memory_usage").count == 1, "the replay stopped")
    }
}
