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
                        Button { store.openDetail(bill, show: true) } label: {
                            HStack(spacing: 8) {
                                KindIcon(kind: bill.kind, size: 28)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(bill.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                    Text(String(bill.dateText.suffix(5)) + " 到期")
                                        .font(.system(size: 10)).foregroundStyle(Design.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Text("¥" + Money.format(bill.amountInCents))
                                    .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                                    .lineLimit(1).minimumScaleFactor(0.7)
                                    .frame(width: 74, alignment: .trailing).layoutPriority(1)
                            }.padding(6).contentShape(RoundedRectangle(cornerRadius: 12))
                        }.buttonStyle(.plain)
                    }
                }
            }
            HStack(spacing: 6) {
                Button { store.open(.add) } label: { Text("记一笔").frame(maxWidth: .infinity) }
                    .buttonStyle(TealButtonStyle(height: 24))
                Button { store.open(.home) } label: { Text("打开账本").frame(maxWidth: .infinity) }
                    .buttonStyle(GhostButtonStyle(height: 24))
            }
            HStack {
                Button(action: settings) { Label("设置", systemImage: "gearshape") }
                Spacer()
                Button("退出", action: quit)
            }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(Design.secondary).padding(.top, 4)
        }
        .padding(12).frame(width: 236).foregroundStyle(Design.body)
        .background(Color(hex: 0xD6F8EF).opacity(0.25))
        .preferredColorScheme(.light)
    }
}

struct ReminderSettingsView: View {
    @Bindable var service: ReminderService
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
            if let error = service.schedulingError {
                Text(error).font(.system(size: 11)).foregroundStyle(Design.danger)
            }
        }
        .padding(24).frame(width: 410).foregroundStyle(Design.body)
        .background(.ultraThinMaterial).preferredColorScheme(.light)
        .onChange(of: service.settings.hour) { service.refresh() }
        .onChange(of: service.settings.minute) { service.refresh() }
        .onChange(of: service.settings.sound) { service.refresh() }
    }
}
