import AppKit
import RelayKit

/// Fixed content width matching MemBar's menu panel (312pt − 6pt padding each side).
let menuContentWidth: CGFloat = 300

private func roundedFont(ofSize size: CGFloat, weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    guard let roundedDescriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
    return NSFont(descriptor: roundedDescriptor, size: size) ?? base
}

/// Header: 26pt rounded hero mode name, subline, proxy status pill, and (in DeepSeek
/// mode) usage, balance, and a spend sparkline. The sparkline chip is hover-tracked;
/// when the enclosing NSMenuItem is enabled and carries a submenu, hovering the whole
/// header opens it (same pattern MemBar uses for its History popup).
final class RelayHeaderView: NSView {
    private static let baseHeight: CGFloat = 64
    private static let usageLineHeight: CGFloat = 16
    private static let balanceLineHeight: CGFloat = 16

    private let mode: RoutingMode
    private let proxyStatus: ProxyStatus
    private let port: Int
    private let sessionSpendUSD: Double
    private let lifetimeSpendUSD: Double
    private let balanceUSD: Double?
    private let spendHistory: [Double]

    private var isChipHovering = false

    private static let headerPadding: CGFloat = 11
    private static let headerTopInset: CGFloat = 10

    private let sparkW: CGFloat = 58
    private let sparkH: CGFloat = 14

