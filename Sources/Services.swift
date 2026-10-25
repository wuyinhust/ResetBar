import Foundation
import Darwin

enum ReadFailure: LocalizedError {
    case missingCLI, quotaUnavailable, timeout, http(Int), expired, inconsistent, rateLimited(Int)
    var errorDescription: String? {
        switch self {
        case .missingCLI: return "找不到 CodexBar 的额度读取组件"
        case .quotaUnavailable: return "额度读取失败，保留上次结果"
        case .timeout: return "请求超时，保留上次结果"
        case .http(let code): return "网站返回 HTTP \(code)，保留上次结果"
        case .expired: return "网站发布数据已过期，保留上次结果"
        case .inconsistent: return "网站数据正在更新，下一轮重试"
        case .rateLimited(let seconds): return "网站限流，\(seconds) 秒后重试"
        }
    }
}

enum UsageReader {
    static let helperPath = "/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI"

    static func fetch() async throws -> Data {
        try await Task.detached(priority: .utility) {
            guard FileManager.default.isExecutableFile(atPath: helperPath) else { throw ReadFailure.missingCLI }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: helperPath)
            process.arguments = ["usage", "--provider", "codex", "--source", "oauth", "--format", "json"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let handle = output.fileHandleForReading
            defer { try? handle.close() }
            let descriptor = handle.fileDescriptor
            _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
            let deadline = ProcessInfo.processInfo.systemUptime + 35
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                var ready = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
                _ = poll(&ready, 1, 100)
                var readCount = 0
                repeat {
                    readCount = Darwin.read(descriptor, &buffer, buffer.count)
                    if readCount > 0 { data.append(contentsOf: buffer.prefix(readCount)) }
                } while readCount > 0 && data.count <= 2_000_000
                if data.count > 2_000_000 {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    throw ReadFailure.quotaUnavailable
                }
                if !process.isRunning { break }
                if ProcessInfo.processInfo.systemUptime >= deadline {
                    kill(process.processIdentifier, SIGKILL)
                    throw ReadFailure.timeout
                }
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0, data.count <= 2_000_000 else { throw ReadFailure.quotaUnavailable }
            return data
        }.value
    }
}

struct SitePayload {
    let forecast: Data
    let timeline: Data
}

final class SiteReader {
    private let session: URLSession
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 25
        session = URLSession(configuration: configuration)
    }

    private func read(_ path: String) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: URL(string: "https://codex-reset.com" + path)!)
        request.setValue("ResetBar/1.0 (personal macOS menu bar; codex-reset.com public API)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ReadFailure.http(0) }
        if http.statusCode == 429 {
            let retry = Int(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 300
            throw ReadFailure.rateLimited(max(60, retry))
        }
        guard http.statusCode == 200, data.count <= 2_000_000 else { throw ReadFailure.http(http.statusCode) }
        if let expires = http.value(forHTTPHeaderField: "x-published-expires-at"),
           let date = Self.date(expires), date < Date() { throw ReadFailure.expired }
        if let checked = http.value(forHTTPHeaderField: "x-published-checked-at"),
           let date = Self.date(checked), Date().timeIntervalSince(date) > 900 { throw ReadFailure.expired }
        return (data, http)
    }

    func fetch() async throws -> SitePayload {
        async let forecast = read("/api/forecast")
        async let timeline = read("/api/timeline")
        let (f, t) = try await (forecast, timeline)
        // The public API guarantees each copy's freshness, not an atomic batch
        // shared by endpoints. Adjacent CDN batches are valid; each response is
        // checked above and each payload's own timestamp is checked by Core.
        return SitePayload(forecast: f.0, timeline: t.0)
    }

    private static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
