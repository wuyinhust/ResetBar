import Foundation

@main
enum CoreTests {
    static var checks = 0
    static let now = ISO8601DateFormatter().date(from: "2026-10-24T15:00:00Z")!
    static func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    static func iso(_ offset: TimeInterval = 0) -> String { ISO8601DateFormatter().string(from: now.addingTimeInterval(offset)) }
    static func expect(_ condition: Bool, _ label: String) {
        checks += 1
        guard condition else { fatalError("FAILED: \(label)") }
    }
    static func rejects(_ label: String, _ operation: () throws -> Any) {
        checks += 1
        do { _ = try operation(); fatalError("FAILED: \(label) unexpectedly accepted") } catch {}
    }
    static func quota(_ used: Any = 39, updated: String? = nil, weekly: Bool = true) throws -> Data {
        try json([["provider": "codex", "usage": ["updatedAt": updated ?? iso(), "primary": NSNull(),
                    "secondary": ["usedPercent": used, "windowMinutes": weekly ? 10080 : 300]]]])
    }
    static func site(events: [[String: Any]], alert: [String: Any]? = nil,
                     forecastAge: TimeInterval = 0, timelineAge: TimeInterval = 0,
                     last: String? = nil) throws -> SiteSnapshot {
        var forecast: [String: Any] = ["updated_at": iso(forecastAge)]
        forecast["latest_alert"] = alert
        forecast["last_reset_at"] = last
        return try ResetBarCore.parseSite(forecast: json(forecast),
            timeline: json(["updated_at": iso(timelineAge), "events": events]), now: now)
    }
    static func event(_ id: String, kind: String = "reset", offset: TimeInterval = -3600,
                      confirmed: Bool = true, banked: Bool = false) -> [String: Any] {
        ["id": id, "group": kind, "type": kind, "confirmed": confirmed, "banked_grant": banked,
         "preview": false, "effective_at": NSNull(), "announced_at": iso(offset)]
    }
    static func main() throws {
        let weekly = try ResetBarCore.parseQuota(quota(), now: now)
        expect(weekly.remainingPercent == 61 && weekly.windowLabel == "每周", "null session and valid weekly")
        let session = try ResetBarCore.parseQuota(quota(20, weekly: false), now: now)
        expect(session.windowLabel == "5 小时", "actual fallback window label")
        let mixed = try json([["provider": "codex", "usage": ["updatedAt": iso(),
            "primary": ["usedPercent": 1, "windowMinutes": 300],
            "tertiary": ["usedPercent": 80, "windowMinutes": 10080]]]])
        expect(try ResetBarCore.parseQuota(mixed, now: now).remainingPercent == 20, "weekly preferred over primary")
        rejects("over 100 percent") { try ResetBarCore.parseQuota(quota(101), now: now) }
        rejects("negative percent") { try ResetBarCore.parseQuota(quota(-1), now: now) }
        rejects("string percent") { try ResetBarCore.parseQuota(quota("39"), now: now) }
        rejects("boolean percent") { try ResetBarCore.parseQuota(quota(true), now: now) }
        rejects("nonfinite percent") { try ResetBarCore.parseQuota(Data("[{\"provider\":\"codex\",\"usage\":{\"updatedAt\":\"\(iso())\",\"primary\":{\"usedPercent\":1e999,\"windowMinutes\":300}}}]".utf8), now: now) }
        rejects("unreasonable window") { try ResetBarCore.parseQuota(json([["provider": "codex", "usage": ["updatedAt": iso(), "primary": ["usedPercent": 10, "windowMinutes": 1e300]]]]), now: now) }
        rejects("stale quota") { try ResetBarCore.parseQuota(quota(updated: iso(-901)), now: now) }
        rejects("future quota") { try ResetBarCore.parseQuota(quota(updated: iso(1)), now: now) }
        rejects("quota error") { try ResetBarCore.parseQuota(json([["provider": "codex", "error": "login required"]]), now: now) }
        rejects("malformed JSON") { try ResetBarCore.parseQuota(Data("oops".utf8), now: now) }
        rejects("missing usage") { try ResetBarCore.parseQuota(json([["provider": "codex"]]), now: now) }

        var observed = event("observed")
        observed["source"] = "operator-observed"
        observed["reset_verification_status"] = "pending"
        let regular = try site(events: [observed, event("rumor", offset: -500, confirmed: false), event("future", offset: 30)])
        expect(regular.event?.id == "observed", "only confirmed elapsed regular reset")
        expect(regular.event?.summary.contains("待官方确认") == true, "operator observation source is explicit")
        var preview = event("preview", offset: -100)
        preview["preview"] = true
        expect(try site(events: [observed, preview]).event?.id == "observed", "previews excluded")
        var futureEffective = event("future-effective", offset: -100)
        futureEffective["effective_at"] = iso(100)
        expect(try site(events: [observed, futureEffective]).event?.id == "observed", "future effective cannot use past announcement")

        let bank = event("grant", kind: "credits", offset: -600, banked: true)
        let arrival = event("arrival", kind: "credits", offset: -60, banked: false)
        let banks = try site(events: [observed, bank, arrival])
        expect(banks.event?.id == "grant" && banks.event?.kind == .banked, "bank grant chosen; arrival ignored")
        expect(banks.alert?.key == "banked:grant:confirmed", "recent bank grant alert")
        var watch: [String: Any] = ["id": "watch-1", "kind": "watch", "state": "active", "source_at": iso(-7200),
                                  "summary": "Tomorrow", "window": ["end_at": iso(3600)]]
        let active = try site(events: [observed], alert: watch)
        expect(active.alert?.key == "watch:watch-1:active", "active watch remains even if source precedes reset")
        watch["window"] = ["end_at": iso(-1)]
        expect(try site(events: [], alert: watch).alert == nil, "expired watch hidden")
        watch["window"] = ["end_at": "invalid"]
        expect(try site(events: [], alert: watch).alert == nil, "malformed watch expiry hidden")
        watch["window"] = NSNull()
        expect(try site(events: [], alert: watch).alert != nil, "untimed active watch")
        watch["state"] = "expired"
        expect(try site(events: [], alert: watch).alert == nil, "expired state hidden")
        watch["state"] = "active"
        watch["pending"] = true
        expect(try site(events: [], alert: watch).alert?.key == "watch:watch-1:active:pending", "watch pending transition key")
        var newerWatch = watch
        newerWatch["source_at"] = iso(-100)
        expect(try site(events: [bank], alert: newerWatch).alert?.kind == "watch", "newer canonical alert takes precedence over bank grant")
        watch["pending"] = "on_its_way"
        expect(try site(events: [], alert: watch).alert?.key == "watch:watch-1:active:on_its_way", "actual watch pending string is part of key")
        let confirmation: [String: Any] = ["id": "watch-1", "kind": "reset", "state": "confirmed", "pending": true,
                                         "source_at": iso(-600), "summary": "Observed by operator"]
        let confirmed = try site(events: [], alert: confirmation, last: iso(-600))
        expect(confirmed.alert?.key == "reset:watch-1:confirmed", "kind transition distinct; reset ignores pending")
        expect(confirmed.event?.id == "watch-1", "confirmed alert corroborates missing timeline reset")
        expect(try site(events: [], last: iso(-600)).event == nil, "last reset alone insufficient")
        var oldConfirmation = confirmation
        oldConfirmation["source_at"] = iso(-49 * 3600)
        expect(try site(events: [], alert: oldConfirmation).alert == nil, "old reset no longer alert")
        rejects("stale forecast is error, not alert clear") { try site(events: [], forecastAge: -901) }
        rejects("stale timeline is error") { try site(events: [], timelineAge: -901) }
        rejects("future site publication is error") { try site(events: [], forecastAge: 301) }
        expect(ResetBarCore.elapsed(since: now.addingTimeInterval(-21 * 3600 - 8 * 60), now: now) == "21h08m", "hour elapsed")
        expect(ResetBarCore.elapsed(since: now.addingTimeInterval(-51 * 3600), now: now) == "2d03h", "day elapsed")
        expect(ResetBarCore.elapsed(since: now.addingTimeInterval(30), now: now) == "0h00m", "future elapsed clamp")
        let persisted = try JSONDecoder().decode(SiteSnapshot.self, from: JSONEncoder().encode(banks))
        expect(persisted.event?.id == "grant", "Codable snapshot persistence")

        func sample(_ remaining: Double, offset: TimeInterval = 0, banked: Int? = nil,
                    end: TimeInterval = 3600, window: Int = 10080,
                    expiry: TimeInterval? = 3600, account: String? = "account-A") -> QuotaSample {
            QuotaSample(remainingPercent: remaining, windowLabel: window == 10080 ? "每周" : "会话",
                        fetchedAt: now.addingTimeInterval(offset), measuredAt: now.addingTimeInterval(offset),
                        resetsAt: now.addingTimeInterval(end), windowMinutes: window, bankedAvailable: banked,
                        bankedNextExpiry: expiry.map { now.addingTimeInterval($0) }, accountFingerprint: account)
        }
        let oldReset = PersonalReset(at: now.addingTimeInterval(-3600), kind: "R", confidence: "observed")
        func observe(_ before: QuotaSample?, _ after: QuotaSample, _ existing: PersonalReset? = oldReset) -> PersonalReset? {
            ResetBarCore.observePersonalReset(previous: before, current: after, existing: existing)
        }
        let initial = observe(nil, sample(61), nil)
        expect(initial == nil, "first install waits for an actual personal restoration")
        expect(observe(nil, sample(61), PersonalReset(at: now.addingTimeInterval(-60), kind: "↻", confidence: "estimated")) == nil, "old inferred window anchor discarded")
        expect(observe(nil, sample(61, end: -1), nil) == nil, "expired metadata cannot infer current window anchor")
        expect(observe(nil, sample(61, end: 10080 * 60 + 1), nil) == nil, "future inferred anchor rejected")
        expect(observe(sample(61, offset: -60), sample(60))?.at == oldReset.at, "normal usage preserves personal timer")
        expect(observe(sample(61, offset: -60), sample(62))?.at == oldReset.at, "minor provider adjustment does not reset timer")
        expect(observe(sample(61, offset: -60, banked: 2), sample(61, banked: 3))?.at == oldReset.at, "new bank grant without restoration is not personal reset")
        let redeemed = observe(sample(61, offset: -60, banked: 2), sample(62, banked: 1))
        expect(redeemed?.kind == "B" && redeemed?.confidence == "observed" && redeemed?.at == now, "bank redemption plus increase records personal B")
        let direct = observe(sample(61, offset: -60, banked: 2), sample(100, banked: 2))
        expect(direct?.kind == "R" && direct?.at == now, "large restoration with stable bank records R")
        let unknown = observe(sample(61, offset: -60), sample(100))
        expect(unknown?.kind == "↻" && unknown?.confidence == "observed", "missing bank inventory keeps observed type unknown")
        let windowRestore = observe(sample(20, offset: -60, banked: 2, end: 60), sample(60, banked: 2, end: 604800))
        expect(windowRestore?.kind == "R", "forward window boundary corroborates partial restored quota")
        expect(observe(sample(20, offset: -60), sample(60))?.at == oldReset.at, "uncorroborated partial increase preserves timer")
        expect(observe(sample(61, offset: -60), sample(100, offset: -120))?.at == oldReset.at, "out of order sample cannot reset")
        expect(observe(sample(61, offset: -1000), sample(100))?.at == oldReset.at, "long sampling gap cannot establish personal reset")
        expect(observe(sample(61, offset: -60), sample(100, window: 300)) == nil, "different quota window clears old timer")
        expect(observe(sample(61, offset: -60), sample(100, account: "account-B")) == nil, "account switch clears old timer")
        expect(observe(sample(61, offset: -60, account: nil), sample(100, account: nil))?.at == oldReset.at, "unknown account identity cannot establish continuity")
        let expiredBank = observe(sample(61, offset: -60, banked: 2, expiry: -30), sample(100, banked: 1))
        expect(expiredBank?.kind == "↻", "expired inventory drop is not proof of bank redemption")
        expect(observe(sample(61, offset: -60, banked: 2, expiry: nil), sample(62, banked: 1))?.at == oldReset.at, "small correction plus inventory drop without expiry proof does not reset")
        let stale = QuotaSample(remainingPercent: 100, windowLabel: "每周", fetchedAt: now,
                                measuredAt: now.addingTimeInterval(-901), windowMinutes: 10080,
                                accountFingerprint: "account-A")
        expect(observe(sample(61, offset: -1000), stale)?.at == oldReset.at, "stale provider sample cannot reset")
        let withCredits = try json([["provider": "codex", "resetCredits": ["available": 3, "nextExpiresAt": iso(7200)], "usage": ["updatedAt": iso(), "identity": ["accountEmail": "Example@Example.com"],
            "secondary": ["usedPercent": 39, "windowMinutes": 10080, "resetsAt": iso(3600)]]]])
        let creditsSample = try ResetBarCore.parseQuota(withCredits, now: now)
        expect(creditsSample.bankedAvailable == 3 && creditsSample.windowMinutes == 10080 && creditsSample.resetsAt == now.addingTimeInterval(3600), "outer bank inventory and window metadata parsed")
        expect(creditsSample.bankedNextExpiry == now.addingTimeInterval(7200), "bank next expiry metadata parsed")
        expect(creditsSample.accountFingerprint?.count == 64 && creditsSample.accountFingerprint?.contains("Example") == false, "account identity is persisted only as SHA256")
        let nativeCredits = try json([["provider": "codex", "usage": ["updatedAt": iso(), "codexResetCredits": ["availableCount": 4],
            "identity": ["accountEmail": "example@example.com"], "secondary": ["usedPercent": 39, "windowMinutes": 10080]]]])
        let nativeSample = try ResetBarCore.parseQuota(nativeCredits, now: now)
        expect(nativeSample.bankedAvailable == 4 && nativeSample.accountFingerprint == creditsSample.accountFingerprint, "native availableCount and normalized stable account identity")
        func scopedQuota(_ plan: String, _ login: String = "chatgpt") throws -> QuotaSample {
            try ResetBarCore.parseQuota(json([["provider": "codex", "usage": ["updatedAt": iso(),
                "accountEmail": "example@example.com", "plan": plan, "loginMethod": login,
                "secondary": ["usedPercent": 39, "windowMinutes": 10080]]]]), now: now)
        }
        let fallbackIdentity = try scopedQuota("pro")
        expect(fallbackIdentity.accountFingerprint?.count == 64, "top level usage email fallback establishes account scope")
        expect(try scopedQuota("plus").accountFingerprint != fallbackIdentity.accountFingerprint, "plan change creates a distinct scope")
        expect(try scopedQuota("pro", "api").accountFingerprint != fallbackIdentity.accountFingerprint, "login method change creates a distinct scope")
        let legacyJSON = try json(["remainingPercent": 61, "windowLabel": "每周", "fetchedAt": now.timeIntervalSinceReferenceDate,
                                   "measuredAt": now.timeIntervalSinceReferenceDate])
        expect(try JSONDecoder().decode(QuotaSample.self, from: legacyJSON).bankedAvailable == nil, "old persisted quota remains decodable")
        print("CoreTests: \(checks) checks passed")
    }
}
