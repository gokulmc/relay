import AppKit
import RelayKit

/// One routing target in the menu — Claude or a provider. MemBar app-row style:
/// 20pt colored badge, name + subline, right-aligned mono value, optional `›`.
/// Clicking the row body fires `onSelect` (switch routing); hovering elsewhere
/// still lets AppKit open the item's submenu.
final class RoutingRowView: NSView {
    static let height: CGFloat = 38

    struct Model {
        let name: String
        let subline: String
        let rightText: String?
        let rightTextDimmed: Bool
        let badgeInitial: String
        let badgeColor: NSColor
        let isActive: Bool
        let hasSubmenu: Bool
    }

    private let model: Model
    private let onSelect: () -> Void
    private var isHovering = false

    private let leftPad: CGFloat = 9
    private let rightPad: CGFloat = 7
    private let gap: CGFloat = 10
    private let badgeSize: CGFloat = 20
    private let chevWidth: CGFloat = 8

    init(model: Model, onSelect: @escaping () -> Void) {
        self.model = model
        self.onSelect = onSelect
        super.init(frame: NSRect(x: 0, y: 0, width: menuContentWidth, height: Self.height))
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(model.isActive ? "\(model.name), active" : model.name)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeAlways],
            owner: self, userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        // Row click switches routing; close the menu first so any modal error
        // alert doesn't fight menu tracking.
        enclosingMenuItem?.menu?.cancelTracking()
        DispatchQueue.main.async { [onSelect] in onSelect() }
    }

    override func mouseUp(with event: NSEvent) {}

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let hoverTextWhite = isHovering
        if isHovering {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 7, yRadius: 7)
            NSColor.selectedContentBackgroundColor.setFill()
            path.fill()
        } else if model.isActive {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 7, yRadius: 7)
            model.badgeColor.withAlphaComponent(0.10).setFill()
            path.fill()
        }

        // Badge: rounded square with the provider initial.
        let badgeRect = NSRect(
            x: leftPad + 5,
            y: (bounds.height - badgeSize) / 2,
            width: badgeSize,
            height: badgeSize
        )
        let badgePath = NSBezierPath(roundedRect: badgeRect, xRadius: 6, yRadius: 6)
        if model.isActive {
            model.badgeColor.setFill()
        } else {
            model.badgeColor.withAlphaComponent(0.18).setFill()
        }
        badgePath.fill()
        let initialColor: NSColor = model.isActive ? .white : model.badgeColor
        let initialAttrs: [NSAttributedString.Key: Any] = [
            .font: roundedFont(ofSize: 11, weight: .bold),
            .foregroundColor: initialColor,
        ]
        let initialSize = model.badgeInitial.size(withAttributes: initialAttrs)
        NSAttributedString(string: model.badgeInitial, attributes: initialAttrs).draw(at: NSPoint(
            x: badgeRect.midX - initialSize.width / 2,
            y: badgeRect.midY - initialSize.height / 2
        ))

        // Right column: chevron, then value to its left.
        var rightEdge = bounds.width - rightPad - 4
        if model.hasSubmenu {
            let chevAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
                .foregroundColor: hoverTextWhite ? NSColor.white.withAlphaComponent(0.7) : NSColor.tertiaryLabelColor,
            ]
            let chev = "\u{203A}"
            let chevSize = chev.size(withAttributes: chevAttrs)
            NSAttributedString(string: chev, attributes: chevAttrs).draw(at: NSPoint(
                x: rightEdge - chevWidth,
                y: (bounds.height - chevSize.height) / 2
            ))
            rightEdge -= chevWidth + 6
        }

        var valueLeft = rightEdge
        if let rightText = model.rightText {
            let valueColor: NSColor = hoverTextWhite
                ? .white
                : (model.rightTextDimmed ? .tertiaryLabelColor : .secondaryLabelColor)
            let valueAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold),
                .foregroundColor: valueColor,
            ]
            let valueSize = rightText.size(withAttributes: valueAttrs)
            NSAttributedString(string: rightText, attributes: valueAttrs).draw(at: NSPoint(
                x: rightEdge - valueSize.width,
                y: (bounds.height - valueSize.height) / 2
            ))
            valueLeft = rightEdge - valueSize.width
        }

        // Mid column: name over subline.
        let textLeft = badgeRect.maxX + gap
        let textWidth = max(0, valueLeft - 8 - textLeft)
        let nameColor: NSColor = hoverTextWhite ? .white : .labelColor
        drawTruncatingLine(model.name, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: nameColor,
        ], in: NSRect(x: textLeft, y: 4, width: textWidth, height: 17))

        let sublineColor: NSColor = hoverTextWhite ? NSColor.white.withAlphaComponent(0.75) : .tertiaryLabelColor
        drawTruncatingLine(model.subline, attributes: [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .regular),
            .foregroundColor: sublineColor,
        ], in: NSRect(x: textLeft, y: 21, width: textWidth, height: 14))
    }
}
