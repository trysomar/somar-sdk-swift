import XCTest
@testable import SomarSDK

final class SomarSDKTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Session.reset()
    }

    func testDistinctIDIsStable() {
        let first = Session.distinctID()
        XCTAssertEqual(first, Session.distinctID())
        XCTAssertFalse(first.isEmpty)
    }

    func testSessionRotatesAfterIdle() {
        let now = Date()
        let first = Session.sessionID(now: now)
        // Within the idle window the session holds…
        XCTAssertEqual(first, Session.sessionID(now: now.addingTimeInterval(10 * 60)))
        // …but half an hour of silence rotates it.
        XCTAssertNotEqual(first, Session.sessionID(now: now.addingTimeInterval(41 * 60)))
    }

    func testResetForgetsIdentity() {
        let before = Session.distinctID()
        Session.reset()
        XCTAssertNotEqual(before, Session.distinctID())
    }

    func testEventEncodingUsesWireKeys() throws {
        let event = Event(
            eventID: "e-1", name: "signup_completed", distinctID: "d-1",
            sessionID: "s-1", ts: "2026-07-18T09:00:00Z",
            props: JSONValue.wrap(["plan": "pro", "seats": 3]),
            context: JSONValue.wrap(["$lib": "somar-swift"]))
        let data = try JSONEncoder().encode(event)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["event_id"] as? String, "e-1")
        XCTAssertEqual(object["distinct_id"] as? String, "d-1")
        XCTAssertEqual(object["session_id"] as? String, "s-1")
        let props = try XCTUnwrap(object["props"] as? [String: Any])
        XCTAssertEqual(props["plan"] as? String, "pro")
        XCTAssertEqual(props["seats"] as? Double, 3)
    }

    func testJSONValueRoundTripsNestedStructures() throws {
        let wrapped = JSONValue.wrap([
            "$set": ["name": "Ada", "tags": ["a", "b"], "active": true],
            "empty": NSNull(),
        ])
        let data = try JSONEncoder().encode(wrapped)
        let decoded = try JSONDecoder().decode([String: JSONValue].self, from: data)
        guard case .object(let set)? = decoded["$set"],
              case .string(let name)? = set["name"],
              case .array(let tags)? = set["tags"] else {
            return XCTFail("structure lost in round trip")
        }
        XCTAssertEqual(name, "Ada")
        XCTAssertEqual(tags.count, 2)
    }
}
