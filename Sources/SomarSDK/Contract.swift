// The enforced event contract (docs/event-contract.md · docs/event-contract.json
// at the monorepo root). Values are vendored because the SDK ships standalone;
// parity with the canonical JSON is asserted by ContractTests, so a drift here
// fails `swift test` inside the monorepo.

import Foundation

enum SomarContract {
    static let maxBatch = 100
    static let maxBodyBytes = 524_288
    static let maxEventBytes = 65_536
    static let maxEventNameLen = 200
    static let maxDistinctIDLen = 200
    static let minDistinctIDLen = 2
    static let maxSessionIDLen = 200
    static let maxStringValueLen = 8_192
    static let maxPropertyDepth = 6
    static let futureTsToleranceHours = 24
    static let quarantineRetentionDays = 30
    static let blockedDistinctIDs = [
        "0", "[object object]", "anonymous", "distinct_id", "distinctid",
        "email", "false", "guest", "id", "nan", "none", "not_authenticated",
        "null", "true", "undefined",
    ]

    // Misuse warns once per offender, then stays silent — never throws.
    private static var warned = Set<String>()
    private static let warnLock = NSLock()
    static func warnOnce(_ key: String, _ message: String) {
        warnLock.lock(); defer { warnLock.unlock() }
        guard !warned.contains(key) else { return }
        warned.insert(key)
        print("[Somar] \(message)")
    }

    // ── Debug ────────────────────────────────────────────────────────────────
    // The SDK swallows every error by design — analytics must never break the
    // host app. Swallowing SILENTLY makes integration problems invisible, so
    // the debug flag is the seam: off (default) nothing is logged; on, every
    // swallowed failure is reported. The ONLY channel for the SDK's own errors.
    nonisolated(unsafe) private static var debugEnabled = false
    static func setDebug(_ on: Bool) { debugEnabled = on }
    static func debugLog(_ message: @autoclosure () -> String) {
        guard debugEnabled else { return }
        print("[Somar] \(message())")
    }

    /// Recursively redact any property whose KEY matches one of `keys`
    /// (case-insensitive). Runs before `beforeSend`, so a hook sees masked data
    /// too — masking is a floor, not something a hook can accidentally undo.
    static func mask(_ value: Any, keys: [String], depth: Int = 0) -> Any {
        guard !keys.isEmpty, depth < maxPropertyDepth else { return value }
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in dict {
                out[k] = keys.contains(where: { $0.caseInsensitiveCompare(k) == .orderedSame })
                    ? "[masked]" : mask(v, keys: keys, depth: depth + 1)
            }
            return out
        }
        if let array = value as? [Any] {
            return array.map { mask($0, keys: keys, depth: depth + 1) }
        }
        return value
    }

    /// The privacy pipeline for one event's properties: mask, then offer to
    /// the hook. Returns nil when the hook vetoes. Pure — it takes the config
    /// rather than reading global state, so it is testable directly and the
    /// ordering guarantee (mask BEFORE hook) is a test, not a comment.
    static func applyPrivacy(name: String, props: [String: Any], masked: [String],
                             beforeSend: ((String, [String: Any]) -> [String: Any]?)?)
        -> [String: Any]? {
        var out = props
        if !masked.isEmpty {
            out = (mask(out, keys: masked) as? [String: Any]) ?? out
        }
        if let beforeSend {
            guard let kept = beforeSend(name, out) else {
                debugLog("beforeSend dropped \"\(name)\"")
                return nil
            }
            out = kept
        }
        return out
    }

    /// Contract §3: strip control chars, collapse whitespace, trim, cap at 200.
    /// Case- and separator-preserving — sdk.events.<name> metrics key on the
    /// exact name, so folding case would re-key customers' metrics.
    static func normaliseEventName(_ name: String) -> String {
        let noControl = name.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
        let collapsed = String(String.UnicodeScalarView(noControl))
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return String(collapsed.prefix(maxEventNameLen))
    }

    /// Contract §4/§5: customer-supplied properties. `$` keys are Somar's
    /// reserved namespace — stripped (with a one-time warning) so a caller can
    /// never forge or override a platform property; strings and nesting are
    /// bounded. Internal SDK code adds its own `$` properties AFTER this runs.
    static func sanitise(_ props: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, value) in props {
            if key.hasPrefix("$") {
                warnOnce("prop:\(key)", "\"\(key)\" is a reserved Somar property and was dropped — the $ namespace is platform-only (see event-contract.md §4).")
                continue
            }
            out[key] = sanitiseValue(value, depth: 1)
        }
        return out
    }

    private static func sanitiseValue(_ value: Any, depth: Int) -> Any {
        if let s = value as? String { return String(s.prefix(maxStringValueLen)) }
        if let dict = value as? [String: Any] {
            // Contract §5: an object or array at max depth is cut, not sent.
            guard depth < maxPropertyDepth else { return "[somar:truncated]" }
            return dict.mapValues { sanitiseValue($0, depth: depth + 1) }
        }
        if let array = value as? [Any] {
            guard depth < maxPropertyDepth else { return "[somar:truncated]" }
            return array.map { sanitiseValue($0, depth: depth + 1) }
        }
        return value
    }
}
