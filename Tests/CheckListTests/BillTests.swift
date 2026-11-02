import Foundation
import Testing
@testable import CheckList

@Suite(.serialized) @MainActor
struct BillTests {
    func calendar(_ zone: String = "Asia/Shanghai") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }
    func date(_ year: Int = 2026, _ month: Int = 11, _ day: Int = 2, _ hour: Int = 10, _ minute: Int = 0,
              calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    @Test func decimalMoneyValidation() {
        #expect(Money.parse("3280.50") == 328050)
        #expect(Money.parse("0.01") == 1)
        #expect(Money.parse("999999999.99") == Money.maximumCents)
        for invalid in ["", "0", "-1", "1.234", "1..2", "1e6", "NaN", "Infinity", "1000000000", "1,234", "."] {
            #expect(Money.parse(invalid) == nil, "Invalid money: \(invalid)")
        }
        #expect(Money.format(126080) == "1,260.80")
        #expect(Money.format(10 + 20) == "0.30")
    }

    @Test func dailyDeliveryAndSnooze() throws {
        let cal = calendar()
        let morning = date(2026, 11, 2, 8, calendar: cal)
        let nine = date(2026, 11, 2, 9, calendar: cal)
        let ten = date(calendar: cal)
        let bill = Bill(kind: .creditCard, name: "", amountInCents: 100, dueDate: ten, calendar: cal)
        #expect(bill.name == "信用卡账单")
        #expect(bill.nextReminder(now: morning, hour: 9, minute: 0, calendar: cal) == nine)
        #expect(bill.nextReminder(now: ten, hour: 9, minute: 0, calendar: cal) == ten)
        bill.lastRemindedAt = ten
        #expect(bill.nextReminder(now: ten, hour: 9, minute: 0, calendar: cal) ==
                date(2026, 11, 3, 9, calendar: cal))
        bill.snoozeUntil = ten.addingTimeInterval(3600)
        #expect(bill.nextReminder(now: ten, hour: 9, minute: 0, calendar: cal) == ten.addingTimeInterval(3600))
        let afterSnooze = ten.addingTimeInterval(3601)
        #expect(try #require(bill.nextReminder(now: afterSnooze, hour: 9, minute: 0, calendar: cal)) < afterSnooze)
        bill.isMuted = true
        #expect(bill.nextReminder(now: ten, hour: 9, minute: 0, calendar: cal) == nil)
        bill.isMuted = false
        bill.isPaid = true
        #expect(bill.nextReminder(now: ten, hour: 9, minute: 0, calendar: cal) == nil)
    }

    @Test func futureReminderAndQueueEligibility() {
        let cal = calendar()
        let now = date(calendar: cal)
        let first = Bill(kind: .creditCard, name: "第一笔", amountInCents: 1, dueDate: now, calendar: cal)
        let second = Bill(kind: .loan, name: "第二笔", amountInCents: 2, dueDate: now, calendar: cal)
        let future = Bill(kind: .loan, name: "未来", amountInCents: 3,
                          dueDate: date(2026, 12, 1, 0, calendar: cal), calendar: cal)
        #expect(future.nextReminder(now: now, hour: 9, minute: 30, calendar: cal) ==
                date(2026, 12, 1, 9, 30, calendar: cal))
        first.lastRemindedAt = now
        let eligible = [first, second, future].filter {
            ($0.nextReminder(now: now, hour: 9, minute: 0, calendar: cal) ?? .distantFuture) <= now
        }
        #expect(eligible.map(\.name) == ["第二笔"])
    }

    @Test func overdueCatchupAndCalendarDates() {
        let cal = calendar("America/Los_Angeles")
        let beforeDST = date(2026, 10, 31, 12, calendar: cal)
        let afterDST = date(2026, 11, 2, 8, calendar: cal)
        let bill = Bill(kind: .loan, name: "房贷", amountInCents: 741500, dueDate: beforeDST, calendar: cal)
        #expect(bill.daysLeft(now: afterDST, calendar: cal) == -2)
        #expect(bill.nextReminder(now: afterDST, hour: 9, minute: 0, calendar: cal) == afterDST)
        #expect(bill.dateText == "2026-10-31")
        // The civil date survives a local time-zone change.
        #expect(calendar().component(.day, from: bill.dueDate(in: calendar())) == 31)
    }

    @Test func persistedStateTransitions() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let url = base.appendingPathComponent("test.store")
        let store = try AppStore(dataURL: url)
        #expect(store.bills.isEmpty)
        store.add(kind: .creditCard, name: " 测试账单 ", cents: 126080, due: .now)
        let bill = try #require(store.pending.first)
        #expect(bill.name == "测试账单")
        #expect(store.total == 126080)
        store.snooze(bill, now: Date(timeIntervalSince1970: 1000))
        #expect(bill.snoozeUntil == Date(timeIntervalSince1970: 4600))
        store.setPaid(bill, paid: true)
        #expect(store.total == 0)
        #expect(store.paidTotal == 126080)
        #expect(bill.snoozeUntil == nil)
        let reopened = try AppStore(dataURL: url)
        #expect(reopened.history.count == 1)
        #expect(reopened.history.first?.amountInCents == 126080)
        store.setPaid(bill, paid: false)
        store.mute(bill, muted: true)
        #expect(store.pending.count == 1)
        #expect(bill.isMuted)
        store.mute(bill, muted: false)
        #expect(!bill.isMuted)
        store.delete(bill)
        #expect(store.bills.isEmpty)
    }
}
