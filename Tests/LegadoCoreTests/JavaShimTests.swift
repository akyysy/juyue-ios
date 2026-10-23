import XCTest
@testable import LegadoCore

/// `java.*` 脚本 API 的补充实现：语料里出现但之前缺的
/// `encodeURI` / `digestHex` / `HMac*` / `base64DecodeToByteArray` / `getElement(s)`。
final class JavaShimTests: XCTestCase {

    private func shim() -> JavaShim {
        JavaShim(context: nil)
    }

    func testEncodeURIKeepsSeparators() {
        XCTAssertEqual(shim().encodeURI("a b/中文?x=1"), "a%20b/%E4%B8%AD%E6%96%87?x=1")
    }

    func testDigestHexSHA256() {
        XCTAssertEqual(
            shim().digestHex("SHA-256", "abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testDigestHexMD5() {
        XCTAssertEqual(shim().digestHex("md5", "abc"), "900150983cd24fb0d6963f7d28e17f72")
    }

    func testHMacHexSHA256() {
        XCTAssertEqual(
            shim().HMacHex("SHA-256", "key", "The quick brown fox jumps over the lazy dog"),
            "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8"
        )
    }

    func testHMacBase64SHA1() {
        XCTAssertEqual(
            shim().HMacBase64("SHA-1", "key", "The quick brown fox jumps over the lazy dog"),
            "3nybhbi3iqa8ino29wqQcBydtNk="
        )
    }

    func testBase64DecodeToByteArray() {
        XCTAssertEqual(shim().base64DecodeToByteArray("YWJj"), [97, 98, 99])
        XCTAssertEqual(shim().base64DecodeToByteArray("不是base64"), [])
    }

    func testGetElementsParsesFragment() {
        let html = #"<div class="a">x</div><div class="a">y</div>"#
        let elements = shim().getElements(html, "class.a")
        XCTAssertEqual(elements.count, 2)
        XCTAssertTrue(elements[0].contains("x"))
        XCTAssertTrue(elements[1].contains("y"))
    }

    func testGetElementReturnsFirstMatch() {
        let html = #"<div class="a">x</div><div class="a">y</div>"#
        let element = shim().getElement(html, "class.a")
        XCTAssertTrue(element.contains("x"))
        XCTAssertFalse(element.contains("y"))
    }
}
