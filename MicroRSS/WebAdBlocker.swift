import Foundation
import WebKit

@MainActor
final class WebAdBlocker {
    enum State: Equatable {
        case disabled
        case preparing
        case updating(lastSuccessfulUpdate: Date?)
        case ready(lastSuccessfulUpdate: Date?)
        case failed(message: String, lastSuccessfulUpdate: Date?)
    }

    static let shared = WebAdBlocker()
    static let defaultListURLString = "https://easylist.to/easylist/easylist.txt"

    private enum DefaultsKey {
        static let activeIdentifier = "MicroRSS.AdBlocker.ActiveIdentifier"
        static let activeSourceURL = "MicroRSS.AdBlocker.ActiveSourceURL"
        static let eTag = "MicroRSS.AdBlocker.ETag"
        static let lastModified = "MicroRSS.AdBlocker.LastModified"
        static let lastAttempt = "MicroRSS.AdBlocker.LastAttempt"
        static let lastAttemptSourceURL = "MicroRSS.AdBlocker.LastAttemptSourceURL"
        static let lastSuccessfulUpdate = "MicroRSS.AdBlocker.LastSuccessfulUpdate"
        static let metadataSourceURL = "MicroRSS.AdBlocker.MetadataSourceURL"
        static let activeRuleCount = "MicroRSS.AdBlocker.ActiveRuleCount"
    }

    private enum RuleIdentifier {
        static let remoteA = "MicroRSS.AdBlocker.EasyList.A.v5"
        static let remoteB = "MicroRSS.AdBlocker.EasyList.B.v5"
        static let supplementary = "MicroRSS.AdBlocker.Supplementary.v1"

        static func isCurrent(_ identifier: String) -> Bool {
            identifier == remoteA || identifier == remoteB
        }
    }

    private static let automaticUpdateInterval: TimeInterval = 4 * 24 * 60 * 60
    private static let failedUpdateRetryInterval: TimeInterval = 4 * 24 * 60 * 60
    nonisolated private static let maximumDownloadSize = 15 * 1_024 * 1_024

    private let defaults: UserDefaults
    private let ruleStore: WKContentRuleListStore
    private var enabled = false
    private var sourceURL: URL?
    private var activeRuleList: WKContentRuleList?
    private var activeSupplementaryRuleList: WKContentRuleList?
    private var activeIdentifier: String?
    private var supplementaryRules = ""
    private var preparationTask: Task<WKContentRuleList?, Never>?
    private var supplementaryPreparationTask: Task<WKContentRuleList?, Never>?
    private var updateTask: Task<Void, Never>?
    private var updateTimer: Timer?
    private var observers: [UUID: (State) -> Void] = [:]
    private var activeRemoteRuleCount: Int?
    private var activeSupplementaryRuleCount: Int?
    private(set) var activeRuleCount: Int?

    private(set) var state: State = .disabled {
        didSet {
            guard state != oldValue else { return }
            observers.values.forEach { $0(state) }
        }
    }

    init(defaults: UserDefaults = .standard, ruleStore: WKContentRuleListStore = .default()) {
        self.defaults = defaults
        self.ruleStore = ruleStore
    }

    func configure(enabled: Bool, listURLString: String, supplementaryRules: String) {
        let normalizedURL = Self.validListURL(from: listURLString)
        let sourceChanged = defaults.string(forKey: DefaultsKey.activeSourceURL) != normalizedURL?.absoluteString
        let storedIdentifier = defaults.string(forKey: DefaultsKey.activeIdentifier)
        let needsRuleListMigration = storedIdentifier.map { !RuleIdentifier.isCurrent($0) } ?? false
        let supplementaryRulesChanged = self.supplementaryRules != supplementaryRules
        self.enabled = enabled
        sourceURL = normalizedURL
        self.supplementaryRules = supplementaryRules

        if supplementaryRulesChanged {
            supplementaryPreparationTask?.cancel()
            supplementaryPreparationTask = nil
            activeSupplementaryRuleList = nil
            activeSupplementaryRuleCount = nil
            refreshActiveRuleCount()
        }

        guard enabled else {
            state = .disabled
            updateTimer?.invalidate()
            updateTimer = nil
            updateTask?.cancel()
            updateTask = nil
            return
        }

        guard normalizedURL != nil else {
            state = .failed(
                message: "The filter-list URL must be a valid HTTPS URL.",
                lastSuccessfulUpdate: lastSuccessfulUpdate
            )
            return
        }

        prepareSupplementaryRuleListIfNeeded()

        if activeRuleList == nil {
            state = .preparing
        } else if sourceChanged {
            state = .updating(lastSuccessfulUpdate: lastSuccessfulUpdate)
        } else {
            state = .ready(lastSuccessfulUpdate: lastSuccessfulUpdate)
        }

        Task { [weak self] in
            guard let self else { return }
            let ruleList = await self.ensureRuleList()
            self.refreshIfNeeded(force: sourceChanged || needsRuleListMigration)
            if self.updateTask == nil {
                self.scheduleAutomaticUpdate()
                if ruleList == nil {
                    self.state = .failed(
                        message: "No compiled list is available yet. Choose Update Now to retry before the next scheduled attempt.",
                        lastSuccessfulUpdate: nil
                    )
                }
            }
        }
    }

