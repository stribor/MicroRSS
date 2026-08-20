import XCTest
import WebKit
@testable import MicroRSS

final class EasyListConverterTests: XCTestCase {
    func testConvertsNetworkOptionsAndExceptions() throws {
        let source = """
        ! comment
        ||ads.example.com^$script,third-party,domain=example.com
        @@|https://example.com/allowed.js|$match-case
        """

        let result = try EasyListConverter.convert(Data(source.utf8))
        let rules = try decodedRules(result.json)

        XCTAssertEqual(result.sourceRuleCount, 2)
        XCTAssertEqual(result.convertedRuleCount, 6)
        XCTAssertEqual(result.skippedRuleCount, 0)
        let block = try XCTUnwrap(rules.first { ($0["action"] as? [String: Any])?["type"] as? String == "block" && (($0["trigger"] as? [String: Any])?["url-filter"] as? String)?.contains("ads\\.example\\.com") == true })
        let trigger = try XCTUnwrap(block["trigger"] as? [String: Any])
        XCTAssertEqual(trigger["resource-type"] as? [String], ["script"])
        XCTAssertEqual(trigger["load-type"] as? [String], ["third-party"])
        XCTAssertEqual(trigger["if-domain"] as? [String], ["*example.com"])

        let exception = try XCTUnwrap(rules.first { ($0["action"] as? [String: Any])?["type"] as? String == "ignore-previous-rules" })
        XCTAssertEqual((exception["trigger"] as? [String: Any])?["url-filter-is-case-sensitive"] as? Bool, true)
    }

    func testGroupsCosmeticSelectorsAndAppliesExceptions() throws {
        let source = """
        example.com##.ad
        example.com##.sponsor
        example.com#@#.ad
        ##.global-ad
        news.example#@#.global-ad
        """

        let result = try EasyListConverter.convert(Data(source.utf8))
        let rules = try decodedRules(result.json)
        let cosmetic = rules.filter { ($0["action"] as? [String: Any])?["type"] as? String == "css-display-none" }

        XCTAssertEqual(result.sourceRuleCount, 5)
        XCTAssertEqual(result.skippedRuleCount, 1)
        XCTAssertTrue(cosmetic.contains { rule in
            let action = rule["action"] as? [String: Any]
            let trigger = rule["trigger"] as? [String: Any]
            return action?["selector"] as? String == ".sponsor" && trigger?["if-domain"] as? [String] == ["*example.com"]
        })
        XCTAssertTrue(cosmetic.contains { rule in
            let action = rule["action"] as? [String: Any]
            let trigger = rule["trigger"] as? [String: Any]
            return action?["selector"] as? String == ".global-ad" && trigger?["unless-domain"] as? [String] == ["*news.example"]
        })
    }

    func testDeduplicatesRulesAndCountsUnsupportedRules() throws {
        let source = """
        ||ads.example^
        ||ads.example^
        /raw-regex/
        ||redirect.example^$redirect=noopjs
        """

        let result = try EasyListConverter.convert(Data(source.utf8))

        XCTAssertEqual(result.sourceRuleCount, 4)
        XCTAssertEqual(result.convertedRuleCount, 5)
        XCTAssertEqual(result.skippedRuleCount, 2)
    }

    func testIncludesSlashdotNativeAdFallbackBlock() throws {
        let result = try EasyListConverter.convert(Data("! no subscription rules".utf8))
        let rules = try decodedRules(result.json)

        let slashdotFilters = rules.compactMap { rule -> String? in
            let action = rule["action"] as? [String: Any]
            let trigger = rule["trigger"] as? [String: Any]
            guard action?["type"] as? String == "block",
                  let filter = trigger?["url-filter"] as? String,
                  filter.contains("slashdot\\.org/ajax\\.pl\\?op=nel") else {
                return nil
            }
            return filter
        }

        XCTAssertEqual(Set(slashdotFilters), [
            "^[^:]+://+([^:/]+\\.)?slashdot\\.org/ajax\\.pl\\?op=nel$",
            "^[^:]+://+([^:/]+\\.)?slashdot\\.org/ajax\\.pl\\?op=nel&"
        ])
    }

    @MainActor
    func testBuiltInRulesCompileInWebKit() async throws {
        let result = try EasyListConverter.convert(Data("! no subscription rules".utf8))
        let identifier = "MicroRSSTests.BuiltIns.\(UUID().uuidString)"
        let store = try XCTUnwrap(WKContentRuleListStore.default())

        _ = try await withCheckedThrowingContinuation { continuation in
            store.compileContentRuleList(
                forIdentifier: identifier,
                encodedContentRuleList: result.json
            ) { ruleList, error in
                if let ruleList {
                    continuation.resume(returning: ruleList)
                } else {
                    continuation.resume(throwing: error ?? CocoaError(.coderInvalidValue))
                }
            }
        } as WKContentRuleList

        await withCheckedContinuation { continuation in
            store.removeContentRuleList(forIdentifier: identifier) { _ in
                continuation.resume()
            }
        }
    }

    func testConvertsSupplementaryRulesWithoutBuiltIns() throws {
        let source = "n1info.rs##.ad-loading-placeholder"

        let result = try EasyListConverter.convert(Data(source.utf8), includeBuiltInRules: false)
        let rules = try decodedRules(result.json)

        XCTAssertEqual(result.sourceRuleCount, 1)
        XCTAssertEqual(result.convertedRuleCount, 1)
        let rule = try XCTUnwrap(rules.first)
        XCTAssertEqual((rule["trigger"] as? [String: Any])?["if-domain"] as? [String], ["*n1info.rs"])
        XCTAssertEqual((rule["action"] as? [String: Any])?["type"] as? String, "css-display-none")
        XCTAssertEqual((rule["action"] as? [String: Any])?["selector"] as? String, ".ad-loading-placeholder")
    }

    func testRejectsNonUTF8Input() {
        XCTAssertThrowsError(try EasyListConverter.convert(Data([0xFF, 0xFE]))) { error in
            guard case EasyListConverter.ConversionError.invalidEncoding = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    @MainActor
    func testAdBlockListURLValidationRequiresHTTPSHostAndTrimsWhitespace() {
        XCTAssertEqual(
            WebAdBlocker.validListURL(from: "  https://example.com/easylist.txt\n")?.absoluteString,
            "https://example.com/easylist.txt"
        )
        XCTAssertNil(WebAdBlocker.validListURL(from: "http://example.com/list.txt"))
        XCTAssertNil(WebAdBlocker.validListURL(from: "https:///missing-host"))
        XCTAssertNil(WebAdBlocker.validListURL(from: "not a URL"))
    }

    private func decodedRules(_ json: String) throws -> [[String: Any]] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
    }
}
