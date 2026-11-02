import SwiftUI

struct RootView: View {
    @Bindable var store: AppStore
    let settings: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(.white.opacity(0.5)).frame(width: 1)
            ScrollView {
                Group {
                    switch store.route {
                    case .home: HomeView(store: store)
                    case .history: HistoryView(store: store)
                    case .add: AddBillView(store: store)
                    case .detail(let id):
                        if let bill = store.bill(id) {
                            BillDetailView(store: store, bill: bill)
                        } else {
                            HomeView(store: store)
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .foregroundStyle(Design.body)
        .frame(width: 760, height: 520)
        .background {
            // A restrained tint keeps the teal identity over any desktop wallpaper.
            LinearGradient(colors: [Color(hex: 0xD7EEEF).opacity(0.5), Color(hex: 0xBDF5E6).opacity(0.3)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .glassCard(radius: 28, thin: false)
        .clipShape(RoundedRectangle(cornerRadius: 28))
        .preferredColorScheme(.light)
        .overlay(alignment: .bottom) {
            if let toast = store.toast {
                Text(toast).font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .glassCard(radius: 20, thin: false).padding(.bottom, 18)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: store.toast)
        .alert("无法完成操作", isPresented: Binding(get: { store.errorMessage != nil },
                                              set: { if !$0 { store.errorMessage = nil } })) {
            Button("好") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
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
            Text("常驻菜单栏，到期日当天\n弹窗并伴随提示音提醒。")
                .font(.system(size: 10)).foregroundStyle(Design.secondary).lineSpacing(4)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading).glassCard()
            Button(action: settings) {
                Label("提醒设置", systemImage: "gearshape").font(.system(size: 10))
            }
            .buttonStyle(.plain).foregroundStyle(Design.secondary).padding(.top, 12)
        }
        .padding(16).frame(width: 176, height: 520)
        .background(.white.opacity(0.1))
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
            .background(.white.opacity(selected ? 0.7 : 0), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).padding(.bottom, 6)
        .accessibilityLabel("\(title)，\(count) 笔")
    }
}

struct HomeView: View {
    @Bindable var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("本期待还总额").font(.system(size: 12)).foregroundStyle(Design.secondary)
                    HStack(alignment: .top, spacing: 4) {
                        Text("¥").font(.system(size: 20, weight: .semibold)).padding(.top, 5)
                            .foregroundStyle(Color(hex: 0x0F766E))
                        CountingAmount(cents: Double(store.total)).font(.system(size: 46, weight: .semibold))
                            .tracking(-0.9).foregroundStyle(Design.ink)
                            .animation(reduceMotion ? nil : .easeOut(duration: 0.8), value: store.total)
                            .minimumScaleFactor(0.5).lineLimit(1)
                    }
                    HStack(spacing: 6) {
                        Text("共 \(store.pending.count) 笔未还")
                        if store.dueCount > 0 { Text("· \(store.dueCount) 笔今天到期").foregroundStyle(Color(hex: 0x92400E)) }
                        if store.overdueCount > 0 { Text("· \(store.overdueCount) 笔逾期").foregroundStyle(Design.danger) }
                    }.font(.system(size: 12)).foregroundStyle(Design.secondary)
                }
                Spacer(minLength: 8)
                Button { store.route = .add } label: { Label("记一笔", systemImage: "plus") }
                    .buttonStyle(TealButtonStyle()).keyboardShortcut("n")
            }
            if store.pending.isEmpty {
                EmptyState(title: "全部还清了", subtitle: "点「记一笔」添加新账单", symbol: "checkmark")
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(store.pending) { bill in
                        BillRow(bill: bill, now: store.now) { store.openDetail(bill) }
                    }
                }
            }
        }
    }
}

struct BillRow: View {
    let bill: Bill
    let now: Date
    let action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                KindIcon(kind: bill.kind)
                VStack(alignment: .leading, spacing: 3) {
                    Text(bill.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
                    Text(bill.isPaid ? bill.dateText : "\(bill.kind.title) · 还款日 \(bill.dateText)")
                        .font(.system(size: 10)).foregroundStyle(Design.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
                DueBadge(bill: bill, now: now)
                Text("¥" + Money.format(bill.amountInCents))
                    .font(.system(size: 16, weight: .semibold)).monospacedDigit()
                    .strikethrough(bill.isPaid, color: Design.teal)
                    .frame(width: 106, alignment: .trailing).minimumScaleFactor(0.6).lineLimit(1)
            }
            .padding(12).frame(maxWidth: .infinity).glassCard()
            .overlay(RoundedRectangle(cornerRadius: 16).fill(.white.opacity(hovered ? 0.15 : 0)))
            .opacity(bill.isPaid ? 0.8 : 1).contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain).onHover { hovered = $0 }
        .accessibilityLabel("\(bill.name)，\(Money.format(bill.amountInCents)) 元，还款日 \(bill.dateText)\(bill.isPaid ? "，已还款" : "")")
    }
}

struct HistoryView: View {
    @Bindable var store: AppStore
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 5) {
                Text("已还清").font(.system(size: 20, weight: .semibold))
                Text("累计已还 ¥" + Money.format(store.paidTotal)).font(.system(size: 12))
                    .foregroundStyle(Design.secondary)
            }
            if store.history.isEmpty {
                EmptyState(title: "还没有已还清的账单", subtitle: "完成还款后，会在这里留下记录", symbol: "checkmark")
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(store.history) { bill in
                        BillRow(bill: bill, now: store.now) { store.openDetail(bill) }
                    }
                }
            }
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

