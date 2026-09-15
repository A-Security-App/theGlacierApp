import XCTest
import NetworkExtension
@testable import Glacier

/// Covers the two decisions in `VPNProtectionAlert` that determine whether a user
/// gets an alert: how a stop reason is classified, and how long an unresolved
/// warning survives. Both are pure enough to test without NetworkExtension state.
final class VPNProtectionAlertTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suiteName = "VPNProtectionAlertTests"

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suiteName)
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: - Stop-reason classification

    /// Acceptance criterion: intentional disconnects must not trigger the alert.
    func testUserDrivenStopReasonsAreDeliberate() {
        let deliberate: [NEProviderStopReason] = [
            .userInitiated, .providerDisabled, .configurationDisabled,
            .configurationRemoved, .userLogout, .userSwitch
        ]
        for reason in deliberate {
            guard case .deliberate = VPNProtectionAlert.disposition(for: reason) else {
                return XCTFail("\(reason.rawValue) should be deliberate")
            }
        }
    }

    /// The case from the customer report: an app update tore the tunnel down and no
    /// alert was sent. It must classify as a failure *and* keep the appUpdate kind,
    /// because that is what selects the "finish updating first" copy.
    func testAppUpdateIsAFailureCarryingItsOwnKind() {
        guard case .failure(let kind) = VPNProtectionAlert.disposition(for: .appUpdate) else {
            return XCTFail("appUpdate should be a failure")
        }
        XCTAssertEqual(kind, .appUpdate)
    }

    func testBreakageReasonsAreFailures() {
        let failures: [NEProviderStopReason] = [
            .providerFailed, .connectionFailed, .configurationFailed, .authenticationCanceled
        ]
        for reason in failures {
            guard case .failure(let kind) = VPNProtectionAlert.disposition(for: reason) else {
                return XCTFail("\(reason.rawValue) should be a failure")
            }
            XCTAssertEqual(kind, .failure)
        }
    }

    /// These are either expected (the network went away, the device slept) or produced
    /// by Glacier's own region-switch flow. Treating any of them as breakage in the
    /// extension would risk a false "protection is off" alert on a trusted network,
    /// so they must defer to the app-side paths that can check the on-demand policy.
    func testExpectedAndAmbiguousReasonsStaySilent() {
        let transient: [NEProviderStopReason] = [
            NEProviderStopReason.none, .noNetworkAvailable, .unrecoverableNetworkChange,
            .idleTimeout, .superceded, .sleep
        ]
        for reason in transient {
            guard case .transient = VPNProtectionAlert.disposition(for: reason) else {
                return XCTFail("\(reason.rawValue) should be transient")
            }
        }
    }

    // MARK: - Pending warning

    func testPendingWarningRoundTrips() {
        VPNProtectionAlert.recordPendingWarning(.appUpdate, defaults: defaults)
        XCTAssertEqual(VPNProtectionAlert.pendingWarningKind(defaults: defaults), .appUpdate)

        VPNProtectionAlert.clearPendingWarning(defaults: defaults)
        XCTAssertNil(VPNProtectionAlert.pendingWarningKind(defaults: defaults))
    }

    /// A warning written just before the app was force-quit for a week must not still
    /// be shown when the user finally reopens it.
    func testPendingWarningExpires() {
        VPNProtectionAlert.recordPendingWarning(.failure, defaults: defaults)
        let expired = Date().timeIntervalSince1970 - VPNProtectionAlert.warningLifetime - 1
        defaults.set(expired, forKey: "glacier.vpn.pendingWarningDate")

        XCTAssertNil(VPNProtectionAlert.pendingWarningKind(defaults: defaults))
    }

    func testNoPendingWarningByDefault() {
        XCTAssertNil(VPNProtectionAlert.pendingWarningKind(defaults: defaults))
    }

    // MARK: - App-initiated stop window

    func testNoAppInitiatedStopWindowByDefault() {
        XCTAssertFalse(VPNProtectionAlert.isWithinAppInitiatedStopWindow(defaults: defaults))
    }

    /// Covers the config-change bounce in `TunnelsManager.modify`, which stops the
    /// tunnel with on-demand still enabled — indistinguishable from a system kill
    /// without this marker.
    func testAppInitiatedStopIsInWindowImmediatelyAfterBeingNoted() {
        VPNProtectionAlert.noteAppInitiatedStop(defaults: defaults)
        XCTAssertTrue(VPNProtectionAlert.isWithinAppInitiatedStopWindow(defaults: defaults))
    }

    func testAppInitiatedStopWindowExpires() {
        let stale = Date().timeIntervalSince1970 - VPNProtectionAlert.appInitiatedStopWindow - 1
        defaults.set(stale, forKey: "glacier.vpn.appInitiatedStopDate")

        XCTAssertFalse(VPNProtectionAlert.isWithinAppInitiatedStopWindow(defaults: defaults))
    }

    func testClearingAppInitiatedStopEndsTheWindow() {
        VPNProtectionAlert.noteAppInitiatedStop(defaults: defaults)
        VPNProtectionAlert.clearAppInitiatedStop(defaults: defaults)

        XCTAssertFalse(VPNProtectionAlert.isWithinAppInitiatedStopWindow(defaults: defaults))
    }
}
