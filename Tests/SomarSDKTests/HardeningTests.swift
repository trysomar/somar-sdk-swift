import XCTest
@testable import SomarSDK

/// The privacy and safety seams (docs/sdk.md): field masking and the
/// beforeSend veto. Parity with the JS SDK's hardening suite.
final class HardeningTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Session.reset()
        Session.isOptedOut = false
    }

    func testMaskingRedactsByKeyCaseInsensitively() {
        let out = SomarContract.mask(
            ["email": "ada@capsha.example", "TOKEN": "sk-live-1", "safe": "keep"],
            keys: ["email", "Token"]) as? [String: Any]
        XCTAssertEqual(out?["email"] as? String, "[masked]")
        XCTAssertEqual(out?["TOKEN"] as? String, "[masked]",
                       "masking must not depend on the case the customer used")
        XCTAssertEqual(out?["safe"] as? String, "keep")
    }

    func testMaskingReachesNestedValues() {
        let out = SomarContract.mask(
            ["user": ["email": "a@b.c", "id": 7], "list": [["email": "d@e.f"]]],
            keys: ["email"]) as? [String: Any]
        let user = out?["user"] as? [String: Any]
        XCTAssertEqual(user?["email"] as? String, "[masked]")
        XCTAssertEqual(user?["id"] as? Int, 7)
        let list = out?["list"] as? [[String: Any]]
        XCTAssertEqual(list?.first?["email"] as? String, "[masked]")
    }

    func testMaskingIsANoOpWithoutKeys() {
        let input: [String: Any] = ["email": "a@b.c"]
        let out = SomarContract.mask(input, keys: []) as? [String: Any]
        XCTAssertEqual(out?["email"] as? String, "a@b.c")
    }

    /// The exact pipeline enqueue() runs: mask, then offer to the hook.
    func testBeforeSendSeesMaskedDataAndCanVeto() {
        var seen: [String: [String: Any]] = [:]
        let hook: (String, [String: Any]) -> [String: Any]? = { name, props in
            seen[name] = props
            return name == "vetoed" ? nil : props
        }

        let kept = SomarContract.applyPrivacy(
            name: "kept", props: ["email": "ada@capsha.example", "plan": "pro"],
            masked: ["email"], beforeSend: hook)
        XCTAssertNotNil(kept, "a hook returning props must keep the event")
        XCTAssertEqual(kept?["email"] as? String, "[masked]",
                       "masking must run before the event reaches the wire")
        XCTAssertEqual(seen["kept"]?["email"] as? String, "[masked]",
                       "the hook must see ALREADY-MASKED data — masking is a floor")
        XCTAssertEqual(kept?["plan"] as? String, "pro")

        XCTAssertNil(SomarContract.applyPrivacy(name: "vetoed", props: [:],
                                                masked: [], beforeSend: hook),
                     "returning nil from beforeSend must drop the event")
    }

    /// With no hook and no mask the pipeline is the identity — the default path
    /// must not quietly alter anyone's properties.
    func testPipelineIsIdentityWhenUnconfigured() {
        let out = SomarContract.applyPrivacy(name: "e", props: ["a": 1, "b": "two"],
                                             masked: [], beforeSend: nil)
        XCTAssertEqual(out?["a"] as? Int, 1)
        XCTAssertEqual(out?["b"] as? String, "two")
    }
}
