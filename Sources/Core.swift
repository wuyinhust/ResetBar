import Foundation
import CoreFoundation
import CryptoKit

struct QuotaSample: Codable {
    let remainingPercent: Double
    let windowLabel: String
    let fetchedAt: Date
    let measuredAt: Date
    let resetsAt: Date?
    let windowMinutes: Int?
    let bankedAvailable: Int?
    let bankedNextExpiry: Date?
    let accountFingerprint: String?

    init(remainingPercent: Double, windowLabel: String, fetchedAt: Date, measuredAt: Date,
         resetsAt: Date? = nil, windowMinutes: Int? = nil, bankedAvailable: Int? = nil,
         bankedNextExpiry: Date? = nil, accountFingerprint: String? = nil) {
        self.remainingPercent = remainingPercent
        self.windowLabel = windowLabel
        self.fetchedAt = fetchedAt
        self.measuredAt = measuredAt
        self.resetsAt = resetsAt
        self.windowMinutes = windowMinutes
        self.bankedAvailable = bankedAvailable
        self.bankedNextExpiry = bankedNextExpiry
        self.accountFingerprint = accountFingerprint
    }
}

struct PersonalReset: Codable {
    let at: Date
    // R: direct restoration, B: bank redemption, ↻: type not established.
    let kind: String
    // observed is the first provider sample showing restoration (poll precision).
    // Forecast window boundaries never establish a personal restoration event.
    let confidence: String
}

enum ResetKind: String, Codable {
    case regular = "R"
    case banked = "B"
}

struct ResetEvent: Codable {
    let id: String
    let kind: ResetKind
    let at: Date
    let summary: String
    let url: String?
}

struct SiteAlert: Codable {
    let key: String
    let kind: String
    let summary: String
    let url: String?
    let at: Date
    let active: Bool
}

struct SiteSnapshot: Codable {
    let event: ResetEvent?
    let alert: SiteAlert?
    let fetchedAt: Date
    let sourceUpdatedAt: Date
}

