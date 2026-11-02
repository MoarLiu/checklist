import Foundation
import SwiftData
import Testing
import UserNotifications
@testable import CheckList

@MainActor
final class FakeNotifications: NotificationClient {
    var permissionValue = NotificationPermission.allowed
    var deliveredValues: [DeliveredReminder] = []
    var pendingValues: [ScheduledReminder] = []
    var added: [ScheduledReminder] = []
    var removedPending: [String] = []
    var removedDelivered: [String] = []
    var calls = 0
    func install(delegate: UNUserNotificationCenterDelegate) { calls += 1 }
    func permission() async -> NotificationPermission { calls += 1; return permissionValue }
    func requestPermission() async throws { calls += 1 }
    func delivered() async -> [DeliveredReminder] { calls += 1; return deliveredValues }
    func pending() async -> [PendingReminder] {
        calls += 1
        return pendingValues.map { PendingReminder(identifier: $0.identifier, reminder: $0) }
    }
    func add(_ reminder: ScheduledReminder) async throws {
        calls += 1
        added.append(reminder)
        pendingValues.removeAll { $0.identifier == reminder.identifier }
        pendingValues.append(reminder)
    }
    func removePending(_ identifiers: [String]) {
        calls += 1
        removedPending += identifiers
        pendingValues.removeAll { identifiers.contains($0.identifier) }
    }
    func removeDelivered(_ identifiers: [String]) {
        calls += 1
        removedDelivered += identifiers
        deliveredValues.removeAll { identifiers.contains($0.identifier) }
    }
}

