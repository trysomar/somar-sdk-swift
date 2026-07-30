import XCTest
@testable import SomarSDK

/// Feature flags, and the arm that makes an experiment measurable.
///
/// `sdk_experiment_results` computes its posterior from `$variant` on the
/// `$feature_flag_called` event. Before multivariate flags existed nothing in
/// this SDK ever wrote that property, so an experiment collected exposures and
/// reported "not enough data" forever — a failure with no error, no log and no
/// symptom other than a result that never arrives. These tests exist because
/// that is invisible in review.
final class FlagTests: XCTestCase {

    private func store(_ json: String,
                       onExposure: @escaping (String, [String: Any]) -> Void) throws -> FlagsStore {
        let config = Config(apiKey: "somar_pk_" + String(repeating: "a", count: 48),
                            host: URL(string: "https://example.invalid")!)
        let s = FlagsStore(config: config, exposure: onExposure)
        struct Body: Codable { let flags: [String: FlagsStore.Flag]? }
        let body = try JSONDecoder().decode(Body.self, from: Data(json.utf8))
        s.replaceForTesting(body.flags ?? [:])
        return s
    }

    /// A flag serialised WITHOUT a variant must still decode. `variant` was
    /// added after both SDKs shipped, so every cached flag on every device
    /// predates it — a non-optional field here would fail the decode and empty
    /// the cache for every existing install at once.
    func testBooleanFlagDecodesWithoutVariant() throws {
        var props: [String: Any] = [:]
        let s = try store(#"{"flags":{"beta":{"enabled":true,"payload":null}}}"#) { _, p in props = p }
        XCTAssertTrue(s.isEnabled("beta"))
        XCTAssertNil(s.variant("beta"))
        XCTAssertEqual(props["$flag_key"] as? String, "beta")
        XCTAssertEqual(props["$flag_enabled"] as? Bool, true)
        // Absent, not null: the analysis distinguishes "not an experiment" from
        // "arm unknown", and a null would collapse the two.
        XCTAssertNil(props["$variant"], "a boolean flag must not report an arm")
    }

    func testMultivariateFlagReportsItsArm() throws {
        var props: [String: Any] = [:]
        let s = try store(#"{"flags":{"pricing":{"enabled":true,"variant":"test","payload":null}}}"#) { _, p in props = p }
        XCTAssertEqual(s.variant("pricing"), "test")
        XCTAssertEqual(props["$variant"] as? String, "test",
                       "without this the experiment has no input and never concludes")
    }

    /// One exposure per key, however the app reads it. Two accessors each
    /// firing their own exposure would double every denominator.
    func testExposureIsReportedOncePerKey() throws {
        var count = 0
        let s = try store(#"{"flags":{"pricing":{"enabled":true,"variant":"control","payload":null}}}"#) { _, _ in count += 1 }
        _ = s.isEnabled("pricing")
        _ = s.variant("pricing")
        _ = s.isEnabled("pricing")
        XCTAssertEqual(count, 1, "each extra exposure inflates the experiment's denominator")
    }

    /// An unknown key must report nothing at all. Reporting an exposure for a
    /// flag the server never sent would put someone in the denominator of an
    /// experiment they were never in.
    func testUnknownFlagReportsNothing() throws {
        var fired = false
        let s = try store(#"{"flags":{}}"#) { _, _ in fired = true }
        XCTAssertFalse(s.isEnabled("nope"))
        XCTAssertNil(s.variant("nope"))
        XCTAssertFalse(fired)
    }
}
