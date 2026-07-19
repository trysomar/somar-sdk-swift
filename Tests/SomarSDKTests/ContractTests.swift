import XCTest
@testable import SomarSDK

/// The event contract (docs/event-contract.md): the sanitiser, the name
/// normaliser, reset() semantics, and parity between the vendored constants
/// and the canonical docs/event-contract.json at the monorepo root.
final class ContractTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Session.reset()
        Session.isOptedOut = false
    }

    // ── Name normalisation (§3) ──────────────────────────────────────────────

    func testEventNameIsNormalised() {
        XCTAssertEqual(SomarContract.normaliseEventName("  Signed \t\n  Up  "), "Signed Up")
        XCTAssertEqual(SomarContract.normaliseEventName("Weird\u{07} Name"), "Weird Name")
        // Case and separators are preserved — sdk.events.<name> keys on them.
        XCTAssertEqual(SomarContract.normaliseEventName("signed_up"), "signed_up")
        XCTAssertEqual(SomarContract.normaliseEventName(" \t "), "")
        XCTAssertEqual(SomarContract.normaliseEventName(String(repeating: "n", count: 300)).count, 200)
    }

    // ── Property sanitisation (§4/§5) ────────────────────────────────────────

    func testReservedDollarKeysAreStripped() {
        let out = SomarContract.sanitise(["$user_id": "forged", "plan": "builder"])
        XCTAssertNil(out["$user_id"])
        XCTAssertEqual(out["plan"] as? String, "builder")
    }

    func testLongStringsAreTruncatedAtEveryDepth() {
        let out = SomarContract.sanitise([
            "top": String(repeating: "x", count: 9_000),
            "nested": ["inner": String(repeating: "y", count: 9_000)],
        ])
        XCTAssertEqual((out["top"] as? String)?.count, 8_192)
        XCTAssertEqual(((out["nested"] as? [String: Any])?["inner"] as? String)?.count, 8_192)
    }

    func testNestingIsCutAtDepthSix() {
        var nest: Any = "bottom"
        for _ in 0..<8 { nest = ["d": nest] }
        let out = SomarContract.sanitise(["deep": nest])
        // props.deep is depth 1; the object five "d"s down sits at depth 6 → cut.
        var cursor = out["deep"] as? [String: Any]
        for _ in 0..<4 { cursor = cursor?["d"] as? [String: Any] }
        XCTAssertEqual(cursor?["d"] as? String, "[somar:truncated]")
    }

    func testScalarsSurviveSanitisation() {
        let out = SomarContract.sanitise(["n": 42, "b": true, "s": "ok", "a": [1, 2]])
        XCTAssertEqual(out["n"] as? Int, 42)
        XCTAssertEqual(out["b"] as? Bool, true)
        XCTAssertEqual(out["s"] as? String, "ok")
        XCTAssertEqual((out["a"] as? [Any])?.count, 2)
    }

    // ── reset() semantics (§8) ───────────────────────────────────────────────

    func testResetClearsSuperPropertiesButKeepsOptOut() {
        Session.register(["tier": "gold"])
        Session.isOptedOut = true
        Session.reset()
        XCTAssertTrue(Session.superProperties.isEmpty,
                      "super properties belong to the account and must not survive logout")
        XCTAssertTrue(Session.isOptedOut,
                      "the opt-out preference belongs to the device and MUST survive logout")
        Session.isOptedOut = false
    }

    // ── Parity with the canonical contract ───────────────────────────────────
    // Tests/SomarSDKTests/ContractTests.swift → monorepo root is three dirs up
    // from the package root. A standalone checkout of just the SDK skips.

    func testVendoredConstantsMatchCanonicalContract() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SomarSDKTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // somar-sdk-swift
        let canonical = packageRoot.deletingLastPathComponent()
            .appendingPathComponent("docs/event-contract.json")
        guard FileManager.default.fileExists(atPath: canonical.path) else {
            throw XCTSkip("standalone checkout — no ../docs/event-contract.json")
        }
        let data = try Data(contentsOf: canonical)
        let doc = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let enforced = try XCTUnwrap(doc["enforced"] as? [String: Any])

        XCTAssertEqual(enforced["max_batch"] as? Int, SomarContract.maxBatch)
        XCTAssertEqual(enforced["max_body_bytes"] as? Int, SomarContract.maxBodyBytes)
        XCTAssertEqual(enforced["max_event_bytes"] as? Int, SomarContract.maxEventBytes)
        XCTAssertEqual(enforced["max_event_name_len"] as? Int, SomarContract.maxEventNameLen)
        XCTAssertEqual(enforced["max_distinct_id_len"] as? Int, SomarContract.maxDistinctIDLen)
        XCTAssertEqual(enforced["min_distinct_id_len"] as? Int, SomarContract.minDistinctIDLen)
        XCTAssertEqual(enforced["max_session_id_len"] as? Int, SomarContract.maxSessionIDLen)
        XCTAssertEqual(enforced["max_string_value_len"] as? Int, SomarContract.maxStringValueLen)
        XCTAssertEqual(enforced["max_property_depth"] as? Int, SomarContract.maxPropertyDepth)
        XCTAssertEqual(enforced["future_ts_tolerance_hours"] as? Int, SomarContract.futureTsToleranceHours)
        XCTAssertEqual(enforced["quarantine_retention_days"] as? Int, SomarContract.quarantineRetentionDays)
        XCTAssertEqual(enforced["blocked_distinct_ids"] as? [String], SomarContract.blockedDistinctIDs)
        // Nothing in `enforced` may be missing from this assertion list.
        XCTAssertEqual(enforced.count, 12, "docs/event-contract.json gained a field this test does not assert")
    }
}
