import SwiftUI
import AppKit

@MainActor
enum BrandAssets {
    static let logo: NSImage = {
        guard let url = Bundle.main.url(forResource: "logo", withExtension: "png", subdirectory: "Brand"),
              let image = NSImage(contentsOf: url) else { return NSApp.applicationIconImage }
        return image
    }()
}

struct ProductLogo: View {
    var size: CGFloat = 32
    var body: some View {
        Image(nsImage: BrandAssets.logo).resizable().interpolation(.high).scaledToFit()
            .frame(width: size, height: size).accessibilityHidden(true)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 255) / 255,
                  green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1)
    }

    /// Resolve from the hosting window's native appearance so AppKit controls,
    /// SwiftUI text and material surfaces all use the same light/dark palette.
    static func adaptive(_ light: UInt32, dark: UInt32,
                         lightAlpha: Double = 1, darkAlpha: Double = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: Double((hex >> 16) & 255) / 255,
                           green: Double((hex >> 8) & 255) / 255,
                           blue: Double(hex & 255) / 255,
                           alpha: isDark ? darkAlpha : lightAlpha)
        })
    }
}

enum Design {
    static let ink = Color.adaptive(0x134E4A, dark: 0xB9F5E6)
    static let body = Color.adaptive(0x1E293B, dark: 0xE6F2EF)
    static let secondary = Color.adaptive(0x64748B, dark: 0xA8BDB7)
    static let currency = Color.adaptive(0x0F766E, dark: 0x5EEAD4)
    static let teal = Color(hex: 0x0FBFA0)
    // Primary buttons remain bright mint in both modes and need dark text.
    static let darkTeal = Color(hex: 0x02332B)
    static let danger = Color.adaptive(0xE11D48, dark: 0xFDA4AF)
    static let accent = LinearGradient(colors: [Color(hex: 0x3FF0CD), teal], startPoint: .top, endPoint: .bottom)
    static let windowTop = Color.adaptive(0xD7EEEF, dark: 0x0E2B26, lightAlpha: 0.5, darkAlpha: 0.94)
    static let windowBottom = Color.adaptive(0xBDF5E6, dark: 0x071D1A, lightAlpha: 0.3, darkAlpha: 0.98)
    static let glassTint = Color.adaptive(0xFFFFFF, dark: 0x0C251F, lightAlpha: 0.15, darkAlpha: 0.72)
    static let thinTint = Color.adaptive(0xFFFFFF, dark: 0x12362D, lightAlpha: 0, darkAlpha: 0.85)
    static let glassBorder = Color.adaptive(0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.6, darkAlpha: 0.14)
    static let ghostFill = Color.adaptive(0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.45, darkAlpha: 0.07)
    static let ghostPressed = Color.adaptive(0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.7, darkAlpha: 0.14)
    static let ghostBorder = Color.adaptive(0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.7, darkAlpha: 0.16)
    static let sidebarFill = Color.adaptive(0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.1, darkAlpha: 0.025)
    static let sidebarDivider = Color.adaptive(0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.5, darkAlpha: 0.1)
    static let selectionFill = Color.adaptive(0xFFFFFF, dark: 0x3FF0CD, lightAlpha: 0.7, darkAlpha: 0.14)
    static let rowHover = Color.adaptive(0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.15, darkAlpha: 0.05)
    static let popoverFill = Color.adaptive(0xD6F8EF, dark: 0x071E1B, lightAlpha: 0.25, darkAlpha: 0.85)
    static let settingsFill = Color.adaptive(0xFFFFFF, dark: 0x0A241F, lightAlpha: 0, darkAlpha: 0.9)
    static let overdueText = Color.adaptive(0xBE123C, dark: 0xFDA4AF)
    static let todayText = Color.adaptive(0x92400E, dark: 0xFDE68A)
    static let soonText = Color.adaptive(0x9A3412, dark: 0xFED7AA)
    static let futureText = Color.adaptive(0x115E59, dark: 0x99F6E4)
    static let overdueFill = Color.adaptive(0xF43F5E, dark: 0xF43F5E, lightAlpha: 0.2, darkAlpha: 0.16)
    static let todayFill = Color.adaptive(0xFBBF24, dark: 0xFBBF24, lightAlpha: 0.3, darkAlpha: 0.15)
    static let soonFill = Color.adaptive(0xFDBA74, dark: 0xFDBA74, lightAlpha: 0.3, darkAlpha: 0.14)
    static let futureFill = Color.adaptive(0x2DD4BF, dark: 0x2DD4BF, lightAlpha: 0.2, darkAlpha: 0.14)
    static let paidFill = Color.adaptive(0x2DD4BF, dark: 0x2DD4BF, lightAlpha: 0.25, darkAlpha: 0.16)
}

