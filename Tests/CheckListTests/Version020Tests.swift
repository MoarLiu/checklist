import Foundation
import SwiftData
import Testing
@testable import CheckList

@Suite(.serialized) @MainActor
struct Version020Tests {
    func calendar(_ zone: String = "Asia/Shanghai") -> Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(identifier: zone)!
        return result
    }

    func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0,
              calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    @Test func countdownUsesEntireDueDayAndRoundsUp() {
        let cal = calendar()
        let due = date(2026, 11, 4, calendar: cal)
        #expect(BillCountdown(dueDate: nil, now: due, calendar: cal).text == "已还清")
        #expect(BillCountdown(dueDate: due, now: date(2026, 11, 2, 23, 59, calendar: cal), calendar: cal) == .days(3))
        #expect(BillCountdown(dueDate: due, now: date(2026, 11, 3, 23, 59, calendar: cal), calendar: cal) == .days(2))
        #expect(BillCountdown(dueDate: due, now: due, calendar: cal) == .days(1))
        #expect(BillCountdown(dueDate: due, now: date(2026, 11, 4, 0, 1, calendar: cal), calendar: cal).text == "剩 24 小时")
        #expect(BillCountdown(dueDate: due, now: date(2026, 11, 4, 12, calendar: cal), calendar: cal) == .hours(12))
        #expect(BillCountdown(dueDate: due, now: date(2026, 11, 4, 23, 59, calendar: cal), calendar: cal) == .hours(1))
        #expect(BillCountdown(dueDate: due, now: date(2026, 11, 5, calendar: cal), calendar: cal).text == "逾期 1 天")
        #expect(BillCountdown(dueDate: due, now: date(2026, 11, 7, 12, calendar: cal), calendar: cal) == .overdue(3))
    }

    @Test func countdownHandlesDaylightSavingBoundaries() {
        let cal = calendar("America/Los_Angeles")
        let spring = date(2026, 3, 8, calendar: cal)
        #expect(BillCountdown(dueDate: spring, now: spring, calendar: cal) == .hours(23))
        let autumn = date(2026, 11, 1, calendar: cal)
        #expect(BillCountdown(dueDate: autumn, now: date(2026, 11, 1, 2, calendar: cal), calendar: cal) == .hours(22))
        #expect(BillCountdown(dueDate: autumn, now: date(2026, 11, 2, calendar: cal), calendar: cal) == .overdue(1))
    }

    @Test func nearestBillIncludesMutedAndExcludesPaidBills() throws {
        let store = try AppStore(inMemory: true)
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        store.now = today.addingTimeInterval(12 * 3600)
        #expect(store.countdown == .paidOff)
        store.add(kind: .loan, name: "未来", cents: 200, due: cal.date(byAdding: .day, value: 10, to: today)!)
        store.add(kind: .creditCard, name: "今天静音", cents: 100, due: today)
        let nearest = try #require(store.pending.first)
        store.mute(nearest, muted: true)
        #expect(store.countdown == BillCountdown(dueDate: today, now: store.now))
        store.setPaid(nearest, paid: true)
        #expect(store.pending.first?.name == "未来")
        #expect(store.countdown == BillCountdown(dueDate: store.pending.first?.dueDate, now: store.now))
        store.add(kind: .loan, name: "逾期", cents: 300, due: cal.date(byAdding: .day, value: -2, to: today)!)
        #expect(store.countdown == .overdue(2))
    }

    @Test func installmentPreservesDataAndRestoresMonthEndAcrossRestarts() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let url = base.appendingPathComponent("bills.store")
        let cal = calendar()
        let store = try AppStore(dataURL: url)
        let january = Bill(kind: .loan, name: "房贷 · 自定义名称", amountInCents: 741_501,
                           dueDate: date(2027, 1, 31, calendar: cal), calendar: cal)
        store.context.insert(january)
        #expect(store.save())
        january.isMuted = true
        january.lastRemindedAt = date(2027, 1, 31, 9, calendar: cal)
        january.snoozeUntil = date(2027, 1, 31, 10, calendar: cal)
        #expect(store.save())
        let previousGeneration = january.reminderGeneration
        let payment = date(2027, 2, 2, 13, calendar: cal)
        #expect(store.advanceInstallment(january, now: payment, calendar: cal))
        #expect(january.isPaid && january.paidAt == payment)
        #expect(january.snoozeUntil == nil && january.lastRemindedAt == nil)
        #expect(january.reminderGeneration != previousGeneration)
        let february = try #require(store.pending.first)
        #expect(january.nextInstallmentID == february.id)
        #expect(february.dateText == "2027-02-28")
        #expect(february.installmentDay == 31)
        #expect(february.name == january.name && february.kind == .loan)
        #expect(february.amountInCents == january.amountInCents)
        #expect(february.isMuted && !february.isPaid)
        #expect(february.snoozeUntil == nil && february.lastRemindedAt == nil && february.paidAt == nil)
        #expect(february.reminderGeneration != previousGeneration)
        #expect(store.total == 741_501 && store.paidTotal == 741_501)
        #expect(!store.advanceInstallment(january, calendar: cal))
        let reopened = try AppStore(dataURL: url)
        let savedFebruary = try #require(reopened.pending.first)
        #expect(savedFebruary.installmentDay == 31)
        #expect(reopened.advanceInstallment(savedFebruary, calendar: cal))
        #expect(reopened.pending.first?.dateText == "2027-03-31")
        #expect(reopened.paidTotal == 1_483_002)
    }

    @Test func installmentHandlesLeapYearsYearEndAndOrdinaryDates() throws {
        let cal = calendar()
        for (year, month, day, expected) in [
            (2028, 1, 31, "2028-02-29"), (2026, 12, 31, "2027-01-31"),
            (2026, 4, 15, "2026-05-15"), (2026, 8, 31, "2026-09-30"),
        ] {
            let bill = Bill(kind: .loan, name: "贷款", amountInCents: 1,
                            dueDate: date(year, month, day, calendar: cal), calendar: cal)
            let next = try #require(bill.nextInstallmentDate(calendar: cal))
            let copy = Bill(kind: .loan, name: "", amountInCents: 1, dueDate: next, calendar: cal)
            #expect(copy.dateText == expected)
        }
    }

    @Test func undoCannotGenerateDuplicateInstallmentsAndTotalsStayExact() throws {
        let store = try AppStore(inMemory: true)
        store.add(kind: .loan, name: "贷款", cents: 10, due: .now)
        store.add(kind: .creditCard, name: "信用卡", cents: 20, due: .now)
        let loan = try #require(store.bills.first { $0.kind == .loan })
        let credit = try #require(store.bills.first { $0.kind == .creditCard })
        #expect(!store.advanceInstallment(credit))
        #expect(store.advanceInstallment(loan))
        #expect(store.paidTotal == 10 && store.total == 30)
        #expect(store.setPaid(credit, paid: true))
        #expect(store.paidTotal == 30 && store.total == 10)
        #expect(store.setPaid(loan, paid: false))
        #expect(!store.advanceInstallment(loan))
        #expect(store.bills.count == 3)
        #expect(store.paidTotal == 20 && store.total == 20)
        store.delete(credit)
        #expect(store.paidTotal == 0)
    }

    @Test func failedInstallmentRollsBackBothPaymentAndNewBillThenRetries() throws {
        enum Failure: Error { case diskFull }
        var fail = false
        let store = try AppStore(inMemory: true, persist: {
            if fail { throw Failure.diskFull }
            try $0.save()
        })
        store.add(kind: .loan, name: "保存失败", cents: 123, due: .now)
        let loan = try #require(store.pending.first)
        store.snooze(loan, now: .now)
        let previousGeneration = loan.reminderGeneration
        let previousSnooze = loan.snoozeUntil
        let previousRevision = store.revision
        var changed = 0
        store.onChange = { changed += 1 }
        fail = true
        #expect(!store.advanceInstallment(loan))
        #expect(!loan.isPaid && loan.paidAt == nil && loan.nextInstallmentID == nil)
        #expect(loan.reminderGeneration == previousGeneration && loan.snoozeUntil == previousSnooze)
        #expect(store.pending.count == 1 && store.history.isEmpty && store.paidTotal == 0)
        #expect(try store.context.fetchCount(FetchDescriptor<Bill>()) == 1)
        #expect(store.revision == previousRevision && changed == 0)
        fail = false
        #expect(store.advanceInstallment(loan))
        #expect(store.pending.count == 1 && store.history.count == 1)
        #expect(changed == 1)
    }

    @Test func appearanceStartsWithSystemAndPersistsBothChoices() throws {
        let suite = "CheckList.Tests.Appearance.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let appearance = AppearanceSettings(defaults: defaults)
        #expect(appearance.theme == nil)
        var applied: [AppTheme] = []
        appearance.onChange = { applied.append($0) }
        appearance.toggle(isDark: false)
        #expect(appearance.theme == .dark)
        #expect(AppearanceSettings(defaults: defaults).theme == .dark)
        appearance.toggle(isDark: true)
        #expect(appearance.theme == .light)
        #expect(AppearanceSettings(defaults: defaults).theme == .light)
        #expect(applied == [.dark, .light])
        defaults.set("unknown", forKey: "appearanceTheme")
        #expect(AppearanceSettings(defaults: defaults).theme == nil)
    }
}