    func prepare(_ configuration: WKWebViewConfiguration, completion: @escaping () -> Void) {
        guard enabled else {
            completion()
            return
        }

        Task { [weak self, weak configuration] in
            guard let self else {
                completion()
                return
            }
            let ruleList = await self.ruleListForPreview()
            let supplementaryRuleList = await self.ensureSupplementaryRuleList()
            if self.enabled, let configuration {
                if let ruleList {
                    configuration.userContentController.add(ruleList)
                }
                if let supplementaryRuleList {
                    configuration.userContentController.add(supplementaryRuleList)
                }
            }
            completion()
        }
    }

    func updateNow() {
        refreshIfNeeded(force: true)
    }

    @discardableResult
    func observe(_ handler: @escaping (State) -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        handler(state)
        return id
    }

    func removeObserver(id: UUID) {
        observers[id] = nil
    }

    static func validListURL(from string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https",
              url.host != nil else {
            return nil
        }
        return url
    }

    static func validateSupplementaryRules(_ rules: String) throws {
        guard !rules.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        _ = try EasyListConverter.convert(Data(rules.utf8), includeBuiltInRules: false)
    }

    private var lastSuccessfulUpdate: Date? {
        defaults.object(forKey: DefaultsKey.lastSuccessfulUpdate) as? Date
    }

    private func ensureRuleList() async -> WKContentRuleList? {
        if let activeRuleList {
            return activeRuleList
        }
        if let preparationTask {
            return await preparationTask.value
        }

        let task = Task { @MainActor [weak self] () -> WKContentRuleList? in
            guard let self else { return nil }
            if let storedIdentifier = self.defaults.string(forKey: DefaultsKey.activeIdentifier),
               RuleIdentifier.isCurrent(storedIdentifier),
               let storedList = await self.lookUpRuleList(identifier: storedIdentifier) {
                self.activeIdentifier = storedIdentifier
                self.activeRuleList = storedList
                let storedRuleCount = self.defaults.integer(forKey: DefaultsKey.activeRuleCount)
                self.activeRemoteRuleCount = storedRuleCount > 0 ? storedRuleCount : nil
                self.refreshActiveRuleCount()
                self.state = self.enabled ? .ready(lastSuccessfulUpdate: self.lastSuccessfulUpdate) : .disabled
                return storedList
            }
            return nil
        }
        preparationTask = task
        let result = await task.value
        preparationTask = nil
        return result
    }

    private func prepareSupplementaryRuleListIfNeeded() {
        guard enabled,
              activeSupplementaryRuleList == nil,
              supplementaryPreparationTask == nil,
              !supplementaryRules.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        let source = supplementaryRules
        let task = Task { @MainActor [weak self] () -> WKContentRuleList? in
            guard let self else { return nil }
            do {
                let conversion = try await Task.detached(priority: .utility) {
                    try EasyListConverter.convert(Data(source.utf8), includeBuiltInRules: false)
                }.value
                try Task.checkCancellation()
                guard self.supplementaryRules == source else { return nil }
                let ruleList = try await self.compileRuleList(
                    identifier: RuleIdentifier.supplementary,
                    json: conversion.json
                )
                try Task.checkCancellation()
                guard self.supplementaryRules == source else { return nil }
                self.activeSupplementaryRuleList = ruleList
                self.activeSupplementaryRuleCount = conversion.convertedRuleCount
                self.refreshActiveRuleCount()
                self.supplementaryPreparationTask = nil
                return ruleList
            } catch is CancellationError {
                return nil
            } catch {
                guard self.supplementaryRules == source else { return nil }
                self.supplementaryPreparationTask = nil
                self.state = .failed(
                    message: "Supplementary rules could not be compiled: \(error.localizedDescription)",
                    lastSuccessfulUpdate: self.lastSuccessfulUpdate
                )
                return nil
            }
        }
        supplementaryPreparationTask = task
    }

