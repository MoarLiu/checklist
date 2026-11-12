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
    /// The first-run hint to allow system notifications is shown until it is answered once.
    var permissionPromptDismissed: Bool {
        didSet { defaults.set(permissionPromptDismissed, forKey: "permissionPromptDismissed") }
    }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Clamp once, so construction does not count as an edit and write defaults back.
        hour = min(23, max(0, defaults.object(forKey: "reminderHour") as? Int ?? 9))
        minute = min(59, max(0, defaults.integer(forKey: "reminderMinute")))
        sound = defaults.object(forKey: "reminderSound") as? Bool ?? true
        permissionPromptDismissed = defaults.bool(forKey: "permissionPromptDismissed")
    }
}

struct SnoozeChoice: Equatable {
    let title: String
    let date: Date
    /// Shown in the toast once the choice is saved.
    let confirmation: String
}

enum SnoozeOptions {
    /// "Tonight" is offered only while 20:00 is later than the one-hour choice.
    static func make(now: Date, hour: Int, minute: Int, calendar: Calendar = .current) -> [SnoozeChoice] {
        let inAnHour = now.addingTimeInterval(3600)
        var choices = [SnoozeChoice(title: "1 小时后", date: inAnHour, confirmation: "1 小时后再提醒你")]
        let today = calendar.startOfDay(for: now)
        if let tonight = calendar.date(bySettingHour: 20, minute: 0, second: 0, of: today), tonight > inAnHour {
            choices.append(SnoozeChoice(title: "今晚 20:00", date: tonight, confirmation: "今晚 20:00 再提醒你"))
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: today),
           let morning = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: tomorrow) {
            let time = String(format: "%02d:%02d", hour, minute)
            choices.append(SnoozeChoice(title: "明天 \(time)", date: morning, confirmation: "明天 \(time) 再提醒你"))
        }
        return choices
    }
}

