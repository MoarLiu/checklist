import AppKit
import Observation
import SwiftUI
import UserNotifications

@MainActor @Observable
final class ReminderSettings {
    private let defaults: UserDefaults
    var hour: Int { didSet { defaults.set(hour, forKey: "reminderHour") } }
    var minute: Int { didSet { defaults.set(minute, forKey: "reminderMinute") } }
    var sound: Bool { didSet { defaults.set(sound, forKey: "reminderSound") } }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hour = defaults.object(forKey: "reminderHour") as? Int ?? 9
        minute = defaults.integer(forKey: "reminderMinute")
        sound = defaults.object(forKey: "reminderSound") as? Bool ?? true
        hour = min(23, max(0, hour))
        minute = min(59, max(0, minute))
    }
}

@MainActor @Observable
final class ReminderService: NSObject, UNUserNotificationCenterDelegate {
    let store: AppStore
    var settings: ReminderSettings
    var permission = NotificationPermission.notDetermined
    var authorization = "尚未开启系统通知"
    var schedulingError: String?
    let systemNotificationsEnabled: Bool
    @ObservationIgnored private let client: NotificationClient?
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let presenter: ((Bill) -> Void)?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var panel: NSPanel?
    private(set) var activeBillID: UUID?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var suppressedNotificationIDs: [String: Date] = [:]

    init(store: AppStore, settings: ReminderSettings? = nil,
         systemNotificationsEnabled: Bool = true, client: NotificationClient? = nil,
         clock: @escaping () -> Date = Date.init, presenter: ((Bill) -> Void)? = nil) {
        self.store = store
        self.systemNotificationsEnabled = systemNotificationsEnabled
        self.settings = settings ?? ReminderSettings(defaults: systemNotificationsEnabled ? .standard :
            UserDefaults(suiteName: "app.chuzhangri.CheckList.demo")!)
        self.client = systemNotificationsEnabled ? (client ?? SystemNotificationClient()) : nil
        self.clock = clock
        self.presenter = presenter
        super.init()
        self.client?.install(delegate: self)
        if !systemNotificationsEnabled { authorization = "演示模式使用独立账本，不修改系统通知" }
    }

