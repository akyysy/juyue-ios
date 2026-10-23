import Foundation
import SwiftSoup
import Kanna

public class RuleAnalyzer {
    public let content: Any
    public let baseUrl: String?
    public let jsEngine: JSEngine

    private var parsedDocument: Document?
    private var parsedJson: Any?

    public init(content: Any, baseUrl: String? = nil, bookSource: BookSource? = nil, jsEngine: JSEngine? = nil) {
        self.content = content
        self.baseUrl = baseUrl
        self.jsEngine = jsEngine ?? JSEngine(bookSource: bookSource, baseUrl: baseUrl)

        if let stringContent = content as? String {
            let trimmed = stringContent.trimmingCharacters(in: .whitespacesAndNewlines)
            if (trimmed.starts(with: "{") && trimmed.hasSuffix("}")) ||
               (trimmed.starts(with: "[") && trimmed.hasSuffix("]")),
               let data = trimmed.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) {
                self.parsedJson = json
            } else {
                self.parsedDocument = try? SwiftSoup.parse(stringContent, baseUrl ?? "")
            }
        } else if let dict = content as? [String: Any] {
            self.parsedJson = dict
        } else if let array = content as? [Any] {
            self.parsedJson = array
        }
    }

    /// Resolves relative URLs using baseUrl
    public func resolveUrl(_ urlString: String) -> String {
        guard let base = baseUrl, let baseUrlObj = URL(string: base) else {
            return urlString
        }
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.starts(with: "http://") || trimmed.starts(with: "https://") {
            return trimmed
        }
        return URL(string: trimmed, relativeTo: baseUrlObj)?.absoluteString ?? trimmed
    }

    /// Evaluates template expressions with {{...}} placeholders
    public func evaluateTemplate(_ template: String) -> String {
        var result = template
        let pattern = "\\{\\{(.*?)\\}\\}"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return template }
        let matches = regex.matches(in: template, range: NSRange(location: 0, length: (template as NSString).length))

        for match in matches.reversed() {
            let fullRange = match.range
            let innerRange = match.range(at: 1)
            let innerExpr = (template as NSString).substring(with: innerRange).trimmingCharacters(in: .whitespacesAndNewlines)

            var evaluatedValue = ""
            if (innerExpr.starts(with: "'") && innerExpr.hasSuffix("'")) || (innerExpr.starts(with: "\"") && innerExpr.hasSuffix("\"")) {
                evaluatedValue = String(innerExpr.dropFirst().dropLast())
                    .replacingOccurrences(of: "\\n", with: "\n")
                    .replacingOccurrences(of: "\\t", with: "\t")
            } else if innerExpr.starts(with: "java.") || innerExpr.starts(with: "source.") || innerExpr.starts(with: "book.") {
                let jsRes = jsEngine.evalRule(script: innerExpr, result: content)
                evaluatedValue = jsRes != nil ? "\(jsRes!)" : ""
            } else {
                evaluatedValue = getString(innerExpr)
            }

            result = (result as NSString).replacingCharacters(in: fullRange, with: evaluatedValue)
        }
        return result
    }

    /// Evaluates a rule string and returns a single string result
    public func getString(_ rule: String?, isUrl: Bool = false) -> String {
        guard let rawRule = rule?.trimmingCharacters(in: .whitespacesAndNewlines), !rawRule.isEmpty else {
            return ""
        }
        // `@get:{key}` 在整条规则的入口就展开，URL、正文、目录都走这里。
        let rule = JSEngine.expandSourceVariables(rawRule)

        // 安卓语法的 @json: 明确取 JSONPath；和 $.xxx 等价，但优先级更高
        if rule.hasPrefix("@json:"), let json = parsedJson {
            let path = String(rule.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            if let value = JSONPath.evaluate(path: path, json: json) {
                let text = value is String ? (value as? String ?? "") : "\(value)"
                return isUrl ? resolveUrl(text) : text
            }
            return ""
        }

        // Handle template expressions {{...}}
        if rule.contains("{{") && rule.contains("}}") {
            let expanded = evaluateTemplate(rule)
            return isUrl ? resolveUrl(expanded) : expanded
        }

        // Handle JS scripts: with or without rule prefix
        var rulePrefix = ""
        var jsScript: String? = nil

        if let jsStart = rule.range(of: "<js>"), let jsEnd = rule.range(of: "</js>") {
            rulePrefix = String(rule[..<jsStart.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            jsScript = String(rule[jsStart.upperBound..<jsEnd.lowerBound])
        } else if rule.starts(with: "@js:") {
            jsScript = String(rule.dropFirst(4))
        }

        if let script = jsScript {
            var targetContent: Any? = content
            if !rulePrefix.isEmpty {
                let prefixVal = getString(rulePrefix, isUrl: false)
                if !prefixVal.isEmpty {
                    targetContent = prefixVal
                }
            }
            let evalResult = jsEngine.evalRule(script: script, result: targetContent)

            // `<js>…</js>$.content` 这种写法尾巴上还挂一段规则：先跑 JS，再把尾巴套在
            // JS 的结果上（聚合源的正文脚本就是回 `{"content":"…"}` 再取 `$.content`，
            // 不接尾巴的话正文字典会带着 JSON 壳和 \n 直接上屏）。
            if let jsEnd = rule.range(of: "</js>") {
                let suffix = String(rule[jsEnd.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !suffix.isEmpty {
                    let nested = RuleAnalyzer(content: evalResult ?? "", baseUrl: baseUrl, bookSource: nil, jsEngine: jsEngine)
                    return nested.getString(suffix, isUrl: isUrl)
                }
            }

            let resStr = evalResult != nil ? "\(evalResult!)" : ""
            return isUrl ? resolveUrl(resStr) : resStr
        }

        // Handle fallback operator: rule1 || rule2
        if let options = Self.splitTopLevel(rule, by: "||") {
            for option in options {
                let res = getString(option, isUrl: isUrl)
                if !res.isEmpty {
                    return res
                }
            }
            return ""
        }

        // Handle concatenation operator: rule1 && rule2
        if let segments = Self.splitTopLevel(rule, by: "&&") {
            let combined = segments.map { getString($0, isUrl: isUrl) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            return combined
        }

        let list = getStringList(rule, isUrl: isUrl)
        return list.first ?? ""
    }

    // MARK: - 顶层运算符切分

    /// 按 `&&` / `||` / `%%` 在**顶层**切分规则：引号内、括号内、`{{ }}` 内的都不切。
    ///
    /// 安卓 RuleAnalyzer 也是同一套 depth/quote 扫描，所以 `@css:a[title="x||y"]`、
    /// `{{page==1?"a&&b":"c"}}` 这类写法不能被粗暴 split（原来的
    /// `components(separatedBy:)` 会把它们切碎）。
    /// 没有该运算符时返回 nil，让调用方继续走后面的分支。
    static func splitTopLevel(_ rule: String, by op: String) -> [String]? {
        guard !op.isEmpty else { return nil }
        let chars = Array(rule)
        var parts: [String] = []
        var current = ""
        current.reserveCapacity(rule.count)
        var depth = 0
        var quote: Character?
        var escaped = false
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if escaped {
                current.append(ch); escaped = false; i += 1; continue
            }
            if ch == "\\" {
                current.append(ch); escaped = true; i += 1; continue
            }
            if let q = quote {
                current.append(ch)
                if ch == q { quote = nil }
                i += 1
                continue
            }
            if ch == "\"" || ch == "'" {
                quote = ch; current.append(ch); i += 1; continue
            }
            if ch == "(" || ch == "[" || ch == "{" {
                depth += 1; current.append(ch); i += 1; continue
            }
            if ch == ")" || ch == "]" || ch == "}" {
                depth = max(0, depth - 1); current.append(ch); i += 1; continue
            }
            if depth == 0, i + op.count <= chars.count, String(chars[i..<(i + op.count)]) == op {
                parts.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
                i += op.count
                continue
            }
            current.append(ch)
            i += 1
        }
        guard !parts.isEmpty else { return nil }
        parts.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        return parts
    }

    /// `%%` 的语义：几段规则各自出列表，再按下标交叉合并（第 0 段第 0 个、第 1 段第 0 个…）。
    private func mergeListsByPercent(_ rule: String, isUrl: Bool) -> [String]? {
        guard let parts = Self.splitTopLevel(rule, by: "%%"), parts.count > 1 else { return nil }
        let lists = parts.map { getStringList($0, isUrl: isUrl) }
        var merged: [String] = []
        let maxCount = lists.map { $0.count }.max() ?? 0
        for index in 0..<maxCount {
            for list in lists where index < list.count {
                merged.append(list[index])
            }
        }
        return merged
    }

    /// Evaluates a rule string and returns a list of string results
    public func getStringList(_ rule: String?, isUrl: Bool = false) -> [String] {
        guard let rawRule = rule?.trimmingCharacters(in: .whitespacesAndNewlines), !rawRule.isEmpty else {
            return []
        }
        let rule = JSEngine.expandSourceVariables(rawRule)

        // `%%` 交叉合并要在 tokenize 之前处理；`||` / `&&` 交给 getString 的优先级逻辑。
        if let merged = mergeListsByPercent(rule, isUrl: isUrl) {
            return merged
        }
        if Self.splitTopLevel(rule, by: "||") != nil || Self.splitTopLevel(rule, by: "&&") != nil {
            let single = getString(rule, isUrl: isUrl)
            return single.isEmpty ? [] : [single]
        }

        // If pure JS: @js:script or <js>...</js>
        if rule.starts(with: "@js:") {
            let script = String(rule.dropFirst(4))
            let evalResult = jsEngine.evalRule(script: script, result: content)
            if let arr = evalResult as? [Any] {
                return arr.map { "\(isUrl ? resolveUrl("\($0)") : "\($0)")" }
            } else if let single = evalResult {
                let str = "\(single)"
                return [isUrl ? resolveUrl(str) : str]
            }
            return []
        } else if rule.contains("<js>") && rule.contains("</js>") {
            let start = rule.range(of: "<js>")?.upperBound ?? rule.startIndex
            let end = rule.range(of: "</js>")?.lowerBound ?? rule.endIndex
            let script = String(rule[start..<end])
            let evalResult = jsEngine.evalRule(script: script, result: content)
            if let arr = evalResult as? [Any] {
                return arr.map { "\(isUrl ? resolveUrl("\($0)") : "\($0)")" }
            } else if let single = evalResult {
                let str = "\(single)"
                return [isUrl ? resolveUrl(str) : str]
            }
            return []
        }

        let steps = RuleTokenizer.parse(rule)
        var currentValues: [Any] = []

        // Root evaluation
        let jsonTarget: Any? = parsedJson ?? (content as? [String: Any])
        if let json = jsonTarget {
            let candidatePaths = [rule, "$.\(rule)"]
            for p in candidatePaths {
                if let val = JSONPath.evaluate(path: p, json: json) {
                    if let arr = val as? [Any] {
                        currentValues = arr
                    } else {
                        currentValues = [val]
                    }
                    break
                }
            }
            if currentValues.isEmpty {
                currentValues = evaluateJsonSteps(steps: steps, json: json)
            }
        } else if let doc = parsedDocument {
            currentValues = evaluateHtmlSteps(steps: steps, element: doc)
        } else if let element = content as? Element {
            currentValues = evaluateHtmlSteps(steps: steps, element: element)
        }

        // Apply remaining steps: JS, regex, attribute
        return currentValues.map { val in
            var text = "\(val)"
            for step in steps {
                switch step.type {
                case .regex(let pattern, let replacement):
                    if let rx = try? NSRegularExpression(pattern: pattern) {
                        text = rx.stringByReplacingMatches(
                            in: text,
                            range: NSRange(location: 0, length: (text as NSString).length),
                            withTemplate: replacement
                        )
                    }
                case .js(let script):
                    let res = jsEngine.evalRule(script: script, result: text)
                    if let res = res {
                        text = "\(res)"
                    }
                default:
                    break
                }
            }
            return isUrl ? resolveUrl(text) : text
        }
    }

    /// Evaluates a rule that returns multiple elements/objects (e.g. book list, chapter list)
    /// 脚本回一串 JSON 时，把里面的元素数组取出来。
    ///
    /// 聚合源的章节列表惯例是回 `{"code":0,…,"data":[…]}`，条目字段再用 `$.title` 这类
    /// 规则取；直接把它当一个元素、或者整串丢掉，目录就空了。
    static func elementsFromJSONText(_ text: String) -> [Any]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else { return nil }
        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return nil }
        if let array = json as? [Any], !array.isEmpty { return array }
        guard let dict = json as? [String: Any] else { return nil }
        for key in ["data", "list", "chapters", "items", "result"] {
            if let array = dict[key] as? [Any], !array.isEmpty { return array }
        }
        let arrays = dict.values.compactMap { $0 as? [Any] }.filter { !$0.isEmpty }
        if arrays.count == 1 { return arrays[0] }
        return nil
    }

    public func getElements(_ rule: String?) -> [Any] {
        guard let rule = rule?.trimmingCharacters(in: .whitespacesAndNewlines), !rule.isEmpty else {
            return []
        }

        if rule.hasPrefix("@json:"), let json = parsedJson {
            let path = String(rule.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            if let evaluated = JSONPath.evaluate(path: path, json: json) {
                if let array = evaluated as? [Any] { return array }
                if let dict = evaluated as? [String: Any] { return [dict] }
            }
            return []
        }

        var rulePrefix = ""
        var jsScript: String? = nil

        if let jsStart = rule.range(of: "<js>"), let jsEnd = rule.range(of: "</js>") {
            rulePrefix = String(rule[..<jsStart.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            jsScript = String(rule[jsStart.upperBound..<jsEnd.lowerBound])
        } else if rule.starts(with: "@js:") {
            jsScript = String(rule.dropFirst(4))
        }

        if let script = jsScript {
            var targetContent: Any? = content
            if !rulePrefix.isEmpty {
                let prefixAnalyzer = RuleAnalyzer(content: content, baseUrl: baseUrl, jsEngine: jsEngine)
                let prefixElements = prefixAnalyzer.getElements(rulePrefix)
                if !prefixElements.isEmpty {
                    targetContent = prefixElements
                }
            }
            if let evalResult = jsEngine.evalRule(script: script, result: targetContent) {
                if let array = evalResult as? [Any] {
                    return array
                } else if let dict = evalResult as? [String: Any] {
                    return [dict]
                } else if let text = evalResult as? String {
                    // 聚合源的章节脚本直接回一串 JSON（章节列表在 data 里），
                    // 这不是「一个元素」，是新的页面内容，接着往下解析。
                    if let array = RuleAnalyzer.elementsFromJSONText(text) {
                        return array
                    }
                }
            }
            return []
        }

        // If JSON content, prioritize JSONPath / JSON key lookup
        let jsonTarget: Any? = parsedJson ?? (content as? [String: Any]) ?? (content as? [Any])
        if let json = jsonTarget {
            let candidatePaths = [rule, "$.\(rule)"]
            for p in candidatePaths {
                if let evaluated = JSONPath.evaluate(path: p, json: json) {
                    if let array = evaluated as? [Any] {
                        return array
                    } else if let dict = evaluated as? [String: Any] {
                        return [dict]
                    }
                }
            }
        }

        let steps = RuleTokenizer.parse(rule)
        guard let firstStep = steps.first else { return [] }

        switch firstStep.type {
        case .jsonPath(let path):
            if let json = jsonTarget {
                let evaluated = JSONPath.evaluate(path: path, json: json)
                if let array = evaluated as? [Any] {
                    return array
                } else if let dict = evaluated as? [String: Any] {
                    return [dict]
                }
            }
        default:
            break
        }

        // HTML multi-step chained CSS selection
        if parsedDocument != nil || content is Element {
            var currentElements: [Element] = []
            if let doc = parsedDocument {
                currentElements = [doc]
            } else if let el = content as? Element {
                currentElements = [el]
            }

            for step in steps {
                switch step.type {
                case .css(let rawSelector):
                    var next: [Element] = []
                    for el in currentElements {
                        next.append(contentsOf: selectElements(from: el, selector: rawSelector))
                    }
                    currentElements = next
                case .xpath(let rawXPath):
                    // 先用 libxml2 真正执行 XPath；取不到时再用 XPath→CSS 子集翻译兜底
                    var next: [Element] = []
                    for el in currentElements {
                        next.append(contentsOf: selectByXPath(from: el, xpath: rawXPath))
                    }
                    if next.isEmpty, let cssSelector = XPathToCSS.css(from: rawXPath) {
                        for el in currentElements {
                            next.append(contentsOf: selectElements(from: el, selector: cssSelector))
                        }
                    }
                    currentElements = next
                default:
                    continue
                }
            }
            if !currentElements.isEmpty {
                return currentElements
            }
        }

        return []
    }

    /// Selects elements from a parent element given a selector, supporting Legado's `tag.index` syntax (e.g. `li.1`, `a.-1`).
    ///
    /// 书源里 `.index` 不只跟在标签后面：老写法 `class.bookname.0@tag.a.0@text`
    /// 在经过 `RuleTokenizer.normalizeSelector` 之后会变成 `.bookname.0` / `a.0`，
    /// 这里的下标必须对任意选择器（`.class`、`#id`、标签、复合选择器）生效，
    /// 否则带下标的 class 规则会整条取不到元素，搜索/目录直接为空。
    private func selectElements(from element: Element, selector: String) -> [Element] {
        let trimmed = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        if let (base, index) = Self.splitIndexSuffix(trimmed) {
            let all = (try? element.select(base))?.array() ?? []
            if index >= 0 {
                return index < all.count ? [all[index]] : []
            }
            let position = all.count + index
            return position >= 0 && position < all.count ? [all[position]] : []
        }

        if let selected = try? element.select(trimmed) {
            return selected.array()
        }
        return []
    }

    /// 用 libxml2（Kanna）执行真正的 XPath。
    ///
    /// SwiftSoup 本身没有 XPath，原来的实现只能把「标签 + 单个谓词 + 位置」翻成 CSS，
    /// 多谓词、`text()`、`following-sibling::` 轴、`last()`、并集 `|` 这些真实书源里
    /// 常见的写法一律取不到元素（实测 140 条 XPath 规则里有 40 条属于这类）。
    /// 这里把当前节点的 HTML 交给 Kanna 再跑一遍 XPath，命中后转回 SwiftSoup 的 Element，
    /// 让后续 `@text` / `@href` / 链式选择器照旧工作。
    private func selectByXPath(from element: Element, xpath: String) -> [Element] {
        let trimmed = xpath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let html = (try? element.outerHtml()) ?? ""
        guard !html.isEmpty, let document = try? Kanna.HTML(html: html, encoding: .utf8) else {
            return []
        }

        var results: [Element] = []
        for node in document.xpath(trimmed) {
            if let fragment = node.toHTML, !fragment.isEmpty {
                if let converted = Self.parseFragmentElement(fragment) {
                    results.append(converted)
                }
            } else if let text = node.text, !text.isEmpty {
                // `text()` / `@text` 命中文本节点时没有 HTML，包一层 span 让它仍是 Element
                if let converted = Self.parseFragmentElement("<span>\(Self.escapeHTML(text))</span>") {
                    results.append(converted)
                }
            }
        }
        return results
    }

    private static func parseFragmentElement(_ html: String) -> Element? {
        guard let document = try? SwiftSoup.parseBodyFragment(html),
              let body = document.body() else { return nil }
        return body.children().first()
    }

    private static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// 把选择器尾部的 `.N` / `.-N` 下标拆出来，例如 `a.0` -> ("a", 0)、`.bookname.0` -> (".bookname", 0)。
    /// 只认「点 + 纯数字」结尾，`div.mt-2` 这类类名不会被误拆。
    static func splitIndexSuffix(_ selector: String) -> (base: String, index: Int)? {
        let pattern = #"^(.+?)\.(-?\d{1,7})$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: selector, options: [], range: NSRange(location: 0, length: selector.utf16.count)),
              let baseRange = Range(match.range(at: 1), in: selector),
              let indexRange = Range(match.range(at: 2), in: selector),
              let index = Int(selector[indexRange])
        else { return nil }
        let base = String(selector[baseRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, base != "." else { return nil }
        return (base, index)
    }

    private func evaluateJsonSteps(steps: [RuleStep], json: Any) -> [Any] {
        guard let first = steps.first else { return [] }
        var resultList: [Any] = []

        if case .jsonPath(let path) = first.type {
            if let evalResult = JSONPath.evaluate(path: path, json: json) {
                if let array = evalResult as? [Any] {
                    resultList = array
                } else {
                    resultList = [evalResult]
                }
            }
        }

        return resultList
    }

    private func evaluateHtmlSteps(steps: [RuleStep], element: Element) -> [Any] {
        var elements: [Element] = [element]

        for step in steps {
            switch step.type {
            case .css(let selector):
                var next: [Element] = []
                for el in elements {
                    let found = selectElements(from: el, selector: selector)
                    if found.isEmpty {
                        if (try? el.iS(selector)) == true {
                            next.append(el)
                        }
                    } else {
                        next.append(contentsOf: found)
                    }
                }
                elements = next
            case .xpath(let xpath):
                // 和 getElements 里的链式选择保持一致：先用 libxml2 真跑 XPath，
                // 取不到再用 XPath→CSS 子集翻译兜底。getString 走的就是这条路径。
                var next: [Element] = []
                for el in elements {
                    next.append(contentsOf: selectByXPath(from: el, xpath: xpath))
                }
                if next.isEmpty, let cssSelector = XPathToCSS.css(from: xpath) {
                    for el in elements {
                        next.append(contentsOf: selectElements(from: el, selector: cssSelector))
                    }
                }
                if !next.isEmpty { elements = next }
            default:
                break
            }
        }

        // Check if an attribute is requested
        for step in steps {
            if case .attribute(let attr) = step.type {
                return elements.compactMap { el in
                    switch attr {
                    case "text", "textnodes":
                        return (try? el.text()) ?? ""
                    case "html":
                        return (try? el.html()) ?? ""
                    case "href":
                        return (try? el.attr("href")) ?? ""
                    case "src":
                        return (try? el.attr("src")) ?? ""
                    default:
                        if attr.starts(with: "attr(") && attr.hasSuffix(")") {
                            let attrName = String(attr.dropFirst(5).dropLast())
                            return try? el.attr(attrName)
                        }
                        return try? el.attr(attr)
                    }
                }
            }
        }

        return elements.compactMap { try? $0.text() }
    }
}
