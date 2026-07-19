import XCTest
@testable import SomarSDK

/// The retry policy (docs/ingestion.md §response contract). Before this the
/// Swift SDK had no backoff at all and treated every non-401 failure the
/// same — a 400 was retried forever, blocking every later event behind it.
final class DeliveryTests: XCTestCase {

    func testSuccessIsDelivered() {
        XCTAssertEqual(EventQueue.delivery(status: 200, failed: false, retryAfter: nil), .ok)
        XCTAssertEqual(EventQueue.delivery(status: 204, failed: false, retryAfter: nil), .ok)
    }

    func testBadKeyStopsHoarding() {
        // 401 counts as "delivered": the queue is cleared rather than grown
        // forever behind a credential that will never work.
        XCTAssertEqual(EventQueue.delivery(status: 401, failed: false, retryAfter: nil), .ok)
    }

    func testPermanentClientErrorsAreDropped() {
        for status in [400, 403, 404, 413, 422] {
            XCTAssertEqual(EventQueue.delivery(status: status, failed: false, retryAfter: nil), .drop,
                           "\(status) must not be retried — the bytes can never become acceptable")
        }
    }

    func testRateLimitObeysRetryAfter() {
        XCTAssertEqual(EventQueue.delivery(status: 429, failed: false, retryAfter: 12), .retry(after: 12))
        XCTAssertEqual(EventQueue.delivery(status: 429, failed: false, retryAfter: nil), .retry(after: nil))
    }

    func testServerErrorsAndOfflineAreRetried() {
        XCTAssertEqual(EventQueue.delivery(status: 500, failed: false, retryAfter: nil), .retry(after: nil))
        XCTAssertEqual(EventQueue.delivery(status: 503, failed: false, retryAfter: nil), .retry(after: nil))
        // Transport failure: no status at all.
        XCTAssertEqual(EventQueue.delivery(status: 0, failed: true, retryAfter: nil), .retry(after: nil))
    }
}
