import AppKit
import RelayKit

/// Header: 26pt rounded hero name, status pill top-right, subline with semibold
/// values, and (in provider mode) a usage line with a hover-tracked sparkline
/// chip plus an optional balance line. The enclosing NSMenuItem carries the
/// spend-history submenu, so hovering the header opens it (MemBar pattern).
final class RelayHeaderView: NSView {
    private static let baseHeight: CGFloat = 64
    private static let usageLineHeight: CGFloat = 18
    private static let balanceLineHeight: CGFloat = 16

    private let mode: RoutingMode
    private let provider: Provider?
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
        provider: Provider? = nil,
        proxyStatus: ProxyStatus,
        port: Int = AppSupport.defaultPort,
        sessionSpendUSD: Double = 0,
        lifetimeSpendUSD: Double = 0,
        balanceUSD: Double? = nil,
        spendHistory: [Double] = []
    ) {
        self.mode = mode
        self.provider = provider
        self.proxyStatus = proxyStatus
        self.port = port
        self.sessionSpendUSD = sessionSpendUSD
        self.lifetimeSpendUSD = lifetimeSpendUSD
        self.balanceUSD = balanceUSD
        self.spendHistory = spendHistory
        let balanceLine: CGFloat = (mode == .deepSeek && provider?.hasBalance == true) ? Self.balanceLineHeight : 0
        let extraRows: CGFloat = mode == .deepSeek ? (Self.usageLineHeight + balanceLine) : 0
        super.init(frame: NSRect(x: 0, y: 0, width: menuContentWidth, height: Self.baseHeight + extraRows))
        setAccessibilityElement(true)
        setAccessibilityLabel(Self.accessibilityLabel(mode: mode, provider: provider, proxyStatus: proxyStatus))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override var isFlipped: Bool { true }

    static func accessibilityLabel(mode: RoutingMode, provider: Provider?, proxyStatus: ProxyStatus) -> String {
        let target = mode == .deepSeek ? (provider?.displayName ?? "provider") : "Claude"
        return "Routing \(target), proxy \(proxyStatus.label)"
    }

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

    private var heroName: String {
        guard let provider, mode == .deepSeek else { return "Claude" }
        return provider.displayName
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

        let heroAttrs: [NSAttributedString.Key: Any] = [
            .font: roundedFont(ofSize: 26, weight: .bold),
            .foregroundColor: accentColor,
            .kern: -0.5,
        ]
        NSAttributedString(string: heroName, attributes: heroAttrs).draw(at: NSPoint(x: padding, y: topInset))

        drawSubline(at: NSPoint(x: padding, y: topInset + 30))
        drawStatusPill()

        if mode == .deepSeek {
            drawUsageLine()
            drawBalanceLine()
        }
    }

    /// "via local proxy · port 4010" with semibold values (MemBar buildSubline pattern).
    private func drawSubline(at point: NSPoint) {
        let regular: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let semibold: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let line = NSMutableAttributedString()
        if mode == .deepSeek {
            line.append(NSAttributedString(string: "via local proxy \u{00B7} port ", attributes: regular))
            line.append(NSAttributedString(string: "\(port)", attributes: semibold))
        } else {
            line.append(NSAttributedString(string: "via ", attributes: regular))
            line.append(NSAttributedString(string: "claude.ai", attributes: semibold))
        }
        line.draw(at: point)
    }

    private func drawUsageLine() {
        let y = Self.headerTopInset + 30 + 20
        let regular: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let semibold: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let line = NSMutableAttributedString()
        line.append(NSAttributedString(string: formatUSD(sessionSpendUSD), attributes: semibold))
        line.append(NSAttributedString(string: " session \u{00B7} ", attributes: regular))
        line.append(NSAttributedString(string: formatUSD(lifetimeSpendUSD + sessionSpendUSD), attributes: semibold))
        line.append(NSAttributedString(string: " lifetime", attributes: regular))
        line.draw(at: NSPoint(x: Self.headerPadding, y: y))

        guard spendHistory.count >= 2 else { return }

        let chip = chipRect
        let chipFillAlpha: CGFloat = isChipHovering ? 0.22 : 0.14
        let chipPath = NSBezierPath(roundedRect: chip, xRadius: 6, yRadius: 6)
        accentColor.withAlphaComponent(chipFillAlpha).setFill()
        chipPath.fill()
        accentColor.withAlphaComponent(0.35).setStroke()
        chipPath.lineWidth = 1
        chipPath.stroke()

        let sparkRect = NSRect(x: chip.minX + 6, y: chip.minY + 3, width: sparkW - 8, height: sparkH)
        drawSparkline(in: sparkRect)

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
        guard provider?.hasBalance == true else { return }
        let y = Self.headerTopInset + 30 + 20 + Self.usageLineHeight
        let regular: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let semibold: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let line = NSMutableAttributedString(string: "Balance ", attributes: regular)
        line.append(NSAttributedString(string: balanceUSD.map(formatUSD) ?? "\u{2014}", attributes: semibold))
        line.draw(at: NSPoint(x: Self.headerPadding, y: y))
    }

    private func drawStatusPill() {
        let (label, color): (String, NSColor) = {
            switch proxyStatus {
            case .running: return ("Running", .systemGreen)
            case .starting: return ("Starting\u{2026}", .systemOrange)
            case .failed: return ("Failed", .systemRed)
            case .stopped: return ("Stopped", .secondaryLabelColor)
            }
        }()

        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let textSize = label.size(withAttributes: [.font: font])
        let padH: CGFloat = 9
        let padV: CGFloat = 3
        let dot: CGFloat = 6
        let gap: CGFloat = 5
        let width = padH + dot + gap + textSize.width + padH
        let height = textSize.height + padV * 2
        let x = bounds.width - Self.headerPadding - width
        let y = Self.headerTopInset
        let rect = NSRect(x: x, y: y, width: width, height: height)

        let path = NSBezierPath(roundedRect: rect, xRadius: height / 2, yRadius: height / 2)
        color.withAlphaComponent(0.18).setFill()
        path.fill()

        let dotRect = NSRect(x: rect.minX + padH, y: rect.midY - dot / 2, width: dot, height: dot)
        color.setFill()
        NSBezierPath(ovalIn: dotRect).fill()

        NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: color])
            .draw(at: NSPoint(x: rect.minX + padH + dot + gap, y: rect.minY + padV))
    }
}
