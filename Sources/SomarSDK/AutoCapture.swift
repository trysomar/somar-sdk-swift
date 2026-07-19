// Automatic behaviour capture: crashes, screen views, StoreKit revenue, and
// network context. Everything here is on by default (see Somar.Options) and
// captures structured fields only — no replay, no screenshots, no content.

import Foundation
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif
#if canImport(StoreKit)
import StoreKit
#endif
#if canImport(Network)
import Network
#endif

// ── Crashes ──────────────────────────────────────────────────────────────────
// An uncaught exception or fatal signal can't be uploaded mid-crash; the
// report is written to disk synchronously and sent as an unhandled $error on
// the NEXT launch, with the breadcrumb trail that led up to it.

enum CrashReporter {

    private static var previousExceptionHandler: (@convention(c) (NSException) -> Void)?
    private static let fatalSignals: [Int32] = [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP]

    static var reportURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SomarSDK", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("pending-crash.json")
    }

    static func install() {
        previousExceptionHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler { exception in
            CrashReporter.write(
                type: exception.name.rawValue,
                message: exception.reason ?? "Uncaught exception",
                stack: exception.callStackSymbols.joined(separator: "\n")
            )
            CrashReporter.previousExceptionHandler?(exception)
        }
        for sig in fatalSignals {
            signal(sig) { number in
                CrashReporter.write(
                    type: "signal",
                    message: "Fatal signal \(number) (\(String(cString: strsignal(number))))",
                    stack: Thread.callStackSymbols.joined(separator: "\n")
                )
                signal(number, SIG_DFL)
                raise(number)
            }
        }
    }

    static func write(type: String, message: String, stack: String) {
        let report: [String: Any] = [
            "type": type,
            "message": message,
            "stack": String(stack.prefix(8_000)),
            "breadcrumbs": Session.breadcrumbsUnsafe,
            "session_id": Session.lastKnownSessionID,
            "at": ISO8601DateFormatter().string(from: Date()),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report) {
            try? data.write(to: reportURL, options: .atomic)
        }
    }

    /// The crash saved by the previous run, if any — caller sends and clears.
    static func drainPendingCrash() -> [String: Any]? {
        guard let data = try? Data(contentsOf: reportURL),
              let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        try? FileManager.default.removeItem(at: reportURL)
        return report
    }
}

// ── Screen views ─────────────────────────────────────────────────────────────
// UIKit apps get every view controller appearance as a $screen automatically;
// SwiftUI apps use .somarScreen(_:) (SwiftUI hosts everything in generic
// controllers, so swizzled names would be noise there).

#if canImport(UIKit) && !os(watchOS)
enum ScreenViewAutoCapture {

    /// System/container controllers whose appearances are plumbing, not screens.
    private static let ignoredPrefixes = [
        "UINavigation", "UITabBar", "UISplitView", "UIPage", "UIInputWindow",
        "UIAlert", "UIActivity", "UIHosting", "UIKeyboard", "UIEditing",
        "UISystem", "UIPredictionViewController", "SwiftUI", "_",
    ]

    static func install() {
        let original = #selector(UIViewController.viewDidAppear(_:))
        let swizzled = #selector(UIViewController.somar_viewDidAppear(_:))
        guard let originalMethod = class_getInstanceMethod(UIViewController.self, original),
              let swizzledMethod = class_getInstanceMethod(UIViewController.self, swizzled) else { return }
        method_exchangeImplementations(originalMethod, swizzledMethod)
    }

    static func screenName(for controller: UIViewController) -> String? {
        let raw = String(describing: type(of: controller))
        guard !ignoredPrefixes.contains(where: { raw.hasPrefix($0) }) else { return nil }
        return raw
            .replacingOccurrences(of: "ViewController", with: "")
            .replacingOccurrences(of: "Controller", with: "")
    }
}

extension UIViewController {
    @objc func somar_viewDidAppear(_ animated: Bool) {
        somar_viewDidAppear(animated)   // swizzled: calls the original
        if let name = ScreenViewAutoCapture.screenName(for: self), !name.isEmpty {
            // enqueue, not the public screen(): SDK-owned $ props would be
            // stripped by the public sanitiser (contract §4).
            Somar.enqueue("$screen", ["$screen_name": name, "$auto_captured": true])
        }
    }
}
#endif

// ── StoreKit revenue ─────────────────────────────────────────────────────────
// Verified transactions become purchase events with $revenue — this is how
// MRR/ARR/refund metrics exist without any payment connector.

enum StoreKitRevenueObserver {
    static func install() {
        #if canImport(StoreKit)
        guard #available(iOS 15.0, macOS 12.0, *) else { return }
        Task.detached(priority: .background) {
            for await result in Transaction.updates {
                guard case .verified(let transaction) = result else { continue }
                var props: [String: Any] = [
                    "$product_id": transaction.productID,
                    "$quantity": transaction.purchasedQuantity,
                    "$store": "app_store",
                    "$auto_captured": true,
                ]
                if let revocationDate = transaction.revocationDate {
                    props["is_refund"] = "true"
                    props["$revoked_at"] = ISO8601DateFormatter().string(from: revocationDate)
                }
                if let price = transaction.price {
                    var currency = "USD"
                    if #available(iOS 16.0, macOS 13.0, *) {
                        currency = transaction.currency?.identifier ?? "USD"
                    }
                    props["currency"] = currency
                    props["$revenue"] = NSDecimalNumber(decimal: price)
                }
                // enqueue, not the public API: SDK-owned $ props ($product_id,
                // $revenue…) would be stripped by the public sanitiser.
                Somar.enqueue("purchase", props)
            }
        }
        #endif
    }
}

// ── Network type ─────────────────────────────────────────────────────────────

final class NetworkMonitor {
    static let shared = NetworkMonitor()
    private(set) var currentType: String?

    private init() {}

    func start() {
        #if canImport(Network)
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            if path.usesInterfaceType(.wifi) { self?.currentType = "wifi" }
            else if path.usesInterfaceType(.cellular) { self?.currentType = "cellular" }
            else if path.usesInterfaceType(.wiredEthernet) { self?.currentType = "ethernet" }
            else { self?.currentType = path.status == .satisfied ? "other" : "offline" }
        }
        monitor.start(queue: DispatchQueue(label: "com.somar.sdk.network"))
        #endif
    }
}

// ── Device model ─────────────────────────────────────────────────────────────

enum DeviceInfo {
    /// The hardware identifier ("iPhone16,2", "Mac15,6") — UIDevice.model only
    /// says "iPhone", which can't segment device performance.
    static let modelIdentifier: String = {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(validatingUTF8: $0) ?? "unknown" }
        }
    }()
}
