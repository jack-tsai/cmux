import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class MermaidRendererTests: XCTestCase {
    func testEscapeWrapsInDoubleQuotesAndJSONEncodesControlChars() {
        let result = MermaidRenderer.escape(source: "hello\nworld\t\"end\"")
        XCTAssertEqual(result, "\"hello\\nworld\\t\\\"end\\\"\"")
    }

    func testEscapeNeutralisesScriptCloseSequence() {
        let result = MermaidRenderer.escape(source: "</script>")
        XCTAssertFalse(result.contains("</"), "</ must be escaped as <\\/ to avoid HTML parser breakout")
        XCTAssertTrue(result.contains("<\\/script>"))
    }

    func testEscapeEncodesLineSeparatorAndParagraphSeparator() {
        let input = "a\u{2028}b\u{2029}c"
        let result = MermaidRenderer.escape(source: input)
        XCTAssertTrue(result.contains("\\u2028"))
        XCTAssertTrue(result.contains("\\u2029"))
        XCTAssertFalse(result.unicodeScalars.contains(Unicode.Scalar(0x2028)!))
        XCTAssertFalse(result.unicodeScalars.contains(Unicode.Scalar(0x2029)!))
    }

    func testEscapeEscapesBackslash() {
        let result = MermaidRenderer.escape(source: "a\\b")
        XCTAssertEqual(result, "\"a\\\\b\"")
    }

    func testEscapeHandlesEmptyString() {
        XCTAssertEqual(MermaidRenderer.escape(source: ""), "\"\"")
    }

    func testApplySubstitutesBothPlaceholders() {
        let template = "var s = \(MermaidRenderer.sourcePlaceholder); var t = \(MermaidRenderer.themePlaceholder);"
        let result = MermaidRenderer.apply(template: template, source: "graph TD", theme: .dark)
        XCTAssertEqual(result, "var s = \"graph TD\"; var t = \"dark\";")
    }

    func testApplyInjectsDarkThemeAsMermaidDarkString() {
        let template = MermaidRenderer.themePlaceholder
        let dark = MermaidRenderer.apply(template: template, source: "x", theme: .dark)
        let light = MermaidRenderer.apply(template: template, source: "x", theme: .light)
        XCTAssertEqual(dark, "\"dark\"")
        XCTAssertEqual(light, "\"default\"")
    }

    func testThemeForColorScheme() {
        XCTAssertEqual(MermaidTheme.forColorScheme(isDark: true), .dark)
        XCTAssertEqual(MermaidTheme.forColorScheme(isDark: false), .light)
        XCTAssertEqual(MermaidTheme.dark.rawValue, "dark")
        XCTAssertEqual(MermaidTheme.light.rawValue, "default")
    }

    func testApplyWithMaliciousSourceDoesNotBreakOutOfStringLiteral() {
        // A malicious source that tries to close the JS string and inject code
        // must remain a single quoted literal after escape + apply. The inner
        // `"` MUST be escaped to `\"`. The `/` characters may be defensively
        // escaped to `\/` by JSONSerialization (both forms are semantically
        // equivalent inside a JS string literal, so accept either).
        let malicious = "\";alert(1);//"
        let template = "var s = \(MermaidRenderer.sourcePlaceholder);"
        let result = MermaidRenderer.apply(template: template, source: malicious, theme: .light)
        let expectedUnescapedSlashes = "var s = \"\\\";alert(1);//\";"
        let expectedEscapedSlashes = "var s = \"\\\";alert(1);\\/\\/\";"
        XCTAssertTrue(
            result == expectedUnescapedSlashes || result == expectedEscapedSlashes,
            "got: \(result)"
        )
        // Whichever form, the malicious quote must remain neutralised so the
        // JS string literal continues past the semicolon rather than closing.
        XCTAssertTrue(result.hasPrefix("var s = \"\\\";"))
        XCTAssertTrue(result.hasSuffix("\";"))
    }

    func testHtmlDocumentFallsBackWhenBundleLacksTemplate() {
        // The cmuxTests bundle does not contain Resources/Mermaid, so htmlDocument
        // must return the fallback template (which posts a runtimeMissing error).
        let bundle = Bundle(for: type(of: self))
        let html = MermaidRenderer.htmlDocument(source: "x", theme: .light, bundle: bundle)
        XCTAssertTrue(html.contains("runtimeMissing"))
        XCTAssertTrue(html.contains("bundled mermaid template missing"))
    }

    func testLoadBundledTemplateReturnsNilForEmptyBundle() {
        let bundle = Bundle(for: type(of: self))
        XCTAssertNil(MermaidRenderer.loadBundledTemplate(bundle: bundle))
        XCTAssertNil(MermaidRenderer.templateURL(bundle: bundle))
        XCTAssertNil(MermaidRenderer.mermaidResourcesDirectory(bundle: bundle))
    }
}
