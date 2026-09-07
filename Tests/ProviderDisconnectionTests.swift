import Combine
import XCTest
@testable import Codenotch

@MainActor
final class ProviderDisconnectionTests: XCTestCase {
    private func makeStore(_ providers: [UsageProvider], disconnected: Set<String> = [])
        -> (UsageStore, UsageArchive) {
        let name = "ProviderDisconnectionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let archive = UsageArchive(defaults: defaults)
        return (UsageStore(providers: providers, archive: archive, disconnected: disconnected), archive)
    }

    func testSettingsDoesNotReadADisconnectedAccount() {
        let disabled = Probe(id: "disabled")
        let enabled = Probe(id: "enabled")
        let (store, _) = makeStore([disabled, enabled], disconnected: [disabled.id])

        let summaries = store.providerSummaries

        XCTAssertEqual(summaries.map(\.id), [disabled.id, enabled.id])
        XCTAssertNil(summaries.first?.account)
        XCTAssertEqual(disabled.accountReads, 0)
        XCTAssertEqual(enabled.accountReads, 1)
    }

    func testDisconnectDiscardsAnInFlightReadingAndItsArchive() async {
        let started = expectation(description: "Request started")
        let provider = Probe(id: "a", started: started)
        let (store, archive) = makeStore([provider])
        store.refreshNow()
        await fulfillment(of: [started], timeout: 2)

        store.disconnected = [provider.id]
        await finish(provider, in: store)

        XCTAssertTrue(store.snapshots.isEmpty)
        XCTAssertNil(archive.load()[provider.id])
    }

    func testDisconnectDiscardsAnInFlightAccessRefusal() async {
        let started = expectation(description: "Request started")
        let provider = Probe(id: "a", started: started)
        let (store, archive) = makeStore([provider])
        store.refreshNow()
        await fulfillment(of: [started], timeout: 2)

        store.disconnected = [provider.id]
        await finish(provider, in: store, error: .accessDenied)

        XCTAssertTrue(store.snapshots.isEmpty)
        XCTAssertTrue(store.refusedAccess.isEmpty)
        XCTAssertNil(archive.load()[provider.id])
    }

    func testAQueuedProviderIsNotReadAfterItIsDisconnected() async {
        let started = expectation(description: "First request started")
        let first = Probe(id: "a", started: started)
        let queued = Probe(id: "b")
        let (store, archive) = makeStore([first, queued])
        store.refreshNow()
        await fulfillment(of: [started], timeout: 2)

        store.disconnected = [queued.id]
        await finish(first, in: store)

        XCTAssertEqual(queued.calls, 0)
        XCTAssertEqual(store.snapshots.map(\.id), [first.id])
        XCTAssertNil(archive.load()[queued.id])
        XCTAssertNotNil(archive.load()[first.id])
    }

    func testAnEarlierResultCannotReturnWhileALaterProviderIsWaiting() async {
        let started = expectation(description: "Second request started")
        let first = Probe(id: "a")
        let second = Probe(id: "b", started: started)
        let (store, archive) = makeStore([first, second])
        store.refreshNow()
        await fulfillment(of: [started], timeout: 2)
        XCTAssertNotNil(archive.load()[first.id])

        store.disconnected = [first.id]
        await finish(second, in: store)

        XCTAssertEqual(store.snapshots.map(\.id), [second.id])
        XCTAssertNil(archive.load()[first.id])
        XCTAssertNotNil(archive.load()[second.id])
    }

    func testReconnectingDoesNotAcceptThePreviousConnectionsResponse() async {
        let started = expectation(description: "Old request started")
        let provider = Probe(id: "a", started: started)
        let (store, archive) = makeStore([provider])
        store.refreshNow()
        await fulfillment(of: [started], timeout: 2)

        store.disconnected = [provider.id]
        store.disconnected = []
        await finish(provider, in: store)

        XCTAssertTrue(store.snapshots.isEmpty)
        XCTAssertNil(archive.load()[provider.id])

        // Only the first request is suspended: the next connection can refresh
        // normally, so rejecting the old response must not leave it locked out.
        await store.refresh()
        XCTAssertEqual(provider.calls, 2)
        XCTAssertEqual(store.snapshots.map(\.id), [provider.id])
        XCTAssertNotNil(archive.load()[provider.id])
    }

