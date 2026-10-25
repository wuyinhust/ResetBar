import AppKit
import ServiceManagement
import UserNotifications

private struct SavedState: Codable {
    var quota: QuotaSample?
    var site: SiteSnapshot?
    var personalReset: PersonalReset?
    var personalResets: [String: PersonalReset]?
    var pendingReset: PersonalReset?
    var pendingQuota: QuotaSample?
    var lastAlertKey: String?
    var seenAlertKeys: [String]?
    var readAlertKey: String?
    var readAlertKeys: [String]?
    var notificationsEnabled = false
    var hasSeenWelcome: Bool?
    var menuBarPresentationVersion: Int?
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private var item: NSStatusItem!
    private let menu = NSMenu()
    private let siteReader = SiteReader()
    private var state = SavedState()
    private var quotaError: String?
    private var siteError: String?
    private var readingQuota = false
    private var readingSite = false
    private var nextSiteRead = Date.distantPast
    private var timers: [Timer] = []
    private var previewWindow: NSWindow?
    private var previewLabel: NSTextField?
    private var previewIcon: NSImageView?
    private let stateURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ResetBar/state.json")

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A second launch must not create a second menu-bar item.
        if NSRunningApplication.runningApplications(withBundleIdentifier: "work.kuohu.ResetBar").count > 1 {
            NSApp.terminate(nil)
            return
        }
        load()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.menu = menu
        menu.delegate = self
        UNUserNotificationCenter.current().delegate = self
        updateTitle()
        refresh()
        if state.hasSeenWelcome != true || state.menuBarPresentationVersion != 2 {
            showPreview()
            state.hasSeenWelcome = true
            state.menuBarPresentationVersion = 2
            save()
        }
        timers.append(Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateTitle() }
        })
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)
        if state.notificationsEnabled { checkNotificationPermission() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPreview()
        return true
    }

    @objc private func woke() { refresh() }

    private var quotaStale: Bool {
        guard let quota = state.quota else { return true }
        return quotaError != nil || Date().timeIntervalSince(quota.measuredAt) > 900
    }
    private var siteStale: Bool {
        guard let site = state.site else { return true }
        return siteError != nil || Date().timeIntervalSince(site.sourceUpdatedAt) > 900
    }
    private var unread: Bool {
        guard !siteStale, let alert = state.site?.alert, alert.active,
              alert.kind == "watch" || Date().timeIntervalSince(alert.at) <= 172_800 else { return false }
        return alert.key != state.readAlertKey && !(state.readAlertKeys ?? []).contains(alert.key)
    }

    private func updateTitle() {
        guard let button = item?.button else { return }
        let quotaText: String
        if let quota = state.quota {
            quotaText = String(format: "%.0f%%", quota.remainingPercent) + (quotaStale ? "?" : "")
        } else { quotaText = "—%" }
        let resetText: String
        if let reset = state.personalReset {
            resetText = reset.kind + " " + ResetBarCore.elapsed(since: reset.at, now: Date())
        } else { resetText = "↻ —" }
        // Native status-bar text and template imagery follow the menu bar's own
        // appearance (which can differ from an ordinary window or app theme).
        // Do not use secondaryLabelColor or attributed-image attachments here.
        button.title = quotaText + "  ·  " + resetText + "  ·  "
        button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        button.contentTintColor = nil
        let symbol = siteStale ? "bell.slash" : unread ? "bell.badge.fill" : "bell"
        if let original = NSImage(systemSymbolName: symbol, accessibilityDescription: unread ? "有新的重置提醒" : "重置提醒") {
            let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            let image = original.withSymbolConfiguration(configuration) ?? original
            image.isTemplate = true
            button.image = image
            button.imagePosition = .imageRight
        } else {
            button.image = nil
            button.title += unread ? "!" : "♧"
        }
        previewLabel?.stringValue = button.title
        previewIcon?.image = button.image
        if let label = previewLabel, let icon = previewIcon {
            icon.frame.origin.x = label.frame.minX + label.intrinsicContentSize.width + 2
        }
        button.setAccessibilityLabel("ResetBar，" + plainStatus)
        button.toolTip = plainStatus + "\n点击查看详情；? 表示缓存数据，铃铛带点表示新提醒。"
        if previewWindow?.isVisible == true { exportOwnStatusView() }
    }

    private var plainStatus: String {
        let quota = state.quota.map { "\($0.windowLabel)剩余 \(Int($0.remainingPercent.rounded()))%" } ?? "额度暂不可用"
        let event = state.personalReset.map { "你的账号恢复额度后已过 \(ResetBarCore.elapsed(since: $0.at, now: Date()))，类型 \($0.kind)" } ?? "尚未观测到你的账号恢复额度"
        return "\(quota)；\(event)；\(siteStale ? "提醒数据未更新" : unread ? "有新提醒" : "暂无未读提醒")"
    }

    private func refresh() {
        if !readingQuota {
            readingQuota = true
            Task {
                defer { readingQuota = false; updateTitle() }
                do {
                    let data = try await UsageReader.fetch()
                    let current = try ResetBarCore.parseQuota(data, now: Date())
                    observeQuota(current)
                    quotaError = nil
                    save()
                } catch { quotaError = "额度读取失败，保留上次结果" }
            }
        }
        if !readingSite && Date() >= nextSiteRead {
            readingSite = true
            nextSiteRead = Date().addingTimeInterval(60)
            Task {
                defer { readingSite = false; updateTitle() }
                do {
                    let payload = try await siteReader.fetch()
                    let snapshot = try ResetBarCore.parseSite(forecast: payload.forecast, timeline: payload.timeline, now: Date())
                    let firstRead = state.site == nil
                    state.site = snapshot
                    siteError = nil
                    if let alert = snapshot.alert, alert.active {
                        var seen = state.seenAlertKeys ?? []
                        if firstRead {
                            state.lastAlertKey = alert.key
                            // A currently active promise deserves a badge; old completed resets do not.
                            if alert.kind != "watch" { recordRead(alert.key) }
                        } else if !seen.contains(alert.key) && alert.key != state.lastAlertKey {
                            state.lastAlertKey = alert.key
                            notify(alert)
                        }
                        if !seen.contains(alert.key) { seen.append(alert.key) }
                        state.seenAlertKeys = Array(seen.suffix(256))
                    }
                    save()
                } catch {
                    if case ReadFailure.rateLimited(let seconds) = error { nextSiteRead = Date().addingTimeInterval(TimeInterval(seconds)) }
                    siteError = (error as? ReadFailure)?.errorDescription ?? "网站读取失败，保留上次结果"
                }
            }
        }
    }

    func menuWillOpen(_ menu: NSMenu) { rebuildMenu() }

    @discardableResult private func row(_ title: String, action: Selector? = nil) -> NSMenuItem {
        let row = NSMenuItem(title: title, action: action, keyEquivalent: "")
        row.target = self
        if action == nil { row.isEnabled = false }
        menu.addItem(row)
        return row
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        row("ResetBar")
        if let quota = state.quota {
            row("\(quota.windowLabel)剩余：\(Int(quota.remainingPercent.rounded()))%" + (quotaStale ? "（缓存）" : ""))
            row("额度更新：\(formatted(quota.measuredAt))")
        } else { row("剩余额度：等待读取") }
        if let error = quotaError { row(error) }
        menu.addItem(.separator())
        if let reset = state.personalReset {
            row(reset.kind == "B" ? "B · 银行重置已使用" : reset.kind == "R" ? "R · 账号额度直接恢复" : "↻ · 账号额度恢复，类型未确认")
            row("已过 \(ResetBarCore.elapsed(since: reset.at, now: Date())) · \(formatted(reset.at))")
            row(reset.confidence == "manual" ? "按你确认的恢复时间记录" : "按账号实际恢复观测记录（约 1–2 分钟精度）")
        } else {
            row(state.pendingReset == nil ? "↻ · 等待首次记录账号额度恢复" : "↻ · 已观察到额度回升，等待下一轮确认")
            row("未用网站事件或下次重置时间代替")
        }
        row("校准上次恢复时间…", action: #selector(calibrateReset))
        menu.addItem(.separator())
        if let alert = state.site?.alert {
            row((unread ? "● " : "") + alertTitle(alert))
            // NSMenu titles are plain text. Wrap long source text into bounded, readable lines.
            for line in wrapped(alert.summary, width: 48).prefix(5) { row(line) }
            row("\(formatted(alert.at))" + (siteStale ? "（缓存）" : ""))
            row("查看提醒原文…", action: #selector(openAlert))
            if unread { row("标记已读", action: #selector(markRead)) }
        } else { row(siteStale ? "提醒暂不可用" : "暂无新的重置提醒") }
        if let error = siteError { row(error) }
        row("Data: codex-reset.com", action: #selector(openSite))
        menu.addItem(.separator())
        let refreshItem = row("立即刷新", action: #selector(manualRefresh))
        refreshItem.keyEquivalent = "r"
        let notificationItem = row(state.notificationsEnabled ? "系统通知已开启" : "启用系统通知…", action: #selector(toggleNotifications))
        notificationItem.state = state.notificationsEnabled ? .on : .off
        let loginItem = row("登录时启动", action: #selector(toggleLogin))
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        row("查看顶部显示…", action: #selector(showPreview))
        row("退出 ResetBar", action: #selector(quit)).keyEquivalent = "q"
    }

    private func alertTitle(_ alert: SiteAlert) -> String {
        if alert.kind == "watch" { return "明确重置预告" }
        if alert.kind == "banked" { return "银行重置发放" }
        return "网站确认重置"
    }

    private func wrapped(_ value: String, width: Int) -> [String] {
        var result: [String] = []
        for original in value.components(separatedBy: .newlines) where !original.isEmpty {
            let chars = Array(original)
            for start in stride(from: 0, to: chars.count, by: width) {
                result.append(String(chars[start..<min(start + width, chars.count)]))
            }
        }
        return result
    }

    private func formatted(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d HH:mm"
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    @objc private func manualRefresh() { refresh() }
    @objc private func markRead() {
        if let key = state.site?.alert?.key { recordRead(key) }
        save()
        updateTitle()
    }
    private func recordRead(_ key: String) {
        state.readAlertKey = key
        var keys = state.readAlertKeys ?? []
        if !keys.contains(key) { keys.append(key) }
        state.readAlertKeys = Array(keys.suffix(256))
    }
    @objc private func openSite() { open("https://codex-reset.com/zh/") }
    @objc private func openEvent() { open(state.site?.event?.url ?? "https://codex-reset.com/zh/timeline") }
    @objc private func openAlert() { open(state.site?.alert?.url ?? "https://codex-reset.com/zh/"); markRead() }
    private func open(_ value: String) {
        // Only public web links are accepted from remote JSON, never application/file URLs.
        guard let url = URL(string: value), url.scheme == "https", let host = url.host,
              host == "codex-reset.com" || host == "x.com" || host == "twitter.com" else { return }
        NSWorkspace.shared.open(url)
    }

    private func observeQuota(_ current: QuotaSample) {
        let previous = state.quota
        let changed = previous.map { quotaKey($0) != quotaKey(current) } ?? false
        if changed {
            if let previous, let key = quotaKey(previous), let reset = state.personalReset {
                var history = state.personalResets ?? [:]
                history[key] = reset
                state.personalResets = history
            }
            state.personalReset = quotaKey(current).flatMap { state.personalResets?[$0] }
            state.pendingReset = nil
            state.pendingQuota = nil
        }
        if let candidate = state.pendingReset, let baseline = state.pendingQuota {
            let age = current.measuredAt.timeIntervalSince(baseline.measuredAt)
            let sameBoundary = baseline.resetsAt.flatMap { first in current.resetsAt.map { abs($0.timeIntervalSince(first)) <= 60 } } ?? (baseline.resetsAt == nil && current.resetsAt == nil)
            if age > 0 && age <= 300 && quotaKey(baseline) == quotaKey(current) &&
                sameBoundary && current.remainingPercent >= baseline.remainingPercent - 3 {
                state.personalReset = candidate
                storePersonalReset(current)
                state.pendingReset = nil
                state.pendingQuota = nil
            } else if age > 300 || current.remainingPercent < baseline.remainingPercent - 3 {
                state.pendingReset = nil
                state.pendingQuota = nil
            }
        }
        let candidate = ResetBarCore.observePersonalReset(previous: changed ? nil : previous, current: current, existing: state.personalReset)
        if let candidate, candidate.at != state.personalReset?.at, state.pendingReset == nil {
            state.pendingReset = candidate
            state.pendingQuota = current
        }
        state.quota = current
    }

    private func quotaKey(_ sample: QuotaSample) -> String? {
        guard let fingerprint = sample.accountFingerprint else { return nil }
        return fingerprint + ":" + String(sample.windowMinutes ?? 0) + ":" + sample.windowLabel
    }
    private func storePersonalReset(_ sample: QuotaSample) {
        guard let key = quotaKey(sample), let reset = state.personalReset else { return }
        var history = state.personalResets ?? [:]
        history[key] = reset
        state.personalResets = history
    }

    @objc private func calibrateReset() {
        let alert = NSAlert()
        alert.messageText = "记录你确认的上次恢复时间"
        alert.informativeText = "使用本机时区。R 为直接恢复；B 为手动使用银行重置。若不确定，请取消并等待实际观测。"
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 330, height: 66))
        let input = NSTextField(frame: NSRect(x: 0, y: 36, width: 330, height: 24))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.isLenient = false
        input.stringValue = formatter.string(from: state.personalReset?.at ?? Date())
        input.placeholderString = "yyyy-MM-dd HH:mm"
        let type = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 330, height: 26))
        type.addItems(withTitles: ["↻ · 类型未知", "R · 直接恢复", "B · 使用银行重置"])
        view.addSubview(input)
        view.addSubview(type)
        alert.accessoryView = view
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let date = formatter.date(from: input.stringValue), date <= Date(), Date().timeIntervalSince(date) < 366 * 86400 else {
            showMessage("时间无效", "请输入过去一年内、尚未晚于现在的时间，格式为 yyyy-MM-dd HH:mm。")
            return
        }
        state.personalReset = PersonalReset(at: date, kind: ["↻", "R", "B"][type.indexOfSelectedItem], confidence: "manual")
        if let quota = state.quota { storePersonalReset(quota) }
        state.pendingReset = nil
        state.pendingQuota = nil
        save()
        updateTitle()
    }

    @objc private func toggleNotifications() {
        if state.notificationsEnabled { state.notificationsEnabled = false; save(); return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in
                self.state.notificationsEnabled = granted
                self.save()
                if !granted { self.showMessage("通知未开启", "可在系统设置 → 通知 → ResetBar 中开启。顶部提醒仍然有效。") }
            }
        }
    }
    private func checkNotificationPermission() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            if settings.authorizationStatus == .denied {
                Task { @MainActor in self.state.notificationsEnabled = false; self.save() }
            }
        }
    }
    private func notify(_ alert: SiteAlert) {
        guard state.notificationsEnabled, alert.active else { return }
        let content = UNMutableNotificationContent()
        content.title = alertTitle(alert)
        content.body = String(alert.summary.prefix(350))
        content.sound = .default
        content.userInfo = ["url": alert.url ?? "https://codex-reset.com/zh/"]
        let request = UNNotificationRequest(identifier: alert.key, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let url = response.notification.request.content.userInfo["url"] as? String
        let identifier = response.notification.request.identifier
        Task { @MainActor in
            if let url { self.open(url) }
            if self.state.site?.alert?.key == identifier { self.markRead() }
            completionHandler()
        }
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { showMessage("无法更新登录启动", error.localizedDescription) }
    }
    private func showMessage(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func showPreview() {
        if let previewWindow {
            previewWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 450, height: 222), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "ResetBar"
        window.isReleasedWhenClosed = false
        let heading = NSTextField(labelWithString: "顶部只保留这三项")
        heading.font = .systemFont(ofSize: 16, weight: .semibold)
        heading.frame = NSRect(x: 26, y: 166, width: 398, height: 25)
        let preview = NSTextField(labelWithString: item.button?.title ?? "—% · ↻ — · ")
        preview.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        preview.textColor = .labelColor
        preview.frame = NSRect(x: 26, y: 132, width: 398, height: 25)
        previewLabel = preview
        let icon = NSImageView(frame: NSRect(x: 26 + preview.intrinsicContentSize.width + 2, y: 139, width: 15, height: 14))
        icon.image = item.button?.image
        icon.contentTintColor = .labelColor
        previewIcon = icon
        let explanation = NSTextField(wrappingLabelWithString: "剩余额度 · 你的账号恢复后正计时 · 网站提醒\nR：直接恢复　B：银行重置已使用　↻：类型未知\n首次尚无实际恢复记录时，计时显示 —。")
        explanation.font = .systemFont(ofSize: 12)
        explanation.textColor = .secondaryLabelColor
        explanation.frame = NSRect(x: 26, y: 61, width: 398, height: 66)
        let menuButton = NSButton(title: "打开顶部菜单", target: self, action: #selector(showStatusMenu))
        menuButton.bezelStyle = .rounded
        menuButton.frame = NSRect(x: 22, y: 17, width: 148, height: 32)
        let closeButton = NSButton(title: "完成", target: self, action: #selector(closePreview))
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\r"
        closeButton.frame = NSRect(x: 343, y: 17, width: 84, height: 32)
        for view in [heading, preview, icon, explanation, menuButton, closeButton] { window.contentView?.addSubview(view) }
        previewWindow = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        exportOwnStatusView()
    }
    @objc private func showStatusMenu() { item.button?.performClick(nil) }
    @objc private func closePreview() { previewWindow?.close() }

    // Export only our own status-button view, never another app or screen.
    // This makes first-run UI validation possible for a windowless menu-bar app.
    private func exportOwnStatusView() {
        guard let button = item.button else { return }
        let folder = stateURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func writeView(_ name: String) {
            if let bitmap = button.bitmapImageRepForCachingDisplay(in: button.bounds) {
                button.cacheDisplay(in: button.bounds, to: bitmap)
                if let png = bitmap.representation(using: .png, properties: [:]) { try? png.write(to: folder.appendingPathComponent(name), options: .atomic) }
            }
        }
        writeView("status-item.png")
        // Exercise this actual control under both appearances without changing
        // the user's system setting. Restore the live bar's inherited appearance.
        let inherited = button.appearance
        for (name, appearanceName) in [("status-item-dark.png", NSAppearance.Name.vibrantDark),
                                       ("status-item-light.png", NSAppearance.Name.vibrantLight)] {
            if let appearance = NSAppearance(named: appearanceName) {
                button.appearance = appearance
                appearance.performAsCurrentDrawingAppearance { writeView(name) }
            }
        }
        button.appearance = inherited
        let check: [String: Any] = ["statusItemVisible": item.isVisible, "windowVisible": button.window?.isVisible ?? false,
                                    "title": plainStatus, "width": button.bounds.width, "height": button.bounds.height,
                                    "nativeTitle": true, "templateIcon": button.image?.isTemplate ?? false]
        if let data = try? JSONSerialization.data(withJSONObject: check, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: folder.appendingPathComponent("status-item-check.json"), options: .atomic)
        }
    }
    @objc private func quit() { NSApp.terminate(nil) }

    private func load() {
        if let data = try? Data(contentsOf: stateURL), let saved = try? JSONDecoder().decode(SavedState.self, from: data) { state = saved }
    }
    private func save() {
        do {
            try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(state)
            try data.write(to: stateURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
        } catch { /* Read-only operation remains useful if local caching is unavailable. */ }
    }
}

@main
struct ResetBarMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
