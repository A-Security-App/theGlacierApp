import XCTest
@testable import Glacier

final class GlacierJailbreakChecksTests: XCTestCase {

    func testCleanDeviceReportsNotJailbroken() {
        // No path exists → no indicators.
        let result = GlacierJailbreakChecks.run(pathExists: { _ in false })
        XCTAssertFalse(result.jailbroken)
        XCTAssertTrue(result.indicators.isEmpty)
    }

    func testRootlessJailbreakRootIsDetected() {
        // palera1n/Dopamine/XinaA15 rootless root — the gap in 1.9.11.
        let result = GlacierJailbreakChecks.run(pathExists: { $0 == "/var/jb" })
        XCTAssertTrue(result.jailbroken)
        XCTAssertEqual(result.indicators, ["/var/jb"])
    }

    func testTrollStoreBundleIsDetected() {
        let result = GlacierJailbreakChecks.run(pathExists: { $0 == "/Applications/TrollStore.app" })
        XCTAssertTrue(result.jailbroken)
        XCTAssertEqual(result.indicators, ["/Applications/TrollStore.app"])
    }

    func testMultipleIndicatorsAreAllReported() {
        let present: Set<String> = ["/var/jb", "/var/jb/etc/apt", "/var/jb/Applications/Sileo.app"]
        let result = GlacierJailbreakChecks.run(pathExists: { present.contains($0) })
        XCTAssertTrue(result.jailbroken)
        XCTAssertEqual(Set(result.indicators), present)
    }

    func testUnrelatedPathDoesNotTrigger() {
        // A path that exists on stock devices but isn't in our list must not flag.
        let result = GlacierJailbreakChecks.run(pathExists: { $0 == "/var/mobile" })
        XCTAssertFalse(result.jailbroken)
        XCTAssertTrue(result.indicators.isEmpty)
    }

    func testOnlyListedPathsAreProbed() {
        // Every path handed to the probe must be one we declared — guards against
        // accidentally querying arbitrary paths.
        var probed: [String] = []
        _ = GlacierJailbreakChecks.run(pathExists: { path in
            probed.append(path)
            return false
        })
        XCTAssertEqual(Set(probed), Set(GlacierJailbreakChecks.suspiciousPaths))
    }

    func testLiveProbeIsCleanInTestEnvironment() {
        // The default filesystem probe must report clean in the simulator / CI,
        // where none of the jailbreak paths exist.
        let result = GlacierJailbreakChecks.run()
        XCTAssertFalse(result.jailbroken, "unexpected indicators: \(result.indicators)")
    }
}
