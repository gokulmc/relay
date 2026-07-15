import Foundation

public enum VSCodeSettingsWriterError: Error, CustomStringConvertible {
    case missingOpeningBrace
    case unbalancedBrackets
    case writeFailed(String)

    public var description: String {
        switch self {
        case .missingOpeningBrace:
            return "VS Code settings.json has no opening '{'"
        case .unbalancedBrackets:
            return "VS Code settings.json has unbalanced brackets around claudeCode.environmentVariables"
        case .writeFailed(let message):
            return "Failed to write VS Code settings.json: \(message)"
        }
    }
}

/// Targeted textual patch of `claudeCode.environmentVariables` — preserves
/// JSONC comments and unrelated keys (unlike a full JSON rewrite).
public struct VSCodeSettingsWriter {
    public static let keyName = "claudeCode.environmentVariables"
    public static let baseURLName = "ANTHROPIC_BASE_URL"
    public static let authTokenName = "ANTHROPIC_AUTH_TOKEN"

    private let fileURL: URL
    private let backup: SettingsBackup
    private let indent = "    "

    public init(
        fileURL: URL = VSCodeSettingsWriter.defaultFileURL(),
        appSupportDir: URL = AppSupport.defaultDirectory()
    ) {
        self.fileURL = fileURL
        self.backup = SettingsBackup(appSupportDir: appSupportDir)
    }

