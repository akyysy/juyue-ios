import XCTest
@testable import LegadoCore

/// 书源规则语法回归：`@css:` / `@xpath:` 前缀、`@get:{key}` 变量、
/// `%%` 交叉合并，以及 `&&` / `||` 只在顶层切分。
final class RuleSyntaxTests: XCTestCase {

    private let html = """
    <html><body>
        <div class="bookname"><a href="/book/1">第一本</a></div>
        <div class="bookname"><a href="/book/2">第二本</a></div>
        <ul><li>甲</li><li>乙</li></ul>
        <ol><li>1</li><li>2</li></ol>
    </body></html>
    """

    private func analyzer() -> RuleAnalyzer {
        RuleAnalyzer(content: html, baseUrl: "https://example.com")
    }

    // MARK: - @css: / @xpath: 前缀

    func testAtCssPrefixText() {
        XCTAssertEqual(analyzer().getString("@css:.bookname a@text"), "第一本")
    }

    func testAtCssPrefixHref() {
        XCTAssertEqual(analyzer().getString("@css:.bookname a@href"), "/book/1")
    }

    func testAtXpathPrefix() {
        XCTAssertEqual(analyzer().getString(#"@xpath://div[@class="bookname"]/a@text"#), "第一本")
    }

    func testTokenizerKeepsPrefixType() {
        let steps = RuleTokenizer.parse(#"@xpath://div[@class="bookname"]/a@text"#)
        XCTAssertEqual(steps.first?.type, .xpath(#"//div[@class="bookname"]/a"#))
        XCTAssertEqual(steps.last?.type, .attribute("text"))
    }

    // MARK: - @get:{key}

    func testGetVariableInUrlTemplate() {
        let engine = JSEngine()
        _ = engine.eval(script: "java.put('cid','42')")
        let expanded = JSEngine.expandSourceVariables("https://x.com/@get:{cid}/{{1+1}}.html")
        XCTAssertEqual(expanded, "https://x.com/42/{{1+1}}.html")
        XCTAssertEqual(engine.renderTemplate(expanded), "https://x.com/42/2.html")
    }

    func testGetVariableMissingBecomesEmpty() {
        XCTAssertEqual(
            JSEngine.expandSourceVariables("https://x.com/@get:{definitely_not_set}/a"),
            "https://x.com//a"
        )
    }

    // MARK: - %% 交叉合并

    func testPercentMergesListsAlternately() {
        let merged = analyzer().getStringList("@css:ul li@text%%@css:ol li@text")
        XCTAssertEqual(merged, ["甲", "1", "乙", "2"])
    }

    // MARK: - && / || 只切顶层

    func testSplitTopLevelIgnoresQuotedPipe() {
        XCTAssertNil(RuleAnalyzer.splitTopLevel(#"@css:a[title="x||y"]"#, by: "||"))
    }

    func testSplitTopLevelIgnoresTemplateBraces() {
        XCTAssertNil(RuleAnalyzer.splitTopLevel(#"{{page==1?"a&&b":"c"}}"#, by: "&&"))
    }

    func testSplitTopLevelSplitsPlainRule() {
        XCTAssertEqual(RuleAnalyzer.splitTopLevel("a||b", by: "||"), ["a", "b"])
    }

    func testFallbackOperatorStillFallsThrough() {
        // 第一条取不到，回退到第二条
        XCTAssertEqual(analyzer().getString("@css:.nope a@text||@css:.bookname a@text"), "第一本")
    }
}
