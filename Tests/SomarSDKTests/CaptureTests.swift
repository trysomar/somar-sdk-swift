import XCTest
@testable import SomarSDK

/// Behaviour-capture guarantees: crashes survive to the next launch, group
/// membership rides every later event, breadcrumbs stay bounded, and API
/// capture produces the fields the rollup reads.
final class CaptureTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Session.reset()
        try? FileManager.default.removeItem(at: CrashReporter.reportURL)
    }

    // ── Crash persistence ────────────────────────────────────────────────

    func testCrashReportPersistsAndDrainsOnce() throws {
        CrashReporter.write(type: "NSRangeException",
                            message: "Index 4 beyond bounds",
                            stack: "0 CoreFoundation\n1 Somar")
        let report = try XCTUnwrap(CrashReporter.drainPendingCrash())
        XCTAssertEqual(report["type"] as? String, "NSRangeException")
        XCTAssertEqual(report["message"] as? String, "Index 4 beyond bounds")
        XCTAssertNotNil(report["at"])
        // Draining clears the file — a crash is reported exactly once.
        XCTAssertNil(CrashReporter.drainPendingCrash())
    }

    func testCrashReportCarriesBreadcrumbTrail() throws {
        Session.addBreadcrumb("$screen")
        Session.addBreadcrumb("checkout_started")
        CrashReporter.write(type: "signal", message: "Fatal signal 11", stack: "")
        let report = try XCTUnwrap(CrashReporter.drainPendingCrash())
        XCTAssertEqual(report["breadcrumbs"] as? [String], ["$screen", "checkout_started"])
    }

    func testCrashStackIsBounded() throws {
        CrashReporter.write(type: "t", message: "m",
                            stack: String(repeating: "x", count: 50_000))
        let report = try XCTUnwrap(CrashReporter.drainPendingCrash())
        XCTAssertEqual((report["stack"] as? String)?.count, 8_000)
    }

    // ── Breadcrumbs ──────────────────────────────────────────────────────

    func testBreadcrumbTrailKeepsTheLastTwenty() {
        for i in 0..<30 { Session.addBreadcrumb("event_\(i)") }
        let trail = Session.breadcrumbs
        XCTAssertEqual(trail.count, 20)
        XCTAssertEqual(trail.first, "event_10")
        XCTAssertEqual(trail.last, "event_29")
    }

    // ── Groups ride subsequent events (account analytics) ────────────────

    func testGroupMembershipBecomesSuperProperty() {
        Somar.group("company", "acme")
        Somar.group("team", "growth")
        let groups = Session.superProperties["$groups"] as? [String: Any]
        XCTAssertEqual(groups?["company"] as? String, "acme")
        XCTAssertEqual(groups?["team"] as? String, "growth")
        // Re-grouping the same type replaces, never duplicates.
        Somar.group("company", "globex")
        let updated = Session.superProperties["$groups"] as? [String: Any]
        XCTAssertEqual(updated?["company"] as? String, "globex")
    }

    // ── Device context ───────────────────────────────────────────────────

    func testContextCarriesTheCaptureTaxonomyFields() {
        let ctx = Somar.context()
        XCTAssertEqual(ctx["$lib"] as? String, "somar-swift")
        XCTAssertEqual(ctx["$lib_version"] as? String, Somar.version)
        XCTAssertNotNil(ctx["$locale"])
        XCTAssertNotNil(ctx["$timezone"])
        XCTAssertNotNil(ctx["$device_model_identifier"])
        XCTAssertNotNil(ctx["$device_type"])
    }

    func testLastKnownSessionIDTracksWithoutLocking() {
        let id = Session.sessionID()
        XCTAssertEqual(Session.lastKnownSessionID, id)
    }
}
