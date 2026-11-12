import AppKit
import Observation
import SwiftData

enum AppRoute: Equatable {
    case home, add, history, detail(UUID), edit(UUID)
}

/// A bill the form starts from without it existing yet: repeating a monthly card bill.
struct BillDraft: Equatable {
    let kind: BillKind
    let name: String
    let due: Date
    /// The bill the draft was copied from, named in the form's hint.
    let source: String

    init(_ bill: Bill, calendar: Calendar = .current) {
        kind = bill.kind
        name = bill.name
        source = bill.name
        due = Bill.monthAfter(bill.dueDate(in: calendar), day: bill.installmentDay ?? bill.dueDay, calendar: calendar)
            ?? bill.dueDate(in: calendar)
    }
}

@MainActor
struct ReminderDeliverySnapshot {
    let bill: Bill
    let id: UUID
    let lastRemindedAt: Date?
    let snoozeUntil: Date?

    init(_ bill: Bill) {
        self.bill = bill
        id = bill.id
        lastRemindedAt = bill.lastRemindedAt
        snoozeUntil = bill.snoozeUntil
    }

    func restore(_ target: Bill) {
        target.lastRemindedAt = lastRemindedAt
        target.snoozeUntil = snoozeUntil
    }
}

/// Everything needed to bring a deleted bill back unchanged.
@MainActor
struct BillSnapshot {
    let id: UUID
    let kindRaw: String
    let name: String
    let amountInCents: Int64
    let dueYear: Int
    let dueMonth: Int
    let dueDay: Int
    let isPaid: Bool
    let isMuted: Bool
    let snoozeUntil: Date?
    let lastRemindedAt: Date?
    let createdAt: Date
    let paidAt: Date?
    let installmentDay: Int?
    let nextInstallmentID: UUID?

    init(_ bill: Bill) {
        id = bill.id
        kindRaw = bill.kindRaw
        name = bill.name
        amountInCents = bill.amountInCents
        dueYear = bill.dueYear
        dueMonth = bill.dueMonth
        dueDay = bill.dueDay
        isPaid = bill.isPaid
        isMuted = bill.isMuted
        snoozeUntil = bill.snoozeUntil
        lastRemindedAt = bill.lastRemindedAt
        createdAt = bill.createdAt
        paidAt = bill.paidAt
        installmentDay = bill.installmentDay
        nextInstallmentID = bill.nextInstallmentID
    }

    /// A fresh reminder generation is kept: notifications from before the deletion stay invalid.
    func makeBill() -> Bill {
        let bill = Bill(kind: BillKind(rawValue: kindRaw) ?? .creditCard, name: name,
                        amountInCents: amountInCents, dueDate: .now, now: createdAt)
        bill.id = id
        bill.kindRaw = kindRaw
        bill.dueYear = dueYear
        bill.dueMonth = dueMonth
        bill.dueDay = dueDay
        bill.isPaid = isPaid
        bill.isMuted = isMuted
        bill.snoozeUntil = snoozeUntil
        bill.lastRemindedAt = lastRemindedAt
        bill.paidAt = paidAt
        bill.installmentDay = installmentDay
        bill.nextInstallmentID = nextInstallmentID
        return bill
    }
}

@MainActor @Observable
final class AppStore {
    let container: ModelContainer
    let appearance: AppearanceSettings
    var bills: [Bill] = []
    var route: AppRoute = .home
    var detailSource: AppRoute = .home
    /// Where the edit form returns to: the list or detail page it was opened from.
    var editReturn: AppRoute = .home
    /// The row the keyboard acts on in the bill lists.
    var selectedBillID: UUID?
    /// Set while the add form is filling in a copy of an existing monthly bill.
    var draft: BillDraft?
    var errorMessage: String?
    var toast: String?
    /// Reverses the action the current toast reports. Cleared together with the toast.
    var toastAction: (() -> Void)?
    var now = Date()
    var revision = 0
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored var onClockChange: (() -> Void)?
    @ObservationIgnored var showWindow: (() -> Void)?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private let persist: (ModelContext) throws -> Void

