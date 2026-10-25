import Foundation

@main
struct LiveProbe {
    static func main() async {
        do {
            async let usageData = UsageReader.fetch()
            async let payload = SiteReader().fetch()
            let (data, siteData) = try await (usageData, payload)
            let quota = try ResetBarCore.parseQuota(data, now: Date())
            let site = try ResetBarCore.parseSite(forecast: siteData.forecast, timeline: siteData.timeline, now: Date())
            // Normalized public fields only: never emit the helper's raw identity or credit IDs.
            let output: [String: Any] = [
                "quotaRemaining": quota.remainingPercent,
                "quotaWindow": quota.windowLabel,
                "bankedInventoryAvailable": quota.bankedAvailable != nil,
                "accountScopeAvailable": quota.accountFingerprint != nil,
                "quotaMeasurement": ISO8601DateFormatter().string(from: quota.measuredAt),
                "siteUpdated": ISO8601DateFormatter().string(from: site.sourceUpdatedAt),
                "latestAlertKind": site.alert?.kind ?? "none",
                "firstPersonalReset": "unknown; waiting for observed account restoration"
            ]
            let sanitized = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
            print(String(data: sanitized, encoding: .utf8)!)
        } catch {
            print("Live probe failed: \(error.localizedDescription)")
            exit(1)
        }
    }
}
