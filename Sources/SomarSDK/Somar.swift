// Somar SDK for Apple platforms.
//
//   import SomarSDK
//   Somar.initialize(apiKey: "somar_pk_…")
//   Somar.capture("signup_completed", ["plan": "pro"])
//
// Events flow to your Somar workspace, where they become live analytics pages,
// AI insights, and automations. The API key is a public, ingestion-scoped
// project key — it cannot read your workspace.

import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(SwiftUI)
import SwiftUI
#endif

public enum Somar {

    static let defaultHost = URL(string: "https://dkdrkjndprldmthdkxxk.supabase.co/functions/v1/sdk-ingest")!
    public static let version = "0.3.0"

    /// Everything below is on by default; turn pieces off at initialize time.
    public struct Options {
        /// Report uncaught exceptions and fatal signals as unhandled $error
        /// events (sent on the next launch, with breadcrumbs).
        public var captureCrashes = true
        /// UIKit apps: every view controller appearance becomes a $screen.
        /// SwiftUI apps should use the .somarScreen(_:) modifier instead.
        public var autoScreenViews = true
        /// Verified StoreKit transactions become purchase events with $revenue.
        public var captureStoreKitRevenue = true

        public init() {}
    }

    private static var queue: EventQueue?
    private static var flagsStore: FlagsStore?
    private static let stateLock = NSLock()
    private static let sdkLoadedAt = Date()

