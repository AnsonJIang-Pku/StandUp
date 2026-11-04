import AppKit
import StandUpCore

@MainActor
final class SleepWakeMonitor {
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    func start(send: @escaping @MainActor (TimerEvent) -> Void) {
        let workspace = NSWorkspace.shared.notificationCenter
        let system = NotificationCenter.default
        observe(NSWorkspace.willSleepNotification, in: workspace, event: .systemWillSleep, send: send)
        observe(NSWorkspace.didWakeNotification, in: workspace, event: .systemDidWake, send: send)
        observe(.NSSystemClockDidChange, in: system, event: .refresh, send: send)
        observe(.NSSystemTimeZoneDidChange, in: system, event: .refresh, send: send)
        observe(.NSCalendarDayChanged, in: system, event: .refresh, send: send)
    }

    func stop() {
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
    }

    private func observe(_ name: Notification.Name, in center: NotificationCenter,
                         event: TimerEvent, send: @escaping @MainActor (TimerEvent) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { send(event) }
        }
        observers.append((center, token))
    }
}
