import AppKit
import WebKit
import XCTest
@testable import MicroRSS

final class InlinePreviewPanelTests: XCTestCase {
    @MainActor
    func testEditingCommandRouterForwardsStandardEditingCommandsToInlineTarget() {
        let target = EditingTarget()
        let router = EditingCommandRouter()
        router.inlineTarget = target
        let commands: [(() -> Void, Selector)] = [
            ({ router.cut(nil) }, #selector(NSText.cut(_:))),
            ({ router.copy(nil) }, #selector(NSText.copy(_:))),
            ({ router.paste(nil) }, #selector(NSText.paste(_:))),
            ({ router.selectAll(nil) }, #selector(NSText.selectAll(_:)))
        ]

        for (command, expectedAction) in commands {
            target.action = nil
            command()
            XCTAssertEqual(target.action.map(NSStringFromSelector), NSStringFromSelector(expectedAction))
        }
    }

    @MainActor
    func testMenuDelegateCopyCommandWritesSelectedWebTextToPasteboard() async throws {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let panel = makeWindow()
        panel.contentView = webView
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }

        let navigation = NavigationWaiter()
        let loaded = expectation(description: "HTML loaded")
        navigation.didFinish = { loaded.fulfill() }
        webView.navigationDelegate = navigation
        webView.loadHTMLString("<p id='selection'>copied from WebKit</p>", baseURL: nil)
        await fulfillment(of: [loaded], timeout: 5)
        try await webView.evaluateJavaScript(
            "const range = document.createRange(); range.selectNodeContents(document.getElementById('selection')); const selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(range);"
        )

        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        await withCheckedContinuation { continuation in
            WebPreviewEditing.copySelection(in: webView, pasteboard: pasteboard) {
                continuation.resume()
            }
        }

        XCTAssertEqual(pasteboard.string(forType: .string), "copied from WebKit")
    }

    @MainActor
    func testWebEditingSelectAllPasteAndCutUseDOMSelection() async throws {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let panel = makeWindow()
        panel.contentView = webView
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }

        let navigation = NavigationWaiter()
        let loaded = expectation(description: "HTML loaded")
        navigation.didFinish = { loaded.fulfill() }
        webView.navigationDelegate = navigation
        webView.loadHTMLString("<textarea id='editor'>old text</textarea>", baseURL: nil)
        await fulfillment(of: [loaded], timeout: 5)
        try await webView.evaluateJavaScript("document.getElementById('editor').focus()")

        await withCheckedContinuation { continuation in
            WebPreviewEditing.selectAll(in: webView) { continuation.resume() }
        }
        await withCheckedContinuation { continuation in
            WebPreviewEditing.paste("replacement", in: webView) { continuation.resume() }
        }
        let pastedValue = try await webView.evaluateJavaScript("document.getElementById('editor').value") as? String
        XCTAssertEqual(pastedValue, "replacement")

        await withCheckedContinuation { continuation in
            WebPreviewEditing.selectAll(in: webView) { continuation.resume() }
        }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        await withCheckedContinuation { continuation in
            WebPreviewEditing.cutSelection(in: webView, pasteboard: pasteboard) {
                continuation.resume()
            }
        }
        let cutValue = try await webView.evaluateJavaScript("document.getElementById('editor').value") as? String
        XCTAssertEqual(cutValue, "")
        XCTAssertEqual(pasteboard.string(forType: .string), "replacement")
    }

    @MainActor
    func testDetachedPreviewPanelIsHiddenWithoutHidingArticleWindow() {
        let registry = InlinePreviewPanelRegistry()
        let panel = makeWindow()
        let articleWindow = makeWindow()
        defer {
            panel.orderOut(nil)
            articleWindow.orderOut(nil)
        }
        let preview = NSView(frame: panel.contentView!.bounds)
        panel.contentView!.addSubview(preview)
        registry.register(panel)
        panel.orderFrontRegardless()
        articleWindow.orderFrontRegardless()
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(articleWindow.isVisible)

        // Reproduce the inspected state: the menu panel survives its custom view.
        preview.removeFromSuperview()
        XCTAssertNil(preview.window)
        registry.hideClosedPanels(isMenuTracking: false)

        XCTAssertFalse(panel.isVisible)
        XCTAssertTrue(articleWindow.isVisible)
    }

    @MainActor
    func testReopeningDoesNotLosePreviouslyOrphanedPanel() {
        let registry = InlinePreviewPanelRegistry()
        let oldPanel = makeWindow()
        let newPanel = makeWindow()
        defer {
            oldPanel.orderOut(nil)
            newPanel.orderOut(nil)
        }
        registry.register(oldPanel)
        oldPanel.orderFrontRegardless()
        registry.register(newPanel)
        newPanel.orderFrontRegardless()

        // Deferred cleanup from the previous menu runs after a rapid reopening.
        registry.hideClosedPanels(isMenuTracking: true)
        XCTAssertTrue(oldPanel.isVisible)
        XCTAssertTrue(newPanel.isVisible)

        // Closing the new menu must also find the old orphan.
        registry.hideClosedPanels(isMenuTracking: false)
        XCTAssertFalse(oldPanel.isVisible)
        XCTAssertFalse(newPanel.isVisible)
    }

    @MainActor
    func testDelayedCleanupDoesNotCloseReopenedPreviewMenu() {
        let registry = InlinePreviewMenuRegistry()
        let menu = NSMenu()
        var cleanupCount = 0

        registry.didOpen(menu)
        registry.didClose(menu)
        registry.didOpen(menu)

        registry.performCleanupIfClosed(menu) {
            cleanupCount += 1
        }

        XCTAssertEqual(cleanupCount, 0)

        registry.didClose(menu)
        registry.performCleanupIfClosed(menu) {
            cleanupCount += 1
        }

        XCTAssertEqual(cleanupCount, 1)
    }

    @MainActor
    func testWebViewPreparationRetriesAfterPreviewIsDetachedAndReattached() {
        let panel = makeWindow()
        let story = FeedStory(
            id: "story",
            title: "Story",
            link: nil,
            summary: "Summary",
            publishedAt: nil,
            sourceFeedID: UUID()
        )
        var pendingCompletions: [(WKWebView) -> Void] = []
        var factoryCallCount = 0
        let preview = StoryPreviewMenuView(
            story: story,
            feed: nil,
            size: NSSize(width: 320, height: 240),
            markReadDelaySeconds: 0,
            panels: InlinePreviewPanelRegistry(),
            webViewFactory: { _, completion in
                factoryCallCount += 1
                pendingCompletions.append(completion)
            },
            markRead: { _ in }
        )
        defer { preview.endPreview() }

        panel.contentView?.addSubview(preview)
        preview.beginPreview()
        XCTAssertEqual(factoryCallCount, 1)

        preview.removeFromSuperview()
        pendingCompletions.removeFirst()(WKWebView(frame: preview.bounds))
        XCTAssertTrue(preview.subviews.isEmpty)

        panel.contentView?.addSubview(preview)
        XCTAssertEqual(factoryCallCount, 2)

        pendingCompletions.removeFirst()(WKWebView(frame: preview.bounds))
        XCTAssertEqual(preview.subviews.count, 1)
    }

    @MainActor
    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 240),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.level = .popUpMenu
        window.isReleasedWhenClosed = false
        return window
    }

}

@MainActor
private final class EditingTarget: NSResponder, EditingCommandTarget {
    var action: Selector?

    @objc func cut(_ sender: Any?) { action = #selector(NSText.cut(_:)) }
    @objc func copy(_ sender: Any?) { action = #selector(NSText.copy(_:)) }
    @objc func paste(_ sender: Any?) { action = #selector(NSText.paste(_:)) }
    override func selectAll(_ sender: Any?) { action = #selector(NSText.selectAll(_:)) }

    func cutSelection() { cut(nil) }
    func copySelection() { copy(nil) }
    func pasteClipboard() { paste(nil) }
    func selectAllContent() { selectAll(nil) }
}

@MainActor
private final class NavigationWaiter: NSObject, WKNavigationDelegate {
    var didFinish: (() -> Void)?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        didFinish?()
    }
}
