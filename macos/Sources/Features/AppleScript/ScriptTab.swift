import AppKit

/// AppleScript-facing wrapper around a single tab in a scripting window.
///
/// `ScriptWindow.tabs` vends these objects so AppleScript can traverse
/// `window -> tab` without knowing anything about AppKit controllers.
@MainActor
@objc(GhosttyScriptTab)
final class ScriptTab: NSObject {
    /// Stable identifier used by AppleScript `tab id "..."` references.
    private let stableID: String

    /// Weak back-reference to the scripting window that owns this tab wrapper.
    ///
    /// We only need this for dynamic properties (`index`, `selected`) and for
    /// building an object specifier path.
    private weak var window: ScriptWindow?

    /// Live terminal controller for this tab.
    ///
    /// This can become `nil` if the tab closes while a script is running.
    private weak var controller: BaseTerminalController?

    /// Stable identifier for Ghostty-managed sidebar tabs.
    private let tabID: UUID?

    /// Called by `ScriptWindow.tabs` / `ScriptWindow.selectedTab`.
    ///
    /// The ID is computed once so object specifiers built from this instance keep
    /// a consistent tab identity.
    init(window: ScriptWindow, controller: BaseTerminalController, tabID: UUID? = nil) {
        self.stableID = Self.stableID(controller: controller, tabID: tabID)
        self.window = window
        self.controller = controller
        self.tabID = tabID
    }

    /// Exposed as the AppleScript `id` property.
    @objc(id)
    var idValue: String {
        guard NSApp.isAppleScriptEnabled else { return "" }
        return stableID
    }

    /// Exposed as the AppleScript `title` property.
    ///
    /// Returns the title of the tab's window.
    @objc(title)
    var title: String {
        guard NSApp.isAppleScriptEnabled else { return "" }
        if let tabState {
            return tabState.title
        }

        return controller?.window?.title ?? ""
    }

    /// Exposed as the AppleScript `index` property.
    ///
    /// Cocoa scripting expects this to be 1-based for user-facing collections.
    @objc(index)
    var index: Int {
        guard NSApp.isAppleScriptEnabled else { return 0 }
        guard let controller else { return 0 }
        return window?.tabIndex(for: controller, tabID: tabID) ?? 0
    }

    /// Exposed as the AppleScript `selected` property.
    ///
    /// Powers script conditions such as `if selected of tab 1 then ...`.
    @objc(selected)
    var selected: Bool {
        guard NSApp.isAppleScriptEnabled else { return false }
        guard let controller else { return false }
        return window?.tabIsSelected(controller, tabID: tabID) ?? false
    }

    /// Best-effort native window containing this tab.
    var parentWindow: NSWindow? {
        guard NSApp.isAppleScriptEnabled else { return nil }
        return controller?.window
    }

    /// Live controller backing this tab wrapper.
    var parentController: BaseTerminalController? {
        guard NSApp.isAppleScriptEnabled else { return nil }
        return controller
    }

    /// Exposed as the AppleScript `terminals` element on a tab.
    ///
    /// Returns all terminal surfaces (split panes) within this tab.
    @objc(terminals)
    var terminals: [ScriptTerminal] {
        guard NSApp.isAppleScriptEnabled else { return [] }
        if let tabState {
            return (tabState.surfaceTree.root?.leaves() ?? [])
                .map(ScriptTerminal.init)
        }

        guard let controller else { return [] }
        return (controller.surfaceTree.root?.leaves() ?? [])
            .map(ScriptTerminal.init)
    }

    /// Enables unique-ID lookup for `terminals` references on a tab.
    @objc(valueInTerminalsWithUniqueID:)
    func valueInTerminals(uniqueID: String) -> ScriptTerminal? {
        guard NSApp.isAppleScriptEnabled else { return nil }
        if let tabState {
            return (tabState.surfaceTree.root?.leaves() ?? [])
                .first(where: { $0.id.uuidString == uniqueID })
                .map(ScriptTerminal.init)
        }

        guard let controller else { return nil }
        return (controller.surfaceTree.root?.leaves() ?? [])
            .first(where: { $0.id.uuidString == uniqueID })
            .map(ScriptTerminal.init)
    }

    /// Handler for `select tab <tab>`.
    @objc(handleSelectTabCommand:)
    func handleSelectTab(_ command: NSScriptCommand) -> Any? {
        guard NSApp.validateScript(command: command) else { return nil }

        if let controller = controller as? TerminalController,
           let tabID {
            guard controller.selectTab(id: tabID, focus: true) else {
                command.scriptErrorNumber = errAEEventFailed
                command.scriptErrorString = "Tab is no longer available."
                return nil
            }

            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return nil
        }

        guard let tabContainerWindow = parentWindow else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = "Tab is no longer available."
            return nil
        }

        tabContainerWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return nil
    }

    /// Handler for `close tab <tab>`.
    @objc(handleCloseTabCommand:)
    func handleCloseTab(_ command: NSScriptCommand) -> Any? {
        guard NSApp.validateScript(command: command) else { return nil }

        if let managedTerminalController = controller as? TerminalController,
           let tabID {
            managedTerminalController.closeTabImmediately(
                tabID: tabID,
                registerUndo: true,
                registerRedo: false
            )
            return nil
        }

        guard let tabController = parentController else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = "Tab is no longer available."
            return nil
        }

        if let managedTerminalController = tabController as? TerminalController {
            managedTerminalController.closeTabImmediately(registerRedo: false)
            return nil
        }

        guard let tabContainerWindow = parentWindow else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = "Tab container window is no longer available."
            return nil
        }

        tabContainerWindow.close()
        return nil
    }

    /// Provides Cocoa scripting with a canonical "path" back to this object.
    override var objectSpecifier: NSScriptObjectSpecifier? {
        guard NSApp.isAppleScriptEnabled else { return nil }
        guard let window else { return nil }
        guard let windowClassDescription = window.classDescription as? NSScriptClassDescription else {
            return nil
        }
        guard let windowSpecifier = window.objectSpecifier else { return nil }

        // This tells Cocoa how to re-find this tab later:
        // application -> scriptWindows[id] -> tabs[id].
        return NSUniqueIDSpecifier(
            containerClassDescription: windowClassDescription,
            containerSpecifier: windowSpecifier,
            key: "tabs",
            uniqueID: stableID
        )
    }
}

extension ScriptTab {
    private var tabState: TerminalTabState? {
        guard let terminalController = controller as? TerminalController,
              let tabID else { return nil }
        return terminalController.tabState(id: tabID)
    }

    static func stableID(controller: BaseTerminalController, tabID: UUID? = nil) -> String {
        if let tabID {
            return "tab-\(tabID.uuidString)"
        }

        return "tab-\(ObjectIdentifier(controller).hexString)"
    }
}
