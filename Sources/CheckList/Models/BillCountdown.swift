import Foundation

/// Bills have a civil due date, with the entire due day available for repayment.
enum BillCountdown: Equatable {
    case paidOff
    case days(Int)
    case hours(Int)
    case overdue(Int)

    init(dueDate: Date?, now: Date, calendar: Calendar = .current) {
        guard let dueDate else { self = .paidOff; return }
        let dueDay = calendar.startOfDay(for: dueDate)
        let today = calendar.startOfDay(for: now)
        if dueDay < today {
            self = .overdue(max(1, calendar.dateComponents([.day], from: dueDay, to: today).day ?? 1))
            return
        }
        let deadline = calendar.date(byAdding: .day, value: 1, to: dueDay) ?? dueDay
        let seconds = max(0, deadline.timeIntervalSince(now))
        if seconds >= 86_400 {
            self = .days(Int(seconds / 86_400))
        } else {
            self = .hours(max(1, Int(ceil(seconds / 3_600))))
        }
    }

    var text: String {
        switch self {
        case .paidOff: "已还清"
        case .days(let days): "剩 \(days) 天"
        case .hours(let hours): "剩 \(hours) 小时"
        case .overdue(let days): "逾期 \(days) 天"
        }
    }
}