@Suite(.serialized) @MainActor
struct ReminderTests {
    func makeSettings() -> ReminderSettings {
        let defaults = UserDefaults(suiteName: "CheckList.Tests")!
        defaults.removePersistentDomain(forName: "CheckList.Tests")
        return ReminderSettings(defaults: defaults)
    }
    var now: Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 12))!
    }
    func makeStore(due: Date? = nil) throws -> AppStore {
        let store = try AppStore(inMemory: true)
        store.add(kind: .creditCard, name: "测试", cents: 1234, due: due ?? now)
        return store
    }
    func delivered(_ bill: Bill, generation: String? = nil, date: Date? = nil) -> DeliveredReminder {
        DeliveredReminder(identifier: "delivered", billID: bill.id,
                          generation: generation ?? bill.reminderGeneration, date: date ?? now)
    }

    @Test func demoDoesNotTouchProductionNotifications() async throws {
        let store = try makeStore()
        let fake = FakeNotifications()
        var presented = 0
        let service = ReminderService(store: store, settings: makeSettings(), systemNotificationsEnabled: false, client: fake,
                                      clock: { now }, presenter: { _ in presented += 1 })
        await service.reconcile()
        #expect(fake.calls == 0)
        #expect(presented == 1)
    }

    @Test func dailyTickKeepsUnchangedSystemRequests() async throws {
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now)!
        let store = try makeStore(due: tomorrow)
        let fake = FakeNotifications()
        let service = ReminderService(store: store, settings: makeSettings(), client: fake, clock: { now }, presenter: { _ in })
        await service.reconcile()
        let initial = fake.added.count
        #expect(initial == 8)
        await service.reconcile()
        #expect(fake.added.count == initial)
        #expect(fake.removedPending.isEmpty)
        store.setPaid(try #require(store.bills.first), paid: true)
        await service.reconcile()
        #expect(fake.pendingValues.isEmpty)
        #expect(fake.removedPending.count == initial)
    }

    @Test func staleDeliveredNotificationDoesNotSuppressReenabledReminder() async throws {
        let store = try makeStore()
        let bill = try #require(store.bills.first)
        let stale = delivered(bill)
        store.mute(bill, muted: true)
        store.mute(bill, muted: false)
        let fake = FakeNotifications()
        fake.deliveredValues = [stale]
        var presented: [UUID] = []
        let service = ReminderService(store: store, settings: makeSettings(), client: fake, clock: { now }, presenter: { presented.append($0.id) })
        await service.reconcile()
        #expect(presented == [bill.id])
        #expect(fake.removedDelivered == ["delivered"])
    }

    @Test func freshDeliveredNotificationIsAbsorbedWithoutDuplicatePanel() async throws {
        let store = try makeStore()
        let bill = try #require(store.bills.first)
        let fake = FakeNotifications()
        fake.deliveredValues = [delivered(bill)]
        var presented = 0
        let service = ReminderService(store: store, settings: makeSettings(), client: fake, clock: { now }, presenter: { _ in presented += 1 })
        await service.reconcile()
        #expect(bill.lastRemindedAt == now)
        #expect(presented == 0)
    }

    @Test func saveFailurePreservesCardAndPaymentState() async throws {
        enum Failure: Error { case diskFull }
        var fail = false
        let store = try AppStore(inMemory: true, persist: {
            if fail { throw Failure.diskFull }
            try $0.save()
        })
        store.add(kind: .loan, name: "测试", cents: 100, due: now)
        let bill = try #require(store.bills.first)
        let generation = bill.reminderGeneration
        let service = ReminderService(store: store, settings: makeSettings(), systemNotificationsEnabled: false,
                                      clock: { now }, presenter: { _ in })
        await service.reconcile()
        #expect(service.activeBillID == bill.id)
        fail = true
        #expect(!service.handle(.paid, billID: bill.id))
        #expect(service.activeBillID == bill.id)
        #expect(!bill.isPaid)
        #expect(bill.reminderGeneration == generation)
        #expect(store.errorMessage != nil)
        fail = false
        #expect(service.handle(.paid, billID: bill.id))
        #expect(service.activeBillID == nil)
        #expect(bill.isPaid)
    }

    @Test func deliveryMarkerFailureDoesNotSilentlyHideBill() async throws {
        enum Failure: Error { case diskFull }
        var fail = false
        let store = try AppStore(inMemory: true, persist: {
            if fail { throw Failure.diskFull }
            try $0.save()
        })
        store.add(kind: .loan, name: "测试", cents: 100, due: now)
        let bill = try #require(store.bills.first)
        fail = true
        var presented = 0
        let service = ReminderService(store: store, settings: makeSettings(), systemNotificationsEnabled: false,
                                      clock: { now }, presenter: { _ in presented += 1 })
        await service.reconcile()
        #expect(bill.lastRemindedAt == nil)
        #expect(presented == 0)
        fail = false
        await service.reconcile()
        #expect(presented == 1)
    }

    @Test func queueProcessesSecondBillAfterSuccessfulSnooze() async throws {
        let store = try makeStore()
        store.add(kind: .loan, name: "第二笔", cents: 100, due: now)
        let first = try #require(store.pending.first)
        let second = try #require(store.pending.last)
        var presented: [UUID] = []
        let service = ReminderService(store: store, settings: makeSettings(), systemNotificationsEnabled: false,
                                      clock: { now }, presenter: { presented.append($0.id) })
        await service.reconcile()
        #expect(service.handle(.snooze, billID: first.id))
        #expect(first.snoozeUntil == now.addingTimeInterval(3600))
        await service.reconcile()
        #expect(service.activeBillID == second.id)
        #expect(presented == [first.id, second.id])
    }

    @Test func failedSnoozedDeliveryRetainsDeadlineForRetry() async throws {
        enum Failure: Error { case diskFull }
        var fail = false
        let store = try AppStore(inMemory: true, persist: {
            if fail { throw Failure.diskFull }
            try $0.save()
        })
        store.add(kind: .loan, name: "稍后提醒", cents: 100, due: now)
        let bill = try #require(store.bills.first)
        let deadline = now.addingTimeInterval(-10)
        bill.snoozeUntil = deadline
        #expect(store.save())
        fail = true
        var presented = 0
        let service = ReminderService(store: store, settings: makeSettings(), systemNotificationsEnabled: false,
                                      clock: { now }, presenter: { _ in presented += 1 })
        await service.reconcile()
        #expect(bill.lastRemindedAt == nil)
        #expect(bill.snoozeUntil == deadline)
        #expect(presented == 0)
        fail = false
        await service.reconcile()
        #expect(presented == 1)
        #expect(bill.snoozeUntil == nil)
    }

    @Test func failedSystemDeliveryAbsorptionRestoresPreviousValues() async throws {
        enum Failure: Error { case diskFull }
        var fail = false
        let store = try AppStore(inMemory: true, persist: {
            if fail { throw Failure.diskFull }
            try $0.save()
        })
        store.add(kind: .creditCard, name: "系统提醒", cents: 100, due: now)
        let bill = try #require(store.bills.first)
        let deadline = now.addingTimeInterval(-10)
        bill.snoozeUntil = deadline
        #expect(store.save())
        let client = FakeNotifications()
        client.deliveredValues = [delivered(bill)]
        let service = ReminderService(store: store, settings: makeSettings(), client: client,
                                      clock: { now }, presenter: { _ in })
        fail = true
        await service.reconcile()
        #expect(bill.lastRemindedAt == nil)
        #expect(bill.snoozeUntil == deadline)
        #expect(client.deliveredValues.count == 1)
        fail = false
        await service.reconcile()
        #expect(bill.lastRemindedAt == now)
        #expect(bill.snoozeUntil == nil)
        #expect(service.activeBillID == nil)
    }

    @Test func plannerReservesFirstNotificationForEachBill() throws {
        let store = try AppStore(inMemory: true)
        for offset in 0..<10 {
            store.add(kind: .loan, name: "\(offset)", cents: 100,
                      due: Calendar.current.date(byAdding: .day, value: offset + 1, to: now)!)
        }
        let planned = NotificationPlanner.make(bills: store.pending, now: now, hour: 9, minute: 0, sound: true)
        #expect(planned.count == 60)
        #expect(Set(planned.map(\.billID)).count == 10)
        #expect(Set(planned.map(\.identifier)).count == planned.count)
        let snoozed = try #require(store.pending.first)
        store.snooze(snoozed, now: now)
        let plan = NotificationPlanner.make(bills: [snoozed], now: now, hour: 9, minute: 0, sound: false)
        #expect(plan.first?.date == now.addingTimeInterval(3600))
        #expect(plan.allSatisfy { !$0.sound && $0.generation == snoozed.reminderGeneration })
    }

    @Test func staleNotificationActionCannotRepayAnUndoneBill() throws {
        let store = try makeStore()
        let bill = try #require(store.bills.first)
        let oldGeneration = bill.reminderGeneration
        store.setPaid(bill, paid: true)
        store.setPaid(bill, paid: false)
        let service = ReminderService(store: store, settings: makeSettings(), systemNotificationsEnabled: false,
                                      clock: { now }, presenter: { _ in })
        service.handleNotificationAction("PAID", billID: bill.id, generation: oldGeneration)
        #expect(!bill.isPaid)
        service.handleNotificationAction("PAID", billID: bill.id, generation: bill.reminderGeneration)
        #expect(bill.isPaid)
    }
}