struct AddBillView: View {
    @Bindable var store: AppStore
    @State private var kind = BillKind.creditCard
    @State private var name = ""
    @State private var amount = ""
    @State private var due = Calendar.current.date(byAdding: .day, value: 7, to: .now)!
    @FocusState private var amountFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Button { store.route = .home } label: { Label("取消", systemImage: "chevron.left") }
                .buttonStyle(GhostButtonStyle()).keyboardShortcut(.cancelAction)
            Text("记一笔").font(.system(size: 20, weight: .semibold))
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
                    TextField(kind == .creditCard ? "如：招商银行信用卡" : "如：房贷", text: $name)
                        .textFieldStyle(.plain).font(.system(size: 13))
                        .padding(.horizontal, 14).frame(height: 36).glassCard()
                        .accessibilityLabel("账单名称")
                }
                field("账单金额") {
                    HStack(spacing: 8) {
                        Text("¥").font(.system(size: 20)).foregroundStyle(Color(hex: 0x0F766E))
                        TextField("0.00", text: $amount).textFieldStyle(.plain)
                            .font(.system(size: 24, weight: .semibold)).monospacedDigit()
                            .focused($amountFocused).accessibilityLabel("账单金额")
                    }.padding(.horizontal, 14).frame(height: 48).glassCard()
                    if !amount.isEmpty && Money.parse(amount) == nil {
                        Text("请输入大于 0 的金额，最多两位小数")
                            .font(.system(size: 10)).foregroundStyle(Design.danger)
                    }
                }
                field("还款日期") {
                    DatePicker("还款日期", selection: $due, displayedComponents: .date)
                        .labelsHidden().datePickerStyle(.field).font(.system(size: 13))
                        .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                        .glassCard()
                }
            }
            Button {
                if let cents = Money.parse(amount) { store.add(kind: kind, name: name, cents: cents, due: due) }
            } label: { Text("保存").frame(maxWidth: .infinity) }
            .buttonStyle(TealButtonStyle()).disabled(Money.parse(amount) == nil).keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: 336, alignment: .leading)
        .onAppear { amountFocused = true }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12)).foregroundStyle(Design.secondary)
            content()
        }
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
                    Text(bill.name).font(.system(size: 20, weight: .semibold)).lineLimit(2)
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
                    info("还款日期", value: bill.dateText)
                    info("状态", value: bill.isPaid ? "已还款" : "待还款")
                    info("提醒", value: bill.isPaid ? "已完成" : bill.isMuted ? "已关闭" :
                            bill.snoozeUntil != nil ? "已稍后提醒" : "到期日提醒")
                }
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading).glassCard(radius: 20)
            HStack(spacing: 10) {
                if bill.isPaid {
                    Button("撤销还款") { store.setPaid(bill, paid: false) }.buttonStyle(GhostButtonStyle())
                } else {
                    Button { if store.setPaid(bill, paid: true) { store.route = .home } } label: {
                        Label("设为已经还款", systemImage: "checkmark")
                    }.buttonStyle(TealButtonStyle())
                    Button(bill.isMuted ? "开启提醒" : "不再提醒") { store.mute(bill, muted: !bill.isMuted) }
                        .buttonStyle(GhostButtonStyle())
                }
                Spacer()
                Button { confirmDelete = true } label: {
                    Image(systemName: "trash").font(.system(size: 12)).foregroundStyle(Design.danger)
                        .frame(width: 28, height: 28).background(.white.opacity(0.45), in: Circle())
                }.buttonStyle(.plain).help("删除账单").accessibilityLabel("删除账单")
            }
        }
        .alert("删除「\(bill.name)」？", isPresented: $confirmDelete) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { store.delete(bill) }
        } message: { Text("删除后将取消这笔账单的所有提醒。") }
    }

    private func info(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).foregroundStyle(Design.secondary)
            Text(value).fontWeight(.medium)
        }.font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
    }
}
