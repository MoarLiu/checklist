import Foundation
import Observation

enum AppTheme: String {
    case light, dark
}

@MainActor @Observable
final class AppearanceSettings {
    private let defaults: UserDefaults
    private(set) var theme: AppTheme?
    @ObservationIgnored var onChange: ((AppTheme) -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        theme = defaults.string(forKey: "appearanceTheme").flatMap(AppTheme.init(rawValue:))
    }

    func toggle(isDark: Bool) {
        let next: AppTheme = isDark ? .light : .dark
        theme = next
        defaults.set(next.rawValue, forKey: "appearanceTheme")
        onChange?(next)
    }
}
