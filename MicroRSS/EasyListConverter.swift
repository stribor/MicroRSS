import Foundation

enum EasyListConverter {
    struct Result: Sendable {
        let json: String
        let sourceRuleCount: Int
        let convertedRuleCount: Int
        let skippedRuleCount: Int
    }

    private struct ContentRule: Encodable, Hashable {
        let trigger: Trigger
        let action: Action
    }

    private struct Trigger: Encodable, Hashable {
        let urlFilter: String
        var urlFilterIsCaseSensitive: Bool?
        var ifDomain: [String]?
        var unlessDomain: [String]?
        var resourceType: [String]?
        var loadType: [String]?

        enum CodingKeys: String, CodingKey {
            case urlFilter = "url-filter"
            case urlFilterIsCaseSensitive = "url-filter-is-case-sensitive"
            case ifDomain = "if-domain"
            case unlessDomain = "unless-domain"
            case resourceType = "resource-type"
            case loadType = "load-type"
        }
    }

    private struct Action: Encodable, Hashable {
        let type: String
        var selector: String?
    }

    private struct NetworkRule: Hashable {
        var trigger: Trigger
        let isException: Bool
    }

    private struct CosmeticRule {
        let domains: DomainRestriction
        let selector: String
    }

    private struct DomainRestriction: Hashable {
        var included: Set<String>
        var excluded: Set<String>
    }

    private struct CosmeticGroupKey: Hashable {
        let included: [String]
        let excluded: [String]
    }

    private static let allResourceTypes: Set<String> = [
        "child-document", "document", "image", "style-sheet", "script", "font", "raw",
        "svg-document", "media", "popup", "ping", "fetch", "websocket", "other"
    ]
    private static let resourceTypeOptions: [String: Set<String>] = [
        "document": ["document"],
        "font": ["font"],
        "image": ["image", "svg-document"],
        "media": ["media"],
        "object": ["other"],
        "other": ["other"],
        "ping": ["ping"],
        "popup": ["popup"],
        "script": ["script"],
        "stylesheet": ["style-sheet"],
        "subdocument": ["child-document"],
        "websocket": ["websocket"],
        "xmlhttprequest": ["fetch", "raw"]
    ]
    private static let ignoredOptions: Set<String> = [
        "collapse", "elemhide", "generichide", "genericblock"
    ]
    private static let unsupportedOptionPrefixes = [
        "badfilter", "csp", "denyallow=", "header=", "important", "permissions=",
        "redirect", "removeheader", "removeparam", "replace=", "rewrite=", "sitekey=",
        "urltransform="
    ]
    private static let maximumRules = 140_000
    private static let maximumURLFilterLength = 2_048
    private static let maximumSelectorGroupLength = 24_000
    private static let builtInRules = [
        ContentRule(
            trigger: Trigger(
                urlFilter: "^[^:]+://+([^:/]+\\.)?waytogrow\\.bbvms\\.com/p/[^/]*_instream/"
            ),
            action: Action(type: "block", selector: nil)
        ),
        ContentRule(
            trigger: Trigger(urlFilter: ".*"),
            action: Action(
                type: "css-display-none",
                selector: "[id^=\"bb-iawr-\"][id*=\"_instream-\"], [id^=\"bb-wr-\"][id*=\"_instream-\"]"
            )
        )
    ]

    static func convert(_ data: Data) throws -> Result {
        guard let source = String(data: data, encoding: .utf8) else {
            throw ConversionError.invalidEncoding
        }

        let lines = source.split(whereSeparator: \Character.isNewline).map(String.init)
        var blockingRules: [NetworkRule] = []
        var exceptionRules: [NetworkRule] = []
        var cosmeticRules: [CosmeticRule] = []
        var cosmeticExceptions: [String: Set<String>] = [:]
        var sourceRuleCount = 0
        var skippedRuleCount = 0

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("!"), !line.hasPrefix("[") else { continue }
            sourceRuleCount += 1

            if let parsed = parseCosmeticException(line) {
                cosmeticExceptions[parsed.selector, default: []].formUnion(parsed.domains)
            } else if let parsed = parseCosmeticRule(line) {
                cosmeticRules.append(parsed)
            } else if let parsed = parseNetworkRule(line) {
                if parsed.isException {
                    exceptionRules.append(parsed)
                } else {
                    blockingRules.append(parsed)
                }
            } else {
                skippedRuleCount += 1
            }
        }

