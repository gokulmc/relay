import Foundation

/// Text-shaping helpers for menu display. Lives in RelayKit (not RelayApp) so the
/// pure formatting logic is unit-testable without AppKit.
public enum MenuText {
    /// Menu items render as a single line — anything longer wrecks the popup's
    /// layout — so this is the default cap used unless a call site needs a smaller
    /// budget to leave room for extra trailing text.
    public static let defaultSummaryCap = 60

    /// Collapses a possibly multi-line string (e.g. a LiteLLM traceback) into a
    /// single line and hard-truncates it with an ellipsis so it can never blow up
    /// a menu item's layout, however long or newline-riddled the input is.
    public static func menuErrorSummary(_ raw: String, cap: Int = defaultSummaryCap) -> String {
        let singleLine = raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard singleLine.count > cap else { return singleLine }
        let cutoff = singleLine.index(singleLine.startIndex, offsetBy: cap)
        return String(singleLine[..<cutoff]).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }
}
