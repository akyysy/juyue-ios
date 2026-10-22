import XCTest
@testable import LegadoCore

/// 真 XPath 回归测试：这些写法 XPathToCSS 翻不动，只有 libxml2 能算。
final class XPathRuleTests: XCTestCase {

    private let html = """
    <html><body>
        <div class="bookname"><a href="/book/1">第一本</a></div>
        <div class="bookname"><a href="/book/2">第二本</a></div>
        <div class="bookname"><a href="/book/3">第三本</a></div>
        <div class="meta"><span>作者:甲</span></div>
        <div class="meta"><span>作者:乙</span></div>
        <ul class="chapters">
            <li><a href="/c/1">第一章</a></li>
            <li><a href="/c/2">第二章</a></li>
        </ul>
    </body></html>
    """

    private func analyzer() -> RuleAnalyzer {
        RuleAnalyzer(content: html, baseUrl: "https://example.com")
    }

    func testMultiPredicateWithPosition() {
        XCTAssertEqual(analyzer().getString(#"//div[@class="bookname"][2]/a@text"#), "第二本")
    }

    func testLastFunction() {
        XCTAssertEqual(analyzer().getString(#"/html/body/ul/li[last()]/a@text"#), "第二章")
    }

    func testFollowingSiblingAxis() {
        XCTAssertEqual(
            analyzer().getString(#"//div[@class="meta"][1]/following-sibling::div[1]/span@text"#),
            "作者:乙"
        )
    }

    func testPositionFunction() {
        XCTAssertEqual(analyzer().getString(#"//ul/li[position()=1]/a@href"#), "/c/1")
    }

    func testUnionExpression() {
        let elements = analyzer().getElements(#"//div[@class="bookname"] | //ul/li"#)
        XCTAssertEqual(elements.count, 5)
    }

    func testSimpleXPathStillWorksAfterFallback() {
        // 原来 XPathToCSS 就能翻的写法，不能因为加了 libxml2 而退化
        XCTAssertEqual(analyzer().getString(#"//div[@class="bookname"]/a@text"#), "第一本")
    }
}
