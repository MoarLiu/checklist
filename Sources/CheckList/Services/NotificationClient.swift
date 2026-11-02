import Foundation
import UserNotifications

enum NotificationPermission { case allowed, denied, notDetermined }

struct ScheduledReminder: Equatable, Sendable {
    let identifier: String
    let billID: UUID
    let generation: String
    let date: Date
    let title: String
    let body: String
    let sound: Bool
}

struct DeliveredReminder: Sendable {
    let identifier: String
    let billID: UUID?
    let generation: String?
    let date: Date
}

struct PendingReminder {
    let identifier: String
    let reminder: ScheduledReminder?
}

@MainActor
protocol NotificationClient: AnyObject {
    func install(delegate: UNUserNotificationCenterDelegate)
    func permission() async -> NotificationPermission
    func requestPermission() async throws
    func delivered() async -> [DeliveredReminder]
    func pending() async -> [PendingReminder]
    func add(_ reminder: ScheduledReminder) async throws
    func removePending(_ identifiers: [String])
    func removeDelivered(_ identifiers: [String])
}

@MainActor
final class SystemNotificationClient: NotificationClient {
    private let center = UNUserNotificationCenter.current()
    func install(delegate: UNUserNotificationCenterDelegate) {
        center.delegate = delegate
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "BILL_DUE", actions: [
                UNNotificationAction(identifier: "PAID", title: "已经还款"),
                UNNotificationAction(identifier: "SNOOZE", title: "1 小时后再提醒"),
                UNNotificationAction(identifier: "MUTE", title: "不再提醒"),
            ], intentIdentifiers: [])
        ])
    }
    func permission() async -> NotificationPermission {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional: return .allowed
        case .denied: return .denied
        default: return .notDetermined
        }
    }
    func requestPermission() async throws {
        _ = try await center.requestAuthorization(options: [.alert, .sound])
    }
    func delivered() async -> [DeliveredReminder] {
        await center.deliveredNotifications().map {
            DeliveredReminder(identifier: $0.request.identifier,
                              billID: ($0.request.content.userInfo["billID"] as? String).flatMap(UUID.init(uuidString:)),
                              generation: $0.request.content.userInfo["generation"] as? String, date: $0.date)
        }
    }
    func pending() async -> [PendingReminder] {
        await center.pendingNotificationRequests().map {
            guard let raw = $0.content.userInfo["billID"] as? String, let billID = UUID(uuidString: raw),
                  let generation = $0.content.userInfo["generation"] as? String,
                  let trigger = $0.trigger as? UNCalendarNotificationTrigger,
                  let date = trigger.nextTriggerDate() else {
                return PendingReminder(identifier: $0.identifier, reminder: nil)
            }
            let reminder = ScheduledReminder(identifier: $0.identifier, billID: billID, generation: generation, date: date,
                                             title: $0.content.title, body: $0.content.body, sound: $0.content.sound != nil)
            return PendingReminder(identifier: $0.identifier, reminder: reminder)
        }
    }
    func add(_ reminder: ScheduledReminder) async throws {
        let content = UNMutableNotificationContent()
        content.title = reminder.title
        content.body = reminder.body
        content.categoryIdentifier = "BILL_DUE"
        content.threadIdentifier = reminder.billID.uuidString
        content.userInfo = ["billID": reminder.billID.uuidString, "generation": reminder.generation]
        if reminder.sound { content.sound = .default }
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: reminder.date)
        try await center.add(UNNotificationRequest(
            identifier: reminder.identifier, content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)))
    }
    func removePending(_ identifiers: [String]) { center.removePendingNotificationRequests(withIdentifiers: identifiers) }
    func removeDelivered(_ identifiers: [String]) { center.removeDeliveredNotifications(withIdentifiers: identifiers) }
}

@MainActor
enum NotificationPlanner {
    static func make(bills: [Bill], now: Date, hour: Int, minute: Int, sound: Bool,
                     calendar: Calendar = .current, limit: Int = 60) -> [ScheduledReminder] {
        var firsts: [ScheduledReminder] = []
        var followups: [ScheduledReminder] = []
        for bill in bills {
            guard let first = bill.nextReminder(now: now, hour: hour, minute: minute, calendar: calendar) else { continue }
            func entry(date: Date, snooze: Bool = false) -> ScheduledReminder {
                let civil = calendar.dateComponents([.year, .month, .day], from: date)
                let occurrence = snooze ? "snooze-\(Int(date.timeIntervalSince1970))" :
                    "\(civil.year!)-\(civil.month!)-\(civil.day!)-\(hour)-\(minute)"
                return ScheduledReminder(
                    identifier: "\(bill.id.uuidString)-\(bill.reminderGeneration)-\(occurrence)",
                    billID: bill.id, generation: bill.reminderGeneration,
                    date: Date(timeIntervalSince1970: ceil(max(date, now.addingTimeInterval(2)).timeIntervalSince1970)),
                    title: "出账日 · \(bill.name)", body: "应还 ¥\(Money.format(bill.amountInCents)) · 还款日 \(bill.dateText)",
                    sound: sound)
            }
            firsts.append(entry(date: first, snooze: bill.snoozeUntil != nil))
            for offset in 1...7 {
                guard let day = calendar.date(byAdding: .day, value: offset, to: first),
                      let next = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) else { continue }
                followups.append(entry(date: next))
            }
        }
        // Reserve a first notification per bill before spending capacity on daily repeats.
        func ordered(_ entries: [ScheduledReminder]) -> [ScheduledReminder] {
            entries.sorted { $0.date == $1.date ? $0.identifier < $1.identifier : $0.date < $1.date }
        }
        return Array((ordered(firsts) + ordered(followups)).prefix(max(0, limit)))
    }
}
