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

    /// The Go capture service — ingest lands there, /flags and /surveys pass
    /// through to the edge function. Changed BEFORE launch deliberately: a
    /// host baked into a shipped app must live forever (docs/ingest-cutover.md).
    static let defaultHost = URL(string: "https://capture.trysomar.com")!
    public static let version = "0.4.0"

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
        /// Log everything the SDK swallows. Off by default; the only channel
        /// through which the SDK reports its own failures.
        public var debug = false
        /// Property keys to redact anywhere in props/context, case-insensitive.
        /// Applied before `beforeSend`, so masking cannot be undone by a hook.
        public var mask: [String] = []
        /// Last look at every event before it is queued: return the properties
        /// to send (mutated or not), or nil to drop the event. Runs after
        /// masking. If the hook is nil the event is sent unchanged.
        ///
        /// Swift closures cannot throw here by construction, which is the
        /// point: the JS hook's failure mode (throw ⇒ drop) has no analogue,
        /// so returning nil is the only way to veto.
        public var beforeSend: ((_ event: String, _ properties: [String: Any]) -> [String: Any]?)?

        public init() {}
    }

    private static var queue: EventQueue?
    private static var flagsStore: FlagsStore?
    private static var masked: [String] = []
    private static var beforeSend: ((String, [String: Any]) -> [String: Any]?)?
    private static let stateLock = NSLock()
    private static let sdkLoadedAt = Date()

    /// Call once, as early as app launch. Later calls are no-ops.
    public static func initialize(apiKey: String, host: URL? = nil, options: Options = Options()) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard queue == nil else { return }
        SomarContract.setDebug(options.debug)
        masked = options.mask
        beforeSend = options.beforeSend
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
    /// Identifying a DIFFERENT user on this device first rotates the identity
    /// (as reset() would) — the vendor-invariant that stops two people on one
    /// device being merged into one person. Same user again is a no-op.
    public static func identify(_ userID: String, _ props: [String: Any] = [:]) {
        if let previous = Session.identifiedAs, previous != userID {
            reset()
        }
        Session.identifiedAs = userID
        enqueue("$identify", ["$user_id": userID, "$set": SomarContract.sanitise(props)])
    }

    /// Person profile properties: `props` overwrite ($set), `once` only fill
    /// keys the person does not already have ($set_once).
    public static func setPersonProperties(_ props: [String: Any], once: [String: Any] = [:]) {
        let set = SomarContract.sanitise(props)
        let setOnce = SomarContract.sanitise(once)
        enqueue("$set", ["$set": set, "$set_once": setOnce])
        // ⚠️ THE SANITISED VERSIONS, so the bag sent to `/flags` is the bag the
        // server will hold. Remembering the RAW arguments would let a `$`-prefixed
        // key reach the flag call after `sanitise` had stripped it from the event
        // — and capture strips them again on arrival, so the two would simply
        // disagree about who this person is.
        FlagsStore.rememberPersonProperties(set, once: setOnce)
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

    /// One call to a model — what it cost, how fast it was, whether it failed.
    ///
    /// `sdk_ai_overview`, `sdk_ai_cost` and the six `sdk.ai.*` rollup metrics
    /// have been live over `$ai_generation` events for months with **no way to
    /// send one**: the `$` namespace is platform-only, so a hand-built
    /// `capture("$ai_generation", ["$ai_model": …])` is refused by name and
    /// stripped by property. A reader with no writer reads "—" forever.
    ///
    /// ⚠️ **`costUSD` IS OPTIONAL, AND PASSING NIL IS THE NORMAL CASE.** Leave
    /// it out and `sdk_ai_cost()` prices the generation from the model and the
    /// token counts, against prices that are data and get corrected after the
    /// fact; an unknown model yields **null**, which the AI page reports as
    /// `cost_unknown` rather than folding into a total it cannot back.
    ///
    /// So an unknown cost is **absent from the payload**, never `0` and never
    /// `NSNull`. `sdk_ai_overview` branches on the KEY BEING PRESENT
    /// (`props ? '$ai_cost_usd'`) and `sdk_numeric()` answers **0** for
    /// anything non-numeric, so a null there is read as an exact $0.00 that
    /// counts as PRICED and never reaches `cost_unknown`: every generation free,
    /// the honesty field silent, the customer's AI spend zero. A `0` you *pass*
    /// is kept — a cached or free-tier call really is free, and you said so.
    public static func captureAIGeneration(
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        costUSD: Decimal? = nil,
        latencyMs: Int? = nil,
        provider: String? = nil,
        traceID: String? = nil,
        isError: Bool? = nil,
        _ props: [String: Any] = [:]
    ) {
        guard let payload = aiGenerationProps(
            model: model, inputTokens: inputTokens, outputTokens: outputTokens,
            costUSD: costUSD, latencyMs: latencyMs, provider: provider,
            traceID: traceID, isError: isError, props) else { return }
        enqueue("$ai_generation", payload)
    }

    /// The payload `captureAIGeneration` sends, or nil for a call that must not
    /// be sent. Pure — it takes its inputs rather than reading global state, so
    /// "an omitted cost is ABSENT, never 0" is a test rather than a comment.
    static func aiGenerationProps(
        model: String, inputTokens: Int, outputTokens: Int,
        costUSD: Decimal? = nil, latencyMs: Int? = nil, provider: String? = nil,
        traceID: String? = nil, isError: Bool? = nil, _ props: [String: Any] = [:]
    ) -> [String: Any]? {
        // Every figure on the AI page is keyed by model — the price lookup, the
        // by_model breakdown, and the unpriced_models list that explains a gap.
        // A generation with no model can never be priced and would enter that
        // list as "", turning the one field that says "we could not price
        // these" into a row nobody can act on. Warn once and send nothing, as
        // capture() does for an empty name.
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else {
            SomarContract.warnOnce("ai:model", "captureAIGeneration() needs a model id — nothing was sent. Pass the id your provider named, e.g. model: \"gpt-4.1-mini\".")
            return nil
        }
        // Same reasoning one step along: the token counts ARE the cost when no
        // cost is passed, and sdk_ai_cost() prices 0 tokens on a known model at
        // exactly $0.00 — a confident wrong number rather than a visible gap.
        guard inputTokens >= 0, outputTokens >= 0 else {
            SomarContract.warnOnce("ai:tokens", "captureAIGeneration(model: \"\(trimmedModel)\") was given a negative token count — nothing was sent, because a generation costed from it would read as free.")
            return nil
        }
        // Customer props first, then ours: the $ai_* keys are added AFTER
        // sanitisation so a props key can never spoof one (contract §4).
        var merged = SomarContract.sanitise(props)
        merged["$ai_model"] = trimmedModel
        merged["$ai_input_tokens"] = inputTokens
        merged["$ai_output_tokens"] = outputTokens
        if let latencyMs, latencyMs >= 0 { merged["$ai_latency_ms"] = latencyMs }
        if let provider = provider?.trimmingCharacters(in: .whitespacesAndNewlines),
           !provider.isEmpty { merged["$ai_provider"] = provider }
        if let traceID = traceID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !traceID.isEmpty { merged["$ai_trace_id"] = traceID }
        if let isError { merged["$ai_is_error"] = isError }
        // The one property whose ABSENCE is meaningful — see the note above.
        // A NaN Decimal is excluded for the JS suite's reason inverted: it would
        // encode as a non-finite Double and fail JSONEncoder for the WHOLE
        // event, so one bad cost would drop a generation that was otherwise fine.
        if let costUSD, !costUSD.isNaN {
            merged["$ai_cost_usd"] = NSDecimalNumber(decimal: costUSD)
        }
        return merged
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

    /// The assigned arm of a multivariate flag, e.g. "control" / "test".
    ///
    /// Returns nil for a plain boolean flag and for a key that has not loaded,
    /// so branch with `== "test"` and let nil fall through to your default.
    /// The arm is decided by the server at evaluation time and is stable for a
    /// person forever — reading it here is what reports the exposure that an
    /// experiment's results are computed from.
    public static func featureFlagVariant(_ flagKey: String) -> String? {
        flagsStore?.variant(flagKey)
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

        let raw = Session.superProperties.merging(props) { _, newest in newest }
        var ctx = Self.context()
        if !masked.isEmpty {
            ctx = (SomarContract.mask(ctx, keys: masked) as? [String: Any]) ?? ctx
        }
        // Mask, then offer to the hook — in that order, so a hook can never
        // accidentally re-expose a field the customer asked to be redacted.
        guard let merged = SomarContract.applyPrivacy(
                name: name, props: raw, masked: masked, beforeSend: beforeSend) else { return }

        queue.add(Event(
            eventID: UUID().uuidString.lowercased(),
            name: name,
            distinctID: Session.distinctID(),
            sessionID: Session.sessionID(),
            ts: ISO8601DateFormatter().string(from: Date()),
            props: JSONValue.wrap(merged),
            context: JSONValue.wrap(ctx)
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