    init(inMemory: Bool = false, dataURL: URL? = nil, appearanceDefaults: UserDefaults = .standard,
         persist: @escaping (ModelContext) throws -> Void = { try $0.save() }) throws {
        self.persist = persist
        appearance = AppearanceSettings(defaults: appearanceDefaults)
        let schema = Schema([Bill.self])
        let config: ModelConfiguration
        if let dataURL {
            try FileManager.default.createDirectory(at: dataURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            config = ModelConfiguration(schema: schema, url: dataURL)
        } else {
            config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        }
        container = try ModelContainer(for: schema, configurations: [config])
        try reload()
    }

    var context: ModelContext { container.mainContext }
    var pending: [Bill] { bills.filter { !$0.isPaid }.sorted { $0.dueDate == $1.dueDate ? $0.createdAt < $1.createdAt : $0.dueDate < $1.dueDate } }
    var history: [Bill] { bills.filter(\.isPaid).sorted { ($0.paidAt ?? $0.createdAt) > ($1.paidAt ?? $1.createdAt) } }
    var total: Int64 { pending.reduce(0) { $0 + $1.amountInCents } }
    var paidTotal: Int64 { history.reduce(0) { $0 + $1.amountInCents } }
    var countdown: BillCountdown { BillCountdown(dueDate: pending.first?.dueDate, now: now) }
    var dueCount: Int { pending.filter { $0.daysLeft(now: now) == 0 }.count }
    var overdueCount: Int { pending.filter { $0.daysLeft(now: now) < 0 }.count }

    func reload() throws { bills = try context.fetch(FetchDescriptor<Bill>()) }
    func bill(_ id: UUID) -> Bill? { bills.first { $0.id == id } }

    @discardableResult
    func saveReminderState(restoring snapshots: [ReminderDeliverySnapshot]) -> Bool {
        do {
            try persist(context)
            return true
        } catch {
            context.rollback()
            try? reload()
            // SwiftData on macOS 26 may leave @Model property caches unchanged
            // after rollback. Restore the visible values as well as the context.
            for snapshot in snapshots {
                snapshot.restore(snapshot.bill)
                if let current = bill(snapshot.id), current !== snapshot.bill {
                    snapshot.restore(current)
                }
            }
            errorMessage = "无法保存提醒状态：\(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func save() -> Bool {
        do {
            try persist(context)
            try reload()
            revision += 1
            onChange?()
            return true
        } catch {
            context.rollback()
            try? reload()
            errorMessage = "账单未能保存：\(error.localizedDescription)"
            return false
        }
    }

    func add(kind: BillKind, name: String, cents: Int64, due: Date) {
        guard cents > 0, cents <= Money.maximumCents else { return }
        context.insert(Bill(kind: kind, name: name, amountInCents: cents, dueDate: due))
        if save() { route = .home; draft = nil; say("已保存") }
    }

    /// Card bills repeat every month with a fresh amount, so the form starts filled in for the next one.
    func copyToNextMonth(_ bill: Bill) {
        draft = BillDraft(bill)
        route = .add
        showWindow?()
    }

    /// Edits the fields the form offers. Reminders follow the new date and amount on the next sync.
    @discardableResult
    func update(_ bill: Bill, kind: BillKind, name: String, cents: Int64, due: Date,
                calendar: Calendar = .current) -> Bool {
        guard self.bill(bill.id) === bill, cents > 0, cents <= Money.maximumCents else { return false }
        let previous = BillSnapshot(bill)
        let previousGeneration = bill.reminderGeneration
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = calendar.dateComponents([.year, .month, .day], from: due)
        let dateChanged = parts.year != bill.dueYear || parts.month != bill.dueMonth || parts.day != bill.dueDay
        bill.kindRaw = kind.rawValue
        bill.name = trimmed.isEmpty ? kind.defaultName : trimmed
        bill.amountInCents = cents
        bill.dueYear = parts.year!
        bill.dueMonth = parts.month!
        bill.dueDay = parts.day!
        if dateChanged {
            // A new date is a new schedule: later installments follow its day, and the
            // delivery marker of the old date must not swallow the new one.
            bill.installmentDay = nil
            bill.lastRemindedAt = nil
            bill.snoozeUntil = nil
            bill.reminderGeneration = UUID().uuidString
        }
        guard save() else {
            // Restore @Model caches as well as SwiftData's transaction rollback.
            func restore(_ target: Bill) {
                target.kindRaw = previous.kindRaw
                target.name = previous.name
                target.amountInCents = previous.amountInCents
                target.dueYear = previous.dueYear
                target.dueMonth = previous.dueMonth
                target.dueDay = previous.dueDay
                target.installmentDay = previous.installmentDay
                target.lastRemindedAt = previous.lastRemindedAt
                target.snoozeUntil = previous.snoozeUntil
                target.reminderGeneration = previousGeneration
            }
            restore(bill)
            if let current = self.bill(bill.id), current !== bill { restore(current) }
            return false
        }
        say("已保存修改")
        return true
    }

    @discardableResult
    func setPaid(_ bill: Bill, paid: Bool) -> Bool {
        bill.isPaid = paid
        bill.paidAt = paid ? .now : nil
        bill.snoozeUntil = nil
        bill.lastRemindedAt = nil
        bill.reminderGeneration = UUID().uuidString
        guard save() else { return false }
        if paid {
            let id = bill.id
            say("已标记为已还款", undo: { [weak self] in
                guard let self, let target = self.bill(id), target.isPaid else { return }
                self.setPaid(target, paid: false)
            })
        } else {
            say("已撤销还款")
        }
        return true
    }

    /// Repayment and the next installment are persisted together in one save.
    @discardableResult
    func advanceInstallment(_ bill: Bill, now: Date = .now, calendar: Calendar = .current) -> Bool {
        guard self.bill(bill.id) === bill, bill.kind == .loan, !bill.isPaid else { return false }
        if let nextID = bill.nextInstallmentID, self.bill(nextID) != nil {
            errorMessage = "这期账单已生成下一期，请直接查看已有的下一期账单。"
            return false
        }
        guard let due = bill.nextInstallmentDate(calendar: calendar) else {
            errorMessage = "无法计算下一期还款日期，请检查账单日期。"
            return false
        }
        let next = Bill(kind: bill.kind, name: bill.name, amountInCents: bill.amountInCents,
                        dueDate: due, now: now, calendar: calendar)
        next.installmentDay = bill.installmentDay ?? bill.dueDay
        next.isMuted = bill.isMuted
        let previousPaidAt = bill.paidAt
        let previousSnooze = bill.snoozeUntil
        let previousReminded = bill.lastRemindedAt
        let previousGeneration = bill.reminderGeneration
        let previousNextID = bill.nextInstallmentID
        bill.isPaid = true
        bill.paidAt = now
        bill.snoozeUntil = nil
        bill.lastRemindedAt = nil
        bill.reminderGeneration = UUID().uuidString
        bill.nextInstallmentID = next.id
        context.insert(next)
        guard save() else {
            // Restore @Model caches as well as SwiftData's transaction rollback.
            func restore(_ target: Bill) {
                target.isPaid = false
                target.paidAt = previousPaidAt
                target.snoozeUntil = previousSnooze
                target.lastRemindedAt = previousReminded
                target.reminderGeneration = previousGeneration
                target.nextInstallmentID = previousNextID
            }
            restore(bill)
            if let current = self.bill(bill.id), current !== bill { restore(current) }
            return false
        }
        let originalID = bill.id
        let nextID = next.id
        say("本期已还款，下一期还款日 \(next.dateText)", undo: { [weak self] in
            self?.undoInstallment(originalID: originalID, nextID: nextID)
        })
        return true
    }

    /// Reverses a just-made "next installment" as a whole: the new bill goes, the old one is unpaid again.
    @discardableResult
    func undoInstallment(originalID: UUID, nextID: UUID) -> Bool {
        guard let original = bill(originalID), original.isPaid, original.nextInstallmentID == nextID else { return false }
        // Leave an installment the user has already acted on.
        if let next = bill(nextID) {
            guard !next.isPaid, next.nextInstallmentID == nil else { return false }
            context.delete(next)
        }
        original.isPaid = false
        original.paidAt = nil
        original.nextInstallmentID = nil
        original.reminderGeneration = UUID().uuidString
        guard save() else { return false }
        say("已撤销下一期")
        return true
    }

    @discardableResult
    func mute(_ bill: Bill, muted: Bool) -> Bool {
        bill.isMuted = muted
        bill.snoozeUntil = nil
        if !muted { bill.lastRemindedAt = nil }
        bill.reminderGeneration = UUID().uuidString
        guard save() else { return false }
        if muted {
            let id = bill.id
            say("此账单不再提醒", undo: { [weak self] in
                guard let self, let target = self.bill(id), target.isMuted else { return }
                self.mute(target, muted: false)
            })
        } else {
            say("已开启提醒")
        }
        return true
    }

    @discardableResult
    func snooze(_ bill: Bill, now: Date = .now) -> Bool {
        snooze(bill, until: now.addingTimeInterval(3600), message: "1 小时后再提醒你")
    }

    @discardableResult
    func snooze(_ bill: Bill, until: Date, message: String = "稍后再提醒你") -> Bool {
        bill.snoozeUntil = until
        bill.reminderGeneration = UUID().uuidString
        guard save() else { return false }
        say(message)
        return true
    }

    func delete(_ bill: Bill) {
        let snapshot = BillSnapshot(bill)
        context.delete(bill)
        guard save() else { return }
        // Leave a page whose bill is gone; a list keeps its place.
        switch route {
        case .detail(let id) where id == snapshot.id, .edit(let id) where id == snapshot.id:
            route = detailSource
        default: break
        }
        say("已删除账单", undo: { [weak self] in self?.restore(snapshot) })
    }

    @discardableResult
    func restore(_ snapshot: BillSnapshot) -> Bool {
        guard bill(snapshot.id) == nil else { return false }
        context.insert(snapshot.makeBill())
        guard save() else { return false }
        say("已恢复账单")
        return true
    }

    func open(_ route: AppRoute) {
        // A plain "add" starts empty; only copyToNextMonth leaves a draft for the form.
        if route == .add { draft = nil }
        self.route = route
        showWindow?()
    }

    func beginAdding() {
        draft = nil
        route = .add
    }

    func openDetail(_ bill: Bill, show: Bool = false) {
        detailSource = bill.isPaid ? .history : .home
        route = .detail(bill.id)
        if show { showWindow?() }
    }

    func edit(_ bill: Bill) {
        editReturn = route
        route = .edit(bill.id)
    }

    func say(_ message: String, undo: (() -> Void)? = nil) {
        toastTask?.cancel()
        toast = message
        toastAction = undo
        // An undoable toast stays long enough to be read and clicked.
        let duration: Duration = undo == nil ? .seconds(2.2) : .seconds(5)
        toastTask = Task {
            try? await Task.sleep(for: duration)
            if !Task.isCancelled {
                toast = nil
                toastAction = nil
            }
        }
    }

    func undoLastAction() {
        guard let action = toastAction else { return }
        toastTask?.cancel()
        toast = nil
        toastAction = nil
        action()
    }

    func seedDemo() {
        guard bills.isEmpty else { return }
        let entries: [(BillKind, String, Int64, Int)] = [
            (.creditCard, "招商银行信用卡", 328050, 0),
            (.loan, "房贷 · 工商银行", 741500, 6),
            (.creditCard, "花呗", 126080, 3),
            (.loan, "车贷", 298000, 15),
        ]
        for (kind, name, cents, days) in entries {
            context.insert(Bill(kind: kind, name: name, amountInCents: cents,
                                dueDate: Calendar.current.date(byAdding: .day, value: days, to: .now)!))
        }
        _ = save()
    }
}
