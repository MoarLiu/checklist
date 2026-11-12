import SwiftUI

struct RootView: View {
    @Bindable var store: AppStore
    let reminders: ReminderService?
    let settings: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollViewReader { proxy in
            HStack(spacing: 0) {
                sidebar
                Rectangle().fill(Design.sidebarDivider).frame(width: 1)
                ScrollView {
                    Group {
                        switch store.route {
                        case .home: HomeView(store: store, reminders: reminders)
                        case .history: HistoryView(store: store)
                        case .add: BillFormView(store: store, reminders: reminders, editing: nil, draft: store.draft)
                        case .edit(let id):
                            if let bill = store.bill(id) {
                                BillFormView(store: store, reminders: reminders, editing: bill)
                            } else {
                                HomeView(store: store, reminders: reminders)
                            }
                        case .detail(let id):
                            if let bill = store.bill(id) {
                                BillDetailView(store: store, bill: bill)
                            } else {
                                HomeView(store: store, reminders: reminders)
                            }
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .onChange(of: store.selectedBillID) { _, id in
                    guard let id else { return }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo(id) }
                }
            }
        }
        .foregroundStyle(Design.body)
        .frame(minWidth: 760, maxWidth: .infinity, minHeight: 520, maxHeight: .infinity)
        .background {
            // A restrained tint keeps the teal identity over any desktop wallpaper.
            LinearGradient(colors: [Design.windowTop, Design.windowBottom],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .glassCard(radius: 28, thin: false)
        .clipShape(RoundedRectangle(cornerRadius: 28))
        .tint(Design.teal)
        .overlay(alignment: .bottom) { toast }
        .alert("无法完成操作", isPresented: Binding(get: { store.errorMessage != nil },
                                              set: { if !$0 { store.errorMessage = nil } })) {
            Button("好") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }

    private var toast: some View {
        Group {
            if let message = store.toast {
                HStack(spacing: 12) {
                    Text(message).font(.system(size: 12, weight: .medium))
                    if store.toastAction != nil {
                        Button("撤销") { store.undoLastAction() }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Design.currency)
                            .accessibilityLabel("撤销\(message)")
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .glassCard(radius: 20, thin: false).padding(.bottom, 18)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: store.toast)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Real macOS traffic-light controls occupy this first 30 pt.
            Spacer().frame(height: 30)
            HStack(spacing: 10) {
                ProductLogo()
                VStack(alignment: .leading, spacing: 2) {
                    Text("出账日").font(.system(size: 16, weight: .semibold))
                    Text("CheckList").font(.system(size: 10)).foregroundStyle(Design.secondary)
                }
            }
            .padding(.bottom, 22)
            navigation("待还账单", symbol: "list.bullet", count: store.pending.count, route: .home,
                       selected: store.route != .history && !isHistoryDetail)
            navigation("已还清", symbol: "checkmark", count: store.history.count, route: .history,
                       selected: store.route == .history || isHistoryDetail)
            Spacer()
            notificationCard
            HStack {
                Button(action: settings) {
                    Label("提醒设置", systemImage: "gearshape").font(.system(size: 10))
                }
                .buttonStyle(.plain).foregroundStyle(Design.secondary)
                Spacer()
                Button { store.appearance.toggle(isDark: colorScheme == .dark) } label: {
                    Image(systemName: colorScheme == .dark ? "sun.max" : "moon")
                        .font(.system(size: 12)).frame(width: 28, height: 24)
                }
                .buttonStyle(.plain).foregroundStyle(Design.ink)
                .background(Design.ghostFill, in: Capsule())
                .help(colorScheme == .dark ? "切换为浅色模式" : "切换为深色模式")
                .accessibilityLabel(colorScheme == .dark ? "切换为浅色模式" : "切换为深色模式")
                .accessibilityIdentifier("appearanceToggle")
            }
            .padding(.top, 12)
        }
        .padding(16).frame(width: 176)
        .frame(maxHeight: .infinity)
        .background(Design.sidebarFill)
    }

    /// Live notification state instead of a sentence the user has to act on elsewhere.
    @ViewBuilder private var notificationCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let reminders, reminders.systemNotificationsEnabled, reminders.permissionChecked,
               reminders.permission != .allowed {
                Label(reminders.permission == .denied ? "系统通知已关闭" : "系统通知未开启",
                      systemImage: "bell.slash")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Design.ink)
                Text("开启后，退出应用也能收到到期提醒。")
                    .font(.system(size: 11)).foregroundStyle(Design.secondary).lineSpacing(3)
                Button(reminders.permission == .denied ? "打开系统设置" : "开启通知") {
                    reminders.enableNotifications()
                }
                .buttonStyle(GhostButtonStyle(height: 24, strong: true))
            } else {
                Text("常驻菜单栏，到期日当天\n弹窗并伴随提示音提醒。")
                    .font(.system(size: 11)).foregroundStyle(Design.secondary).lineSpacing(4)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading).glassCard()
    }

    private var isHistoryDetail: Bool {
        if case .detail = store.route { return store.detailSource == .history }
        return false
    }

    private func navigation(_ title: String, symbol: String, count: Int, route: AppRoute, selected: Bool) -> some View {
        Button { store.route = route } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 12))
                Text(title).font(.system(size: 11, weight: selected ? .semibold : .medium))
                Spacer()
                Text("\(count)").font(.system(size: 10)).foregroundStyle(Design.secondary)
            }
            .foregroundStyle(Design.ink).padding(.horizontal, 12).frame(height: 28)
            .background(selected ? Design.selectionFill : .clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).padding(.bottom, 6)
        .accessibilityLabel("\(title)，\(count) 笔")
    }
}

