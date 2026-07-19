import XCTest
@testable import SomarSDK

/// Identity resolution, device side (docs/identity-resolution.md): repeated
/// identify keeps the device id; identifying a DIFFERENT user rotates it —
/// the shared-device safeguard every vendor converges on.
final class IdentityTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Session.reset()
        Session.isOptedOut = false
    }

    func testRepeatedIdentifyKeepsTheDeviceID() {
        let before = Session.distinctID()
        Somar.identify("user-a")
        XCTAssertEqual(Session.distinctID(), before)
        Somar.identify("user-a")
        XCTAssertEqual(Session.distinctID(), before,
                       "identify() with the same user must be a no-op for identity")
        XCTAssertEqual(Session.identifiedAs, "user-a")
    }

    func testIdentifyingADifferentUserRotatesTheDeviceID() {
        Somar.identify("user-a")
        let asUserA = Session.distinctID()
        Somar.identify("user-b")
        XCTAssertNotEqual(Session.distinctID(), asUserA,
                          "a second user on the same device must NOT inherit the first user's identity")
        XCTAssertEqual(Session.identifiedAs, "user-b")
    }

    func testUserSwitchClearsTheirSuperProperties() {
        Somar.identify("user-a")
        Session.register(["tier": "gold"])
        Somar.identify("user-b")
        XCTAssertNil(Session.superProperties["tier"],
                     "user-a's super properties must not ride user-b's events")
    }

    func testResetForgetsWhoWasIdentified() {
        Somar.identify("user-a")
        Session.reset()
        XCTAssertNil(Session.identifiedAs)
        // After reset, identifying anyone must not rotate again (fresh device).
        let fresh = Session.distinctID()
        Somar.identify("user-c")
        XCTAssertEqual(Session.distinctID(), fresh)
    }
}
