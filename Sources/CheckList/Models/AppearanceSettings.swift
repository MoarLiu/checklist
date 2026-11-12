import Foundation
import Observation

enum AppTheme: String {
    case light, dark
}

/// How much the menu bar item shows. The full form can crowd a busy menu bar.
enum MenuBarMode: String, CaseIterable, Identifiable {
    case full, countdown, icon
    var id: String { rawValue }
    var title: String {
        switch self {
        case .full: "金额与倒计时"
        case .countdown: "仅倒计时"
        case .icon: "仅图标"
        }
    }
}

@MainActor @Observable
final class AppearanceSettings {
    private let defaults: UserDefaults
    private(set) var theme: AppTheme?
    private(set) var menuBarMode: MenuBarMode
    @ObservationIgnored var onChange: ((AppTheme) -> Void)?
    @ObservationIgnored var onDisplayChange: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        theme = defaults.string(forKey: "appearanceTheme").flatMap(AppTheme.init(rawValue:))
        menuBarMode = defaults.string(forKey: "menuBarMode").flatMap(MenuBarMode.init(rawValue:)) ?? .full
    }

    func toggle(isDark: Bool) {
        let next: AppTheme = isDark ? .light : .dark
        theme = next
        defaults.set(next.rawValue, forKey: "appearanceTheme")
        onChange?(next)
    }

    func setMenuBarMode(_ mode: MenuBarMode) {
        guard mode != menuBarMode else { return }
        menuBarMode = mode
        defaults.set(mode.rawValue, forKey: "menuBarMode")
        onDisplayChange?()
    }
}
