import AppKit

// Shared design helpers, mirrored from MemBar's design system so both apps
// read as siblings. Content width is the 312pt panel minus 6pt padding each side.
let menuContentWidth: CGFloat = 300

/// SF Rounded variant of the system font — used for hero numerals/titles.
func roundedFont(ofSize size: CGFloat, weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    guard let roundedDescriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
    return NSFont(descriptor: roundedDescriptor, size: size) ?? base
}

/// Appearance-aware color that resolves per draw pass.
func dynamicColor(light: NSColor, dark: NSColor) -> NSColor {
    NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
    }
}

/// Plain single-attribute string for section labels and disabled states.
func styledText(
    _ text: String,
    size: CGFloat,
    weight: NSFont.Weight = .regular,
    color: NSColor = .labelColor,
    kern: CGFloat = 0
) -> NSAttributedString {
    NSAttributedString(string: text, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
        .kern: kern,
    ])
}

/// "Primary  secondary" — bold primary with a smaller, dimmer trailing detail.
func styledInline(
    primary: String,
    primarySize: CGFloat = 13,
    primaryWeight: NSFont.Weight = .semibold,
    primaryColor: NSColor = .labelColor,
    secondary: String,
    secondarySize: CGFloat = 11.5,
    secondaryColor: NSColor = .secondaryLabelColor
) -> NSAttributedString {
    let result = NSMutableAttributedString(string: primary, attributes: [
        .font: NSFont.systemFont(ofSize: primarySize, weight: primaryWeight),
        .foregroundColor: primaryColor,
    ])
    result.append(NSAttributedString(string: "  " + secondary, attributes: [
        .font: NSFont.systemFont(ofSize: secondarySize, weight: .regular),
        .foregroundColor: secondaryColor,
    ]))
    return result
}

/// Draws a single line that tail-truncates inside `rect`.
func drawTruncatingLine(_ text: String, attributes: [NSAttributedString.Key: Any], in rect: NSRect) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingTail
    var attrs = attributes
    attrs[.paragraphStyle] = paragraph
    NSAttributedString(string: text, attributes: attrs).draw(in: rect)
}

func formatUSD(_ value: Double) -> String {
    String(format: "$%.2f", value)
}
