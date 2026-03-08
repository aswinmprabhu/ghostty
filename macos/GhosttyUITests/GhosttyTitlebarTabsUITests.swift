import XCTest

final class GhosttyTitlebarTabsUITests: GhosttyCustomConfigCase {
    override func setUp() async throws {
        try await super.setUp()

        try updateConfig(
            """
            macos-titlebar-style = tabs
            title = "GhosttySidebarTabsUITests"
            """
        )
    }

    @MainActor
    func testTabsCompatibilityStyleShowsSidebar() throws {
        let app = try ghosttyApplication()
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5), "Main window should exist")
        XCTAssertTrue(
            window.descendants(matching: .any).matching(identifier: "sidebar-new-tab").firstMatch.waitForExistence(timeout: 5),
            "Left sidebar actions should always be visible"
        )
        XCTAssertTrue(rightSidebar(in: window).waitForExistence(timeout: 5), "Right sidebar should be visible")
        XCTAssertTrue(window.descendants(matching: .any).matching(identifier: "sidebar-right-pr-panel").firstMatch.exists)
        XCTAssertTrue(window.descendants(matching: .any).matching(identifier: "sidebar-new-tab").firstMatch.exists)
        XCTAssertTrue(window.descendants(matching: .any).matching(identifier: "sidebar-new-worktree").firstMatch.exists)
    }

    @MainActor
    func testNewTabButtonAddsSidebarTab() throws {
        let app = try ghosttyApplication()
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5), "Main window should exist")

        let initialCount = sidebarTabRows(in: window).count
        let newTabButton = window.descendants(matching: .any).matching(identifier: "sidebar-new-tab").firstMatch
        XCTAssertTrue(newTabButton.waitForExistence(timeout: 5), "New Tab button should exist")

        newTabButton.click()

        XCTAssertTrue(waitForSidebarTabCount(in: window, expected: initialCount + 1, timeout: 1), "Clicking New Tab should add a new sidebar tab")
    }

    @MainActor
    func testWorktreeButtonOpensSheet() throws {
        let app = try ghosttyApplication()
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5), "Main window should exist")

        let button = window.descendants(matching: .any).matching(identifier: "sidebar-new-worktree").firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), "New Worktree button should exist")

        button.click()

        let repositoryField = app.descendants(matching: .any).matching(identifier: "worktree-repository-path").firstMatch
        XCTAssertTrue(repositoryField.waitForExistence(timeout: 1), "Worktree sheet should appear")
    }

    private func rightSidebar(in window: XCUIElement) -> XCUIElement {
        window.descendants(matching: .any).matching(identifier: "terminal-right-sidebar").firstMatch
    }

    private func sidebarTabRows(in window: XCUIElement) -> XCUIElementQuery {
        window.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "sidebar-tab-"))
    }

    private func waitForSidebarTabCount(in window: XCUIElement, expected: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if sidebarTabRows(in: window).count == expected {
                return true
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        return sidebarTabRows(in: window).count == expected
    }
}