    func start() {
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.refresh() } })
        for name in [NSNotification.Name.NSSystemTimeZoneDidChange, NSNotification.Name.NSCalendarDayChanged,
                     NSNotification.Name("NSSystemClockDidChangeNotification")] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in Task { @MainActor in self?.refresh() }
            })
        }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    func refresh() {
        let previousTask = syncTask
        previousTask?.cancel()
        syncTask = Task { [weak self] in
            await previousTask?.value
            guard let self else { return }
            guard !Task.isCancelled else { return }
            await reconcile()
        }
    }

    func reconcile() async {
        // Retain foreground delivery keys across brief OS delivery races, but bound their lifetime.
        let now = clock()
        store.now = now
        store.onClockChange?()
        suppressedNotificationIDs = suppressedNotificationIDs.filter { now.timeIntervalSince($0.value) < 172800 }
        guard await absorbDeliveredNotifications() else { return }
        guard !Task.isCancelled else { return }
        if let activeBillID, let bill = store.bill(activeBillID), !bill.isPaid, !bill.isMuted, bill.snoozeUntil == nil {
            // Keep the current card until an explicit action is saved successfully.
        } else if activeBillID != nil { closePanel() }
        guard checkDue() else { return }
        guard !Task.isCancelled else { return }
        await synchronizeNotifications()
    }

    func enableNotifications() {
        guard let client else { return }
        Task {
            do {
                if await client.permission() == .denied {
                    // macOS won't present the permission prompt a second time.
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
                    return
                }
                try await client.requestPermission()
                refresh()
            } catch { schedulingError = error.localizedDescription }
        }
    }

    private func absorbDeliveredNotifications() async -> Bool {
        guard let client else { return true }
        let delivered = await client.delivered()
        guard !Task.isCancelled else { return false }
        var snapshots: [UUID: ReminderDeliverySnapshot] = [:]
        for notification in delivered {
            guard suppressedNotificationIDs[notification.identifier] == nil,
                  let id = notification.billID, let bill = store.bill(id),
                  notification.generation == bill.reminderGeneration,
                  !bill.isPaid, !bill.isMuted,
                  notification.date > (bill.lastRemindedAt ?? .distantPast),
                  notification.date >= (bill.snoozeUntil ?? .distantPast) else { continue }
            if snapshots[id] == nil { snapshots[id] = ReminderDeliverySnapshot(bill) }
            bill.lastRemindedAt = notification.date
            bill.snoozeUntil = nil
        }
        // This save does not recursively trigger a new synchronization task.
        if !snapshots.isEmpty {
            return store.saveReminderState(restoring: Array(snapshots.values))
        }
        return true
    }

    @discardableResult
    private func checkDue() -> Bool {
        guard panel == nil, activeBillID == nil else { return true }
        let now = clock()
        guard let bill = store.pending.first(where: {
            guard let date = $0.nextReminder(now: now, hour: settings.hour, minute: settings.minute) else { return false }
            return date <= now
        }) else { return true }
        let snapshot = ReminderDeliverySnapshot(bill)
        bill.lastRemindedAt = now
        bill.snoozeUntil = nil
        guard store.saveReminderState(restoring: [snapshot]) else { return false }
        activeBillID = bill.id
        if let presenter { presenter(bill) }
        else { present(bill: bill, preview: false) }
        return true
    }

    private func synchronizeNotifications() async {
        guard let client else { return }
        let permission = await client.permission()
        guard !Task.isCancelled else { return }
        self.permission = permission
        let allowed = permission == .allowed
        authorization = allowed ? "系统通知已开启" : permission == .denied ?
            "系统通知已关闭，应用运行时仍会弹窗" : "尚未开启系统通知"
        let delivered = await client.delivered()
        guard !Task.isCancelled else { return }
        let obsolete = delivered.filter {
            guard let id = $0.billID, let bill = store.bill(id) else { return true }
            return bill.isPaid || bill.isMuted || bill.snoozeUntil != nil ||
                $0.generation != bill.reminderGeneration || suppressedNotificationIDs[$0.identifier] != nil
        }.map(\.identifier)
        client.removeDelivered(obsolete)
        schedulingError = nil
        let planned = allowed ? NotificationPlanner.make(
            bills: store.pending, now: clock(), hour: settings.hour, minute: settings.minute, sound: settings.sound
        ).filter { suppressedNotificationIDs[$0.identifier] == nil } : []
        let desired = Dictionary(uniqueKeysWithValues: planned.map { ($0.identifier, $0) })
        let pending = await client.pending()
        guard !Task.isCancelled else { return }
        let existing = Dictionary(uniqueKeysWithValues: pending.compactMap { entry in
            entry.reminder.map { (entry.identifier, $0) }
        })
        client.removePending(pending.filter { desired[$0.identifier] == nil }.map(\.identifier))
        for reminder in planned where existing[reminder.identifier] != reminder {
            guard !Task.isCancelled else { return }
            do { try await client.add(reminder) }
            catch { schedulingError = "系统通知调度失败：\(error.localizedDescription)" }
        }
    }

    @discardableResult
    func handle(_ action: ReminderAction, billID: UUID) -> Bool {
        guard let bill = store.bill(billID), !bill.isPaid else { return false }
        let saved: Bool
        switch action {
        case .paid: saved = store.setPaid(bill, paid: true)
        case .nextInstallment: saved = store.advanceInstallment(bill, now: clock())
        case .snooze: saved = store.snooze(bill, now: clock())
        case .mute: saved = store.mute(bill, muted: true)
        }
        if saved {
            if activeBillID == billID { closePanel() }
            refresh()
        } else {
            store.showWindow?()
        }
        return saved
    }

    func preview() {
        if let panel { panel.makeKeyAndOrderFront(nil); return }
        let bill = Bill(kind: .creditCard, name: "招商银行信用卡", amountInCents: 328050, dueDate: .now)
        present(bill: bill, preview: true)
    }

    private func present(bill: Bill, preview: Bool) {
        let panel = ReminderPanel(contentRect: NSRect(x: 0, y: 0, width: 272, height: 178),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.title = "出账日 · 到期提醒"
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: ReminderCard(bill: bill, preview: preview) { [weak self] action in
            guard let self else { return }
            if preview { closePanel(); store.say("测试提醒已关闭"); refresh(); return }
            _ = handle(action, billID: bill.id)
        })
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - 284, y: screen.visibleFrame.maxY - 186))
        }
        self.panel = panel
        if preview { panel.makeKeyAndOrderFront(nil) }
        else { panel.orderFrontRegardless() }
        if settings.sound { NSSound(named: "Glass")?.play() }
    }

    private func closePanel() {
        panel?.orderOut(nil)
        panel = nil
        activeBillID = nil
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        // The custom panel supplies both the visual and sound while this process runs.
        let requestID = notification.request.identifier
        let handled = await MainActor.run {
            guard checkDue() else { return false }
            suppressedNotificationIDs[requestID] = clock()
            refresh()
            return true
        }
        return handled ? [] : [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let rawID = response.notification.request.content.userInfo["billID"] as? String
        let generation = response.notification.request.content.userInfo["generation"] as? String
        let action = response.actionIdentifier
        await MainActor.run {
            guard let rawID, let id = UUID(uuidString: rawID) else { return }
            handleNotificationAction(action, billID: id, generation: generation)
        }
    }

    func handleNotificationAction(_ action: String, billID: UUID, generation: String?) {
        guard let bill = store.bill(billID) else { return }
        guard action == UNNotificationDefaultActionIdentifier || generation == bill.reminderGeneration else {
            refresh()
            return
        }
        switch action {
        case "PAID": _ = handle(.paid, billID: billID)
        case "SNOOZE": if !bill.isMuted { _ = handle(.snooze, billID: billID) }
        case "MUTE": _ = handle(.mute, billID: billID)
        default: store.openDetail(bill, show: true)
        }
        refresh()
    }
}