struct HomeView: View {
    @Bindable var store: AppStore
    let reminders: ReminderService?
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if showsPermissionPrompt, let reminders {
                PermissionBanner(
                    onEnable: { reminders.settings.permissionPromptDismissed = true; reminders.enableNotifications() },
                    onDismiss: { reminders.settings.permissionPromptDismissed = true }
                )
            }
            HStack(alignment: .top) {
                BillAmountSummary(title: "本期待还总额", cents: store.total) {
                    HStack(spacing: 6) {
                        Text("共 \(store.pending.count) 笔未还")
                        if store.dueCount > 0 { Text("· \(store.dueCount) 笔今天到期").foregroundStyle(Design.todayText) }
                        if store.overdueCount > 0 { Text("· \(store.overdueCount) 笔逾期").foregroundStyle(Design.overdueText) }
                    }
                }
                Spacer(minLength: 8)
                Button { store.beginAdding() } label: { Label("记一笔", systemImage: "plus") }
                    .buttonStyle(TealButtonStyle()).keyboardShortcut("n")
            }
            if store.pending.isEmpty {
                EmptyState(title: "全部还清了", subtitle: "点「记一笔」添加新账单", symbol: "checkmark")
            } else {
                BillList(store: store, bills: store.pending, snoozeChoices: snoozeChoices)
            }
        }
    }

    private var showsPermissionPrompt: Bool {
        guard let reminders, reminders.systemNotificationsEnabled, reminders.permissionChecked,
              reminders.permission == .notDetermined, !reminders.settings.permissionPromptDismissed else { return false }
        return !store.bills.isEmpty
    }

    private var snoozeChoices: () -> [SnoozeChoice] {
        { reminders?.snoozeChoices() ?? SnoozeOptions.make(now: .now, hour: 9, minute: 0) }
    }
}

/// First-run nudge: reminders are the point of the app, and the permission is easy to miss.
struct PermissionBanner: View {
    let onEnable: () -> Void
    let onDismiss: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bell.badge").font(.system(size: 14))
                .foregroundStyle(Design.darkTeal).frame(width: 28, height: 28)
                .background(Design.accent, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text("开启系统通知").font(.system(size: 12, weight: .semibold))
                Text("退出应用后也能收到到期提醒。").font(.system(size: 11)).foregroundStyle(Design.secondary)
            }
            Spacer(minLength: 8)
            Button("开启", action: onEnable).buttonStyle(TealButtonStyle())
            Button("以后再说", action: onDismiss).buttonStyle(GhostButtonStyle())
        }
        .padding(12).glassCard()
        .accessibilityElement(children: .contain)
    }
}