    /// Call once, as early as app launch. Later calls are no-ops.
    public static func initialize(apiKey: String, host: URL? = nil, options: Options = Options()) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard queue == nil else { return }
        let config = Config(apiKey: apiKey, host: host ?? defaultHost)
        let newQueue = EventQueue(config: config)
        queue = newQueue
        flagsStore = FlagsStore(config: config) { name, props in
            enqueue(name, props)
        }
        flagsStore?.refresh()
        NetworkMonitor.shared.start()
        // A crash saved by the previous run is this launch's first event —
        // unhandled, fingerprinted by its type, with the trail that led there.
        if options.captureCrashes {
            if let crash = CrashReporter.drainPendingCrash() {
                enqueue("$error", [
                    "$message": crash["message"] ?? "Crash",
                    "$stack": crash["stack"] ?? "",
                    "$fingerprint": "crash:\(crash["type"] ?? "unknown")",
                    "$breadcrumbs": crash["breadcrumbs"] ?? [],
                    "$handled": false,
                    "$crash": true,
                    "$crashed_session_id": crash["session_id"] ?? "",
                    "$crashed_at": crash["at"] ?? "",
                ])
            }
            CrashReporter.install()
        }
        if options.captureStoreKitRevenue { StoreKitRevenueObserver.install() }
        enqueue("$session_start", [:])
        #if canImport(UIKit) && !os(watchOS)
        if options.autoScreenViews { ScreenViewAutoCapture.install() }
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { _ in
            enqueue("$session_end", ["$duration_ms": Session.currentSessionDurationMs])
            newQueue.flushOnBackground()
        }
        // Cold-start time (§10 app performance): SDK load → first active.
        var didBecomeActiveOnce = false
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            guard !didBecomeActiveOnce else { return }
            didBecomeActiveOnce = true
            enqueue("$app_start", [
                "$cold_start_ms": Int(Date().timeIntervalSince(sdkLoadedAt) * 1_000),
            ])
        }
        #endif
    }

    /// Name the current person. Anonymous history stitches to this id server-side.
    public static func identify(_ userID: String, _ props: [String: Any] = [:]) {
        enqueue("$identify", ["$user_id": userID, "$set": SomarContract.sanitise(props)])
    }

    /// Record something the person did.
    public static func capture(_ name: String, _ props: [String: Any] = [:]) {
        // Contract §3/§4: the $ namespace is platform-only, and a name must
        // survive normalisation. Both misuses drop the event with a one-time
        // warning — they can never silently become a platform event.
        if name.hasPrefix("$") {
            SomarContract.warnOnce("event:\(name)", "\"\(name)\" was not sent — $-prefixed event names are reserved for Somar (see event-contract.md §3).")
            return
        }
        let normalised = SomarContract.normaliseEventName(name)
        if normalised.isEmpty {
            SomarContract.warnOnce("event:empty", "capture() was called with an empty event name — nothing was sent.")
            return
        }
        enqueue(normalised, SomarContract.sanitise(props))
    }

    /// Adds persistent properties to all future events, such as product tier or
    /// an experiment cohort. Use only non-sensitive values.
    public static func register(_ props: [String: Any]) {
        Session.register(SomarContract.sanitise(props))
    }

    public static func unregister(_ keys: [String]) {
        Session.unregister(keys)
    }

    /// Records revenue as product behaviour. This is what powers revenue,
    /// MRR and retention metrics; it is not tied to a Stripe connector.
    public static func captureRevenue(_ amount: Decimal, _ props: [String: Any] = [:]) {
        // $revenue is added AFTER sanitisation so a props key can never spoof
        // it; currency/plan are grandfathered unprefixed keys (contract §4).
        var merged = SomarContract.sanitise(props)
        merged["$revenue"] = NSDecimalNumber(decimal: amount)
        if merged["currency"] == nil { merged["currency"] = "USD" }
        enqueue("purchase", merged)
    }

    /// Stops all capture on this device until optIn() is called. The preference
    /// persists across relaunches and is sent as consent metadata when enabled.
    public static func optOut() { Session.isOptedOut = true }
    public static func optIn() {
        Session.isOptedOut = false
        enqueue("$consent", ["$opt_out": false])
    }
    public static func setConsent(_ consent: [String: Any]) {
        Session.register(["$consent": consent, "$opt_out": false])
        if !Session.isOptedOut { enqueue("$consent", consent) }
    }

    /// A screen view — the app equivalent of a web page view.
    public static func screen(_ name: String, _ props: [String: Any] = [:]) {
        var merged = SomarContract.sanitise(props)
        merged["$screen_name"] = name
        enqueue("$screen", merged)
    }

    /// Attach the person to a company/team/organisation. Subsequent events
    /// carry the membership as a $groups super property, powering account
    /// analytics.
    public static func group(_ type: String, _ key: String, _ props: [String: Any] = [:]) {
        enqueue("$group", ["$group_type": type, "$group_key": key, "$set": SomarContract.sanitise(props)])
        var groups = (Session.superProperties["$groups"] as? [String: Any]) ?? [:]
        groups[type] = key
        Session.register(["$groups": groups])
    }

    /// Record an API call's outcome — powers API-latency and network-error
    /// metrics. Call from your networking layer; pass the path, not the query.
    public static func captureRequest(endpoint: String, method: String, statusCode: Int,
                                      durationMs: Int, failed: Bool = false) {
        enqueue("$api_request", [
            "$endpoint": endpoint, "$method": method.uppercased(), "$status": statusCode,
            "$duration_ms": durationMs, "$is_error": failed || statusCode >= 400,
        ])
    }

    /// Record an error.
    public static func captureError(_ error: Error, _ props: [String: Any] = [:]) {
        let ns = error as NSError
        var merged = SomarContract.sanitise(props)
        merged["$message"] = ns.localizedDescription
        merged["$fingerprint"] = "\(ns.domain):\(ns.code)"
        merged["$stack"] = Thread.callStackSymbols.joined(separator: "\n").prefix(8_000).description
        merged["$breadcrumbs"] = Session.breadcrumbs
        enqueue("$error", merged)
    }

    /// The evaluated flag. False before flags load / for unknown keys.
    public static func isEnabled(_ flagKey: String) -> Bool {
        flagsStore?.isEnabled(flagKey) ?? false
    }

    /// The flag's payload, when the flag is on and carries one.
    public static func flagPayload(_ flagKey: String) -> Any? {
        flagsStore?.payload(flagKey)
    }

    /// Push queued events to the server now.
    public static func flush() {
        queue?.flush()
    }

    /// Forget this device's identity — call on logout. Contract §8: rotates
    /// distinct_id and session, clears super properties and flags; the opt-out
    /// preference and queued events survive (privacy choices belong to the
    /// device, queued events to the person who generated them).
    public static func reset() {
        Session.reset()
        flagsStore?.reset()
    }

    // MARK: - Internals

    static func enqueue(_ name: String, _ props: [String: Any]) {
        guard let queue, !Session.isOptedOut else { return }
        Session.addBreadcrumb(name)
        queue.add(Event(
            eventID: UUID().uuidString.lowercased(),
            name: name,
            distinctID: Session.distinctID(),
            sessionID: Session.sessionID(),
            ts: ISO8601DateFormatter().string(from: Date()),
            props: JSONValue.wrap(Session.superProperties.merging(props) { _, newest in newest }),
            context: JSONValue.wrap(Self.context())
        ))
    }

    static func context() -> [String: Any] {
        var ctx: [String: Any] = [
            "$lib": "somar-swift", "$lib_version": version,
            "$locale": Locale.current.identifier, "$language": Locale.current.languageCode ?? "",
            "$timezone": TimeZone.current.identifier,
            "$device_model_identifier": DeviceInfo.modelIdentifier,
        ]
        if let network = NetworkMonitor.shared.currentType { ctx["$network"] = network }
        #if canImport(UIKit) && !os(watchOS)
        ctx["$os"] = UIDevice.current.systemName
        ctx["$os_version"] = UIDevice.current.systemVersion
        ctx["$device_model"] = UIDevice.current.model
        ctx["$device_name"] = UIDevice.current.name
        ctx["$device_type"] = UIDevice.current.userInterfaceIdiom == .pad ? "tablet"
            : UIDevice.current.userInterfaceIdiom == .phone ? "mobile" : "desktop"
        ctx["$screen_width"] = UIScreen.main.bounds.width
        ctx["$screen_height"] = UIScreen.main.bounds.height
        ctx["$viewport_width"] = UIScreen.main.bounds.width
        ctx["$viewport_height"] = UIScreen.main.bounds.height
        ctx["$orientation"] = UIScreen.main.bounds.width >= UIScreen.main.bounds.height
            ? "landscape" : "portrait"
        if Thread.isMainThread {
            ctx["$dark_mode"] = UITraitCollection.current.userInterfaceStyle == .dark
        }
        #elseif os(macOS)
        ctx["$os"] = "macOS"
        ctx["$os_version"] = ProcessInfo.processInfo.operatingSystemVersionString
        ctx["$device_type"] = "desktop"
        #endif
        if let info = Bundle.main.infoDictionary {
            ctx["$app_version"] = info["CFBundleShortVersionString"] as? String
            ctx["$app_build"] = info["CFBundleVersion"] as? String
        }
        return ctx
    }
}

#if canImport(SwiftUI)
public extension View {
    /// Emits a structured screen view when the SwiftUI view appears. This is
    /// intentionally opt-in: names remain meaningful product vocabulary.
    func somarScreen(_ name: String, properties: [String: Any] = [:]) -> some View {
        onAppear { Somar.screen(name, properties) }
    }
}
#endif
