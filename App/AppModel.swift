import AppKit
import Combine
import ServiceManagement
import StandUpCore
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
    private var session: TimerSession
    private let persistence: PersistenceService
    private let notifications: NotificationService
    private let sleepWake = SleepWakeMonitor()
    private let now: () -> Date
    private let canSave: Bool
    private var lastSaved: LocalData
    private var deadlineTimer: Timer?
    private var ticker: AnyCancellable?
    private var running = false
    private var requestingPermission = false
    @Published private var date: Date
    @Published private(set) var notificationStatus: NotificationStatus = .notDetermined
    @Published private(set) var loginStatus: SMAppService.Status = .notRegistered
    @Published private var loginError: String?
    @Published private(set) var storageError: String?

    init(persistence: PersistenceService = .standard, center: UNUserNotificationCenter = .current(),
         now: @escaping () -> Date = { Date() }) {
        self.persistence = persistence
        self.notifications = NotificationService(center: center)
        self.now = now
        self.date = now()
        let data: LocalData
        do {
            data = try persistence.load()
            canSave = true
        } catch {
            data = LocalData()
            canSave = false
            storageError = "无法读取本地数据。重新启动后可重试。"
        }
        self.lastSaved = data
        self.session = TimerSession(data: data, now: now)
    }

    private var engine: TimerEngine { session.engine }
    var state: TimerState { engine.state }
    var stageID: UUID? { engine.snapshot.stage?.id }
    var remaining: TimeInterval? { engine.remaining(at: date) }
    var progress: Double {
        guard let remaining, let stage = engine.snapshot.stage,
              let duration = activeConfiguration.duration(for: stage.phase) else {
            return state == .breakDue ? 1 : 0
        }
        return 1 - remaining / duration
    }

    var settings: AppSettings { session.data.settings }
    var activeConfiguration: TimerConfiguration { engine.activeConfiguration }
    var canSnooze: Bool { engine.canSnooze }

    var scheduleSummary: String {
        if !settings.schedule.enabled { return "提醒时段不限" }
        let closing = engine.snapshot.sessionEndsAt ?? engine.schedule.window(at: date)?.end
        guard let closing else { return "当前不在提醒时段" }
        if closing == .distantFuture { return "全天可提醒" }
        let time = closing.formatted(.dateTime.hour().minute())
        if engine.schedule.calendar.isDate(closing, inSameDayAs: date) { return "可提醒至 \(time)" }
        return "可提醒至 \(closing.formatted(.dateTime.weekday(.abbreviated).hour().minute()))"
    }

    var statisticsEnabled: Bool { session.data.settings.statisticsEnabled }
    var today: DailyStatistics { session.data.statistics.totals(at: date, schedule: engine.schedule) }
    var launchAtLogin: Bool { loginStatus == .enabled || loginNeedsApproval }
    var loginNeedsApproval: Bool { loginStatus == .requiresApproval }
    var loginMessage: String? {
        loginError ?? (loginNeedsApproval ? "请在系统设置中允许 StandUp 登录时启动。" : nil)
    }

    func start() {
        guard !running else { return }
        running = true
        notifications.register()
        sleepWake.start { [weak self] event in self?.send(event) }
        notifications.cancelPending()
        if state != .breakDue { notifications.clear() }
        send(.applicationLaunched)
        refreshSystemSettings()
    }

    func shutdown() {
        running = false
        deadlineTimer?.invalidate()
        ticker?.cancel()
        sleepWake.stop()
        notifications.cancelPending()
        saveIfNeeded()
    }

    func send(_ event: TimerEvent) {
        guard running else { return }
        let effects = session.handle(event)
        date = now()
        saveIfNeeded()
        if event == .systemWillSleep { notifications.cancelPending() }
        publish(effects)
    }

    func saveSettings(_ settings: AppSettings) -> Bool {
        guard canSave else { return false }
        let previous = session.data
        let effects = session.applySettings(settings)
        guard session.data.settings == settings else { return false }
        if !saveIfNeeded() {
            session = TimerSession(data: previous, now: now)
            return false
        }
        date = now()
        publish(effects)
        return true
    }

    private func publish(_ effects: [TimerEffect]) {
        let workMinutes = activeConfiguration.workMinutes
        let canSnooze = self.canSnooze
        for effect in effects {
            switch effect {
            case .clearReminder:
                notifications.clear()
            case let .remind(id):
                Task { [weak self] in
                    guard let self else { return }
                    notificationStatus = await notifications.notify(id, workMinutes: workMinutes, canSnooze: canSnooze) {
                        self.lastSaved.timer == self.engine.snapshot && self.isCurrentReminder(id)
                    }
                }
            case .record:
                break
            }
        }
        scheduleChecks()
    }

    func isCurrentReminder(_ id: UUID) -> Bool {
        running && engine.isCurrentReminder(id, at: now())
    }

    func refreshSystemSettings() {
        loginStatus = LaunchAtLoginService.status
        Task { [weak self] in
            guard let self else { return }
            notificationStatus = await notifications.status()
        }
    }

    func requestNotifications() {
        guard !requestingPermission else { return }
        requestingPermission = true
        Task { [weak self] in
            guard let self else { return }
            defer { requestingPermission = false }
            do {
                notificationStatus = try await notifications.requestPermission()
            } catch {
                notificationStatus = await notifications.status()
                NSLog("StandUp notification authorization: %@", error.localizedDescription)
            }
        }
    }

    func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"),
           NSWorkspace.shared.open(url) { return }
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/System Settings.app"),
                                           configuration: .init(), completionHandler: nil)
    }

    func openLoginSettings() { LaunchAtLoginService.openSettings() }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled != launchAtLogin { try LaunchAtLoginService.setEnabled(enabled) }
            loginStatus = LaunchAtLoginService.status
            loginError = nil
        } catch {
            loginStatus = LaunchAtLoginService.status
            loginError = "无法更改登录项。\(error.localizedDescription)"
        }
    }

    func setStatisticsEnabled(_ enabled: Bool) {
        session.setStatisticsEnabled(enabled)
        date = now()
        saveIfNeeded()
    }

    @discardableResult
    private func saveIfNeeded() -> Bool {
        guard canSave else { return false }
        guard session.data != lastSaved else { return true }
        do {
            try persistence.save(session.data)
            lastSaved = session.data
            storageError = nil
            return true
        } catch {
            storageError = "无法保存本地数据。计时仍可继续。"
            NSLog("StandUp persistence: %@", error.localizedDescription)
            return false
        }
    }

    private func scheduleChecks() {
        deadlineTimer?.invalidate()
        let next = [engine.nextCheck(after: date), engine.schedule.nextMidnight(after: date)]
            .compactMap { $0 }.min()
        if let next {
            let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.send(.refresh) }
            }
            RunLoop.main.add(timer, forMode: .common)
            deadlineTimer = timer
        }

        if engine.snapshot.stage?.deadline != nil {
            if ticker == nil {
                ticker = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect().sink { [weak self] _ in
                    guard let self else { return }
                    date = now()
                }
            }
        } else {
            ticker?.cancel()
            ticker = nil
        }
    }
}
