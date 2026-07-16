import AppKit

/// Full spend chart popup: title, NOW/AVG/PEAK stats, and a line+area chart.
/// Same pattern as MemBar's HistoryChartView — fed by the same ring buffer.
final class SpendHistoryView: NSView {
    private let samples: [Double]

    private static let chartWidth: CGFloat = 278
    private static let chartHeight: CGFloat = 130
    private static let headerHeight: CGFloat = 60
    private static let footHeight: CGFloat = 30

    private static let totalHeight = headerHeight + chartHeight + footHeight

    // Plot-area coordinates inside the chart box
    private static let plotLeft: CGFloat = 24
    private static let plotRight: CGFloat = 274
    private static let plotBottom: CGFloat = 112
    private static let plotTop: CGFloat = 14

    init(samples: [Double]) {
        self.samples = samples
        super.init(frame: NSRect(x: 0, y: 0, width: menuContentWidth, height: Self.totalHeight))
        setAccessibilityElement(true)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawHeader()
        drawChart()
        drawFooter()
    }

    private func drawHeader() {
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]
        NSAttributedString(string: "Spend \u{00B7} last 30 min", attributes: titleAttrs)
            .draw(at: NSPoint(x: 11, y: 9))

        guard !samples.isEmpty else {
            let emptyAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]
            NSAttributedString(string: "Collecting samples…", attributes: emptyAttrs)
                .draw(at: NSPoint(x: 11, y: 32))
            return
        }

        let now = samples.last ?? 0
        let avg = samples.reduce(0, +) / Double(samples.count)
        let peak = samples.max() ?? now

        let stats: [(String, String, NSColor)] = [
            (RelayHeaderView.formatUSD(now), "NOW", .labelColor),
            (RelayHeaderView.formatUSD(avg), "AVG", .labelColor),
            (RelayHeaderView.formatUSD(peak), "PEAK", .systemOrange),
        ]

        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
        ]
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]

        var x: CGFloat = 11
        let valueY: CGFloat = 30
        for (value, label, color) in stats {
            var vAttrs = valueAttrs
            vAttrs[.foregroundColor] = color
            let vStr = NSAttributedString(string: value, attributes: vAttrs)
            vStr.draw(at: NSPoint(x: x, y: valueY))
            let lStr = NSAttributedString(string: label, attributes: labelAttrs)
            lStr.draw(at: NSPoint(x: x, y: valueY + vStr.size().height + 1))
            x += max(vStr.size().width, lStr.size().width) + 18
        }
    }

    private func drawChart() {
        guard samples.count >= 2 else { return }

        let chartY = Self.headerHeight
        let frame = NSRect(x: Self.plotLeft, y: chartY, width: Self.chartWidth, height: Self.chartHeight)

        let accentColor = NSColor(calibratedRed: 0.20, green: 0.47, blue: 0.94, alpha: 1)

        // Gridlines
        let gridColor = NSColor.black.withAlphaComponent(0.06)
        let axisAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9.5),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]

        let maxV = samples.max() ?? 0
        let range = max(maxV, 0.01)
        let roundedMax = ceil(range / 0.01) * 0.01

        for fraction in stride(from: 0.0, through: 1.0, by: 1.0 / 3.0) {
            let value = roundedMax * fraction
            let y = frame.minY + Self.plotBottom - CGFloat(fraction) * (Self.plotBottom - Self.plotTop)
            let line = NSBezierPath()
            line.move(to: NSPoint(x: frame.minX + 2, y: y))
            line.line(to: NSPoint(x: frame.maxX - 2, y: y))
            line.lineWidth = 1
            gridColor.setStroke()
            line.stroke()

            let label = String(format: "$%.3f", value)
            let labelSize = label.size(withAttributes: axisAttrs)
            NSAttributedString(string: label, attributes: axisAttrs)
                .draw(at: NSPoint(x: frame.minX + Self.plotLeft - 4 - labelSize.width, y: y - labelSize.height / 2))
        }

        let count = samples.count
        let points: [NSPoint] = samples.enumerated().map { index, value in
            let px = frame.minX + Self.plotLeft + CGFloat(index) / CGFloat(count - 1) * (Self.plotRight - Self.plotLeft)
            let normalized = CGFloat(value / roundedMax)
            let py = frame.minY + Self.plotBottom - normalized * (Self.plotBottom - Self.plotTop)
            return NSPoint(x: px, y: py)
        }

        // Fill
        let fillPath = NSBezierPath()
        fillPath.move(to: NSPoint(x: points[0].x, y: frame.minY + Self.plotBottom))
        fillPath.line(to: points[0])
        let linePath = NSBezierPath()
        linePath.move(to: points[0])
        for point in points.dropFirst() {
            linePath.line(to: point)
            fillPath.line(to: point)
        }
        fillPath.line(to: NSPoint(x: points[points.count - 1].x, y: frame.minY + Self.plotBottom))
        fillPath.close()
        accentColor.withAlphaComponent(0.14).setFill()
        fillPath.fill()

        linePath.lineWidth = 2
        linePath.lineCapStyle = .round
        linePath.lineJoinStyle = .round
        accentColor.setStroke()
        linePath.stroke()

        // Peak marker
        if let peakIdx = samples.indices.max(by: { samples[$0] < samples[$1] }) {
            let pp = points[peakIdx]
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: pp.x - 5, y: pp.y - 5, width: 10, height: 10)).fill()
            NSColor.systemOrange.setFill()
            NSBezierPath(ovalIn: NSRect(x: pp.x - 4, y: pp.y - 4, width: 8, height: 8)).fill()
        }
    }

    private func drawFooter() {
        let sepY = Self.headerHeight + Self.chartHeight + 4
        NSColor.black.withAlphaComponent(0.08).setFill()
        NSRect(x: 11, y: sepY, width: bounds.width - 22, height: 1).fill()

        let count = samples.count
        let footer = count < 2
            ? "Graph appears after a few samples"
            : "Hover the chip to open this detail \u{00B7} updates every 30s"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        NSAttributedString(string: footer, attributes: attrs)
            .draw(at: NSPoint(x: 11, y: sepY + 8))
    }
}