    public static func defaultFileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Code/User", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    public func enableProxy(baseURL: String, masterKey: String) throws {
        let entries: [[String: String]] = [
            ["name": Self.baseURLName, "value": baseURL],
            ["name": Self.authTokenName, "value": masterKey],
        ]
        try mutate { text in
            try upsertEnvironmentVariables(in: text, entries: entries)
        }
    }

    public func disableProxy() throws {
        try mutate { text in
            try removeRelayEntries(in: text)
        }
    }

    private func mutate(_ transform: (String) throws -> String) throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            _ = try? backup.backup(sourceURL: fileURL)
        }

        let original: String
        if FileManager.default.fileExists(atPath: fileURL.path) {
            original = try String(contentsOf: fileURL, encoding: .utf8)
        } else {
            original = "{\n}\n"
        }

        let updated = try transform(original)
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try updated.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            throw VSCodeSettingsWriterError.writeFailed(error.localizedDescription)
        }
    }

    private func upsertEnvironmentVariables(in text: String, entries: [[String: String]]) throws -> String {
        let fragment = try serializeKeyValue(entries: entries)
        if let span = try findKeySpan(in: text) {
            // Merge with any non-Relay entries already present.
            let existingJSON = String(text[span.valueRange])
            let merged = try mergeEntries(existingJSON: existingJSON, relayEntries: entries)
            let mergedFragment = try serializeKeyValue(entries: merged)
            var result = text
            result.replaceSubrange(span.keyStart..<span.valueRange.upperBound, with: mergedFragment)
            return result
        }

        guard let braceIndex = text.firstIndex(of: "{") else {
            throw VSCodeSettingsWriterError.missingOpeningBrace
        }
        let insertion = "\n\(indent)\(fragment),"
        var result = text
        let insertAt = text.index(after: braceIndex)
        result.insert(contentsOf: insertion, at: insertAt)
        return result
    }

    private func removeRelayEntries(in text: String) throws -> String {
        guard let span = try findKeySpan(in: text) else { return text }

        let existingJSON = String(text[span.valueRange])
        let remaining = try nonRelayEntries(from: existingJSON)
        if remaining.isEmpty {
            return removeEntireKey(from: text, span: span)
        }

        let fragment = try serializeKeyValue(entries: remaining)
        var result = text
        result.replaceSubrange(span.keyStart..<span.valueRange.upperBound, with: fragment)
        return result
    }

    private struct KeySpan {
        let keyStart: String.Index
        let valueRange: Range<String.Index>
        /// Range covering the key through trailing comma (if any), for full removal.
        let fullRemovalRange: Range<String.Index>
    }

    private func findKeySpan(in text: String) throws -> KeySpan? {
        let pattern = #""claudeCode\.environmentVariables"\s*:\s*"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: nsRange),
              let keyRange = Range(match.range, in: text) else {
            return nil
        }

        let afterColon = keyRange.upperBound
        guard let openBracket = text[afterColon...].firstIndex(of: "[") else {
            return nil
        }
        guard let closeBracket = matchingCloseBracket(in: text, open: openBracket) else {
            throw VSCodeSettingsWriterError.unbalancedBrackets
        }
        let valueRange = openBracket..<text.index(after: closeBracket)

        // Extend past trailing whitespace and optional comma for full key removal.
        var removalEnd = valueRange.upperBound
        var idx = removalEnd
        while idx < text.endIndex, text[idx].isWhitespace, text[idx] != "\n" {
            idx = text.index(after: idx)
        }
        if idx < text.endIndex, text[idx] == "," {
            removalEnd = text.index(after: idx)
        } else {
            removalEnd = valueRange.upperBound
        }

        // Also eat a preceding comma on the prior line when this is the last key.
        var removalStart = keyRange.lowerBound
        var lookBack = text.index(before: removalStart)
        while lookBack > text.startIndex, text[lookBack].isWhitespace {
            lookBack = text.index(before: lookBack)
        }
        // Prefer removing trailing comma after the value; if none, remove preceding comma.
        if text[valueRange.upperBound..<removalEnd].contains(",") == false {
            if lookBack >= text.startIndex, text[lookBack] == "," {
                removalStart = lookBack
            }
        }

        // Include leading indentation/newline for cleaner removal when deleting the whole key.
        var lineStart = keyRange.lowerBound
        while lineStart > text.startIndex {
            let prev = text.index(before: lineStart)
            if text[prev] == "\n" { break }
            if !text[prev].isWhitespace { break }
            lineStart = prev
        }
        if lineStart > text.startIndex, text[text.index(before: lineStart)] == "\n" {
            // Keep one newline context; strip the indented line containing the key.
            removalStart = min(removalStart, lineStart)
        }

        return KeySpan(
            keyStart: keyRange.lowerBound,
            valueRange: valueRange,
            fullRemovalRange: removalStart..<removalEnd
        )
    }

    private func removeEntireKey(from text: String, span: KeySpan) -> String {
        var result = text
        result.replaceSubrange(span.fullRemovalRange, with: "")
        // Clean up double blank lines introduced by removal.
        while result.contains("\n\n\n") {
            result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return result
    }

    private func matchingCloseBracket(in text: String, open: String.Index) -> String.Index? {
        var depth = 0
        var inString = false
        var escape = false
        var idx = open
        while idx < text.endIndex {
            let ch = text[idx]
            if inString {
                if escape {
                    escape = false
                } else if ch == "\\" {
                    escape = true
                } else if ch == "\"" {
                    inString = false
                }
            } else {
                switch ch {
                case "\"":
                    inString = true
                case "[":
                    depth += 1
                case "]":
                    depth -= 1
                    if depth == 0 { return idx }
                default:
                    break
                }
            }
            idx = text.index(after: idx)
        }
        return nil
    }

    private func serializeKeyValue(entries: [[String: String]]) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: entries,
            options: [.prettyPrinted, .withoutEscapingSlashes]
        )
        guard var json = String(data: data, encoding: .utf8) else {
            throw VSCodeSettingsWriterError.writeFailed("could not encode environmentVariables")
        }
        // Indent the array body to match 4-space VS Code settings style.
        let lines = json.split(separator: "\n", omittingEmptySubsequences: false)
        let indented = lines.enumerated().map { index, line -> String in
            if index == 0 { return String(line) }
            return indent + String(line)
        }.joined(separator: "\n")
        json = indented
        return "\"\(Self.keyName)\": \(json)"
    }

    private func mergeEntries(existingJSON: String, relayEntries: [[String: String]]) throws -> [[String: String]] {
        var nonRelay = try nonRelayEntries(from: existingJSON)
        nonRelay.append(contentsOf: relayEntries)
        return nonRelay
    }

    private func nonRelayEntries(from existingJSON: String) throws -> [[String: String]] {
        guard let data = existingJSON.data(using: .utf8),
              let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        let relayNames: Set<String> = [Self.baseURLName, Self.authTokenName]
        return array.compactMap { item in
            guard let name = item["name"] as? String,
                  let value = item["value"] as? String,
                  !relayNames.contains(name) else {
                return nil
            }
            return ["name": name, "value": value]
        }
    }
}
