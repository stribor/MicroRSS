import AppKit
import XCTest
@testable import MicroRSS

final class InlinePreviewPanelTests: XCTestCase {
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