        var rules = builtInRules
        var seenNetworkRules: Set<NetworkRule> = []
        for rule in blockingRules where seenNetworkRules.insert(rule).inserted {
            rules.append(ContentRule(trigger: rule.trigger, action: Action(type: "block", selector: nil)))
        }

        let cosmeticResult = makeCosmeticRules(cosmeticRules, exceptions: cosmeticExceptions)
        rules.append(contentsOf: cosmeticResult.rules)
        skippedRuleCount += cosmeticResult.skipped

        seenNetworkRules.removeAll(keepingCapacity: true)
        for rule in exceptionRules where seenNetworkRules.insert(rule).inserted {
            rules.append(ContentRule(trigger: rule.trigger, action: Action(type: "ignore-previous-rules", selector: nil)))
        }

        guard !rules.isEmpty else {
            throw ConversionError.noSupportedRules
        }
        guard rules.count <= maximumRules else {
            throw ConversionError.tooManyRules(rules.count)
        }

        let encoder = JSONEncoder()
        let encoded = try encoder.encode(rules)
        guard let json = String(data: encoded, encoding: .utf8) else {
            throw ConversionError.invalidEncoding
        }
        return Result(
            json: json,
            sourceRuleCount: sourceRuleCount,
            convertedRuleCount: rules.count,
            skippedRuleCount: skippedRuleCount
        )
    }

    private static func parseNetworkRule(_ line: String) -> NetworkRule? {
        var body = line
        let isException = body.hasPrefix("@@")
        if isException {
            body.removeFirst(2)
        }
        guard !body.isEmpty,
              !body.contains("##"),
              !body.contains("#?#"),
              !body.contains("#$#"),
              !body.contains("#%#") else {
            return nil
        }

        let parts = body.split(separator: "$", maxSplits: 1, omittingEmptySubsequences: false)
        let pattern = String(parts[0])
        guard let urlFilter = convertPattern(pattern) else { return nil }

        var trigger = Trigger(urlFilter: urlFilter)
        if parts.count == 2 {
            guard applyOptions(String(parts[1]), to: &trigger) else { return nil }
        }
        return NetworkRule(trigger: trigger, isException: isException)
    }

    private static func applyOptions(_ optionsString: String, to trigger: inout Trigger) -> Bool {
        var includedResources: Set<String> = []
        var excludedResources: Set<String> = []
        var domains = DomainRestriction(included: [], excluded: [])
        var sawResourceOption = false

        for optionSubstring in optionsString.split(separator: ",", omittingEmptySubsequences: true) {
            let option = optionSubstring.lowercased()
            if unsupportedOptionPrefixes.contains(where: { option == $0 || option.hasPrefix($0) }) {
                return false
            }
            if option == "match-case" {
                trigger.urlFilterIsCaseSensitive = true
                continue
            }
            if option == "third-party" {
                trigger.loadType = ["third-party"]
                continue
            }
            if option == "~third-party" {
                trigger.loadType = ["first-party"]
                continue
            }
            if option.hasPrefix("domain=") {
                domains = parseDomains(String(option.dropFirst("domain=".count)), separator: "|")
                continue
            }
            if ignoredOptions.contains(option) {
                continue
            }

            let isNegated = option.hasPrefix("~")
            let resourceName = isNegated ? String(option.dropFirst()) : option
            if let mapped = resourceTypeOptions[resourceName] {
                sawResourceOption = true
                if isNegated {
                    excludedResources.formUnion(mapped)
                } else {
                    includedResources.formUnion(mapped)
                }
                continue
            }
            return false
        }

        if sawResourceOption {
            let resources = includedResources.isEmpty
                ? allResourceTypes.subtracting(excludedResources)
                : includedResources.subtracting(excludedResources)
            guard !resources.isEmpty else { return false }
            trigger.resourceType = resources.sorted()
        }
        guard apply(domains: domains, to: &trigger) else { return false }
        return true
    }

    private static func parseCosmeticRule(_ line: String) -> CosmeticRule? {
        guard let range = line.range(of: "##"),
              !line.contains("#?#"),
              !line.contains("#$#"),
              !line.contains("#%#") else {
            return nil
        }
        let domainText = String(line[..<range.lowerBound])
        let selector = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard isSupportedSelector(selector) else { return nil }
        return CosmeticRule(domains: parseDomains(domainText, separator: ","), selector: selector)
    }

    private static func parseCosmeticException(_ line: String) -> (selector: String, domains: Set<String>)? {
        guard let range = line.range(of: "#@#") else { return nil }
        let domainText = String(line[..<range.lowerBound])
        let selector = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard isSupportedSelector(selector) else { return nil }
        let restriction = parseDomains(domainText, separator: ",")
        return (selector, restriction.included.union(restriction.excluded))
    }

    private static func makeCosmeticRules(
        _ cosmeticRules: [CosmeticRule],
        exceptions: [String: Set<String>]
    ) -> (rules: [ContentRule], skipped: Int) {
        var grouped: [CosmeticGroupKey: [String]] = [:]
        var skipped = 0

        for cosmetic in cosmeticRules {
            var restriction = cosmetic.domains
            let selectorExceptions = exceptions[cosmetic.selector] ?? []
            if restriction.included.isEmpty {
                restriction.excluded.formUnion(selectorExceptions)
            } else if !selectorExceptions.isEmpty {
                restriction.included = Set(restriction.included.filter { included in
                    !selectorExceptions.contains(where: { exception in
                        domain(exception, isEqualToOrSubdomainOf: included)
                    })
                })
                if restriction.included.isEmpty {
                    skipped += 1
                    continue
                }
            }

            let safeRestriction = makeSafeDomainRestriction(restriction)
            guard safeRestriction != nil else {
                skipped += 1
                continue
            }
            let domains = safeRestriction!
            let key = CosmeticGroupKey(
                included: domains.included.map(webKitDomain).sorted(),
                excluded: domains.excluded.map(webKitDomain).sorted()
            )
            grouped[key, default: []].append(cosmetic.selector)
        }

        var result: [ContentRule] = []
        for (key, selectors) in grouped {
            var uniqueSelectors = Array(Set(selectors)).sorted()
            while !uniqueSelectors.isEmpty {
                var chunk: [String] = []
                var length = 0
                while let selector = uniqueSelectors.first {
                    let addedLength = selector.utf8.count + (chunk.isEmpty ? 0 : 2)
                    guard chunk.isEmpty || length + addedLength <= maximumSelectorGroupLength else { break }
                    chunk.append(selector)
                    length += addedLength
                    uniqueSelectors.removeFirst()
                }
                var trigger = Trigger(urlFilter: ".*")
                if !key.included.isEmpty {
                    trigger.ifDomain = key.included
                } else if !key.excluded.isEmpty {
                    trigger.unlessDomain = key.excluded
                }
                result.append(ContentRule(
                    trigger: trigger,
                    action: Action(type: "css-display-none", selector: chunk.joined(separator: ", "))
                ))
            }
        }
        return (result, skipped)
    }

    private static func parseDomains(_ text: String, separator: Character) -> DomainRestriction {
        var restriction = DomainRestriction(included: [], excluded: [])
        for substring in text.split(separator: separator, omittingEmptySubsequences: true) {
            var value = substring.lowercased().trimmingCharacters(in: .whitespaces)
            let excluded = value.hasPrefix("~")
            if excluded { value.removeFirst() }
            while value.hasPrefix(".") { value.removeFirst() }
            guard isValidDomain(value) else { continue }
            if excluded {
                restriction.excluded.insert(value)
            } else {
                restriction.included.insert(value)
            }
        }
        return restriction
    }

    private static func apply(domains: DomainRestriction, to trigger: inout Trigger) -> Bool {
        guard let safe = makeSafeDomainRestriction(domains) else { return false }
        if !safe.included.isEmpty {
            trigger.ifDomain = safe.included.map(webKitDomain).sorted()
        } else if !safe.excluded.isEmpty {
            trigger.unlessDomain = safe.excluded.map(webKitDomain).sorted()
        }
        return true
    }

    private static func makeSafeDomainRestriction(_ restriction: DomainRestriction) -> DomainRestriction? {
        guard !restriction.included.isEmpty, !restriction.excluded.isEmpty else { return restriction }
        let safeIncluded = restriction.included.filter { included in
            !restriction.excluded.contains(where: { excluded in
                domain(excluded, isEqualToOrSubdomainOf: included)
            })
        }
        guard !safeIncluded.isEmpty else { return nil }
        return DomainRestriction(included: Set(safeIncluded), excluded: [])
    }

    private static func convertPattern(_ original: String) -> String? {
        guard !original.isEmpty,
              original.utf8.count <= maximumURLFilterLength,
              original.unicodeScalars.allSatisfy(\.isASCII),
              !(original.hasPrefix("/") && original.hasSuffix("/") && original.count > 1) else {
            return nil
        }

        var pattern = original
        var prefix = ""
        var suffix = ""
        if pattern.hasPrefix("||") {
            pattern.removeFirst(2)
            prefix = "^[^:]+://+([^:/]+\\.)?"
        } else if pattern.hasPrefix("|") {
            pattern.removeFirst()
            prefix = "^"
        }
        if pattern.hasSuffix("|") {
            pattern.removeLast()
            suffix = "$"
        }

        var converted = ""
        let characters = Array(pattern)
        for character in characters {
            switch character {
            case "*":
                converted += ".*"
            case "^":
                converted += "[^A-Za-z0-9_\\-.%]"
            case ".", "+", "?", "(", ")", "[", "]", "{", "}", "|", "\\":
                converted += "\\\(character)"
            default:
                converted.append(character)
            }
        }
        let result = prefix + converted + suffix
        return result.isEmpty || result.utf8.count > maximumURLFilterLength ? nil : result
    }

    private static func isSupportedSelector(_ selector: String) -> Bool {
        guard !selector.isEmpty,
              selector.utf8.count <= maximumSelectorGroupLength,
              !selector.contains(":-abp-"),
              !selector.contains(":xpath("),
              !selector.contains("{remove:"),
              !selector.contains("{") else {
            return false
        }
        return true
    }

    private static func isValidDomain(_ domain: String) -> Bool {
        guard !domain.isEmpty,
              domain.unicodeScalars.allSatisfy(\.isASCII),
              !domain.contains("/"),
              !domain.contains("*") else {
            return false
        }
        return true
    }

    private static func webKitDomain(_ domain: String) -> String {
        domain.hasPrefix("*") ? domain : "*\(domain)"
    }

    private static func domain(_ candidate: String, isEqualToOrSubdomainOf parent: String) -> Bool {
        candidate == parent || candidate.hasSuffix(".\(parent)")
    }
}

extension EasyListConverter {
    enum ConversionError: LocalizedError {
        case invalidEncoding
        case noSupportedRules
        case tooManyRules(Int)

        var errorDescription: String? {
            switch self {
            case .invalidEncoding:
                "The filter list is not valid UTF-8."
            case .noSupportedRules:
                "The filter list contains no supported EasyList rules."
            case .tooManyRules(let count):
                "The converted list contains \(count) rules, exceeding MicroRSS's 140,000-rule safety limit."
            }
        }
    }
}