struct HistoryView: View {
    @Bindable var store: AppStore
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            BillAmountSummary(title: "累计已还总额", cents: store.paidTotal) {
                Text("共 \(store.history.count) 笔已还清")
            }
            if store.history.isEmpty {
                EmptyState(title: "还没有已还清的账单", subtitle: "完成还款后，会在这里留下记录", symbol: "checkmark")
            } else {
                BillList(store: store, bills: store.history, snoozeChoices: { [] })
            }
        }
    }
}

/// A bill list with one selected row, so the keyboard can act without the mouse.
struct BillList: View {
    @Bindable var store: AppStore
    let bills: [Bill]
    let snoozeChoices: () -> [SnoozeChoice]
    @FocusState private var focused: Bool
    @State private var pendingDelete: Bill?

    var body: some View {
        LazyVStack(spacing: 12) {
            ForEach(bills) { bill in
                BillRow(bill: bill, now: store.now, store: store,
                        selected: focused && store.selectedBillID == bill.id,
                        snoozeChoices: snoozeChoices,
                        requestDelete: { pendingDelete = bill })
                    .id(bill.id)
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.upArrow) { move(-1) }
        .onKeyPress(.downArrow) { move(1) }
        .onKeyPress(.return) { onSelected { store.openDetail($0) } }
        .onKeyPress(.space) { onSelected { store.setPaid($0, paid: !$0.isPaid) } }
        .onKeyPress(.delete) { onSelected { pendingDelete = $0 } }
        .onKeyPress(.escape) {
            guard store.selectedBillID != nil else { return .ignored }
            store.selectedBillID = nil
            return .handled
        }
        .alert("删除「\(pendingDelete?.name ?? "")」？",
               isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                if let bill = pendingDelete { store.delete(bill) }
            }
        } message: { Text("删除后可以立即撤销；提醒会一并取消。") }
    }

    private func move(_ step: Int) -> KeyPress.Result {
        guard !bills.isEmpty else { return .ignored }
        let index = bills.firstIndex { $0.id == store.selectedBillID }
        let next = min(max((index ?? (step > 0 ? -1 : bills.count)) + step, 0), bills.count - 1)
        store.selectedBillID = bills[next].id
        return .handled
    }

    private func onSelected(_ action: (Bill) -> Void) -> KeyPress.Result {
        guard let bill = bills.first(where: { $0.id == store.selectedBillID }) else { return .ignored }
        action(bill)
        return .handled
    }
}

struct BillRow: View {
    let bill: Bill
    let now: Date
    let store: AppStore
    var selected = false
    var snoozeChoices: () -> [SnoozeChoice] = { [] }
    let requestDelete: () -> Void
    @State private var hovered = false

    private var showsQuickAction: Bool { hovered || selected }

