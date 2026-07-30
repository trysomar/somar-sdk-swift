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

    // ── AI spend ─────────────────────────────────────────────────────────
    // sdk_ai_overview / sdk_ai_cost / the six sdk.ai.* metrics read
    // $ai_generation, and nothing in this SDK could write it: the $ namespace
    // is platform-only, so a hand-built capture("$ai_generation", …) was
    // refused by name and stripped by property.

    func testAIGenerationCarriesTheFieldsTheReaderReads() throws {
        let props = try XCTUnwrap(Somar.aiGenerationProps(
            model: "gpt-4.1-mini", inputTokens: 1_200, outputTokens: 340,
            latencyMs: 880, provider: "openai", traceID: "trace-1",
            ["feature": "summarise"]))
        XCTAssertEqual(props["$ai_model"] as? String, "gpt-4.1-mini")
        XCTAssertEqual(props["$ai_input_tokens"] as? Int, 1_200)
        XCTAssertEqual(props["$ai_output_tokens"] as? Int, 340)
        XCTAssertEqual(props["$ai_latency_ms"] as? Int, 880)
        XCTAssertEqual(props["$ai_provider"] as? String, "openai")
        XCTAssertEqual(props["$ai_trace_id"] as? String, "trace-1")
        XCTAssertEqual(props["feature"] as? String, "summarise")
    }

    /// THE ASSERTION THIS METHOD EXISTS FOR. sdk_ai_overview branches on the
    /// KEY BEING PRESENT (`props ? '$ai_cost_usd'`) and sdk_numeric() answers 0
    /// for anything non-numeric — so a null or a 0 here is read as an exact
    /// $0.00 that counts as PRICED and never reaches cost_unknown. Server-side
    /// pricing happens only when the key is ABSENT.
    func testAnOmittedCostIsAbsentFromThePayload() throws {
        let props = try XCTUnwrap(Somar.aiGenerationProps(
            model: "gpt-4.1-mini", inputTokens: 10, outputTokens: 5))
        XCTAssertFalse(props.keys.contains("$ai_cost_usd"),
                       "an unknown cost must not appear at all — sent as 0 or null it is read as an exact $0.00 and this generation reads as free")
    }

    func testAKnownCostIsSentAndAnAssertedZeroSurvives() throws {
        let known = try XCTUnwrap(Somar.aiGenerationProps(
            model: "claude-sonnet-4-5", inputTokens: 10, outputTokens: 5,
            costUSD: Decimal(string: "0.000105")))
        XCTAssertEqual(known["$ai_cost_usd"] as? NSDecimalNumber,
                       NSDecimalNumber(string: "0.000105"))
        // We must not INVENT a zero; we must not discard one the caller
        // asserted either. A cached or free-tier call really is free.
        let free = try XCTUnwrap(Somar.aiGenerationProps(
            model: "gpt-4.1-nano", inputTokens: 7, outputTokens: 0, costUSD: 0))
        XCTAssertEqual(free["$ai_cost_usd"] as? NSDecimalNumber, NSDecimalNumber(value: 0))
    }

    /// A NaN cost would encode as a non-finite Double and fail JSONEncoder for
    /// the WHOLE event, so one bad cost would drop a generation that was
    /// otherwise perfectly good. It is left out, and the rest is sent.
    func testANaNCostIsDroppedButTheGenerationSurvives() throws {
        let props = try XCTUnwrap(Somar.aiGenerationProps(
            model: "gpt-4.1", inputTokens: 1, outputTokens: 1, costUSD: Decimal.nan))
        XCTAssertFalse(props.keys.contains("$ai_cost_usd"))
        XCTAssertEqual(props["$ai_model"] as? String, "gpt-4.1")
        // And it must be encodable — the reason the guard exists at all.
        XCTAssertNoThrow(try JSONEncoder().encode(JSONValue.wrap(props)))
    }

    func testTheErrorFlagIsSentOnlyWhenTheCallerKnowsIt() throws {
        let failed = try XCTUnwrap(Somar.aiGenerationProps(
            model: "gpt-4.1", inputTokens: 1, outputTokens: 1, isError: true))
        XCTAssertEqual(failed["$ai_is_error"] as? Bool, true)
        let unknown = try XCTUnwrap(Somar.aiGenerationProps(
            model: "gpt-4.1", inputTokens: 1, outputTokens: 1))
        XCTAssertFalse(unknown.keys.contains("$ai_is_error"),
                       "the server reads an absent flag as false; claiming false we were never told is a different fact")
    }

    /// The $ai_* keys are added AFTER sanitisation, so no props key can spoof
    /// the model the whole page is broken down by.
    func testPropsCannotForgeTheModel() throws {
        let props = try XCTUnwrap(Somar.aiGenerationProps(
            model: "gpt-4.1-mini", inputTokens: 1, outputTokens: 1,
            ["$ai_model": "forged", "$ai_cost_usd": 999]))
        XCTAssertEqual(props["$ai_model"] as? String, "gpt-4.1-mini")
        XCTAssertFalse(props.keys.contains("$ai_cost_usd"),
                       "a forged cost would price this generation at $999 and skip server-side pricing")
    }

    /// Refused rather than recorded as free: both of these would reach the
    /// server as a priced $0.00 generation with nothing saying so.
    func testUnpriceableGenerationsAreNotSent() {
        XCTAssertNil(Somar.aiGenerationProps(model: "   ", inputTokens: 1, outputTokens: 1),
                     "a generation with no model can never be priced or broken down")
        XCTAssertNil(Somar.aiGenerationProps(model: "gpt-4.1", inputTokens: -1, outputTokens: 1))
        XCTAssertNil(Somar.aiGenerationProps(model: "gpt-4.1", inputTokens: 1, outputTokens: -1))
    }

    /// A negative latency is not a reason to lose the generation — it is one
    /// field, and it does not feed the cost. Dropped alone, the rest is sent.
    func testANegativeLatencyIsOmittedNotFatal() throws {
        let props = try XCTUnwrap(Somar.aiGenerationProps(
            model: "gpt-4.1", inputTokens: 1, outputTokens: 1, latencyMs: -3))
        XCTAssertFalse(props.keys.contains("$ai_latency_ms"))
        XCTAssertEqual(props["$ai_model"] as? String, "gpt-4.1")
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