enum ReminderAction { case paid, nextInstallment, snooze, mute }

final class ReminderPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

struct ReminderCard: View {
    let bill: Bill
    let preview: Bool
    let action: (ReminderAction) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "bell").font(.system(size: 14))
                    .foregroundStyle(Design.darkTeal).frame(width: 28, height: 28)
                    .background(Design.accent, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text(preview ? "出账日 · 测试提醒" : "出账日 · 现在")
                        .font(.system(size: 10)).foregroundStyle(Design.secondary)
                    Text("\(bill.name) \(bill.daysLeft() < 0 ? "已逾期" : "今天到期")")
                        .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                }
            }
            Text("¥" + Money.format(bill.amountInCents)).font(.system(size: 20, weight: .semibold))
                .monospacedDigit().foregroundStyle(Design.ink)
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Button { action(.paid) } label: {
                        Label("已经还款", systemImage: "checkmark").frame(maxWidth: .infinity)
                    }.buttonStyle(TealButtonStyle())
                    if bill.kind == .loan {
                        Button { action(.nextInstallment) } label: {
                            Label("下一期", systemImage: "arrow.right")
                        }
                        .buttonStyle(GhostButtonStyle())
                        .help("将本期设为已还款，并复制为下个月的账单")
                    }
                }
                HStack(spacing: 6) {
                    Button { action(.snooze) } label: {
                        Label("稍后再提醒", systemImage: "clock").frame(maxWidth: .infinity)
                    }
                    Button { action(.mute) } label: {
                        Label("不再提醒", systemImage: "bell.slash").frame(maxWidth: .infinity)
                    }
                }.buttonStyle(GhostButtonStyle())
            }
        }
        .padding(14).frame(width: 272).foregroundStyle(Design.body)
        .glassCard(radius: 18, thin: false)
        .tint(Design.teal)
    }
}