    var body: some View {
        HStack(spacing: 12) {
            // The kind icon becomes the quick action on hover: the checkbox pattern, without moving anything.
            if showsQuickAction {
                QuickActionButton(bill: bill, store: store, size: 36)
            } else {
                KindIcon(kind: bill.kind)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(bill.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
                    ReminderMark(bill: bill)
                }
                Text(subtitle).font(.system(size: 10)).foregroundStyle(Design.secondary).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            DueBadge(bill: bill, now: now)
            Text("¥" + Money.format(bill.amountInCents))
                .font(.system(size: 16, weight: .semibold)).monospacedDigit()
                .strikethrough(bill.isPaid, color: Design.teal)
                .frame(width: 106, alignment: .trailing).minimumScaleFactor(0.6).lineLimit(1)
        }
        .padding(12).frame(maxWidth: .infinity).glassCard()
        .overlay(RoundedRectangle(cornerRadius: 16)
            .fill(selected ? Design.selectionFill : hovered ? Design.rowHover : .clear)
            .allowsHitTesting(false))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .strokeBorder(Design.teal.opacity(selected ? 0.55 : 0), lineWidth: 1.5)
            .allowsHitTesting(false))
        .opacity(bill.isPaid ? 0.8 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .onTapGesture { store.selectedBillID = bill.id; store.openDetail(bill) }
        .onHover { hovered = $0 }
        .contextMenu { menu }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(bill.name)，\(Money.format(bill.amountInCents)) 元，还款日 \(bill.dateText)，\(bill.statusText(now: now))")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { store.selectedBillID = bill.id; store.openDetail(bill) }
        .accessibilityAction(named: bill.isPaid ? "撤销还款" : "设为已经还款") {
            store.setPaid(bill, paid: !bill.isPaid)
        }
        .accessibilityAction(named: "编辑") { store.edit(bill) }
        .accessibilityAction(named: "删除") { requestDelete() }
    }

    private var subtitle: String {
        bill.isPaid ? "\(bill.kind.title) · \(bill.paidText ?? bill.dateText) 已还"
            : "\(bill.kind.title) · 还款日 \(bill.dateText)"
    }

    @ViewBuilder private var menu: some View {
        if bill.isPaid {
            Button("撤销还款") { store.setPaid(bill, paid: false) }
        } else {
            Button("设为已经还款") { store.setPaid(bill, paid: true) }
            if bill.kind == .loan {
                Button("下一期") { store.advanceInstallment(bill) }
            }
            if bill.daysLeft(now: now) <= 0 {
                Menu("稍后提醒") {
                    ForEach(snoozeChoices(), id: \.date) { choice in
                        Button(choice.title) { store.snooze(bill, until: choice.date, message: choice.confirmation) }
                    }
                }
            }
            Button(bill.isMuted ? "开启提醒" : "不再提醒") { store.mute(bill, muted: !bill.isMuted) }
        }
        Divider()
        // Most useful once this month's bill is paid, so it is offered for paid bills too.
        if bill.kind == .creditCard {
            Button("复制为下月账单…") { store.copyToNextMonth(bill) }
        }
        Button("编辑…") { store.edit(bill) }
        Button("删除…", role: .destructive) { requestDelete() }
    }
}

/// The round action that replaces a bill's kind icon on hover.
struct QuickActionButton: View {
    let bill: Bill
    let store: AppStore
    var size: CGFloat = 36
    var body: some View {
        Button {
            store.setPaid(bill, paid: !bill.isPaid)
        } label: {
            Image(systemName: bill.isPaid ? "arrow.uturn.backward" : "checkmark")
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(Design.darkTeal)
                .frame(width: size, height: size)
                .background(Design.accent, in: RoundedRectangle(cornerRadius: size / 3))
                .contentShape(RoundedRectangle(cornerRadius: size / 3))
        }
        .buttonStyle(.plain)
        .help(bill.isPaid ? "撤销还款" : "设为已经还款")
        .accessibilityLabel(bill.isPaid ? "撤销\(bill.name)的还款" : "将\(bill.name)设为已经还款")
    }
}

/// Muted and snoozed bills look like any other row otherwise, while still driving the menu bar.
struct ReminderMark: View {
    let bill: Bill
    var body: some View {
        if !bill.isPaid, bill.isMuted || bill.snoozeUntil != nil {
            Image(systemName: bill.isMuted ? "bell.slash" : "clock")
                .font(.system(size: 10))
                .foregroundStyle(Design.secondary)
                .help(bill.isMuted ? "已关闭提醒" : "已稍后提醒")
                .accessibilityLabel(bill.isMuted ? "已关闭提醒" : "已稍后提醒")
        }
    }
}

struct BillAmountSummary<Detail: View>: View {
    let title: String
    let cents: Int64
    @ViewBuilder let detail: () -> Detail
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12)).foregroundStyle(Design.secondary)
            HStack(alignment: .top, spacing: 4) {
                Text("¥").font(.system(size: 20, weight: .semibold)).padding(.top, 5)
                    .foregroundStyle(Design.currency)
                CountingAmount(cents: Double(cents)).font(.system(size: 46, weight: .semibold))
                    .tracking(-0.9).foregroundStyle(Design.ink)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.8), value: cents)
                    .minimumScaleFactor(0.5).lineLimit(1)
            }
            detail().font(.system(size: 12)).foregroundStyle(Design.secondary)
        }
    }
}

struct EmptyState: View {
    let title: String
    let subtitle: String
    let symbol: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 24, weight: .medium))
                .foregroundStyle(Design.darkTeal).frame(width: 48, height: 48)
                .background(Design.accent, in: Circle())
            Text(title).font(.system(size: 13, weight: .medium))
            Text(subtitle).font(.system(size: 11)).foregroundStyle(Design.secondary)
        }.frame(maxWidth: .infinity).padding(.vertical, 64)
    }
}

