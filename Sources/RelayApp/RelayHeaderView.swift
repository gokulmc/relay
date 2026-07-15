import AppKit
import RelayKit

/// Fixed content width matching MemBar's menu panel (312pt − 6pt padding each side).
let menuContentWidth: CGFloat = 300

private func roundedFont(ofSize size: CGFloat, weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    guard let roundedDescriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
    return NSFont(descriptor: roundedDescriptor, size: size) ?? base
}

/// Header: 26pt rounded hero mode name, subline, and proxy status pill.
final class RelayHeaderView: NSView {
    static let height: CGFloat = 64

    private let mode: RoutingMode
    private let proxyStatus: ProxyStatus

    private static let headerPadding: CGFloat = 11
    private static let headerTopInset: CGFloat = 10

    init(mode: RoutingMode, proxyStatus: ProxyStatus) {
        self.mode = mode
        self.proxyStatus = proxyStatus
        super.init(frame: NSRect(x: 0, y: 0, width: menuContentWidth, height: Self.height))
        setAccessibilityElement(true)
        setAccessibilityLabel(Self.accessibilityLabel(mode: mode, proxyStatus: proxyStatus))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override var isFlipped: Bool { true }

    static func accessibilityLabel(mode: RoutingMode, proxyStatus: ProxyStatus) -> String {
        let modeName = mode == .deepSeek ? "DeepSeek" : "Claude"
        return "Routing \(modeName), proxy \(proxyStatus.label)"
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let padding = Self.headerPadding
        let topInset = Self.headerTopInset

        let hero = mode == .deepSeek ? "DeepSeek" : "Claude"
        let heroAttrs: [NSAttributedString.Key: Any] = [
            .font: roundedFont(ofSize: 26, weight: .bold),
            .foregroundColor: NSColor.labelColor,
            .kern: -0.5,
        ]
        NSAttributedString(string: hero, attributes: heroAttrs).draw(at: NSPoint(x: padding, y: topInset))

        let subline = mode == .deepSeek
            ? "via local proxy · port \(AppSupport.defaultPort)"
            : "via claude.ai"
        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        NSAttributedString(string: subline, attributes: subAttrs)
            .draw(at: NSPoint(x: padding, y: topInset + 30))

        drawStatusPill()
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