    func testDisconnectDiscardsASingleProviderRefreshAndClearsItsSpinner() async {
        let started = expectation(description: "Single request started")
        let provider = Probe(id: "a", started: started)
        let (store, archive) = makeStore([provider])
        store.refresh(providerID: provider.id)
        await fulfillment(of: [started], timeout: 2)

        store.disconnected = [provider.id]
        // Its automatically scheduled full refresh has no enabled providers.
        // Await it before releasing the single-provider response.
        await waitForRefreshToFinish(store)
        provider.resolve()
        await waitForResponseProcessing()

        XCTAssertTrue(store.snapshots.isEmpty)
        XCTAssertNil(archive.load()[provider.id])
        XCTAssertTrue(store.refreshing.isEmpty)
    }

    func testSignOutInvalidatesAResponseBeforeThePreferenceBindingArrives() async {
        let started = expectation(description: "Request started")
        let provider = Probe(id: "a", started: started)
        let (store, archive) = makeStore([provider])
        store.refreshNow()
        await fulfillment(of: [started], timeout: 2)

        store.signOut(providerID: provider.id)
        await finish(provider, in: store)

        XCTAssertTrue(store.snapshots.isEmpty)
        XCTAssertNil(archive.load()[provider.id])
    }

    func testSignOutClearsASingleProviderSpinnerEvenWhenItsResponseIsDiscarded() async {
        let started = expectation(description: "Single request started")
        let provider = Probe(id: "a", started: started)
        let (store, archive) = makeStore([provider])
        store.refresh(providerID: provider.id)
        await fulfillment(of: [started], timeout: 2)

        store.signOut(providerID: provider.id)
        await finish(provider, in: store)

        XCTAssertTrue(store.snapshots.isEmpty)
        XCTAssertNil(archive.load()[provider.id])
        XCTAssertTrue(store.refreshing.isEmpty)
    }

    private func finish(_ provider: Probe, in store: UsageStore,
                        error: UsageProviderError? = nil) async {
        let finished = expectation(description: "Refresh finished")
        let subscription = store.$refreshing.dropFirst().filter(\.isEmpty).prefix(1)
            .sink { _ in finished.fulfill() }
        provider.resolve(error: error)
        await fulfillment(of: [finished], timeout: 2)
        withExtendedLifetime(subscription) {}
    }

    private func waitForRefreshToFinish(_ store: UsageStore) async {
        let finished = expectation(description: "Scheduled refresh finished")
        let subscription = store.$refreshing.dropFirst().filter(\.isEmpty).prefix(1)
            .sink { _ in finished.fulfill() }
        await fulfillment(of: [finished], timeout: 2)
        withExtendedLifetime(subscription) {}
    }

    private func waitForResponseProcessing() async {
        // A short bounded wait also covers the existing 380ms single-cell
        // spinner delay when this regression is run against the old code.
        try? await Task.sleep(nanoseconds: 500_000_000)
    }
}

/// Suspends its first fetch until the test releases it; later fetches return
/// immediately. No network, real account files, or keychain reads are involved.
private final class Probe: UsageProvider, @unchecked Sendable {
    let id: String
    let displayName = "Probe"
    let glyph = ProviderGlyph.claude
    private let started: XCTestExpectation?
    private let lock = NSLock()
    private var pending: CheckedContinuation<ProviderSnapshot, Error>?
    private var fetchCount = 0
    private var accountCount = 0

    init(id: String, started: XCTestExpectation? = nil) {
        self.id = id
        self.started = started
    }

    var calls: Int { lock.withLock { fetchCount } }
    var accountReads: Int { lock.withLock { accountCount } }

    func account() -> ProviderAccount? {
        lock.withLock { accountCount += 1 }
        return ProviderAccount(label: "Test account", plan: nil, source: "Probe", manageURL: nil)
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        let first = lock.withLock { fetchCount += 1; return fetchCount == 1 }
        if first, let started {
            return try await withCheckedThrowingContinuation { continuation in
                lock.withLock { pending = continuation }
                started.fulfill()
            }
        }
        return reading()
    }

    func resolve(error: UsageProviderError? = nil) {
        let continuation = lock.withLock {
            let continuation = pending
            pending = nil
            return continuation
        }
        if let error { continuation?.resume(throwing: error) }
        else { continuation?.resume(returning: reading()) }
    }

    private func reading() -> ProviderSnapshot {
        ProviderSnapshot(id: id, displayName: displayName, glyph: glyph,
                         fidelity: .official, status: .ok,
                         windows: [LimitWindow(id: "session", label: "Session", usedFraction: 0.42)])
    }
}
