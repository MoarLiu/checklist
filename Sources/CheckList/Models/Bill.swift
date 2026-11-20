import Foundation
import SwiftData

enum BillKind: String, Codable, CaseIterable, Identifiable {
    case creditCard, loan, borrowing
    var id: String { rawValue }
    var title: String {
        switch self {
        case .creditCard: "信用卡"
        case .loan: "贷款"
        case .borrowing: "借款"
        }
    }

    var defaultName: String { title + "账单" }
    var symbol: String {
        switch self {
        case .creditCard: "creditcard"
        case .loan: "building.columns"
        case .borrowing: "person.2"
        }
    }

    func acceptsName(_ name: String) -> Bool {
        self != .borrowing || !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
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
    // Loan periods: nil means the old data predates this field. New loans fill both.
    var currentInstallment: Int? = nil
    var totalInstallments: Int? = nil

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

    /// The plan the form offers when a loan carries no period data: a new bill, or one
    /// saved before these fields existed. Twelve periods is a common plan and both
    /// fields stay editable, so the default never has to be right for every loan.
    static let defaultInstallmentPlan: (current: Int, total: Int) = (1, 12)

    var kind: BillKind { BillKind(rawValue: kindRaw) ?? .creditCard }
    var dueDate: Date { dueDate(in: .current) }
    var dateText: String { String(format: "%04d-%02d-%02d", dueYear, dueMonth, dueDay) }

    /// Shown as “第 3 / 12 期” for loans that carry period data.
    var installmentText: String? {
        guard kind == .loan, let current = currentInstallment, let total = totalInstallments else { return nil }
        return "第 \(current) / \(total) 期"
    }

    /// Bills from before this feature had no period data and may still advance.
    var canAdvanceInstallment: Bool {
        guard kind == .loan else { return false }
        guard let current = currentInstallment, let total = totalInstallments else { return true }
        return current < total
    }

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
        // Local calendar math can fail where a zone skips the wall-clock hour; the plain
        // civil date is the only sensible fallback and never crashes the reminder loop.
        let dueTime = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: due) ?? due
        if due > today { return dueTime }
        if let lastRemindedAt, lastRemindedAt >= today {
            guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else { return nil }
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: tomorrow) ?? tomorrow
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

/// Positive whole numbers for loan period fields. Full-width digits, as a Chinese keyboard produces.
enum PeriodNumber {
    static let maximum = 9_999

    static func parse(_ text: String) -> Int? {
        let clean = String(text.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.map { scalar in
            if (0xFF10...0xFF19).contains(scalar.value) {
                return Character(UnicodeScalar(scalar.value - 0xFF10 + 0x30)!)
            }
            return Character(scalar)
        })
        guard let value = Int(clean) else { return nil }
        return value > 0 && value <= maximum ? value : nil
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

    // Configured once: the amount labels render on every list row and re-render on each
    // frame of the counting animation.
    private static let groupedFormatter = makeFormatter(fraction: true)
    private static let wholeFormatter = makeFormatter(fraction: false)

    private static func makeFormatter(fraction: Bool) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = fraction ? 2 : 0
        formatter.maximumFractionDigits = fraction ? 2 : 0
        return formatter
    }

    static func format(_ cents: Int64, fraction: Bool = true) -> String {
        let formatter = fraction ? groupedFormatter : wholeFormatter
        return formatter.string(from: NSDecimalNumber(decimal: Decimal(cents) / 100)) ?? "0.00"
    }

    /// Without grouping separators, as `parse` accepts it: the starting text of an amount field.
    static func plain(_ cents: Int64) -> String {
        String(format: "%lld.%02lld", cents / 100, cents % 100)
    }
}
