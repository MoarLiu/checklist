import AppKit
import SwiftData
import SwiftUI

@main
struct CheckListApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        // AppKit owns the window lifecycle; SwiftUI only renders hosted views.
        // Keep the delegate alive because NSApplication holds it weakly.
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: AppStore?
    var window: NSWindow?
    var statusItem: NSStatusItem?
    var popover = NSPopover()
    var reminders: ReminderService?
    var settingsWindow: NSWindow?
    private var appearanceObserver: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        do {
            let demo = ProcessInfo.processInfo.arguments.contains("--demo")
            let override = ProcessInfo.processInfo.environment["CHECKLIST_DATA_DIR"]
            // Process-local appearance overrides are only available for isolated
            // preview profiles. Normal use always follows the system appearance.
            if override != nil {
                switch ProcessInfo.processInfo.environment["CHECKLIST_PREVIEW_APPEARANCE"] {
                case "light": NSApp.appearance = NSAppearance(named: .aqua)
                case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
                default: break
                }
            }
            let base = override.map { URL(fileURLWithPath: $0, isDirectory: true) } ??
                FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(demo ? "CheckList-Demo" : "CheckList", isDirectory: true)
            let store = try AppStore(dataURL: base.appendingPathComponent("bills.store"))
            self.store = store
            if demo { store.seedDemo() }
            store.showWindow = { [weak self] in self?.showMainWindow() }
            store.onClockChange = { [weak self] in self?.updateStatus() }
            let reminders = ReminderService(store: store, systemNotificationsEnabled: !demo && override == nil)
            self.reminders = reminders
            store.onChange = { [weak self] in
                self?.updateStatus()
                self?.reminders?.refresh()
            }
            setupMainMenu()
            setupStatusItem()
            appearanceObserver = NSApp.observe(\.effectiveAppearance, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.popover.appearance = NSApp.effectiveAppearance
                }
            }
            showMainWindow()
            reminders.start()
        } catch {
            let alert = NSAlert()
            alert.messageText = "无法打开出账日的本地账本"
            alert.informativeText = "\(error.localizedDescription)\n原有数据已保留，请检查目录权限后重试。"
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        popover.behavior = .transient
        if let store {
            popover.contentViewController = NSHostingController(rootView:
                MenuBarPopover(store: store, settings: { [weak self] in self?.showSettings() },
                               quit: { NSApp.terminate(nil) }))
        }
        updateStatus()
    }

    func updateStatus() {
        guard let store, let button = statusItem?.button else { return }
        let amount = MenuBarMark.amount(cents: store.total)
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .medium)
        button.font = font
        button.attributedTitle = NSAttributedString(string: amount, attributes: [.font: font])
        button.image = MenuBarMark.image
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.toolTip = "出账日 · 待还 " + amount
        popover.contentSize = NSSize(width: 236, height: 144 + min(store.pending.count, 4) * 42)
    }

    @objc func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else {
            // The menu-bar anchor can use a different appearance from the app
            // depending on the wallpaper. Keep the app's popover consistent.
            popover.appearance = NSApp.effectiveAppearance
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKeyAndOrderFront(nil)
        }
    }

    func showMainWindow() {
        popover.performClose(nil)
        if window == nil, let store {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
                                  styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "出账日"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.backgroundColor = .clear
            window.isOpaque = false
            window.contentView = NSHostingView(rootView:
                RootView(store: store, settings: { [weak self] in self?.showSettings() }).ignoresSafeArea())
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @objc func showSettings() {
        popover.performClose(nil)
        guard let reminders else { return }
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 410, height: 320),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "出账日 · 提醒设置"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView:
                ReminderSettingsView(service: reminders, close: { [weak self] in self?.settingsWindow?.close() }))
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func setupMainMenu() {
        let menu = NSMenu()
        let appMenu = NSMenu()
        let appRoot = NSMenuItem()
        appRoot.submenu = appMenu
        menu.addItem(appRoot)
        appMenu.addItem(withTitle: "关于出账日", action: #selector(about), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "提醒设置…", action: #selector(showSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出出账日", action: #selector(quit), keyEquivalent: "q")
        let fileMenu = NSMenu(title: "文件")
        let fileRoot = NSMenuItem(title: "文件", action: nil, keyEquivalent: "")
        fileRoot.submenu = fileMenu
        menu.addItem(fileRoot)
        fileMenu.addItem(withTitle: "记一笔", action: #selector(addBill), keyEquivalent: "n")
        fileMenu.addItem(withTitle: "打开账本", action: #selector(openLedger), keyEquivalent: "1")
        fileMenu.addItem(withTitle: "已还清", action: #selector(openHistory), keyEquivalent: "2")
        fileMenu.addItem(withTitle: "菜单栏账单", action: #selector(togglePopover), keyEquivalent: "b")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        for item in appMenu.items where item.action != nil { item.target = self }
        for item in fileMenu.items where item.action != nil && item.keyEquivalent != "w" { item.target = self }
        let edit = NSMenu(title: "编辑")
        let editRoot = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        editRoot.submenu = edit
        menu.addItem(editRoot)
        for (title, action, key) in [
            ("撤销", Selector(("undo:")), "z"), ("剪切", #selector(NSText.cut(_:)), "x"),
            ("复制", #selector(NSText.copy(_:)), "c"), ("粘贴", #selector(NSText.paste(_:)), "v"),
            ("全选", #selector(NSText.selectAll(_:)), "a"),
        ] {
            edit.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        NSApp.mainMenu = menu
    }

    @objc func about() { NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "出账日"]) }
    @objc func addBill() { store?.open(.add) }
    @objc func openLedger() { store?.open(.home) }
    @objc func openHistory() { store?.open(.history) }
    @objc func quit() { NSApp.terminate(nil) }
}