enum ResetBarCore {
    enum ParseError: Error, LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case let .invalid(message) = self { return message }
            return nil
        }
    }

    // A successful HTTP response must still carry recent provider measurements.
    static let maximumDataAge: TimeInterval = 15 * 60
    static let maximumSiteClockSkew: TimeInterval = 5 * 60
    static let alertLifetime: TimeInterval = 48 * 60 * 60

    static func parseQuota(_ data: Data, now: Date) throws -> QuotaSample {
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let row = rows.first(where: { string($0["provider"])?.lowercased() == "codex" }),
              row["error"] == nil || row["error"] is NSNull,
              let usage = row["usage"] as? [String: Any],
              usage["error"] == nil || usage["error"] is NSNull else {
            throw ParseError.invalid("未取得 Codex 的实际额度数据")
        }
        guard let measuredAt = date(usage["updatedAt"]),
              measuredAt <= now,
              now.timeIntervalSince(measuredAt) <= maximumDataAge else {
            throw ParseError.invalid("Codex 额度的测量时间无效或已过期")
        }
        let names = ["primary", "secondary", "tertiary"]
        let windows = names.compactMap { name -> (String, [String: Any])? in
            guard let window = usage[name] as? [String: Any] else { return nil }
            return (name, window)
        }
        // CodexBar may return a null session window and a valid weekly window.
        let selected = windows.first(where: { number($0.1["windowMinutes"]) == 10080 }) ?? windows.first
        guard let (name, window) = selected,
              let used = number(window["usedPercent"]), used.isFinite,
              (0...100).contains(used) else {
            throw ParseError.invalid("Codex 额度百分比无效")
        }
        let minutes = number(window["windowMinutes"])
        if let minutes, (!minutes.isFinite || minutes <= 0 || minutes > 5_256_000 || minutes.rounded() != minutes) {
            throw ParseError.invalid("Codex 额度窗口无效")
        }
        let label: String
        if minutes == 10080 { label = "每周" }
        else if let explicit = string(window["label"]), !explicit.isEmpty { label = explicit }
        else if let minutes, minutes.truncatingRemainder(dividingBy: 60) == 0 {
            label = "\(Int(minutes / 60)) 小时"
        } else if let minutes { label = "\(Int(minutes)) 分钟" }
        else { label = name == "primary" ? "会话" : (name == "secondary" ? "次级窗口" : "第三窗口") }
        let outerCredits = row["resetCredits"] as? [String: Any]
        let credits = outerCredits ?? (usage["codexResetCredits"] as? [String: Any])
            ?? (usage["resetCredits"] as? [String: Any])
        let available = number(credits?["available"]) ?? number(credits?["availableCount"])
        let banked = available.flatMap { count -> Int? in
            guard count.isFinite, count >= 0, count <= Double(Int32.max), count.rounded() == count else { return nil }
            return Int(count)
        }
        return QuotaSample(remainingPercent: 100 - used, windowLabel: label,
                           fetchedAt: now, measuredAt: measuredAt,
                           resetsAt: date(window["resetsAt"]), windowMinutes: minutes.map { Int($0) },
                           bankedAvailable: banked, bankedNextExpiry: date(outerCredits?["nextExpiresAt"]),
                           accountFingerprint: fingerprint(usage))
    }

    static func observePersonalReset(previous: QuotaSample?, current: QuotaSample,
                                     existing: PersonalReset?) -> PersonalReset? {
        if let previous,
           previous.accountFingerprint != current.accountFingerprint
            || previous.windowLabel != current.windowLabel
            || previous.windowMinutes != current.windowMinutes {
            // A personal timestamp belongs to one account and one quota window.
            return nil
        }
        let retained = existing.flatMap { $0.at <= current.fetchedAt && $0.confidence != "estimated" ? $0 : nil }
        guard current.remainingPercent.isFinite, (0...100).contains(current.remainingPercent),
              current.measuredAt <= current.fetchedAt,
              current.fetchedAt.timeIntervalSince(current.measuredAt) <= maximumDataAge else { return retained }
        guard let previous else { return retained }
        guard let account = current.accountFingerprint, !account.isEmpty,
              previous.accountFingerprint == account,
              previous.windowLabel == current.windowLabel,
              previous.windowMinutes == current.windowMinutes,
              previous.remainingPercent.isFinite, (0...100).contains(previous.remainingPercent),
              previous.measuredAt <= previous.fetchedAt,
              previous.fetchedAt.timeIntervalSince(previous.measuredAt) <= maximumDataAge,
              current.fetchedAt >= previous.fetchedAt,
              current.measuredAt > previous.measuredAt,
              current.measuredAt.timeIntervalSince(previous.measuredAt) <= maximumDataAge else { return retained }
        let increase = current.remainingPercent - previous.remainingPercent
        let bankDropped = previous.bankedAvailable.flatMap { before in
            current.bankedAvailable.map { $0 >= 0 && before >= 0 && $0 < before }
        } ?? false
        // Inventory can fall because a stored reset expired. A future expiry in
        // the previous sample rules that out within this observation interval.
        let bankConsumed = bankDropped && previous.bankedNextExpiry.map { $0 > current.measuredAt } == true
        let windowAdvanced = previous.resetsAt.flatMap { before in
            current.resetsAt.map { $0.timeIntervalSince(before) > 60 }
        } ?? false
        // Small provider corrections are not reset evidence. A bank decrement is
        // stronger evidence; otherwise require a material restoration plus a near
        // full window or a changed provider window boundary.
        guard (bankConsumed && increase >= 0.5)
            || (increase >= 5 && (current.remainingPercent >= 95 || windowAdvanced)) else { return retained }
        let kind: String
        if bankConsumed { kind = "B" }
        else if !bankDropped && previous.bankedAvailable != nil && current.bankedAvailable != nil { kind = "R" }
        else { kind = "↻" }
        if let retained, retained.at >= current.measuredAt { return retained }
        return PersonalReset(at: current.measuredAt, kind: kind, confidence: "observed")
    }

    static func parseSite(forecast: Data, timeline: Data, now: Date) throws -> SiteSnapshot {
        guard let forecast = try JSONSerialization.jsonObject(with: forecast) as? [String: Any],
              let timeline = try JSONSerialization.jsonObject(with: timeline) as? [String: Any],
              let forecastUpdated = date(forecast["updated_at"]),
              let timelineUpdated = date(timeline["updated_at"]),
              let events = timeline["events"] as? [[String: Any]] else {
            throw ParseError.invalid("重置网站返回的数据格式无效")
        }
        for updated in [forecastUpdated, timelineUpdated] {
            guard now.timeIntervalSince(updated) <= maximumDataAge,
                  updated.timeIntervalSince(now) <= maximumSiteClockSkew else {
                throw ParseError.invalid("重置网站的数据已过期或时间无效")
            }
        }

        let resetEvents = events.compactMap { item -> ResetEvent? in
            guard let id = string(item["id"]), !id.isEmpty,
                  bool(item["preview"]) != true,
                  let at = eventDate(item), at <= now else { return nil }
            let group = string(item["group"])?.lowercased()
            let type = string(item["type"])?.lowercased()
            let kind: ResetKind
            let summary: String
            if group == "credits", bool(item["banked_grant"]) == true {
                kind = .banked
                summary = "网站记录：银行重置额度已发放"
            } else if (group == "reset" || type == "reset"), bool(item["confirmed"]) == true {
                kind = .regular
                let observed = string(item["source"])?.contains("operator") == true
                summary = observed ? "网站已观测到直接重置，待官方确认" : "网站记录：直接重置已确认"
            } else { return nil }
            return ResetEvent(id: id, kind: kind, at: at, summary: summary, url: safeURL(item["url"]))
        }
        var event = resetEvents.max(by: { $0.at < $1.at })
        let canonical = forecast["latest_alert"] as? [String: Any]

        // last_reset_at alone is not evidence of a completed reset. Require the
        // site's confirmed alert to corroborate the timestamp when filling a gap.
        if !resetEvents.contains(where: { $0.kind == .regular }),
           let canonical, string(canonical["kind"]) == "reset", string(canonical["state"]) == "confirmed",
           let last = date(forecast["last_reset_at"]), last <= now,
           let source = date(canonical["source_at"]), abs(source.timeIntervalSince(last)) <= 60,
           let id = string(canonical["id"]) {
            let fallback = ResetEvent(id: id, kind: .regular, at: last,
                                      summary: string(canonical["summary"]) ?? "网站记录：直接重置已确认",
                                      url: safeURL(canonical["url"]))
            if event == nil || fallback.at > event!.at { event = fallback }
        }

        var alert: SiteAlert?
        if let canonical,
           let id = string(canonical["id"]), !id.isEmpty,
           let kind = string(canonical["kind"]),
           let state = string(canonical["state"]),
           let at = date(canonical["source_at"]), at <= now {
            let accepted: Bool
            if kind == "watch", state == "active" {
                let window = canonical["window"] as? [String: Any]
                if let rawEnd = window?["end_at"], !(rawEnd is NSNull) {
                    // A malformed expiry is not an unbounded active alert.
                    accepted = date(rawEnd).map { $0 > now } ?? false
                } else { accepted = true }
            } else {
                accepted = kind == "reset" && state == "confirmed" && now.timeIntervalSince(at) <= alertLifetime
            }
            if accepted {
                let pendingState = string(canonical["pending"]).flatMap { $0.isEmpty ? nil : $0 }
                    ?? (bool(canonical["pending"]) == true ? "pending" : nil)
                let pending = kind == "watch" ? pendingState.map { ":\($0)" } ?? "" : ""
                alert = SiteAlert(key: "\(kind):\(id):\(state)\(pending)", kind: kind,
                                  summary: string(canonical["summary"]) ?? (kind == "watch" ? "网站发布重置预告" : "网站记录重置已确认"),
                                  url: safeURL(canonical["url"]), at: at, active: true)
            }
        }
        let canonicalAt = canonical.flatMap { date($0["source_at"]) }
        if let banked = resetEvents.filter({ $0.kind == .banked }).max(by: { $0.at < $1.at }),
           now.timeIntervalSince(banked.at) <= alertLifetime,
           canonicalAt == nil || banked.at > canonicalAt! {
            alert = SiteAlert(key: "banked:\(banked.id):confirmed", kind: "banked", summary: banked.summary,
                              url: banked.url, at: banked.at, active: true)
        }
        return SiteSnapshot(event: event, alert: alert, fetchedAt: now,
                            sourceUpdatedAt: min(forecastUpdated, timelineUpdated))
    }

    static func elapsed(since: Date, now: Date) -> String {
        let totalMinutes = max(0, Int(now.timeIntervalSince(since) / 60))
        let hours = totalMinutes / 60
        if hours >= 24 { return "\(hours / 24)d\(String(format: "%02d", hours % 24))h" }
        return "\(hours)h\(String(format: "%02d", totalMinutes % 60))m"
    }

    private static func eventDate(_ item: [String: Any]) -> Date? {
        for field in ["effective_at", "observed_at", "announced_at"] {
            if let raw = item[field], !(raw is NSNull) {
                // Do not reinterpret a future or malformed effective date as an
                // already completed event by falling back to its announcement.
                return date(raw)
            }
        }
        return nil
    }

    private static func string(_ value: Any?) -> String? { value as? String }
    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        return value.doubleValue
    }
    private static func bool(_ value: Any?) -> Bool? {
        guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return value.boolValue
    }
    private static func date(_ value: Any?) -> Date? {
        guard let value = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let result = formatter.date(from: value) { return result }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
    private static func safeURL(_ value: Any?) -> String? {
        guard let value = string(value), let url = URL(string: value),
              let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme), url.host != nil else { return nil }
        return value
    }
    private static func fingerprint(_ usage: [String: Any]) -> String? {
        let identity = usage["identity"] as? [String: Any]
        let accountID = string(identity?["accountID"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = (string(identity?["accountEmail"]) ?? string(usage["accountEmail"]))?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let identityValue: String
        if let accountID, !accountID.isEmpty { identityValue = "account:\(accountID)" }
        else if let email, !email.isEmpty { identityValue = "email:\(email)" }
        else { return nil }
        let loginMethod = (string(identity?["loginMethod"]) ?? string(usage["loginMethod"]))?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let plan = (string(identity?["plan"]) ?? string(usage["plan"]) ?? string(identity?["planType"]) ?? string(usage["planType"]))?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        // Scope changes can themselves change the limits; do not interpret that
        // as a reset of the previously observed subscription's quota.
        let scope = ["account": identityValue, "loginMethod": loginMethod, "plan": plan]
        guard let encoded = try? JSONSerialization.data(withJSONObject: scope, options: [.sortedKeys]) else { return nil }
        return SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
    }
}