    init(
        mode: RoutingMode,
        proxyStatus: ProxyStatus,
        port: Int = AppSupport.defaultPort,
        sessionSpendUSD: Double = 0,
        lifetimeSpendUSD: Double = 0,
        balanceUSD: Double? = nil,
        spendHistory: [Double] = []
    ) {
        self.mode = mode
        self.proxyStatus = proxyStatus
        self.port = port
        self.sessionSpendUSD = sessionSpendUSD
        self.lifetimeSpendUSD = lifetimeSpendUSD
        self.balanceUSD = balanceUSD
        self.spendHistory = spendHistory
        let extraRows: CGFloat = mode == .deepSeek ? (Self.usageLineHeight + Self.balanceLineHeight) : 0
        super.init(frame: NSRect(x: 0, y: 0, width: menuContentWidth, height: Self.baseHeight + extraRows))
        setAccessibilityElement(true)
        setAccessibilityLabel(Self.accessibilityLabel(mode: mode, proxyStatus: proxyStatus))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override var isFlipped: Bool { true }

    static func accessibilityLabel(mode: RoutingMode, proxyStatus: ProxyStatus) -> String {
        let modeName = mode == .deepSeek ? "DeepSeek" : "Claude"
        return "Routing \(modeName), proxy \(proxyStatus.label)"
    }

    /// The chip area (sparkline + chevron) — exposed so AppDelegate can use a
    /// matching rect for its own tracking or layout calculations.
    var chipRect: NSRect {
        guard mode == .deepSeek, spendHistory.count >= 2 else { return .zero }
        let y = Self.headerTopInset + 30 + 20
        let chipY = y + (Self.usageLineHeight - sparkH) / 2 - 3
        let chipH = sparkH + 6
        return NSRect(
            x: bounds.width - Self.headerPadding - sparkW - 6,
            y: chipY,
            width: sparkW + 12,
            height: chipH
        )
    }

    private var accentColor: NSColor {
        mode == .deepSeek
            ? NSColor(calibratedRed: 0.20, green: 0.47, blue: 0.94, alpha: 1)
            : NSColor(calibratedRed: 0.94, green: 0.42, blue: 0.31, alpha: 1)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        let chip = chipRect
        guard chip != .zero else { return }
        addTrackingArea(NSTrackingArea(
            rect: chip, options: [.mouseEnteredAndExited, .activeAlways],
            owner: self, userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        isChipHovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isChipHovering = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let padding = Self.headerPadding
        let topInset = Self.headerTopInset

        let hero = mode == .deepSeek ? "DeepSeek" : "Claude"
        let heroAttrs: [NSAttributedString.Key: Any] = [
            .font: roundedFont(ofSize: 26, weight: .bold),
            .foregroundColor: accentColor,
            .kern: -0.5,
        ]
        NSAttributedString(string: hero, attributes: heroAttrs).draw(at: NSPoint(x: padding, y: topInset))

        let subline = mode == .deepSeek
            ? "via local proxy · port \(port)"
            : "via claude.ai"
        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        NSAttributedString(string: subline, attributes: subAttrs)
            .draw(at: NSPoint(x: padding, y: topInset + 30))

        drawStatusPill()

        if mode == .deepSeek {
            drawUsageLine()
            drawBalanceLine()
        }
    }

    private func drawUsageLine() {
        let y = Self.headerTopInset + 30 + 20
        let usageText = "\(Self.formatUSD(sessionSpendUSD)) this session · \(Self.formatUSD(lifetimeSpendUSD + sessionSpendUSD)) lifetime"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        NSAttributedString(string: usageText, attributes: attrs)
            .draw(at: NSPoint(x: Self.headerPadding, y: y))

        guard spendHistory.count >= 2 else { return }

        let chip = chipRect
        // Hover fill on the chip
        let chipFillAlpha: CGFloat = isChipHovering ? 0.22 : 0.14
        let chipPath = NSBezierPath(roundedRect: chip, xRadius: 6, yRadius: 6)
        accentColor.withAlphaComponent(chipFillAlpha).setFill()
        chipPath.fill()
        accentColor.withAlphaComponent(0.35).setStroke()
        chipPath.lineWidth = 1
        chipPath.stroke()

        // Sparkline
        let sparkRect = NSRect(x: chip.minX + 6, y: chip.minY + 3, width: sparkW, height: sparkH)
        drawSparkline(in: sparkRect)

        // Chevron
        let chevAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .bold),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let chev = "\u{203A}"
        let chevSize = chev.size(withAttributes: chevAttrs)
        NSAttributedString(string: chev, attributes: chevAttrs)
            .draw(at: NSPoint(x: chip.maxX - 5 - chevSize.width, y: chip.midY - chevSize.height / 2))
    }

    private func drawSparkline(in rect: NSRect) {
        guard spendHistory.count >= 2 else { return }

        let minV = spendHistory.min() ?? 0
        let maxV = spendHistory.max() ?? 0
        let range = max(maxV - minV, 0.0001)
        let count = spendHistory.count

        let points: [NSPoint] = spendHistory.enumerated().map { index, value in
            let px = rect.minX + CGFloat(index) / CGFloat(count - 1) * rect.width
            let normalized = CGFloat((value - minV) / range)
            let py = rect.maxY - normalized * rect.height
            return NSPoint(x: px, y: py)
        }

        let fillPath = NSBezierPath()
        fillPath.move(to: NSPoint(x: points[0].x, y: rect.maxY))
        fillPath.line(to: points[0])
        let linePath = NSBezierPath()
        linePath.move(to: points[0])
        for point in points.dropFirst() {
            linePath.line(to: point)
            fillPath.line(to: point)
        }
        fillPath.line(to: NSPoint(x: points[points.count - 1].x, y: rect.maxY))
        fillPath.close()

        accentColor.withAlphaComponent(0.14).setFill()
        fillPath.fill()

        linePath.lineWidth = 1.5
        linePath.lineCapStyle = .round
        linePath.lineJoinStyle = .round
        accentColor.setStroke()
        linePath.stroke()
    }

    private func drawBalanceLine() {
        let y = Self.headerTopInset + 30 + 20 + Self.usageLineHeight
        let balance: String
        if let b = balanceUSD {
            balance = "Balance: \(Self.formatUSD(b))"
        } else {
            balance = "Balance: —"
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        NSAttributedString(string: balance, attributes: attrs)
            .draw(at: NSPoint(x: Self.headerPadding, y: y))
    }

    static func formatUSD(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }

    private func drawStatusPill() {
        let (label, color): (String, NSColor) = {
            switch proxyStatus {
            case .running: return ("Running", .systemGreen)
            case .starting: return ("Starting…", .systemOrange)
            case .failed: return ("Failed", .systemRed)
            case .stopped: return ("Stopped", .secondaryLabelColor)
            }
        }()

        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let textSize = label.size(withAttributes: [.font: font])
        let padH: CGFloat = 8
        let padV: CGFloat = 3
        let dot: CGFloat = 6
        let gap: CGFloat = 5
        let width = padH + dot + gap + textSize.width + padH
        let height = textSize.height + padV * 2
        let x = bounds.width - Self.headerPadding - width
        let y = Self.headerTopInset
        let rect = NSRect(x: x, y: y, width: width, height: height)

        let bg = color.withAlphaComponent(0.18)
        let path = NSBezierPath(roundedRect: rect, xRadius: height / 2, yRadius: height / 2)
        bg.setFill()
        path.fill()

        let dotRect = NSRect(
            x: rect.minX + padH,
            y: rect.midY - dot / 2,
            width: dot,
            height: dot
        )
        let dotPath = NSBezierPath(ovalIn: dotRect)
        color.setFill()
        dotPath.fill()

        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
        ]
        NSAttributedString(string: label, attributes: textAttrs)
            .draw(at: NSPoint(x: rect.minX + padH + dot + gap, y: rect.minY + padV))
    }
}
