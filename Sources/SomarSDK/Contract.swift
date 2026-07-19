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