/// One form for adding and for editing, with a live preview of the bill and its reminder.
struct BillFormView: View {
    let store: AppStore
    let reminders: ReminderService?
    let editing: Bill?
    let draft: BillDraft?
    @State private var kind: BillKind
    @State private var name: String
    @State private var amount: String
    @State private var due: Date
    @FocusState private var amountFocused: Bool

    init(store: AppStore, reminders: ReminderService?, editing: Bill?, draft: BillDraft? = nil) {
        self.store = store
        self.reminders = reminders
        self.editing = editing
        self.draft = draft
        _kind = State(initialValue: editing?.kind ?? draft?.kind ?? .creditCard)
        _name = State(initialValue: editing?.name ?? draft?.name ?? "")
        _amount = State(initialValue: editing.map { Money.plain($0.amountInCents) } ?? "")
        _due = State(initialValue: editing?.dueDate ??
            draft?.due ?? Calendar.current.date(byAdding: .day, value: 7, to: .now)!)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Button { cancel() } label: { Label("取消", systemImage: "chevron.left") }
                .buttonStyle(GhostButtonStyle()).keyboardShortcut(.cancelAction)
            VStack(alignment: .leading, spacing: 4) {
                Text(editing == nil ? "记一笔" : "编辑账单").font(.system(size: 20, weight: .semibold))
                if let draft {
                    Text("已复制「\(draft.source)」的名称和还款日，请填写本期金额。")
                        .font(.system(size: 11)).foregroundStyle(Design.secondary)
                }
            }
            // 336 + 20 + 160 fits the content area of the smallest window (535 pt).
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 16) {
                    field("账单类型") {
                        HStack(spacing: 0) {
                            ForEach(BillKind.allCases) { option in
                                Button { kind = option } label: {
                                    Label(option.title, systemImage: option.symbol)
                                        .font(.system(size: 11, weight: .medium))
                                        .frame(maxWidth: .infinity).frame(height: 28)
                                        .foregroundStyle(kind == option ? Design.darkTeal : Design.secondary)
                                        .background {
                                            if kind == option { Capsule().fill(Design.accent) }
                                        }
                                        .contentShape(Capsule())
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(kind == option ? .isSelected : [])
                            }
                        }.padding(4).glassCard(radius: 20)
                            .accessibilityElement(children: .contain).accessibilityLabel("账单类型")
                    }
                    field("名称（选填）") {
                        TextField("", text: $name)
                            .textFieldStyle(.plain).font(.system(size: 13))
                            .overlay(alignment: .leading) {
                                if name.isEmpty {
                                    Text(kind == .creditCard ? "如：招商银行信用卡" : "如：房贷")
                                        .font(.system(size: 13)).foregroundStyle(Design.secondary)
                                        .allowsHitTesting(false).accessibilityHidden(true)
                                }
                            }
                            .padding(.horizontal, 14).frame(height: 36).glassCard()
                            .accessibilityLabel("账单名称")
                            .accessibilityHint("选填")
                    }
                    field("账单金额") {
                        HStack(spacing: 8) {
                            Text("¥").font(.system(size: 20)).foregroundStyle(Design.currency)
                            TextField("", text: $amount).textFieldStyle(.plain)
                                .font(.system(size: 24, weight: .semibold)).monospacedDigit()
                                .overlay(alignment: .leading) {
                                    if amount.isEmpty {
                                        Text("0.00").font(.system(size: 24, weight: .semibold)).monospacedDigit()
                                            .foregroundStyle(Design.secondary)
                                            .allowsHitTesting(false).accessibilityHidden(true)
                                    }
                                }
                                .focused($amountFocused).accessibilityLabel("账单金额")
                                .accessibilityHint("人民币，最多两位小数")
                        }.padding(.horizontal, 14).frame(height: 48).glassCard()
                        // Report a bad amount once the field is left, not on the first keystroke.
                        if !amount.isEmpty, !amountFocused, Money.parse(amount) == nil {
                            Text("请输入大于 0 的金额，最多两位小数")
                                .font(.system(size: 10)).foregroundStyle(Design.danger)
                        }
                    }
                    field("还款日期") {
                        VStack(alignment: .leading, spacing: 8) {
                            DatePicker("还款日期", selection: $due, displayedComponents: .date)
                                .labelsHidden().datePickerStyle(.field).font(.system(size: 13))
                                .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                                .glassCard()
                            HStack(spacing: 6) {
                                ForEach(presets, id: \.date) { preset in
                                    Button(preset.title) { due = preset.date }
                                        .buttonStyle(GhostButtonStyle(height: 22, strong: sameDay(due, preset.date)))
                                }
                            }
                        }
                    }
                }
                .frame(width: 336)
                BillFormPreview(kind: kind, name: name, amount: amount, due: due,
                                editing: editing, reminders: reminders)
            }
            Button(action: save) { Text(editing == nil ? "保存" : "保存修改").frame(maxWidth: .infinity) }
                .buttonStyle(TealButtonStyle()).disabled(Money.parse(amount) == nil)
                .keyboardShortcut(.defaultAction)
                .frame(maxWidth: 336)
        }
        .onAppear { if editing == nil { amountFocused = true } }
    }

    private var presets: [(title: String, date: Date)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        var result = [(title: "今天", date: today)]
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) { result.append(("明天", tomorrow)) }
        if let week = calendar.date(byAdding: .day, value: 7, to: today) { result.append(("7 天后", week)) }
        if let month = Bill.monthAfter(today, calendar: calendar) { result.append(("下月今天", month)) }
        return result
    }

    private func sameDay(_ lhs: Date, _ rhs: Date) -> Bool {
        Calendar.current.isDate(lhs, inSameDayAs: rhs)
    }

    private func cancel() {
        if editing == nil, draft != nil { store.draft = nil }
        store.route = editing == nil ? .home : store.editReturn
    }

    private func save() {
        guard let cents = Money.parse(amount) else { return }
        if let editing {
            if store.update(editing, kind: kind, name: name, cents: cents, due: due) {
                store.route = store.editReturn
            }
        } else {
            store.add(kind: kind, name: name, cents: cents, due: due)
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12)).foregroundStyle(Design.secondary)
            content()
        }
    }
}