    private func ensureSupplementaryRuleList() async -> WKContentRuleList? {
        guard !supplementaryRules.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        if let activeSupplementaryRuleList {
            return activeSupplementaryRuleList
        }
        prepareSupplementaryRuleListIfNeeded()
        guard let task = supplementaryPreparationTask else { return nil }
        let source = supplementaryRules
        let result = await task.value
        if supplementaryRules == source {
            supplementaryPreparationTask = nil
        }
        return result
    }

    private func ruleListForPreview() async -> WKContentRuleList? {
        if let ruleList = await ensureRuleList() {
            return ruleList
        }

        refreshIfNeeded(force: false)
        let pendingUpdate = updateTask
        await pendingUpdate?.value
        return await ensureRuleList()
    }

    private func refreshIfNeeded(force: Bool) {
        guard enabled, updateTask == nil, let sourceURL else { return }
        guard force || isAutomaticUpdateDue else { return }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.downloadAndCompile(from: sourceURL)
            self.updateTask = nil
            if self.enabled {
                self.scheduleAutomaticUpdate()
            }
        }
        updateTask = task
    }

    private var isAutomaticUpdateDue: Bool {
        guard let sourceURLString = sourceURL?.absoluteString else { return false }
        let now = Date()
        if defaults.string(forKey: DefaultsKey.metadataSourceURL) == sourceURLString,
           let lastSuccessfulUpdate {
            return now.timeIntervalSince(lastSuccessfulUpdate) >= Self.automaticUpdateInterval
        }
        if defaults.string(forKey: DefaultsKey.lastAttemptSourceURL) == sourceURLString,
           let lastAttempt = defaults.object(forKey: DefaultsKey.lastAttempt) as? Date {
            return now.timeIntervalSince(lastAttempt) >= Self.failedUpdateRetryInterval
        }
        return true
    }

    private func scheduleAutomaticUpdate() {
        updateTimer?.invalidate()
        updateTimer = nil
        guard enabled else { return }

        let nextDate: Date
        if defaults.string(forKey: DefaultsKey.metadataSourceURL) == sourceURL?.absoluteString,
           let lastSuccessfulUpdate {
            nextDate = lastSuccessfulUpdate.addingTimeInterval(Self.automaticUpdateInterval)
        } else if defaults.string(forKey: DefaultsKey.lastAttemptSourceURL) == sourceURL?.absoluteString,
                  let lastAttempt = defaults.object(forKey: DefaultsKey.lastAttempt) as? Date {
            nextDate = lastAttempt.addingTimeInterval(Self.failedUpdateRetryInterval)
        } else {
            nextDate = Date().addingTimeInterval(Self.failedUpdateRetryInterval)
        }

        let interval = max(60, nextDate.timeIntervalSinceNow)
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshIfNeeded(force: false)
                if self?.updateTask == nil {
                    self?.scheduleAutomaticUpdate()
                }
            }
        }
        timer.tolerance = min(60 * 60, interval * 0.1)
        updateTimer = timer
    }

    private func downloadAndCompile(from url: URL) async {
        state = .updating(lastSuccessfulUpdate: lastSuccessfulUpdate)
        defaults.set(Date(), forKey: DefaultsKey.lastAttempt)
        defaults.set(url.absoluteString, forKey: DefaultsKey.lastAttemptSourceURL)

        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("text/plain, application/octet-stream;q=0.9", forHTTPHeaderField: "Accept")

        let activeListMatchesSource = activeIdentifier != nil
            && defaults.string(forKey: DefaultsKey.activeSourceURL) == url.absoluteString
        let metadataMatchesSource = activeListMatchesSource
            && defaults.string(forKey: DefaultsKey.metadataSourceURL) == url.absoluteString
        if metadataMatchesSource {
            if let eTag = defaults.string(forKey: DefaultsKey.eTag) {
                request.setValue(eTag, forHTTPHeaderField: "If-None-Match")
            }
            if let lastModified = defaults.string(forKey: DefaultsKey.lastModified) {
                request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
            }
        }

        do {
            let (temporaryURL, response) = try await URLSession.shared.download(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw AdBlockerError.invalidResponse
            }

            if httpResponse.statusCode == 304 {
                markUpdateSuccessful(response: httpResponse, sourceURL: url)
                state = .ready(lastSuccessfulUpdate: lastSuccessfulUpdate)
                return
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                throw AdBlockerError.httpStatus(httpResponse.statusCode)
            }

            let resourceValues = try temporaryURL.resourceValues(forKeys: [.fileSizeKey])
            guard let fileSize = resourceValues.fileSize, fileSize <= Self.maximumDownloadSize else {
                throw AdBlockerError.listTooLarge
            }

            let data = try Data(contentsOf: temporaryURL, options: [.mappedIfSafe])
            let conversion = try await Task.detached(priority: .utility) {
                try EasyListConverter.convert(data)
            }.value
            let candidateIdentifier = nextRemoteIdentifier()
            let candidate = try await compileRuleList(identifier: candidateIdentifier, json: conversion.json)

            activeRuleList = candidate
            activeIdentifier = candidateIdentifier
            activeRemoteRuleCount = conversion.convertedRuleCount
            refreshActiveRuleCount()
            defaults.set(candidateIdentifier, forKey: DefaultsKey.activeIdentifier)
            defaults.set(url.absoluteString, forKey: DefaultsKey.activeSourceURL)
            defaults.set(conversion.convertedRuleCount, forKey: DefaultsKey.activeRuleCount)
            markUpdateSuccessful(response: httpResponse, sourceURL: url)
            state = .ready(lastSuccessfulUpdate: lastSuccessfulUpdate)
        } catch is CancellationError {
            state = enabled ? .ready(lastSuccessfulUpdate: lastSuccessfulUpdate) : .disabled
        } catch {
            state = .failed(
                message: error.localizedDescription,
                lastSuccessfulUpdate: lastSuccessfulUpdate
            )
        }
    }

    private func nextRemoteIdentifier() -> String {
        activeIdentifier == RuleIdentifier.remoteA ? RuleIdentifier.remoteB : RuleIdentifier.remoteA
    }

    private func refreshActiveRuleCount() {
        let counts = [activeRemoteRuleCount, activeSupplementaryRuleCount].compactMap { $0 }
        activeRuleCount = counts.isEmpty ? nil : counts.reduce(0, +)
    }

    private func markUpdateSuccessful(response: HTTPURLResponse, sourceURL: URL) {
        let now = Date()
        defaults.set(now, forKey: DefaultsKey.lastSuccessfulUpdate)
        defaults.set(sourceURL.absoluteString, forKey: DefaultsKey.metadataSourceURL)
        if let eTag = response.value(forHTTPHeaderField: "ETag") {
            defaults.set(eTag, forKey: DefaultsKey.eTag)
        } else {
            defaults.removeObject(forKey: DefaultsKey.eTag)
        }
        if let lastModified = response.value(forHTTPHeaderField: "Last-Modified") {
            defaults.set(lastModified, forKey: DefaultsKey.lastModified)
        } else {
            defaults.removeObject(forKey: DefaultsKey.lastModified)
        }
    }

    private func lookUpRuleList(identifier: String) async -> WKContentRuleList? {
        await withCheckedContinuation { continuation in
            ruleStore.lookUpContentRuleList(forIdentifier: identifier) { ruleList, _ in
                continuation.resume(returning: ruleList)
            }
        }
    }

    private func compileRuleList(identifier: String, json: String) async throws -> WKContentRuleList {
        try await withCheckedThrowingContinuation { continuation in
            ruleStore.compileContentRuleList(
                forIdentifier: identifier,
                encodedContentRuleList: json
            ) { ruleList, error in
                if let ruleList {
                    continuation.resume(returning: ruleList)
                } else {
                    continuation.resume(throwing: error ?? AdBlockerError.compilationFailed)
                }
            }
        }
    }
}

private enum AdBlockerError: LocalizedError {
    case compilationFailed
    case httpStatus(Int)
    case invalidResponse
    case listTooLarge

    var errorDescription: String? {
        switch self {
        case .compilationFailed:
            "WebKit could not compile the filter list."
        case .httpStatus(let status):
            "The filter-list server returned HTTP \(status)."
        case .invalidResponse:
            "The filter-list server returned an invalid response."
        case .listTooLarge:
            "The filter list is empty or larger than 15 MB."
        }
    }
}
