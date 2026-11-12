import AppKit
import SwiftUI

struct MenuBarPopover: View {
    @Bindable var store: AppStore
    let settings: () -> Void
    let quit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("待还总额").font(.system(size: 11))
                Spacer()
                Text("\(store.pending.count) 笔").font(.system(size: 10))
            }.foregroundStyle(Design.secondary)
            Text("¥" + Money.format(store.total)).font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Design.ink).monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
            if store.pending.isEmpty {
                Text("全部还清，轻松一身").font(.system(size: 12))
                    .foregroundStyle(Design.secondary).frame(maxWidth: .infinity).padding(.vertical, 20)
            } else {
                VStack(spacing: 2) {
                    ForEach(Array(store.pending.prefix(4))) { bill in
                        PopoverRow(bill: bill, now: store.now, store: store)
                    }
                }
                if store.pending.count > 4 {
                    // The list stops at four rows; say so instead of hiding the rest.
                    Button { store.open(.home) } label: {
                        Text("查看全部 \(store.pending.count) 笔").font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Design.currency)
                            .frame(maxWidth: .infinity).frame(height: 20).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
            if let message = store.toast, store.toastAction != nil {
                // The main window may be closed, so offer undo here as well. Plain confirmations
                // stay out: the list already shows the change, and they would make the popover jump.
                HStack(spacing: 8) {
                    Text(message).font(.system(size: 10, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 0)
                    Button("撤销") { store.undoLastAction() }
                        .buttonStyle(.plain).font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Design.currency)
                        .accessibilityLabel("撤销\(message)")
                }
                .padding(.horizontal, 10).frame(height: 24)
                .background(Design.ghostStrongFill, in: Capsule())
            }
            HStack(spacing: 6) {
                Button { store.open(.add) } label: { Text("记一笔").frame(maxWidth: .infinity) }
                    .buttonStyle(TealButtonStyle(height: 24))
                Button { store.open(.home) } label: { Text("打开账本").frame(maxWidth: .infinity) }
                    .buttonStyle(GhostButtonStyle(height: 24))
            }
            HStack {
                Button(action: settings) {
                    Label("设置", systemImage: "gearshape")
                        .padding(.vertical, 5).padding(.trailing, 8).contentShape(Rectangle())
                }
                Spacer()
                Button(action: quit) {
                    Text("退出").padding(.vertical, 5).padding(.leading, 8).contentShape(Rectangle())
                }
            }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Design.secondary)
        }
        .padding(12).frame(width: 236).foregroundStyle(Design.body)
        .background(Design.popoverFill)
        .tint(Design.teal)
    }
}

struct PopoverRow: View {
    let bill: Bill
    let now: Date
    let store: AppStore
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            if hovered {
                QuickActionButton(bill: bill, store: store, size: 28)
            } else {
                KindIcon(kind: bill.kind, size: 28)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(bill.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    ReminderMark(bill: bill)
                }
                // The same words and urgency colors as the main list.
                Text(String(bill.dateText.suffix(5)) + " · " + bill.statusText(now: now))
                    .font(.system(size: 10)).foregroundStyle(DueStyle(bill: bill, now: now).text)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text("¥" + Money.format(bill.amountInCents))
                .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
                .frame(width: 74, alignment: .trailing).layoutPriority(1)
        }
        .padding(6)
        .background(hovered ? Design.rowHover : .clear, in: RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { store.openDetail(bill, show: true) }
        .onHover { hovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(bill.name)，\(Money.format(bill.amountInCents)) 元，\(bill.statusText(now: now))")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { store.openDetail(bill, show: true) }
        .accessibilityAction(named: "设为已经还款") { store.setPaid(bill, paid: true) }
    }
}

struct ReminderSettingsView: View {
    @Bindable var service: ReminderService
    let store: AppStore
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("提醒设置").font(.system(size: 20, weight: .semibold))
                Spacer()
                Button("完成", action: close).buttonStyle(GhostButtonStyle())
            }
            HStack {
                Text("每天提醒时间").font(.system(size: 12))
                Spacer()
                Picker("小时", selection: $service.settings.hour) {
                    ForEach(0..<24) { Text(String(format: "%02d", $0)).tag($0) }
                }.labelsHidden().frame(width: 65)
                Text(":")
                Picker("分钟", selection: $service.settings.minute) {
                    ForEach(0..<60) { Text(String(format: "%02d", $0)).tag($0) }
                }.labelsHidden().frame(width: 65)
            }
            Toggle("播放提示音", isOn: $service.settings.sound).font(.system(size: 12)).tint(Design.teal)
            HStack {
                Text("菜单栏显示").font(.system(size: 12))
                Spacer()
                Picker("菜单栏显示", selection: Binding(get: { store.appearance.menuBarMode },
                                                     set: { store.appearance.setMenuBarMode($0) })) {
                    ForEach(MenuBarMode.allCases) { Text($0.title).tag($0) }
                }.labelsHidden().frame(width: 144)
            }
            .help("金额较长或共享屏幕时，可以只显示倒计时或图标")
            Divider()
            Text(service.authorization).font(.system(size: 12)).foregroundStyle(Design.secondary)
            HStack(spacing: 8) {
                Button(service.permission == .denied ? "打开系统设置" : "开启系统通知") {
                    service.enableNotifications()
                }.buttonStyle(TealButtonStyle()).disabled(!service.systemNotificationsEnabled)
                Button("预览提醒") { service.preview() }.buttonStyle(GhostButtonStyle())
            }
            Text("应用运行时会显示玻璃提醒卡。允许系统通知后，退出应用也能收到已排程的提醒。关闭主窗口会继续在菜单栏运行。")
                .font(.system(size: 11)).foregroundStyle(Design.secondary).lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
            if let error = service.schedulingError {
                Text(error).font(.system(size: 11)).foregroundStyle(Design.danger)
            }
        }
        .padding(24).frame(width: 410).foregroundStyle(Design.body)
        .background(Design.settingsFill)
        .background(.ultraThinMaterial)
        .tint(Design.teal)
        .onChange(of: service.settings.hour) { service.refresh() }
        .onChange(of: service.settings.minute) { service.refresh() }
        .onChange(of: service.settings.sound) { service.refresh() }
    }
}