/// Shows what the bill will look like in the list, and when it will actually remind.
struct BillFormPreview: View {
    let kind: BillKind
    let name: String
    let amount: String
    let due: Date
    let editing: Bill?
    let reminders: ReminderService?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("预览").font(.system(size: 12)).foregroundStyle(Design.secondary)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    KindIcon(kind: kind, size: 32)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(displayName).font(.system(size: 13, weight: .medium)).lineLimit(2)
                        Text(kind.title).font(.system(size: 10)).foregroundStyle(Design.secondary)
                    }
                    Spacer(minLength: 0)
                }
                Text("¥" + Money.format(cents)).font(.system(size: 20, weight: .semibold))
                    .monospacedDigit().foregroundStyle(Design.ink).lineLimit(1).minimumScaleFactor(0.6)
                Text(statusText).font(.system(size: 10, weight: .medium))
                    .foregroundStyle(style.text).padding(.horizontal, 10).padding(.vertical, 4)
                    .background(style.fill, in: Capsule()).fixedSize()
                Divider().overlay(Design.sidebarDivider)
                Label(reminderText, systemImage: reminderSymbol)
                    .font(.system(size: 11)).foregroundStyle(Design.secondary)
                    .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading).glassCard()
            .accessibilityElement(children: .combine)
        }
        .frame(minWidth: 160, maxWidth: 260, alignment: .leading)
    }

    private var cents: Int64 { Money.parse(amount) ?? 0 }

    private var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? kind.defaultName : trimmed
    }

    private var daysLeft: Int {
        let calendar = Calendar.current
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: .now),
                                       to: calendar.startOfDay(for: due)).day ?? 0
    }

    private var statusText: String { Bill.statusText(daysLeft: daysLeft) }
    private var style: DueStyle { DueStyle(daysLeft: daysLeft) }

    private var reminderSymbol: String {
        if editing?.isMuted == true { return "bell.slash" }
        return isImmediate ? "bell.badge" : "bell"
    }

    private var isImmediate: Bool {
        let calendar = Calendar.current
        guard let moment = reminderMoment(calendar) else { return true }
        return moment <= .now
    }

    private func reminderMoment(_ calendar: Calendar) -> Date? {
        let hour = reminders?.settings.hour ?? 9
        let minute = reminders?.settings.minute ?? 0
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: calendar.startOfDay(for: due))
    }

    private var reminderText: String {
        if let editing, editing.isPaid { return "已还款，不再提醒" }
        if editing?.isMuted == true { return "这笔账单已关闭提醒" }
        let hour = reminders?.settings.hour ?? 9
        let minute = reminders?.settings.minute ?? 0
        let time = String(format: "%02d:%02d", hour, minute)
        guard !isImmediate else { return "保存后立即提醒" }
        let parts = Calendar.current.dateComponents([.month, .day], from: due)
        return "\(parts.month ?? 0) 月 \(parts.day ?? 0) 日 \(time) 提醒"
    }
}

