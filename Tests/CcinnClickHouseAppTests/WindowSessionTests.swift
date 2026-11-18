import CcinnClickHouseKit
import Foundation
import Testing
@testable import CcinnClickHouse

@Suite("Window session", .serialized)
@MainActor
struct WindowSessionTests {
    private func makeStore() -> (ProfileStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        return (ProfileStore(repository: ProfileRepository(directory: directory, secrets: InMemorySecretStore())), directory)
    }

    /// A connect started while another is in flight (double-click, Connect again) cancels it, and the cancelled
    /// connect's late progress never replaces the new connect's status.
    @Test func aCancelledConnectNeverOverwritesTheNewConnectsStatus() async throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = WindowSession()
        let firstCancelled = CancellationProbe()
        session.opener = { profile, _, _, progress in
            if profile.host == "first" {
                // Not cancellation-aware, like a TCP connect or an ssh handshake: it reports after the second connect began.
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { continuation.resume() }
                }
                progress("first: opening tunnel")
                if Task.isCancelled { firstCancelled.mark() }
            } else {
                progress("second: connecting")
            }
            try await Task.sleep(for: .seconds(30))
            throw CancellationError()
        }
        session.connect(profile: ConnectionProfile(name: "First", host: "first"), store: store, password: "")
        session.connect(profile: ConnectionProfile(name: "Second", host: "second"), store: store, password: "")
        // Until the first connect has reported (bounded; a fixed sleep failed on a loaded machine), then long enough for
        // a late status to land if it were not dropped.
        let deadline = ContinuousClock.now + .seconds(10)
        while !firstCancelled.isMarked, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(300))
        guard case let .connecting(name, status) = session.phase else {
            Issue.record("expected to be connecting")
            return
        }
        #expect(name == "Second")
        #expect(status == "second: connecting")
        #expect(firstCancelled.isMarked, "the first connect was cancelled")
        session.cancelConnecting()
        guard case .connections = session.phase else {
            Issue.record("expected the connection screen")
            return
        }
    }

    /// A connect that fails after a newer one started never shows its error or leaves the connecting screen.
    @Test func aLateFailureOfACancelledConnectIsIgnored() async throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = WindowSession()
        session.opener = { profile, _, _, _ in
            if profile.host == "first" {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { continuation.resume() }
                }
                throw URLError(.cannotConnectToHost)
            }
            try await Task.sleep(for: .seconds(30))
            throw CancellationError()
        }
        session.connect(profile: ConnectionProfile(name: "First", host: "first"), store: store, password: "")
        session.connect(profile: ConnectionProfile(name: "Second", host: "second"), store: store, password: "")
        try await Task.sleep(for: .milliseconds(700))
        #expect(session.connectError == nil)
        guard case let .connecting(name, _) = session.phase else {
            Issue.record("expected to be connecting")
            return
        }
        #expect(name == "Second")
        session.cancelConnecting()
    }
}

/// A flag set from a non-isolated context.
private final class CancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var marked = false
    func mark() { lock.withLock { marked = true } }
    var isMarked: Bool { lock.withLock { marked } }
}
