import AppKit

/// Single-color menu-bar reduction of the product mark: binding rings, bill page,
/// repayment check, and folded corner. Drawn as a template so the menu bar tints it.
@MainActor
enum MenuBarMark {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            draw()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "出账日"
        return image
    }()

    /// Outstanding bills are a liability, so a positive balance is shown as negative.
    static func amount(cents: Int64) -> String {
        let amount = "¥" + Money.format(cents, fraction: false)
        return cents > 0 ? "−" + amount : amount
    }

    private static func draw() {
        NSColor.black.setStroke()
        let page = pagePath(left: 2.35, bottom: 1.45, right: 15.7, top: 12.55, radius: 2.15, fold: 3.35)
        page.lineWidth = 1.25
        page.lineJoinStyle = .round
        page.lineCapStyle = .round
        page.stroke()

        let crease = NSBezierPath()
        crease.move(to: NSPoint(x: 15.7, y: 4.8))
        crease.line(to: NSPoint(x: 12.35, y: 4.8))
        crease.line(to: NSPoint(x: 12.35, y: 1.45))
        crease.lineWidth = 1.15
        crease.lineJoinStyle = .round
        crease.lineCapStyle = .round
        crease.stroke()

        let rings = NSBezierPath()
        rings.lineWidth = 1.7
        rings.lineCapStyle = .round
        rings.move(to: NSPoint(x: 6.15, y: 11.85))
        rings.line(to: NSPoint(x: 6.15, y: 16.15))
        rings.move(to: NSPoint(x: 11.85, y: 11.85))
        rings.line(to: NSPoint(x: 11.85, y: 16.15))
        rings.stroke()

        let check = NSBezierPath()
        check.lineWidth = 1.45
        check.lineCapStyle = .round
        check.lineJoinStyle = .round
        check.move(to: NSPoint(x: 5.55, y: 7.35))
        check.line(to: NSPoint(x: 8.05, y: 4.9))
        check.line(to: NSPoint(x: 12.7, y: 10.05))
        check.stroke()
    }

    private static func pagePath(left: CGFloat, bottom: CGFloat, right: CGFloat, top: CGFloat,
                                 radius: CGFloat, fold: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: left + radius, y: top))
        path.line(to: NSPoint(x: right - radius, y: top))
        path.appendArc(from: NSPoint(x: right, y: top), to: NSPoint(x: right, y: top - radius), radius: radius)
        path.line(to: NSPoint(x: right, y: bottom + fold))
        path.line(to: NSPoint(x: right - fold, y: bottom))
        path.line(to: NSPoint(x: left + radius, y: bottom))
        path.appendArc(from: NSPoint(x: left, y: bottom), to: NSPoint(x: left, y: bottom + radius), radius: radius)
        path.line(to: NSPoint(x: left, y: top - radius))
        path.appendArc(from: NSPoint(x: left, y: top), to: NSPoint(x: left + radius, y: top), radius: radius)
        path.close()
        return path
    }
}