struct GlassSurface: ViewModifier {
    var radius: CGFloat = 16
    var thin = true

    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !thin {
            content
                .glassEffect(.regular.tint(Design.glassTint), in: RoundedRectangle(cornerRadius: radius))
        } else {
            content
                .background(Design.thinTint, in: RoundedRectangle(cornerRadius: radius))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius))
                .overlay {
                    RoundedRectangle(cornerRadius: radius)
                        .strokeBorder(Design.glassBorder, lineWidth: 1)
                        .allowsHitTesting(false)
                }
        }
    }
}

extension View {
    func glassCard(radius: CGFloat = 16, thin: Bool = true) -> some View {
        modifier(GlassSurface(radius: radius, thin: thin))
    }
}

struct TealButtonStyle: ButtonStyle {
    var height: CGFloat = 28
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 14)
            .frame(height: height)
            .foregroundStyle(Design.darkTeal)
            .background(Design.accent, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.65), lineWidth: 0.7))
            .shadow(color: Design.teal.opacity(0.35), radius: 10, y: 4)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Capsule())
    }
}

struct GhostButtonStyle: ButtonStyle {
    var height: CGFloat = 28
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 12)
            .frame(height: height)
            .foregroundStyle(Design.ink)
            .background(configuration.isPressed ? Design.ghostPressed : Design.ghostFill, in: Capsule())
            .overlay(Capsule().strokeBorder(Design.ghostBorder, lineWidth: 1))
            .contentShape(Capsule())
    }
}

struct KindIcon: View {
    let kind: BillKind
    var size: CGFloat = 36
    var body: some View {
        Image(systemName: kind.symbol)
            .font(.system(size: size * 0.45, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(LinearGradient(
                colors: kind == .creditCard ? [Color(hex: 0x38BDF8), Color(hex: 0x6366F1)] :
                    [Color(hex: 0xFCD34D), Color(hex: 0xF97316)],
                startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: size / 3))
            .shadow(color: .black.opacity(0.1), radius: 3, y: 2)
            .accessibilityHidden(true)
    }
}

struct DueBadge: View {
    let bill: Bill
    var now = Date()
    private var days: Int { bill.daysLeft(now: now) }
    private var color: Color {
        if bill.isPaid { return Design.futureText }
        return days < 0 ? Design.overdueText : days == 0 ? Design.todayText :
            days <= 3 ? Design.soonText : Design.futureText
    }
    private var fill: Color {
        if bill.isPaid { return Design.paidFill }
        return days < 0 ? Design.overdueFill : days == 0 ? Design.todayFill :
            days <= 3 ? Design.soonFill : Design.futureFill
    }
    private var text: String {
        bill.isPaid ? "已还款" : days < 0 ? "逾期 \(-days) 天" : days == 0 ? "今天到期" : "\(days) 天后"
    }
    var body: some View {
        Text(text).font(.system(size: 10, weight: .medium))
            .foregroundStyle(color).padding(.horizontal, 10).padding(.vertical, 4)
            .background(fill, in: Capsule()).fixedSize()
    }
}

struct CountingAmount: View, Animatable {
    nonisolated var cents: Double
    nonisolated var animatableData: Double {
        get { cents }
        set { cents = newValue }
    }
    var body: some View {
        Text(Money.format(Int64(cents.rounded())))
            .monospacedDigit()
    }
}
