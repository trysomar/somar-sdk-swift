// Internals: configuration, identity/session, JSON plumbing, the offline
// event queue, and feature flags.

import Foundation

struct Config {
    let apiKey: String
    let host: URL
    var flushAt = 20
    var flushInterval: TimeInterval = 10
}

// ── JSON ─────────────────────────────────────────────────────────────────────
// Events carry loosely-typed dictionaries; JSONValue makes them Codable so the
// queue can persist to disk.

enum JSONValue: Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    static func wrap(_ any: [String: Any]) -> [String: JSONValue] {
        any.compactMapValues(wrapValue)
    }

    static func wrapValue(_ value: Any) -> JSONValue? {
        switch value {
        case let s as String: return .string(s)
        case let b as Bool: return .bool(b)
        case let n as NSNumber: return .number(n.doubleValue)
        case let d as [String: Any]: return .object(wrap(d))
        case let a as [Any]: return .array(a.compactMap(wrapValue))
        case is NSNull: return .null
        default: return .string(String(describing: value))
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

struct Event: Codable {
    let eventID: String
    let name: String
    let distinctID: String
    let sessionID: String
    let ts: String
    let props: [String: JSONValue]
    let context: [String: JSONValue]

    enum CodingKeys: String, CodingKey {
        case eventID = "event_id", name, distinctID = "distinct_id"
        case sessionID = "session_id", ts, props, context
    }
}

// ── Identity & session ───────────────────────────────────────────────────────

enum Session {
    static let idleSeconds: TimeInterval = 30 * 60
    private static let defaults = UserDefaults.standard
    private static let lock = NSLock()

    private static let superPropertiesKey = "somar_super_properties"
    private static let optOutKey = "somar_opted_out"
    private static let sessionStartedKey = "somar_session_started_at"
    private static let identifiedAsKey = "somar_identified_as"
    private static var trail: [String] = []

    /// The user this device last identified as — drives the rotate-on-switch
    /// safeguard in Somar.identify().
    static var identifiedAs: String? {
        get { defaults.string(forKey: identifiedAsKey) }
        set {
            if let newValue { defaults.set(newValue, forKey: identifiedAsKey) }
            else { defaults.removeObject(forKey: identifiedAsKey) }
        }
    }

    static var isOptedOut: Bool {
        get { defaults.bool(forKey: optOutKey) }
        set { defaults.set(newValue, forKey: optOutKey) }
    }

    static var superProperties: [String: Any] {
        guard let data = defaults.data(forKey: superPropertiesKey),
              let raw = try? JSONDecoder().decode([String: JSONValue].self, from: data) else { return [:] }
        return raw.reduce(into: [String: Any]()) { out, item in
            if let data = try? JSONEncoder().encode(item.value),
               let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) { out[item.key] = value }
        }
    }

    static func register(_ properties: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        var merged = superProperties
        for (key, value) in properties { merged[key] = value }
        if let data = try? JSONEncoder().encode(JSONValue.wrap(merged)) { defaults.set(data, forKey: superPropertiesKey) }
    }

    static func unregister(_ keys: [String]) {
        lock.lock(); defer { lock.unlock() }
        var merged = superProperties
        for key in keys { merged.removeValue(forKey: key) }
        if let data = try? JSONEncoder().encode(JSONValue.wrap(merged)) { defaults.set(data, forKey: superPropertiesKey) }
    }

    static var breadcrumbs: [String] {
        lock.lock(); defer { lock.unlock() }
        return trail
    }

    /// Lock-free read for the crash handler (see lastKnownSessionID) — a torn
    /// read is survivable there; a deadlock loses the crash report.
    static var breadcrumbsUnsafe: [String] { trail }

    static func addBreadcrumb(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        trail.append(name)
        if trail.count > 20 { trail.removeFirst(trail.count - 20) }
    }

    static var currentSessionDurationMs: Int {
        max(0, Int((Date().timeIntervalSince1970 - defaults.double(forKey: sessionStartedKey)) * 1_000))
    }

    /// Lock-free snapshot for the crash handler — taking `lock` mid-crash
    /// could deadlock if the crashing thread already holds it.
    private(set) static var lastKnownSessionID: String = ""

    static func distinctID() -> String {
        lock.lock(); defer { lock.unlock() }
        if let id = defaults.string(forKey: "somar_distinct_id") { return id }
        let id = UUID().uuidString.lowercased()
        defaults.set(id, forKey: "somar_distinct_id")
        return id
    }

    /// 30 minutes of inactivity rotates the session, matching the server rollup.
    static func sessionID(now: Date = Date()) -> String {
        lock.lock(); defer { lock.unlock() }
        let last = defaults.double(forKey: "somar_session_at")
        let id = defaults.string(forKey: "somar_session_id")
        if let id, now.timeIntervalSince1970 - last < idleSeconds {
            defaults.set(now.timeIntervalSince1970, forKey: "somar_session_at")
            lastKnownSessionID = id
            return id
        }
        let fresh = UUID().uuidString.lowercased()
        defaults.set(fresh, forKey: "somar_session_id")
        defaults.set(now.timeIntervalSince1970, forKey: "somar_session_at")
        defaults.set(now.timeIntervalSince1970, forKey: sessionStartedKey)
        lastKnownSessionID = fresh
        return fresh
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        defaults.removeObject(forKey: "somar_distinct_id")
        defaults.removeObject(forKey: "somar_session_id")
        defaults.removeObject(forKey: "somar_session_at")
        defaults.removeObject(forKey: sessionStartedKey)
        defaults.removeObject(forKey: superPropertiesKey)
        defaults.removeObject(forKey: identifiedAsKey)
        // Deliberately NOT cleared: the opt-out preference (contract §8) —
        // a privacy choice belongs to the device, not the account logging out.
        trail.removeAll()
    }
}

// ── Queue ────────────────────────────────────────────────────────────────────
// File-backed so offline events survive relaunches; flush on size, on a
// timer, and when the app backgrounds.

final class EventQueue {
    private let config: Config
    private var events: [Event] = []
    private var timer: Timer?
    private var sending = false
    private var attempt = 0
    private var retryScheduled = false
    private let workQueue = DispatchQueue(label: "com.somar.sdk.queue")
    private let maxQueued = 500
    private let baseBackoff: TimeInterval = 2
    private let maxBackoff: TimeInterval = 60

    /// What the server's answer means for this batch.
    enum Delivery: Equatable {
        case ok
        case drop                       // 4xx — retrying re-sends identical bytes
        case retry(after: TimeInterval?)
    }

    /// The retry policy, as a pure function so it can be tested without a
    /// network (docs/ingestion.md — the response contract).
    static func delivery(status: Int, failed: Bool, retryAfter: TimeInterval?) -> Delivery {
        if failed { return .retry(after: nil) }              // offline
        if (200...299).contains(status) { return .ok }
        if status == 401 { return .ok }                      // bad key: stop hoarding
        if status == 429 { return .retry(after: retryAfter) }
        if (400...499).contains(status) { return .drop }     // permanent
        return .retry(after: nil)                            // 5xx is ours to fix
    }

    private var storeURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SomarSDK", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("queue.json")
    }

    init(config: Config) {
        self.config = config
        workQueue.async {
            if let data = try? Data(contentsOf: self.storeURL),
               let saved = try? JSONDecoder().decode([Event].self, from: data) {
                self.events = Array(saved.suffix(self.maxQueued))
            }
        }
    }

    func add(_ event: Event) {
        workQueue.async {
            self.events.append(event)
            if self.events.count > self.maxQueued {
                self.events.removeFirst(self.events.count - self.maxQueued)
            }
            self.persistLocked()
            if self.events.count >= self.config.flushAt {
                self.flushLocked()
            } else {
                self.scheduleTimerLocked()
            }
        }
    }

    func flush() {
        workQueue.async { self.flushLocked() }
    }

    func flushOnBackground() {
        workQueue.async { self.flushLocked() }
    }

    // MARK: - On workQueue

    private func persistLocked() {
        if let data = try? JSONEncoder().encode(events) {
            try? data.write(to: storeURL, options: .atomic)
        }
    }

    private func scheduleTimerLocked() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: config.flushInterval, repeats: false) { [weak self] _ in
            self?.workQueue.async { self?.timer = nil; self?.flushLocked() }
        }
        timer = t
        RunLoop.main.add(t, forMode: .common)
    }

    private func flushLocked() {
        guard !sending, !events.isEmpty else { return }
        sending = true
        let batch = Array(events.prefix(100))
        events.removeFirst(batch.count)
        persistLocked()

        var request = URLRequest(url: config.host)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = ["api_key": config.apiKey]
        var body = try? JSONSerialization.data(withJSONObject: payload)
        // Encode {api_key, events} without re-modelling: splice the encoded
        // events array into the envelope.
        if let eventsData = try? JSONEncoder().encode(batch),
           let apiKeyData = try? JSONSerialization.data(withJSONObject: ["api_key": config.apiKey]) {
            var envelope = String(data: apiKeyData, encoding: .utf8) ?? "{}"
            let eventsJSON = String(data: eventsData, encoding: .utf8) ?? "[]"
            envelope.removeLast()   // trailing }
            envelope += ",\"events\":\(eventsJSON)}"
            body = envelope.data(using: .utf8)
        }
        request.httpBody = body

        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            guard let self else { return }
            let http = response as? HTTPURLResponse
            let outcome = Self.delivery(
                status: http?.statusCode ?? 0,
                failed: error != nil,
                retryAfter: (http?.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init))

            self.workQueue.async {
                self.sending = false
                switch outcome {
                case .ok, .drop:
                    self.attempt = 0
                    self.persistLocked()
                    if !self.events.isEmpty { self.flushLocked() }
                case .retry(let after):
                    self.events.insert(contentsOf: batch, at: 0)
                    if self.events.count > self.maxQueued {
                        self.events.removeLast(self.events.count - self.maxQueued)
                    }
                    self.persistLocked()
                    self.scheduleRetryLocked(after: after)
                }
            }
        }.resume()
    }

    /// Exponential backoff with jitter, or exactly what Retry-After asked for.
    /// Without this a failed batch simply waited for the next natural flush —
    /// and without jitter every client that went offline together returns in
    /// the same instant.
    private func scheduleRetryLocked(after: TimeInterval?) {
        guard !retryScheduled else { return }
        let delay: TimeInterval
        if let after {
            attempt = 0
            delay = min(after, maxBackoff)
        } else {
            attempt += 1
            let ceiling = min(baseBackoff * pow(2, Double(attempt - 1)), maxBackoff)
            delay = ceiling / 2 + Double.random(in: 0...(ceiling / 2))
        }
        retryScheduled = true
        workQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.retryScheduled = false
            self.flushLocked()
        }
    }
}

