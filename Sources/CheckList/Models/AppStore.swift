import AppKit
import Observation
import SwiftData

enum AppRoute: Equatable {
    case home, add, history, detail(UUID)
}

@MainActor @Observable
final class AppStore {
    let container: ModelContainer
    var bills: [Bill] = []
    var route: AppRoute = .home
    var detailSource: AppRoute = .home
    var errorMessage: String?
    var toast: String?
    var now = Date()
    var revision = 0
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored var onClockChange: (() -> Void)?
    @ObservationIgnored var showWindow: (() -> Void)?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private let persist: (ModelContext) throws -> Void

    init(inMemory: Bool = false, dataURL: URL? = nil,
         persist: @escaping (ModelContext) throws -> Void = { try $0.save() }) throws {
        self.persist = persist
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
    var dueCount: Int { pending.filter { $0.daysLeft(now: now) == 0 }.count }
    var overdueCount: Int { pending.filter { $0.daysLeft(now: now) < 0 }.count }
    var hasUrgent: Bool { dueCount + overdueCount > 0 }

    func reload() throws { bills = try context.fetch(FetchDescriptor<Bill>()) }
    func bill(_ id: UUID) -> Bill? { bills.first { $0.id == id } }

    @discardableResult
    func saveReminderState() -> Bool {
        do {
            try persist(context)
            return true
        } catch {
            context.rollback()
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
        if save() { route = .home; say("已保存") }
    }

    @discardableResult
    func setPaid(_ bill: Bill, paid: Bool) -> Bool {
        bill.isPaid = paid
        bill.paidAt = paid ? .now : nil
        bill.snoozeUntil = nil
        bill.lastRemindedAt = nil
        bill.reminderGeneration = UUID().uuidString
        guard save() else { return false }
        say(paid ? "已标记为已还款" : "已撤销还款")
        return true
    }

    @discardableResult
    func mute(_ bill: Bill, muted: Bool) -> Bool {
        bill.isMuted = muted
        bill.snoozeUntil = nil
        if !muted { bill.lastRemindedAt = nil }
        bill.reminderGeneration = UUID().uuidString
        guard save() else { return false }
        say(muted ? "此账单不再提醒" : "已开启提醒")
        return true
    }

    @discardableResult
    func snooze(_ bill: Bill, now: Date = .now) -> Bool {
        bill.snoozeUntil = now.addingTimeInterval(3600)
        bill.reminderGeneration = UUID().uuidString
        guard save() else { return false }
        say("1 小时后再提醒你")
        return true
    }

    func delete(_ bill: Bill) {
        context.delete(bill)
        if save() { route = detailSource; say("已删除账单") }
    }

    func open(_ route: AppRoute) {
        self.route = route
        showWindow?()
    }

    func openDetail(_ bill: Bill, show: Bool = false) {
        detailSource = bill.isPaid ? .history : .home
        route = .detail(bill.id)
        if show { showWindow?() }
    }

    func say(_ message: String) {
        toastTask?.cancel()
        toast = message
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2.2))
            if !Task.isCancelled { toast = nil }
        }
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