struct BillDetailView: View {
    @Bindable var store: AppStore
    let bill: Bill
    @State private var confirmDelete = false
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Button { store.route = store.detailSource } label: { Label("返回", systemImage: "chevron.left") }
                .buttonStyle(GhostButtonStyle()).keyboardShortcut(.cancelAction)
            HStack(spacing: 16) {
                KindIcon(kind: bill.kind, size: 44)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(bill.name).font(.system(size: 20, weight: .semibold)).lineLimit(2)
                        ReminderMark(bill: bill)
                    }
                    Text(bill.kind.title).font(.system(size: 12)).foregroundStyle(Design.secondary)
                }
                Spacer()
                DueBadge(bill: bill, now: store.now)
            }
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("应还金额").font(.system(size: 12)).foregroundStyle(Design.secondary)
                    Text("¥" + Money.format(bill.amountInCents)).font(.system(size: 36, weight: .semibold))
                        .foregroundStyle(Design.ink).monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
                }
                HStack(alignment: .top, spacing: 12) {
                    info("还款日", value: bill.dateText)
                    info("状态", value: bill.isPaid ? "已还款" : "待还款")
                    info("提醒", value: bill.isPaid ? "已完成" : bill.isMuted ? "已关闭" :
                            bill.snoozeUntil != nil ? "已稍后提醒" : "到期日提醒")
                    if let paidText = bill.paidText { info("实际还款", value: paidText) }
                }
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading).glassCard(radius: 20)
            HStack(spacing: 10) {
                if bill.isPaid {
                    Button("撤销还款") { store.setPaid(bill, paid: false) }.buttonStyle(GhostButtonStyle())
                } else {
                    Button { if store.setPaid(bill, paid: true) { store.route = .home } } label: {
                        Label("设为已经还款", systemImage: "checkmark")
                    }.buttonStyle(TealButtonStyle())
                    if bill.kind == .loan {
                        Button {
                            if store.advanceInstallment(bill) { store.route = .home }
                        } label: {
                            Label("下一期", systemImage: "arrow.right")
                        }
                        .buttonStyle(GhostButtonStyle())
                        .help("将本期设为已还款，并复制为下个月的账单")
                    }
                    Button(bill.isMuted ? "开启提醒" : "不再提醒") { store.mute(bill, muted: !bill.isMuted) }
                        .buttonStyle(GhostButtonStyle())
                }
                Button("编辑") { store.edit(bill) }.buttonStyle(GhostButtonStyle())
                if bill.kind == .creditCard {
                    Button("复制为下月账单") { store.copyToNextMonth(bill) }
                        .buttonStyle(GhostButtonStyle())
                        .help("带入名称和还款日，金额留空待填")
                }
                Spacer()
                Button { confirmDelete = true } label: {
                    Image(systemName: "trash").font(.system(size: 12)).foregroundStyle(Design.danger)
                        .frame(width: 28, height: 28).background(Design.ghostFill, in: Circle())
                }.buttonStyle(.plain).help("删除账单").accessibilityLabel("删除账单")
            }
        }
        .alert("删除「\(bill.name)」？", isPresented: $confirmDelete) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { store.delete(bill) }
        } message: { Text("删除后可以立即撤销；提醒会一并取消。") }
    }

    private func info(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).foregroundStyle(Design.secondary)
            Text(value).fontWeight(.medium)
        }.font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
    }
}
