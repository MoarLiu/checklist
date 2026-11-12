import Foundation
import SwiftData
import Testing
@testable import CheckList

/// Behaviour behind the list actions, undo, editing and the reworked reminder card.
@Suite(.serialized) @MainActor
struct InteractionTests {
    func calendar(_ zone: String = "Asia/Shanghai") -> Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(identifier: zone)!
        return result
    }

    func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0,
              calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    var noon: Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 12))!
    }

    func makeService(_ store: AppStore, now: Date, presented: @escaping (Bill) -> Void = { _ in }) -> ReminderService {
        ReminderService(store: store, settings: ReminderSettings(defaults: MemoryDefaults()),
                        systemNotificationsEnabled: false, clock: { now }, presenter: presented)
    }

    @Test func statusTextUsesOneVocabulary() {
        let cal = calendar()
        let now = date(2026, 11, 12, 10, calendar: cal)
        let bill = Bill(kind: .creditCard, name: "", amountInCents: 1,
                        dueDate: date(2026, 11, 15, calendar: cal), calendar: cal)
        #expect(bill.statusText(now: now, calendar: cal) == "剩 3 天")
        #expect(bill.statusText(now: date(2026, 11, 15, 23, calendar: cal), calendar: cal) == "今天到期")
        #expect(bill.statusText(now: date(2026, 11, 17, 1, calendar: cal), calendar: cal) == "逾期 2 天")
        // The list and the menu bar give the same number for the same bill.
        #expect(BillCountdown(dueDate: bill.dueDate(in: cal), now: now, calendar: cal).text == "剩 3 天")
        bill.isPaid = true
        #expect(bill.statusText(now: now, calendar: cal) == "已还款")
        #expect(Bill.statusText(daysLeft: 1) == "剩 1 天")
        #expect(DueStyle(daysLeft: -1) == .overdue && DueStyle(daysLeft: 0) == .today)
        #expect(DueStyle(daysLeft: 3) == .soon && DueStyle(daysLeft: 4) == .future)
    }

    @Test func amountsAcceptFullWidthDigits() {
        #expect(Money.parse("１００") == 10000)
        #expect(Money.parse("１２．３４") == 1234)
        #expect(Money.parse(" ３２８０.５ ") == 328050)
        // Separators and the ideographic full stop are still not a number.
        #expect(Money.parse("1,234") == nil)
        #expect(Money.parse("１。５") == nil)
        #expect(Money.plain(328050) == "3280.50")
        #expect(Money.plain(5) == "0.05")
        for cents: Int64 in [1, 99, 100, 126_080, Money.maximumCents] {
            #expect(Money.parse(Money.plain(cents)) == cents)
        }
    }

    @Test func monthAfterClampsToTheMonthEnd() throws {
        let cal = calendar()
        #expect(try #require(Bill.monthAfter(date(2027, 1, 31, 15, calendar: cal), calendar: cal)) ==
                date(2027, 2, 28, calendar: cal))
        #expect(try #require(Bill.monthAfter(date(2026, 12, 15, calendar: cal), calendar: cal)) ==
                date(2027, 1, 15, calendar: cal))
        // A remembered day survives a short month.
        #expect(try #require(Bill.monthAfter(date(2027, 2, 28, calendar: cal), day: 31, calendar: cal)) ==
                date(2027, 3, 31, calendar: cal))
    }

    @Test func undoReversesPaymentAndMute() throws {
        let store = try AppStore(inMemory: true)
        store.add(kind: .loan, name: "房贷", cents: 741_500, due: .now)
        let bill = try #require(store.bills.first)
        // "已保存" reports nothing that could be undone.
        #expect(store.toast == "已保存" && store.toastAction == nil)

        #expect(store.setPaid(bill, paid: true))
        #expect(store.toast == "已标记为已还款" && store.toastAction != nil)
        store.undoLastAction()
        #expect(!bill.isPaid && bill.paidAt == nil)
        #expect(store.toast == "已撤销还款" && store.toastAction == nil)
        store.undoLastAction()
        #expect(!bill.isPaid)

        #expect(store.mute(bill, muted: true))
        store.undoLastAction()
        #expect(!bill.isMuted && store.toast == "已开启提醒")
    }

    @Test func undoBringsADeletedBillBackUnchanged() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let url = base.appendingPathComponent("bills.store")
        let store = try AppStore(dataURL: url)
        store.add(kind: .loan, name: "车贷", cents: 298_000, due: .now)
        let bill = try #require(store.bills.first)
        bill.installmentDay = 31
        #expect(store.mute(bill, muted: true))
        let id = bill.id
        let created = bill.createdAt
        let due = bill.dateText

        store.delete(bill)
        #expect(store.bills.isEmpty && store.toast == "已删除账单")
        store.undoLastAction()
        let restored = try #require(store.bills.first)
        #expect(restored.id == id && restored.name == "车贷" && restored.amountInCents == 298_000)
        #expect(restored.kind == .loan && restored.dateText == due && restored.createdAt == created)
        #expect(restored.isMuted && restored.installmentDay == 31 && !restored.isPaid)
        #expect(store.toast == "已恢复账单")
        // Restoring twice must not duplicate the bill.
        #expect(!store.restore(BillSnapshot(restored)))
        #expect(store.bills.count == 1)
        let reopened = try AppStore(dataURL: url)
        #expect(reopened.bills.map(\.id) == [id])
    }

    @Test func undoingNextInstallmentRemovesTheNewBill() throws {
        let store = try AppStore(inMemory: true)
        store.add(kind: .loan, name: "车贷", cents: 298_000, due: .now)
        let loan = try #require(store.pending.first)
        #expect(store.advanceInstallment(loan))
        #expect(store.bills.count == 2)
        store.undoLastAction()
        #expect(store.bills.count == 1 && store.toast == "已撤销下一期")
        #expect(!loan.isPaid && loan.paidAt == nil && loan.nextInstallmentID == nil)
        // Once undone, the installment can be generated again.
        #expect(store.advanceInstallment(loan))
        let next = try #require(store.pending.first)
        // An installment the user has already acted on is left alone.
        #expect(store.setPaid(next, paid: true))
        #expect(!store.undoInstallment(originalID: loan.id, nextID: next.id))
        #expect(store.bills.count == 2 && loan.isPaid)
    }

    @Test func editingRestartsRemindersOnlyForANewDate() throws {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        let store = try AppStore(inMemory: true)
        store.add(kind: .creditCard, name: "花呗", cents: 126_080, due: today)
        let bill = try #require(store.bills.first)
        bill.lastRemindedAt = today
        bill.installmentDay = 31
        #expect(store.save())
        let generation = bill.reminderGeneration

        // A new amount or name keeps today's delivery marker, so the card does not pop again.
        #expect(store.update(bill, kind: .creditCard, name: " 花呗分期 ", cents: 130_000, due: today))
        #expect(bill.name == "花呗分期" && bill.amountInCents == 130_000 && store.toast == "已保存修改")
        #expect(bill.lastRemindedAt == today && bill.reminderGeneration == generation && bill.installmentDay == 31)

        let later = cal.date(byAdding: .day, value: 5, to: today)!
        #expect(store.update(bill, kind: .loan, name: "", cents: 130_000, due: later))
        #expect(bill.kind == .loan && bill.name == "贷款账单" && bill.dueDate == later)
        #expect(bill.lastRemindedAt == nil && bill.installmentDay == nil && bill.reminderGeneration != generation)

        #expect(!store.update(bill, kind: .loan, name: "x", cents: 0, due: later))
        #expect(!store.update(bill, kind: .loan, name: "x", cents: Money.maximumCents + 1, due: later))
        #expect(bill.name == "贷款账单" && store.total == 130_000)
    }

    @Test func failedEditLeavesTheBillUnchanged() throws {
        enum Failure: Error { case diskFull }
        var fail = false
        let store = try AppStore(inMemory: true, persist: {
            if fail { throw Failure.diskFull }
            try $0.save()
        })
        store.add(kind: .creditCard, name: "信用卡", cents: 100, due: .now)
        let bill = try #require(store.bills.first)
        let before = BillSnapshot(bill)
        let generation = bill.reminderGeneration
        fail = true
        let later = Calendar.current.date(byAdding: .day, value: 9, to: .now)!
        #expect(!store.update(bill, kind: .loan, name: "改名", cents: 999, due: later))
        #expect(bill.name == before.name && bill.amountInCents == 100 && bill.kind == .creditCard)
        #expect(bill.dueYear == before.dueYear && bill.dueMonth == before.dueMonth && bill.dueDay == before.dueDay)
        #expect(bill.reminderGeneration == generation && store.errorMessage != nil)
        fail = false
        #expect(store.update(bill, kind: .loan, name: "改名", cents: 999, due: later))
        #expect(bill.name == "改名" && bill.amountInCents == 999)
    }

    @Test func deletingAndEditingReturnToWhereTheyStarted() throws {
        let store = try AppStore(inMemory: true)
        store.add(kind: .creditCard, name: "甲", cents: 100, due: .now)
        store.add(kind: .loan, name: "乙", cents: 200, due: .now)
        let first = store.pending[0]
        let second = store.pending[1]
        #expect(store.setPaid(first, paid: true))

        // Deleting from a list keeps that list on screen.
        store.route = .history
        store.edit(first)
        #expect(store.route == .edit(first.id) && store.editReturn == .history)
        store.route = .history
        store.delete(first)
        #expect(store.route == .history)

        // Deleting from the bill's own page leaves it for the list it was opened from.
        store.openDetail(second)
        store.edit(second)
        #expect(store.editReturn == .detail(second.id))
        store.route = .detail(second.id)
        store.delete(second)
        #expect(store.route == .home && store.bills.isEmpty)
    }

    @Test func copyingACardBillPrefillsNextMonthWithoutAnAmount() throws {
        let cal = calendar()
        let january = Bill(kind: .creditCard, name: "招商银行信用卡", amountInCents: 328_050,
                           dueDate: date(2027, 1, 31, calendar: cal), calendar: cal)
        let draft = BillDraft(january, calendar: cal)
        #expect(draft.kind == .creditCard && draft.name == "招商银行信用卡" && draft.source == "招商银行信用卡")
        // Month end is clamped, as for loan installments.
        #expect(draft.due == date(2027, 2, 28, calendar: cal))

        let store = try AppStore(inMemory: true)
        store.add(kind: .creditCard, name: "花呗", cents: 126_080, due: .now)
        let bill = try #require(store.bills.first)
        store.copyToNextMonth(bill)
        #expect(store.route == .add && store.draft?.name == "花呗")
        // Nothing is created until the amount is filled in and saved.
        #expect(store.bills.count == 1)
        store.add(kind: .creditCard, name: "花呗", cents: 98_000, due: try #require(store.draft?.due))
        #expect(store.bills.count == 2 && store.draft == nil && store.route == .home)
        // A plain "add" never starts from an old draft.
        store.copyToNextMonth(bill)
        store.route = .history
        store.open(.add)
        #expect(store.draft == nil)
        store.copyToNextMonth(bill)
        store.beginAdding()
        #expect(store.draft == nil && store.route == .add)
    }

    @Test func snoozeChoicesDependOnTheTimeOfDay() {
        let cal = calendar()
        let choices = SnoozeOptions.make(now: date(2026, 11, 12, 10, calendar: cal), hour: 9, minute: 30, calendar: cal)
        #expect(choices.map(\.title) == ["1 小时后", "今晚 20:00", "明天 09:30"])
        #expect(choices.map(\.date) == [date(2026, 11, 12, 11, calendar: cal), date(2026, 11, 12, 20, calendar: cal),
                                        date(2026, 11, 13, 9, 30, calendar: cal)])
        #expect(choices.map(\.confirmation) == ["1 小时后再提醒你", "今晚 20:00 再提醒你", "明天 09:30 再提醒你"])
        // From 19:00 on, "tonight" would be no later than the one-hour choice.
        for (hour, minute) in [(19, 0), (21, 15), (23, 30)] {
            let late = SnoozeOptions.make(now: date(2026, 11, 12, hour, minute, calendar: cal),
                                          hour: 9, minute: 30, calendar: cal)
            #expect(late.map(\.title) == ["1 小时后", "明天 09:30"])
        }
    }

    @Test func dismissingACardKeepsTheBillQuietAndShowsTheNext() async throws {
        let now = noon
        let store = try AppStore(inMemory: true)
        store.add(kind: .creditCard, name: "第一笔", cents: 100, due: now)
        store.add(kind: .loan, name: "第二笔", cents: 200, due: now)
        store.add(kind: .loan, name: "未到期", cents: 300, due: Calendar.current.date(byAdding: .day, value: 4, to: now)!)
        let first = store.pending[0]
        let second = store.pending[1]
        var presented: [UUID] = []
        let service = makeService(store, now: now) { presented.append($0.id) }
        await service.reconcile()
        #expect(service.activeBillID == first.id)
        // Only the other bill that is already due waits behind the card.
        #expect(service.queuedCount(excluding: first.id) == 1)

        #expect(service.handle(.dismiss, billID: first.id))
        #expect(service.activeBillID == nil)
        #expect(!first.isPaid && !first.isMuted && first.snoozeUntil == nil && first.lastRemindedAt == now)
        await service.reconcile()
        #expect(presented == [first.id, second.id])
        #expect(service.queuedCount(excluding: second.id) == 0)
    }

    @Test func cardSnoozeChoiceSetsTheChosenTime() async throws {
        let now = noon
        let store = try AppStore(inMemory: true)
        store.add(kind: .creditCard, name: "信用卡", cents: 100, due: now)
        let bill = try #require(store.bills.first)
        let service = makeService(store, now: now)
        await service.reconcile()
        let generation = bill.reminderGeneration
        let tomorrow = try #require(service.snoozeChoices().last)
        #expect(tomorrow.title == "明天 09:00")
        #expect(service.handle(.snoozeUntil(tomorrow), billID: bill.id))
        #expect(bill.snoozeUntil == tomorrow.date && service.activeBillID == nil)
        // Notifications scheduled before the choice must not fire in its place.
        #expect(bill.reminderGeneration != generation && store.toast == "明天 09:00 再提醒你")
        #expect(bill.nextReminder(now: now, hour: 9, minute: 0) == tomorrow.date)
    }

    @Test func menuBarModePersistsAndAnnouncesChanges() {
        let defaults = MemoryDefaults()
        let appearance = AppearanceSettings(defaults: defaults)
        #expect(appearance.menuBarMode == .full)
        var changes = 0
        appearance.onDisplayChange = { changes += 1 }
        appearance.setMenuBarMode(.icon)
        appearance.setMenuBarMode(.icon)
        #expect(appearance.menuBarMode == .icon && changes == 1)
        #expect(AppearanceSettings(defaults: defaults).menuBarMode == .icon)
        defaults.set("unknown", forKey: "menuBarMode")
        #expect(AppearanceSettings(defaults: defaults).menuBarMode == .full)
        #expect(MenuBarMode.allCases.map(\.title) == ["金额与倒计时", "仅倒计时", "仅图标"])
    }

    @Test func reminderSettingsWriteOnlyWhatChanged() {
        let defaults = MemoryDefaults()
        let settings = ReminderSettings(defaults: defaults)
        // Construction must not write anything back.
        #expect(defaults.storedKeys.isEmpty)
        #expect(settings.hour == 9 && settings.minute == 0 && settings.sound && !settings.permissionPromptDismissed)
        settings.permissionPromptDismissed = true
        settings.hour = 21
        #expect(defaults.storedKeys == ["permissionPromptDismissed", "reminderHour"])
        let reloaded = ReminderSettings(defaults: defaults)
        #expect(reloaded.permissionPromptDismissed && reloaded.hour == 21)
        // Out-of-range values are clamped on load.
        defaults.set(99, forKey: "reminderHour")
        defaults.set(-5, forKey: "reminderMinute")
        let clamped = ReminderSettings(defaults: defaults)
        #expect(clamped.hour == 23 && clamped.minute == 0)
    }
}
