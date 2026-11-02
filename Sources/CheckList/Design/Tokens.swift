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
}

enum Design {
    static let ink = Color(hex: 0x134E4A)
    static let body = Color(hex: 0x1E293B)
    static let secondary = Color(hex: 0x64748B)
    static let teal = Color(hex: 0x0FBFA0)
    static let darkTeal = Color(hex: 0x02332B)
    static let danger = Color(hex: 0xE11D48)
    static let accent = LinearGradient(colors: [Color(hex: 0x3FF0CD), teal], startPoint: .top, endPoint: .bottom)
}

struct GlassSurface: ViewModifier {
    var radius: CGFloat = 16
    var thin = true

    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !thin {
            content
                .glassEffect(.regular.tint(.white.opacity(0.15)), in: RoundedRectangle(cornerRadius: radius))
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius))
                .overlay {
                    RoundedRectangle(cornerRadius: radius)
                        .strokeBorder(.white.opacity(thin ? 0.6 : 0.65), lineWidth: 1)
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
            .background(.white.opacity(configuration.isPressed ? 0.7 : 0.45), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.7), lineWidth: 1))
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
        if bill.isPaid { return Color(hex: 0x115E59) }
        return days < 0 ? Color(hex: 0xBE123C) : days == 0 ? Color(hex: 0x92400E) :
            days <= 3 ? Color(hex: 0x9A3412) : Color(hex: 0x115E59)
    }
    private var fill: Color {
        if bill.isPaid { return Color(hex: 0x2DD4BF).opacity(0.25) }
        return days < 0 ? Color(hex: 0xF43F5E).opacity(0.2) : days == 0 ? Color(hex: 0xFBBF24).opacity(0.3) :
            days <= 3 ? Color(hex: 0xFDBA74).opacity(0.3) : Color(hex: 0x2DD4BF).opacity(0.2)
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