@MainActor @Observable
final class ReminderService: NSObject, UNUserNotificationCenterDelegate {
    let store: AppStore
    var settings: ReminderSettings
    var permission = NotificationPermission.notDetermined
    /// False until the system has answered once, so the UI does not flash "not enabled" at launch.
    private(set) var permissionChecked = false
    var authorization = "尚未开启系统通知"
    var schedulingError: String?
    let systemNotificationsEnabled: Bool
    @ObservationIgnored private let client: NotificationClient?
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let presenter: ((Bill) -> Void)?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var panelSizeObserver: NSKeyValueObservation?
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
        permissionChecked = true
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
        case .snoozeUntil(let choice): saved = store.snooze(bill, until: choice.date, message: choice.confirmation)
        case .mute: saved = store.mute(bill, muted: true)
        case .dismiss:
            // Nothing to save: the delivery marker already keeps this bill quiet until its next reminder.
            if activeBillID == billID { dismissCard() }
            return true
        }
        if saved {
            if activeBillID == billID { closePanel() }
            refresh()
        } else {
            store.showWindow?()
        }
        return saved
    }

    /// Hides the card without changing the bill, and lets the next due bill take its place.
    func dismissCard() {
        closePanel()
        refresh()
    }

    /// Other bills that are already due and wait behind the card on screen.
    func queuedCount(excluding id: UUID) -> Int {
        let now = clock()
        return store.pending.filter { bill in
            bill.id != id &&
                (bill.nextReminder(now: now, hour: settings.hour, minute: settings.minute) ?? .distantFuture) <= now
        }.count
    }

    func snoozeChoices() -> [SnoozeChoice] {
        SnoozeOptions.make(now: clock(), hour: settings.hour, minute: settings.minute)
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
        let billID = bill.id
        let card = ReminderCard(
            bill: bill, preview: preview,
            queued: { [weak self] in preview ? 0 : (self?.queuedCount(excluding: billID) ?? 0) },
            snoozeChoices: { [weak self] in self?.snoozeChoices() ?? [] }
        ) { [weak self] action in
            guard let self else { return }
            if preview { closePanel(); store.say("测试提醒已关闭"); refresh(); return }
            _ = handle(action, billID: billID)
        }
        // The card decides its own height: the queue line and the loan button come and go.
        let host = NSHostingController(rootView: card)
        host.sizingOptions = [.preferredContentSize]
        panel.contentViewController = host
        panel.setContentSize(host.view.fittingSize)
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - panel.frame.width - 12,
                                         y: screen.visibleFrame.maxY - panel.frame.height - 8))
        }
        panelSizeObserver = host.observe(\.preferredContentSize, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.fitPanel() }
        }
        self.panel = panel
        if preview { panel.makeKeyAndOrderFront(nil) }
        else { panel.orderFrontRegardless() }
        if settings.sound { NSSound(named: "Glass")?.play() }
    }

    /// Follows a change in the card's height while keeping its top-right corner in place.
    private func fitPanel() {
        guard let panel, let size = panel.contentViewController?.preferredContentSize,
              size.width > 0, size.height > 0, size != panel.contentLayoutRect.size else { return }
        let top = panel.frame.maxY
        let right = panel.frame.maxX
        panel.setContentSize(size)
        panel.setFrameOrigin(NSPoint(x: right - panel.frame.width, y: top - panel.frame.height))
    }

    private func closePanel() {
        panelSizeObserver?.invalidate()
        panelSizeObserver = nil
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

enum ReminderAction {
    case paid, nextInstallment, snooze, snoozeUntil(SnoozeChoice), mute, dismiss
}

final class ReminderPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// A native pop-up menu, for a choice that should not change the layout it is opened from.
@MainActor
enum PopUpMenu {
    private final class Target: NSObject {
        let handler: () -> Void
        init(_ handler: @escaping () -> Void) { self.handler = handler }
        @objc func run() { handler() }
    }

    static func show(_ entries: [(title: String, handler: () -> Void)]) {
        let menu = NSMenu()
        for entry in entries {
            let target = Target(entry.handler)
            let item = NSMenuItem(title: entry.title, action: #selector(Target.run), keyEquivalent: "")
            item.target = target
            // NSMenuItem holds its target weakly; the represented object keeps it alive.
            item.representedObject = target
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

struct ReminderCard: View {
    let bill: Bill
    let preview: Bool
    var queued: () -> Int = { 0 }
    var snoozeChoices: () -> [SnoozeChoice] = { [] }
    let action: (ReminderAction) -> Void

    var body: some View {
        let waiting = queued()
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "bell").font(.system(size: 14))
                    .foregroundStyle(Design.darkTeal).frame(width: 28, height: 28)
                    .background(Design.accent, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text(preview ? "出账日 · 测试提醒" : "出账日 · 还款日 \(bill.dateText)")
                        .font(.system(size: 10)).foregroundStyle(Design.secondary).lineLimit(1)
                    Text("\(bill.name) · \(bill.statusText())")
                        .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                }
                Spacer(minLength: 0)
                Button { action(.dismiss) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Design.secondary).frame(width: 20, height: 20)
                        .background(Design.ghostStrongFill, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("收起，到下次提醒时间再弹出")
                .accessibilityLabel("收起提醒")
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
                        .buttonStyle(GhostButtonStyle(strong: true))
                        .help("将本期设为已还款，并复制为下个月的账单")
                    }
                }
                HStack(spacing: 6) {
                    Button { showSnoozeMenu() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "clock")
                            Text("稍后提醒")
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                        }.frame(maxWidth: .infinity)
                    }
                    .accessibilityLabel("稍后提醒")
                    .accessibilityHint("选择 1 小时后、今晚或明天")
                    Button { action(.mute) } label: {
                        Label("不再提醒", systemImage: "bell.slash").frame(maxWidth: .infinity)
                    }
                }.buttonStyle(GhostButtonStyle(strong: true))
            }
            if waiting > 0 {
                Text("还有 \(waiting) 笔待处理").font(.system(size: 10))
                    .foregroundStyle(Design.secondary).frame(maxWidth: .infinity)
            }
        }
        .padding(14).frame(width: 272).foregroundStyle(Design.body)
        .glassCard(radius: 18, thin: false)
        .tint(Design.teal)
    }

    private func showSnoozeMenu() {
        let choices = snoozeChoices()
        guard !choices.isEmpty else { action(.snooze); return }
        PopUpMenu.show(choices.map { choice in (choice.title, { action(.snoozeUntil(choice)) }) })
    }
}