// ── Flags ────────────────────────────────────────────────────────────────────

final class FlagsStore {
    struct Flag: Codable {
        let enabled: Bool
        let payload: JSONValue?
    }

    private let config: Config
    private let exposure: (String, [String: Any]) -> Void
    private var flags: [String: Flag] = [:]
    private var exposuresSent = Set<String>()
    private let lock = NSLock()
    private static let cacheKey = "somar_flags_cache"

    init(config: Config, exposure: @escaping (String, [String: Any]) -> Void) {
        self.config = config
        self.exposure = exposure
        if let data = UserDefaults.standard.data(forKey: Self.cacheKey),
           let cached = try? JSONDecoder().decode([String: Flag].self, from: data) {
            flags = cached
        }
    }

    func refresh() {
        var comps = URLComponents(url: config.host.appendingPathComponent("flags"),
                                  resolvingAgainstBaseURL: false)
        comps?.queryItems = [
            URLQueryItem(name: "api_key", value: config.apiKey),
            URLQueryItem(name: "distinct_id", value: Session.distinctID()),
        ]
        guard let url = comps?.url else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self, let data else { return }
            struct Body: Codable { let flags: [String: Flag]? }
            guard let body = try? JSONDecoder().decode(Body.self, from: data) else { return }
            self.lock.lock()
            self.flags = body.flags ?? [:]
            self.lock.unlock()
            if let encoded = try? JSONEncoder().encode(body.flags ?? [:]) {
                UserDefaults.standard.set(encoded, forKey: Self.cacheKey)
            }
        }.resume()
    }

    func isEnabled(_ key: String) -> Bool {
        lock.lock()
        let flag = flags[key]
        let firstRead = !exposuresSent.contains(key)
        if firstRead { exposuresSent.insert(key) }
        lock.unlock()
        if firstRead, let flag {
            exposure("$feature_flag_called", ["$flag_key": key, "$flag_enabled": flag.enabled])
        }
        return flag?.enabled ?? false
    }

    func payload(_ key: String) -> Any? {
        lock.lock(); defer { lock.unlock() }
        guard let flag = flags[key], flag.enabled, let payload = flag.payload,
              let data = try? JSONEncoder().encode(payload) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        exposuresSent.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.cacheKey)
    }
}
