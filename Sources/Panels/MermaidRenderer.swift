import Foundation

enum MermaidTheme: String {
    case light = "default"
    case dark = "dark"

    static func forColorScheme(isDark: Bool) -> MermaidTheme {
        return isDark ? .dark : .light
    }
}

enum MermaidRenderer {
    static let templateResourceName = "template"
    static let templateResourceExtension = "html"
    static let mermaidDirectoryResourceName = "Mermaid"
    static let sourcePlaceholder = "{{SOURCE}}"
    static let themePlaceholder = "{{THEME}}"

    static func htmlDocument(source: String, theme: MermaidTheme, bundle: Bundle = .main) -> String {
        let template = loadBundledTemplate(bundle: bundle) ?? fallbackTemplate
        return apply(template: template, source: source, theme: theme)
    }

    static func apply(template: String, source: String, theme: MermaidTheme) -> String {
        let sourceLiteral = escape(source: source)
        let themeLiteral = escape(source: theme.rawValue)
        return template
            .replacingOccurrences(of: sourcePlaceholder, with: sourceLiteral)
            .replacingOccurrences(of: themePlaceholder, with: themeLiteral)
    }

    static func escape(source: String) -> String {
        // JSON output for [source] is ["..."] — strip the array brackets AND
        // the JSON-added surrounding quotes so we get just the escaped inner
        // content. manualEscape returns the inner content directly. Both paths
        // feed into a single outer-quote wrap at the end, avoiding the
        // double-wrap bug that turned `"dark"` into `""dark""` and broke the
        // JS `var x = {{SOURCE}};` substitution downstream.
        var encoded: String
        if let data = try? JSONSerialization.data(withJSONObject: [source], options: []),
           let json = String(data: data, encoding: .utf8),
           json.count >= 4 {
            let trimmed = String(json.dropFirst(2).dropLast(2))
            encoded = trimmed
        } else {
            encoded = manualEscape(source)
        }
        encoded = encoded
            .replacingOccurrences(of: "</", with: "<\\/")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return "\"\(encoded)\""
    }

    static func loadBundledTemplate(bundle: Bundle = .main) -> String? {
        if let url = bundle.url(
            forResource: templateResourceName,
            withExtension: templateResourceExtension,
            subdirectory: mermaidDirectoryResourceName
        ), let contents = try? String(contentsOf: url, encoding: .utf8) {
            return contents
        }
        if let mermaidDir = bundle.url(forResource: mermaidDirectoryResourceName, withExtension: nil) {
            let candidate = mermaidDir.appendingPathComponent("\(templateResourceName).\(templateResourceExtension)")
            if let contents = try? String(contentsOf: candidate, encoding: .utf8) {
                return contents
            }
        }
        return nil
    }

    static func mermaidResourcesDirectory(bundle: Bundle = .main) -> URL? {
        return bundle.url(forResource: mermaidDirectoryResourceName, withExtension: nil)
    }

    static func templateURL(bundle: Bundle = .main) -> URL? {
        if let url = bundle.url(
            forResource: templateResourceName,
            withExtension: templateResourceExtension,
            subdirectory: mermaidDirectoryResourceName
        ) {
            return url
        }
        if let mermaidDir = bundle.url(forResource: mermaidDirectoryResourceName, withExtension: nil) {
            let candidate = mermaidDir.appendingPathComponent("\(templateResourceName).\(templateResourceExtension)")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    static let fallbackTemplate: String = """
    <!DOCTYPE html>
    <html><head><meta charset="UTF-8"></head>
    <body>
    <script>
    (function(){try{window.webkit.messageHandlers.cmuxMermaid.postMessage({type:"error",kind:"runtimeMissing",message:"bundled mermaid template missing"});}catch(_){}})();
    </script>
    </body></html>
    """

    private static func manualEscape(_ input: String) -> String {
        var output = ""
        output.reserveCapacity(input.count)
        for scalar in input.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case "\u{08}": output += "\\b"
            case "\u{0C}": output += "\\f"
            default:
                if scalar.value < 0x20 {
                    output += String(format: "\\u%04x", scalar.value)
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        return output
    }
}
