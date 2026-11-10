import XCTest
@testable import Glacier

/// Covers when `AppleSubscriptionOwnershipMonitor` puts up the ownership-conflict cover. The cover
/// locks the user out of the app, so it must appear only when the backend refused the Apple receipt
/// link AND has said the signed-in account has no plan of its own. A website or family-plan account
/// is never locked out, and an account whose status isn't known yet waits instead of flashing it.
@MainActor
final class AppleSubscriptionOwnershipMonitorTests: XCTestCase {

    private var monitor: AppleSubscriptionOwnershipMonitor!
    private let account = UUID()
    private let otherAccount = UUID()

    override func setUp() async throws {
        try await super.setUp()
        monitor = AppleSubscriptionOwnershipMonitor()
    }

    override func tearDown() async throws {
        monitor = nil
        try await super.tearDown()
    }

    // MARK: - Conflict with a saved backend status

    /// The ticket that prompted this: a paid (website) account must not be locked out.
    func testConflictOnSubscribedAccountShowsNoCover() {
        monitor.reportConflict(accountId: account, entitledOnBackend: true)
        XCTAssertFalse(monitor.isConflicted)
    }

    func testConflictOnUnsubscribedAccountShowsCover() {
        monitor.reportConflict(accountId: account, entitledOnBackend: false)
        XCTAssertTrue(monitor.isConflicted)
    }

    // MARK: - Conflict before the backend has answered (fresh sign-in)

    func testConflictWithUnknownStatusWaitsInsteadOfFlashing() {
        monitor.reportConflict(accountId: account, entitledOnBackend: nil)
        XCTAssertFalse(monitor.isConflicted)
    }

    func testUnknownStatusThenSubscribedNeverShowsCover() {
        monitor.reportConflict(accountId: account, entitledOnBackend: nil)
        monitor.reportBackendEntitlement(true)
        XCTAssertFalse(monitor.isConflicted)
    }

    func testUnknownStatusThenNotSubscribedShowsCover() {
        monitor.reportConflict(accountId: account, entitledOnBackend: nil)
        monitor.reportBackendEntitlement(false)
        XCTAssertTrue(monitor.isConflicted)
    }

    // MARK: - Backend status changing while the conflict stands

    func testBackendSubscribingLiftsCover() {
        monitor.reportConflict(accountId: account, entitledOnBackend: false)
        monitor.reportBackendEntitlement(true)
        XCTAssertFalse(monitor.isConflicted)
    }

    func testBackendLapsingRestoresCover() {
        monitor.reportConflict(accountId: account, entitledOnBackend: true)
        monitor.reportBackendEntitlement(false)
        XCTAssertTrue(monitor.isConflicted)
    }

    func testBackendStatusAloneNeverShowsCover() {
        monitor.reportBackendEntitlement(false)
        XCTAssertFalse(monitor.isConflicted)
    }

    // MARK: - Linking and sign-out

    func testSuccessfulLinkClearsConflict() {
        monitor.reportConflict(accountId: account, entitledOnBackend: false)
        monitor.reportLinked(accountId: account)
        XCTAssertFalse(monitor.isConflicted)
        // The conflict is gone, not just hidden: a later "not subscribed" doesn't bring it back.
        monitor.reportBackendEntitlement(false)
        XCTAssertFalse(monitor.isConflicted)
    }

    func testLinkForAnotherAccountDoesNotClearConflict() {
        monitor.reportConflict(accountId: account, entitledOnBackend: false)
        monitor.reportLinked(accountId: otherAccount)
        XCTAssertTrue(monitor.isConflicted)
    }

    func testClearDropsConflict() {
        monitor.reportConflict(accountId: account, entitledOnBackend: false)
        monitor.clear()
        XCTAssertFalse(monitor.isConflicted)
    }

    /// After sign-out, a late status for the previous account must not decide the cover for the
    /// next one: its conflict uses its own saved status.
    func testStaleStatusFromPreviousAccountIsReplacedOnConflict() {
        monitor.clear()
        monitor.reportBackendEntitlement(false)   // late answer for the account that signed out
        monitor.reportConflict(accountId: otherAccount, entitledOnBackend: nil)
        XCTAssertFalse(monitor.isConflicted)
    }

    // MARK: - Recognising the backend's 409

    func testConflictCodeIsOwnershipConflict() throws {
        let body = try JSONSerialization.data(withJSONObject: ["code": AppleSubscriptionOwnershipMonitor.conflictCode])
        XCTAssertTrue(AppleSubscriptionOwnershipMonitor.isOwnershipConflict(statusCode: 409, body: body))
    }

    func testBare409IsOwnershipConflict() {
        XCTAssertTrue(AppleSubscriptionOwnershipMonitor.isOwnershipConflict(statusCode: 409, body: nil))
    }

    func testOther409CodeIsNotOwnershipConflict() throws {
        let body = try JSONSerialization.data(withJSONObject: ["code": "something_else"])
        XCTAssertFalse(AppleSubscriptionOwnershipMonitor.isOwnershipConflict(statusCode: 409, body: body))
    }

    func testNon409IsNotOwnershipConflict() {
        XCTAssertFalse(AppleSubscriptionOwnershipMonitor.isOwnershipConflict(statusCode: 400, body: nil))
    }
}
