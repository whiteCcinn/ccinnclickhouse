import Foundation
import Testing
@testable import CcinnClickHouseKit

@MainActor
@Suite("Window handoff")
struct WindowHandoffTests {
    @Test func aPayloadIsTakenExactlyOnce() {
        let handoff = WindowHandoff<String>()
        let request = handoff.request(profileID: UUID(), payload: "secret")
        #expect(handoff.pendingCount == 1)
        #expect(handoff.take(request) == "secret")
        #expect(handoff.take(request) == nil, "a second window must not reuse the connection")
        #expect(handoff.pendingCount == 0, "the password must not stay in memory once taken")
    }

    @Test func restoredRequestsCarryNothing() throws {
        // A request decoded after a relaunch (window restoration) was not created by this process.
        let handoff = WindowHandoff<String>()
        #expect(handoff.take(WindowRequest(profileID: UUID())) == nil)

        let profile = UUID()
        let restored = try JSONDecoder().decode(WindowRequest.self, from: Data(#"{"profileID":"\#(profile.uuidString)"}"#.utf8))
        #expect(handoff.take(restored) == nil)
    }

    @Test func aRestoredRequestFallsThroughWithoutTouchingPendingConnections() throws {
        // A restored window falls through to the empty-window path while a window this process opened for the
        // same profile has not taken its connection yet: the restored one must neither get nor consume it.
        let handoff = WindowHandoff<String>()
        let profile = UUID()
        let opened = handoff.request(profileID: profile, payload: "in use")
        let restored = try JSONDecoder().decode(WindowRequest.self, from: JSONEncoder().encode(WindowRequest(profileID: profile)))
        #expect(handoff.take(restored) == nil)
        #expect(handoff.pendingCount == 1)
        #expect(handoff.take(opened) == "in use")
    }

    @Test func anotherProcessRequestForTheSameProfileCarriesNothing() {
        let handoff = WindowHandoff<String>()
        let profile = UUID()
        let mine = handoff.request(profileID: profile, payload: "a")
        // Same profile, different nonce: not this request's payload.
        #expect(handoff.take(WindowRequest(profileID: profile)) == nil)
        #expect(handoff.take(mine) == "a")
    }

    @Test func requestsForTheSameProfileAreIndependent() {
        let handoff = WindowHandoff<String>()
        let profile = UUID()
        let first = handoff.request(profileID: profile, payload: "a")
        let second = handoff.request(profileID: profile, payload: "b")
        #expect(first != second)
        #expect(first.profileID == profile && second.profileID == profile)
        #expect(handoff.take(second) == "b")
        #expect(handoff.take(first) == "a")
        #expect(handoff.pendingCount == 0)
    }
}
