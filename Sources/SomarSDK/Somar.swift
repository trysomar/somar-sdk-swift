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

public enum Somar {

    static let defaultHost = URL(string: "https://dkdrkjndprldmthdkxxk.supabase.co/functions/v1/sdk-ingest")!

    private static var queue: EventQueue?
    private static var flagsStore: FlagsStore?
    private static let stateLock = NSLock()

    /// Call once, as early as app launch. Later calls are no-ops.
    public static func initialize(apiKey: String, host: URL? = nil) {
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
        #if canImport(UIKit) && !os(watchOS)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { _ in newQueue.flushOnBackground() }
        #endif
    }

    /// Name the current person. Anonymous history stitches to this id server-side.
    public static func identify(_ userID: String, _ props: [String: Any] = [:]) {
        enqueue("$identify", ["$user_id": userID, "$set": props])
    }

    /// Record something the person did.
    public static func capture(_ name: String, _ props: [String: Any] = [:]) {
        enqueue(name, props)
    }

    /// A screen view — the app equivalent of a web page view.
    public static func screen(_ name: String, _ props: [String: Any] = [:]) {
        var merged = props
        merged["$screen_name"] = name
        enqueue("$screen", merged)
    }

    /// Attach the person to a company/team/organisation.
    public static func group(_ type: String, _ key: String, _ props: [String: Any] = [:]) {
        enqueue("$group", ["$group_type": type, "$group_key": key, "$set": props])
    }

    /// Record an error.
    public static func captureError(_ error: Error, _ props: [String: Any] = [:]) {
        let ns = error as NSError
        var merged = props
        merged["$message"] = ns.localizedDescription
        merged["$fingerprint"] = "\(ns.domain):\(ns.code)"
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

    /// Forget this device's identity — call on logout.
    public static func reset() {
        Session.reset()
        flagsStore?.reset()
    }

    // MARK: - Internals

    static func enqueue(_ name: String, _ props: [String: Any]) {
        guard let queue else { return }
        queue.add(Event(
            eventID: UUID().uuidString.lowercased(),
            name: name,
            distinctID: Session.distinctID(),
            sessionID: Session.sessionID(),
            ts: ISO8601DateFormatter().string(from: Date()),
            props: JSONValue.wrap(props),
            context: JSONValue.wrap(Self.context())
        ))
    }

    static func context() -> [String: Any] {
        var ctx: [String: Any] = ["$lib": "somar-swift"]
        #if canImport(UIKit) && !os(watchOS)
        ctx["$os"] = UIDevice.current.systemName
        ctx["$os_version"] = UIDevice.current.systemVersion
        ctx["$device_model"] = UIDevice.current.model
        #elseif os(macOS)
        ctx["$os"] = "macOS"
        #endif
        if let info = Bundle.main.infoDictionary {
            ctx["$app_version"] = info["CFBundleShortVersionString"] as? String
            ctx["$app_build"] = info["CFBundleVersion"] as? String
        }
        return ctx
    }
}
