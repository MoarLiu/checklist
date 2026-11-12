import Foundation
import SwiftData

enum BillKind: String, Codable, CaseIterable, Identifiable {
    case creditCard, loan
    var id: String { rawValue }
    var title: String { self == .creditCard ? "信用卡" : "贷款" }
    var defaultName: String { title + "账单" }
    var symbol: String { self == .creditCard ? "creditcard" : "building.columns" }
}

@Model
final class Bill {
    @Attribute(.unique) var id: UUID
    var kindRaw: String
    var name: String
    // Store exact minor units. Never round money through binary floating point.
    var amountInCents: Int64
    var dueYear: Int
    var dueMonth: Int
    var dueDay: Int
    var isPaid: Bool
    var isMuted: Bool
    var snoozeUntil: Date?
    var lastRemindedAt: Date?
    var createdAt: Date
    var paidAt: Date?
    // Invalidates notifications from before a payment, mute or snooze change.
    // A literal default permits lightweight migration of existing local stores.
    var reminderGeneration: String = ""
    // Optional defaults allow existing stores to migrate without losing bills.
    // Keep the original day through short months (Jan 31 → Feb 28 → Mar 31).
    var installmentDay: Int? = nil
    var nextInstallmentID: UUID? = nil

    init(kind: BillKind, name: String, amountInCents: Int64, dueDate: Date, now: Date = .now, calendar: Calendar = .current) {
        self.id = UUID()
        self.kindRaw = kind.rawValue
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = trimmed.isEmpty ? kind.defaultName : trimmed
        self.amountInCents = amountInCents
        let parts = calendar.dateComponents([.year, .month, .day], from: dueDate)
        self.dueYear = parts.year!
        self.dueMonth = parts.month!
        self.dueDay = parts.day!
        self.isPaid = false
        self.isMuted = false
        self.createdAt = now
        self.reminderGeneration = UUID().uuidString
    }

    var kind: BillKind { BillKind(rawValue: kindRaw) ?? .creditCard }
    var dueDate: Date { dueDate(in: .current) }
    var dateText: String { String(format: "%04d-%02d-%02d", dueYear, dueMonth, dueDay) }
    var amount: Decimal { Decimal(amountInCents) / 100 }

    /// When the bill was repaid, in the same civil form as the due date.
    var paidText: String? {
        guard let paidAt else { return nil }
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: paidAt)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// One vocabulary for due status, shared by the list, the menu bar and the reminder card.
    func statusText(now: Date = .now, calendar: Calendar = .current) -> String {
        isPaid ? "已还款" : Self.statusText(daysLeft: daysLeft(now: now, calendar: calendar))
    }

    static func statusText(daysLeft days: Int) -> String {
        if days < 0 { return "逾期 \(-days) 天" }
        if days == 0 { return "今天到期" }
        return "剩 \(days) 天"
    }

    func dueDate(in calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: dueYear, month: dueMonth, day: dueDay)) ?? .distantFuture
    }

    func daysLeft(now: Date = .now, calendar: Calendar = .current) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: dueDate(in: calendar)).day ?? 0
    }

    /// The same day one month later, clamped to that month's last day (Jan 31 → Feb 28).
    static func monthAfter(_ date: Date, day: Int? = nil, calendar: Calendar = .current) -> Date? {
        guard let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: date)),
              let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStart),
              let days = calendar.range(of: .day, in: .month, for: nextMonth) else { return nil }
        var parts = calendar.dateComponents([.era, .year, .month], from: nextMonth)
        parts.day = min(max(1, day ?? calendar.component(.day, from: date)), days.count)
        return calendar.date(from: parts)
    }

    func nextInstallmentDate(calendar: Calendar = .current) -> Date? {
        guard let monthStart = calendar.date(from: DateComponents(year: dueYear, month: dueMonth, day: 1)) else { return nil }
        return Self.monthAfter(monthStart, day: installmentDay ?? dueDay, calendar: calendar)
    }

    /// A persisted daily delivery marker prevents timer/wake/notification races.
    /// Snoozing explicitly creates a new occurrence, even on the same day.
    func nextReminder(now: Date, hour: Int, minute: Int, calendar: Calendar = .current) -> Date? {
        guard !isPaid, !isMuted else { return nil }
        if let snoozeUntil { return snoozeUntil }
        let due = dueDate(in: calendar)
        let today = calendar.startOfDay(for: now)
        let dueTime = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: due)!
        if due > today { return dueTime }
        if let lastRemindedAt, lastRemindedAt >= today {
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: tomorrow)
        }
        if due < today {
            // Never delivered (the app was closed on the due day): catch up at once.
            // Delivered on an earlier day: wait for today's reminder time, not midnight.
            guard lastRemindedAt != nil else { return now }
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: today) ?? now
        }
        return max(dueTime, now)
    }
}

enum Money {
    static let maximumCents: Int64 = 99_999_999_999

    static func parse(_ text: String) -> Int64? {
        let clean = normalized(text)
        guard clean.range(of: #"^[0-9]{1,9}(\.[0-9]{1,2})?$"#, options: .regularExpression) != nil,
              let value = Decimal(string: clean, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        let cents = NSDecimalNumber(decimal: value * 100).int64Value
        return cents > 0 && cents <= maximumCents ? cents : nil
    }

    /// Full-width digits and full stop, as a Chinese keyboard produces them.
    private static func normalized(_ text: String) -> String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.map { scalar in
            switch scalar.value {
            case 0xFF10...0xFF19: return Character(UnicodeScalar(scalar.value - 0xFF10 + 0x30)!)
            case 0xFF0E: return "."
            default: return Character(scalar)
            }
        })
    }

    static func format(_ cents: Int64, fraction: Bool = true) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = fraction ? 2 : 0
        formatter.maximumFractionDigits = fraction ? 2 : 0
        return formatter.string(from: NSDecimalNumber(decimal: Decimal(cents) / 100)) ?? "0.00"
    }

    /// Without grouping separators, as `parse` accepts it: the starting text of an amount field.
    static func plain(_ cents: Int64) -> String {
        String(format: "%lld.%02lld", cents / 100, cents % 100)
    }
}
