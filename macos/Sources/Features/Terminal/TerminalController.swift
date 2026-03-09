import Cocoa
import Combine
import Foundation
import GhosttyKit
import SwiftUI

/// A classic, custom-tabbed terminal experience.
class TerminalController: BaseTerminalController {
    override var windowNibName: NSNib.Name? {
        let defaultValue = "Terminal"

        guard let appDelegate = NSApp.delegate as? AppDelegate else { return defaultValue }
        let config = appDelegate.ghostty.config

        if !config.windowDecorations {
            return defaultValue
        }

        return switch config.macosTitlebarStyle {
        case "native":
            "Terminal"
        case "hidden":
            "TerminalHiddenTitlebar"
        case "transparent", "tabs":
            "TerminalTransparentTitlebar"
        default:
            defaultValue
        }
    }

    private struct ClosedTabUndoState {
        let index: Int
        let state: TerminalTabRestorableState
    }

    struct WindowUndoState {
        let frame: NSRect
        let tabs: [TerminalTabRestorableState]
        let selectedTabID: UUID?
    }

    /// This is set to false by init if the window managed by this controller should not be restorable.
    private var restorable: Bool = true

    /// The configuration derived from the Ghostty config so we don't need to rely on references.
    private(set) var derivedConfig: DerivedConfig

    /// The notification cancellable for focused surface property changes.
    private var surfaceAppearanceCancellables: Set<AnyCancellable> = []

    /// This will be set to the initial frame of the window from the xib on load.
    private var initialFrame: NSRect?

    @Published private(set) var tabs: [TerminalTabState] = []
    @Published private(set) var selectedTabID: UUID?
    @Published var worktreeSheetModel: TerminalWorktreeSheetModel?
    @Published var prReviewSheetModel: TerminalPRReviewSheetModel?
    @Published var fileCommandPaletteModel: TerminalFileCommandPaletteModel?

    let repositoryService = TerminalRepositoryService.shared
    private var pullRequestRefreshTask: Task<Void, Never>?
    private var pullRequestRefreshTimer: Timer?
    private let leftSidebarWidth: CGFloat = 280
    private let rightSidebarRailWidth: CGFloat = 32
    private let rightSidebarDefaultWidth: CGFloat = 360
    private let rightSidebarMinimumWidth: CGFloat = 300

    init(
        _ ghostty: Ghostty.App,
        withBaseConfig base: Ghostty.SurfaceConfiguration? = nil,
        withSurfaceTree tree: SplitTree<Ghostty.SurfaceView>? = nil,
        parent: NSWindow? = nil
    ) {
        self.restorable = (base?.command ?? "") == ""
        self.derivedConfig = DerivedConfig(ghostty.config)

        super.init(ghostty, baseConfig: base, surfaceTree: tree)

        let initialFocusedID = surfaceTree.first?.id
        let initialTab = TerminalTabState(
            surfaceTree: surfaceTree,
            focusedSurfaceID: initialFocusedID,
            titleOverride: titleOverride,
            tabColor: .none,
            workingDirectory: surfaceTree.first?.pwd
        )
        self.tabs = [initialTab]
        self.selectedTabID = initialTab.id

        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(onToggleFullscreen),
            name: Ghostty.Notification.ghosttyToggleFullscreen,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(onMoveTab),
            name: .ghosttyMoveTab,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(onGotoTab),
            name: Ghostty.Notification.ghosttyGotoTab,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(onCloseTab),
            name: .ghosttyCloseTab,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(onCloseOtherTabs),
            name: .ghosttyCloseOtherTabs,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(onCloseTabsOnTheRight),
            name: .ghosttyCloseTabsOnTheRight,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(onResetWindowSize),
            name: .ghosttyResetWindowSize,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(ghosttyConfigDidChange(_:)),
            name: .ghosttyConfigDidChange,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(onCloseWindow),
            name: .ghosttyCloseWindow,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for this view")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        pullRequestRefreshTask?.cancel()
        pullRequestRefreshTimer?.invalidate()
    }

    var selectedTab: TerminalTabState? {
        if let selectedTabID {
            return tabs.first(where: { $0.id == selectedTabID }) ?? tabs.first
        }

        return tabs.first
    }

    var selectedTabIndex: Int? {
        guard let selectedTabID else { return nil }
        return tabs.firstIndex(where: { $0.id == selectedTabID })
    }

    var selectedRightSidebarSelection: TerminalInspectorTab {
        selectedTab?.rightSidebarSelection ?? .changes
    }

    var isSelectedRightSidebarCollapsed: Bool {
        selectedTab?.isRightSidebarCollapsed ?? false
    }

    var selectedRightSidebarSplit: CGFloat {
        selectedTab?.rightSidebarSplit ?? 0.74
    }

    var allTabSurfaceViews: [Ghostty.SurfaceView] {
        tabs.flatMap { $0.surfaceTree.root?.leaves() ?? [] }
    }

    func tabState(id: UUID) -> TerminalTabState? {
        tabs.first(where: { $0.id == id })
    }

    var windowUndoState: WindowUndoState? {
        guard let window else { return nil }
        guard !tabs.isEmpty else { return nil }
        syncSelectedTabStateFromController()
        return WindowUndoState(
            frame: window.frame,
            tabs: tabs.map(\.restorableState),
            selectedTabID: selectedTabID
        )
    }

    // MARK: Base Controller Overrides

    override func surfaceTreeDidChange(from: SplitTree<Ghostty.SurfaceView>, to: SplitTree<Ghostty.SurfaceView>) {
        super.surfaceTreeDidChange(from: from, to: to)

        invalidateRestorableState()

        if let selectedTab {
            selectedTab.updateSurfaceTree(to)
            selectedTab.setFocusedSurfaceID(focusedSurface?.id)
        }

        if let window = window as? TerminalWindow {
            window.surfaceIsZoomed = to.zoomed != nil
            window.tabColor = selectedTab?.tabColor ?? .none
        }

        if to.isEmpty {
            if tabs.count > 1 {
                closeTabImmediately(registerUndo: false, registerRedo: false)
            } else {
                self.window?.close()
            }
        }
    }

    override func replaceSurfaceTree(
        _ newTree: SplitTree<Ghostty.SurfaceView>,
        moveFocusTo newView: Ghostty.SurfaceView? = nil,
        moveFocusFrom oldView: Ghostty.SurfaceView? = nil,
        undoAction: String? = nil
    ) {
        guard let selectedTab else {
            super.replaceSurfaceTree(
                newTree,
                moveFocusTo: newView,
                moveFocusFrom: oldView,
                undoAction: undoAction
            )
            return
        }

        if newTree.isEmpty {
            closeTabImmediately(registerUndo: false, registerRedo: false)
            return
        }

        let tabID = selectedTab.id
        let oldTree = surfaceTree
        let oldFocusedSurfaceID = oldView?.id ?? focusedSurface?.id
        let newFocusedSurfaceID = newView?.id ?? selectedTab.activeSurface?.id

        selectedTab.updateSurfaceTree(newTree)
        selectedTab.setFocusedSurfaceID(newFocusedSurfaceID)
        surfaceTree = newTree
        focusedSurface = newView ?? selectedTab.activeSurface

        if let focusTarget = newView {
            DispatchQueue.main.async {
                Ghostty.moveFocus(to: focusTarget, from: oldView)
            }
        }

        registerUndoForTreeChange(
            tabID: tabID,
            oldTree: oldTree,
            oldFocusedSurfaceID: oldFocusedSurfaceID,
            newTree: newTree,
            newFocusedSurfaceID: newFocusedSurfaceID,
            undoAction: undoAction
        )
    }

    override func closeSurface(
        _ node: SplitTree<Ghostty.SurfaceView>.Node,
        withConfirmation: Bool = true
    ) {
        if surfaceTree.root != node {
            super.closeSurface(node, withConfirmation: withConfirmation)
            return
        }

        if tabs.count > 1 {
            closeTab(nil)
            return
        }

        closeWindow(nil)
    }

    override func promptTabTitle() {
        guard let window else { return }

        let alert = NSAlert()
        alert.messageText = "Change Tab Title"
        alert.informativeText = "Leave blank to restore the default."
        alert.alertStyle = .informational

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        textField.stringValue = titleOverride ?? window.title
        alert.accessoryView = textField

        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = textField

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .alertFirstButtonReturn else { return }

            let newTitle = textField.stringValue
            self.setCurrentTabTitleOverride(newTitle.isEmpty ? nil : newTitle)
        }
    }

    override func pwdDidChange(to: URL?) {
        super.pwdDidChange(to: to)

        selectedTab?.setWorkingDirectory(to?.path)
        refreshSelectedTabRepositoryContextAndPullRequest()
    }

    // MARK: Terminal Creation

    /// Returns all the available terminal controllers present in the app currently.
    static var all: [TerminalController] {
        NSApplication.shared.windows.compactMap {
            $0.windowController as? TerminalController
        }
    }

    private static let pullRequestRefreshInterval: TimeInterval = 300
    private static let defaultRightSidebarSplit: CGFloat = 0.74

    private static var lastCascadePoint = NSPoint(x: 0, y: 0)

    private static func applyCascade(to window: NSWindow, hasFixedPos: Bool) {
        if hasFixedPos { return }

        if all.count > 1 {
            lastCascadePoint = window.cascadeTopLeft(from: lastCascadePoint)
        } else {
            lastCascadePoint = window.cascadeTopLeft(
                from: NSPoint(x: window.frame.minX, y: window.frame.maxY)
            )
        }
    }

    static var preferredParent: TerminalController? {
        all.first {
            $0.window?.isMainWindow ?? false
        } ?? lastMain ?? all.last
    }

    static private(set) weak var lastMain: TerminalController?

    static func newWindow(
        _ ghostty: Ghostty.App,
        withBaseConfig baseConfig: Ghostty.SurfaceConfiguration? = nil,
        withParent explicitParent: NSWindow? = nil
    ) -> TerminalController {
        let controller = TerminalController(ghostty, withBaseConfig: baseConfig)
        let parent: NSWindow? = explicitParent ?? preferredParent?.window

        if let parent, parent.styleMask.contains(.fullScreen) {
            controller.toggleFullscreen(mode: .native)
        } else if let fullscreenMode = ghostty.config.windowFullscreen {
            switch fullscreenMode {
            case .native:
                controller.toggleFullscreen(mode: .native)
            case .nonNative, .nonNativeVisibleMenu, .nonNativePaddedNotch:
                DispatchQueue.main.async {
                    controller.toggleFullscreen(mode: fullscreenMode)
                }
            }
        }

        DispatchQueue.main.async {
            if let window = controller.window, !window.styleMask.contains(.fullScreen) {
                let hasFixedPos = controller.derivedConfig.windowPositionX != nil &&
                    controller.derivedConfig.windowPositionY != nil
                Self.applyCascade(to: window, hasFixedPos: hasFixedPos)
            }

            controller.showWindow(self)
            NSApp.activate(ignoringOtherApps: true)
        }

        if let undoManager = controller.undoManager {
            undoManager.setActionName("New Window")
            undoManager.registerUndo(
                withTarget: controller,
                expiresAfter: controller.undoExpiration
            ) { target in
                undoManager.disableUndoRegistration {
                    target.closeWindow(nil)
                }

                undoManager.registerUndo(
                    withTarget: ghostty,
                    expiresAfter: target.undoExpiration
                ) { ghostty in
                    _ = TerminalController.newWindow(
                        ghostty,
                        withBaseConfig: baseConfig,
                        withParent: explicitParent
                    )
                }
            }
        }

        return controller
    }

    static func newWindow(
        _ ghostty: Ghostty.App,
        tree: SplitTree<Ghostty.SurfaceView>,
        position: NSPoint? = nil,
        confirmUndo: Bool = true
    ) -> TerminalController {
        let controller = TerminalController(ghostty, withSurfaceTree: tree)
        let treeSize: CGSize? = tree.root?.viewBounds()

        DispatchQueue.main.async {
            if let window = controller.window {
                if let treeSize, treeSize.width > 0, treeSize.height > 0 {
                    window.setContentSize(treeSize)
                    window.constrainToScreen()
                }

                if !window.styleMask.contains(.fullScreen) {
                    if let position {
                        window.setFrameTopLeftPoint(position)
                        window.constrainToScreen()
                    } else {
                        let hasFixedPos = controller.derivedConfig.windowPositionX != nil &&
                            controller.derivedConfig.windowPositionY != nil
                        Self.applyCascade(to: window, hasFixedPos: hasFixedPos)
                    }
                }
            }

            controller.showWindow(self)
        }

        if let undoManager = controller.undoManager {
            undoManager.setActionName("New Window")
            undoManager.registerUndo(
                withTarget: controller,
                expiresAfter: controller.undoExpiration
            ) { target in
                undoManager.disableUndoRegistration {
                    if confirmUndo {
                        target.closeWindow(nil)
                    } else {
                        target.closeWindowImmediately()
                    }
                }

                undoManager.registerUndo(
                    withTarget: ghostty,
                    expiresAfter: target.undoExpiration
                ) { ghostty in
                    _ = TerminalController.newWindow(ghostty, tree: tree)
                }
            }
        }

        return controller
    }

    static func newTab(
        _ ghostty: Ghostty.App,
        from parent: NSWindow? = nil,
        withBaseConfig baseConfig: Ghostty.SurfaceConfiguration? = nil
    ) -> TerminalController? {
        guard let parent,
              let parentController = parent.windowController as? TerminalController else {
            return newWindow(ghostty, withBaseConfig: baseConfig, withParent: parent)
        }

        if let fullscreenStyle = parentController.fullscreenStyle,
           fullscreenStyle.isFullscreen && !fullscreenStyle.supportsTabs {
            let alert = NSAlert()
            alert.messageText = "Cannot Create New Tab"
            alert.informativeText = "New tabs are unsupported while in non-native fullscreen. Exit fullscreen and try again."
            alert.addButton(withTitle: "OK")
            alert.alertStyle = .warning
            alert.beginSheetModal(for: parent)
            return nil
        }

        if parent.isMiniaturized {
            parent.deminiaturize(self)
        }

        guard let createdTab = parentController.createTab(baseConfig: baseConfig) else {
            return nil
        }

        if let undoManager = parentController.undoManager {
            undoManager.setActionName("New Tab")
            undoManager.registerUndo(
                withTarget: parentController,
                expiresAfter: parentController.undoExpiration
            ) { target in
                target.closeTabImmediately(
                    tabID: createdTab.id,
                    registerUndo: false,
                    registerRedo: false
                )

                undoManager.registerUndo(
                    withTarget: ghostty,
                    expiresAfter: target.undoExpiration
                ) { ghostty in
                    _ = TerminalController.newTab(
                        ghostty,
                        from: parent,
                        withBaseConfig: baseConfig
                    )
                }
            }
        }

        DispatchQueue.main.async {
            parentController.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        return parentController
    }

    @discardableResult
    func createTab(baseConfig: Ghostty.SurfaceConfiguration? = nil, select: Bool = true) -> TerminalTabState? {
        guard let ghosttyApp = ghostty.app else { return nil }

        let surfaceView = Ghostty.SurfaceView(ghosttyApp, baseConfig: baseConfig)
        let tab = TerminalTabState(
            surfaceTree: SplitTree(view: surfaceView),
            focusedSurfaceID: surfaceView.id,
            titleOverride: nil,
            tabColor: .none,
            workingDirectory: surfaceView.pwd
        )

        let insertionIndex: Int
        switch ghostty.config.windowNewTabPosition {
        case "end":
            insertionIndex = tabs.count
        case "current":
            insertionIndex = min((selectedTabIndex ?? (tabs.count - 1)) + 1, tabs.count)
        default:
            insertionIndex = tabs.count
        }

        tabs.insert(tab, at: max(0, insertionIndex))
        relabelTabs()
        invalidateRestorableState()

        if select {
            _ = selectTab(id: tab.id, focus: true)
        }

        return tab
    }

    @discardableResult
    func selectTab(id: UUID, focus: Bool = true) -> Bool {
        guard tabs.contains(where: { $0.id == id }) else { return false }

        syncSelectedTabStateFromController()
        selectedTabID = id
        applySelectedTabState(focus: focus)
        return true
    }

    func moveSelectedTab(by amount: Int) {
        guard amount != 0 else { return }
        guard let selectedTabIndex else { return }

        let destination: Int
        if amount < 0 {
            destination = selectedTabIndex - min(selectedTabIndex, -amount)
        } else {
            let remaining = tabs.count - 1 - selectedTabIndex
            destination = selectedTabIndex + min(remaining, amount)
        }

        guard destination != selectedTabIndex else { return }

        let movedTab = tabs.remove(at: selectedTabIndex)
        tabs.insert(movedTab, at: destination)
        relabelTabs()
        invalidateRestorableState()
    }

    func moveTab(draggedTabID: UUID, before targetID: UUID) {
        guard draggedTabID != targetID else { return }
        guard let sourceIndex = tabs.firstIndex(where: { $0.id == draggedTabID }) else { return }
        guard let destinationIndex = tabs.firstIndex(where: { $0.id == targetID }) else { return }
        guard sourceIndex != destinationIndex else { return }

        let movedTab = tabs.remove(at: sourceIndex)
        let adjustedDestination = sourceIndex < destinationIndex ? destinationIndex - 1 : destinationIndex
        tabs.insert(movedTab, at: adjustedDestination)
        relabelTabs()
        invalidateRestorableState()
    }

    func requestCloseTab(id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        _ = selectTab(id: id, focus: false)
        closeTab(nil)
    }

    func setSelectedRightSidebarSelection(_ selection: TerminalInspectorTab) {
        guard let selectedTab else { return }
        guard selectedTab.rightSidebarSelection != selection else { return }

        selectedTab.setRightSidebarSelection(selection)
        invalidateRestorableState()

        if selection == .changes {
            refreshSelectedTabRepositoryContextAndPullRequest()
        }
    }

    func setSelectedRightSidebarCollapsed(_ isCollapsed: Bool) {
        guard let selectedTab else { return }
        guard selectedTab.isRightSidebarCollapsed != isCollapsed else { return }

        objectWillChange.send()
        selectedTab.setRightSidebarCollapsed(isCollapsed)
        invalidateRestorableState()

        if !isCollapsed {
            refreshSelectedTabRepositoryContextAndPullRequest()
        }
    }

    func toggleSelectedRightSidebarCollapsed() {
        setSelectedRightSidebarCollapsed(!isSelectedRightSidebarCollapsed)
    }

    func setSelectedRightSidebarSplit(_ split: CGFloat) {
        guard let selectedTab else { return }
        let clamped = clampRightSidebarSplit(split)
        guard selectedTab.rightSidebarSplit != clamped else { return }

        selectedTab.setRightSidebarSplit(clamped)
        invalidateRestorableState()
    }

    func resetSelectedRightSidebarSplit() {
        setSelectedRightSidebarSplit(Self.defaultRightSidebarSplit)
    }

    func refreshSelectedTabPullRequestFromUI() {
        refreshSelectedTabRepositoryContextAndPullRequest()
    }

    private var diffLoadTask: Task<Void, Never>?

    func openDiffForFile(_ file: TerminalRepositoryChangeFile) {
        guard let selectedTab else { return }
        objectWillChange.send()
        selectedTab.openDiffForFile(file)

        diffLoadTask?.cancel()
        diffLoadTask = Task { [weak selectedTab, weak self] in
            guard let selectedTab, let self else { return }
            guard let context = selectedTab.repositoryRoot.flatMap({ root in
                selectedTab.branchName.map { branch in
                    TerminalRepositoryContext(
                        workingDirectory: selectedTab.workingDirectory ?? root,
                        repositoryRoot: root,
                        repositoryName: URL(fileURLWithPath: root).lastPathComponent,
                        branchName: branch
                    )
                }
            }) else {
                await MainActor.run { selectedTab.setDiffRawText("") }
                return
            }

            do {
                let rawDiff = try await repositoryService.fetchFileDiffRaw(
                    for: context,
                    file: file,
                    preferredBaseBranch: selectedTab.pullRequestSummary?.baseRefName
                )
                guard !Task.isCancelled else { return }

                // Read the current file content for diff expansion
                let fullPath = (context.repositoryRoot as NSString).appendingPathComponent(file.path)
                let fileContent = try? String(contentsOfFile: fullPath, encoding: .utf8)

                await MainActor.run { selectedTab.setDiffRawText(rawDiff, fileContent: fileContent) }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run { selectedTab.setDiffRawText("") }
            }
        }
    }

    func closeDiff() {
        diffLoadTask?.cancel()
        objectWillChange.send()
        selectedTab?.closeDiff()
    }

    private var fileLoadTask: Task<Void, Never>?

    func openFileViewer(relativePath: String) {
        guard let selectedTab, let root = selectedTab.repositoryRoot else { return }
        let fullPath = (root as NSString).appendingPathComponent(relativePath)
        objectWillChange.send()
        selectedTab.openFileViewer(path: relativePath)

        fileLoadTask?.cancel()
        fileLoadTask = Task { [weak selectedTab] in
            do {
                let content = try String(contentsOfFile: fullPath, encoding: .utf8)
                guard !Task.isCancelled else { return }
                await MainActor.run { selectedTab?.setViewerFileContent(content) }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run { selectedTab?.setViewerFileContent("") }
            }
        }
    }

    func closeFileViewer() {
        fileLoadTask?.cancel()
        objectWillChange.send()
        selectedTab?.closeFileViewer()
    }

    private var combinedDiffLoadTask: Task<Void, Never>?

    func openAllChangesDiff(section: String) {
        guard let selectedTab else { return }
        objectWillChange.send()
        selectedTab.openCombinedDiff(title: "\(section) Changes")

        combinedDiffLoadTask?.cancel()
        combinedDiffLoadTask = Task { [weak selectedTab, weak self] in
            guard let selectedTab, let self else { return }
            guard let context = selectedTab.repositoryRoot.flatMap({ root in
                selectedTab.branchName.map { branch in
                    TerminalRepositoryContext(
                        workingDirectory: selectedTab.workingDirectory ?? root,
                        repositoryRoot: root,
                        repositoryName: URL(fileURLWithPath: root).lastPathComponent,
                        branchName: branch
                    )
                }
            }) else {
                await MainActor.run { selectedTab.setCombinedDiffText("") }
                return
            }

            do {
                let rawDiff = try await repositoryService.fetchAllChangesDiff(
                    for: context,
                    section: section,
                    preferredBaseBranch: selectedTab.pullRequestSummary?.baseRefName
                )
                guard !Task.isCancelled else { return }
                await MainActor.run { selectedTab.setCombinedDiffText(rawDiff) }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run { selectedTab.setCombinedDiffText("") }
            }
        }
    }

    func openCommitDiff(_ commit: TerminalCommitEntry) {
        guard let selectedTab else { return }
        objectWillChange.send()
        selectedTab.openCombinedDiff(title: "\(commit.shortHash) — \(commit.subject)")

        combinedDiffLoadTask?.cancel()
        combinedDiffLoadTask = Task { [weak selectedTab, weak self] in
            guard let selectedTab, let self,
                  let root = selectedTab.repositoryRoot else {
                await MainActor.run { selectedTab?.setCombinedDiffText("") }
                return
            }

            do {
                let rawDiff = try await repositoryService.fetchCommitDiff(
                    repositoryRoot: root,
                    commitHash: commit.hash
                )
                guard !Task.isCancelled else { return }
                await MainActor.run { selectedTab.setCombinedDiffText(rawDiff) }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run { selectedTab.setCombinedDiffText("") }
            }
        }
    }

    func closeCombinedDiff() {
        combinedDiffLoadTask?.cancel()
        objectWillChange.send()
        selectedTab?.closeCombinedDiff()
    }

    private var commitsLoadTask: Task<Void, Never>?

    func loadCommits() {
        guard let selectedTab else { return }
        selectedTab.isCommitsLoading = true

        commitsLoadTask?.cancel()
        commitsLoadTask = Task { [weak selectedTab, weak self] in
            guard let selectedTab, let self else { return }
            guard let context = selectedTab.repositoryRoot.flatMap({ root in
                selectedTab.branchName.map { branch in
                    TerminalRepositoryContext(
                        workingDirectory: selectedTab.workingDirectory ?? root,
                        repositoryRoot: root,
                        repositoryName: URL(fileURLWithPath: root).lastPathComponent,
                        branchName: branch
                    )
                }
            }) else {
                await MainActor.run { selectedTab.setCommitEntries([]) }
                return
            }

            do {
                let entries = try await repositoryService.fetchCommitLog(
                    for: context,
                    preferredBaseBranch: selectedTab.pullRequestSummary?.baseRefName
                )
                guard !Task.isCancelled else { return }
                await MainActor.run { selectedTab.setCommitEntries(entries) }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run { selectedTab.setCommitEntries([]) }
            }
        }
    }

    func presentFileCommandPalette() {
        let root: String
        if let repoRoot = selectedTab?.repositoryRoot {
            root = repoRoot
        } else if let wd = selectedTab?.workingDirectory {
            root = wd
        } else {
            return
        }

        fileCommandPaletteModel = TerminalFileCommandPaletteModel(
            repositoryRoot: root,
            onSelect: { [weak self] relativePath in
                self?.fileCommandPaletteModel = nil
                self?.openFileViewer(relativePath: relativePath)
            },
            onCancel: { [weak self] in
                self?.fileCommandPaletteModel = nil
            }
        )
    }

    func openDiffForComment(_ thread: TerminalPullRequestReviewThread) {
        guard let selectedTab, let path = thread.path else { return }

        // Create a synthetic change file for the comment's path
        let file = TerminalRepositoryChangeFile(
            id: "comment-\(thread.id)",
            path: path,
            additions: 0,
            deletions: 0,
            isBinary: false,
            badges: [],
            sectionTitle: "Committed"
        )

        objectWillChange.send()
        selectedTab.activeReviewThread = thread
        selectedTab.openDiffForFile(file)

        diffLoadTask?.cancel()
        diffLoadTask = Task { [weak selectedTab, weak self] in
            guard let selectedTab, let self else { return }
            guard let context = selectedTab.repositoryRoot.flatMap({ root in
                selectedTab.branchName.map { branch in
                    TerminalRepositoryContext(
                        workingDirectory: selectedTab.workingDirectory ?? root,
                        repositoryRoot: root,
                        repositoryName: URL(fileURLWithPath: root).lastPathComponent,
                        branchName: branch
                    )
                }
            }) else {
                await MainActor.run { selectedTab.setDiffRawText("") }
                return
            }

            do {
                let rawDiff = try await repositoryService.fetchFileDiffRaw(
                    for: context,
                    file: file,
                    preferredBaseBranch: selectedTab.pullRequestSummary?.baseRefName
                )
                guard !Task.isCancelled else { return }

                let fullPath = (context.repositoryRoot as NSString).appendingPathComponent(file.path)
                let fileContent = try? String(contentsOfFile: fullPath, encoding: .utf8)

                await MainActor.run { selectedTab.setDiffRawText(rawDiff, fileContent: fileContent) }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run { selectedTab.setDiffRawText("") }
            }
        }
    }

    func addThreadToChat(_ thread: TerminalPullRequestReviewThread) {
        guard let selectedTab else { return }
        let comment = TerminalLocalReviewComment(
            id: UUID(),
            filePath: thread.path ?? "unknown",
            startLine: thread.startLine ?? thread.line ?? 0,
            endLine: thread.line ?? thread.startLine ?? 0,
            side: thread.diffSide?.lowercased() == "left" ? "old" : "new",
            text: thread.comments.map { "\($0.authorLogin): \($0.body)" }.joined(separator: "\n")
        )
        selectedTab.addPRThreadComment(comment)
        objectWillChange.send()
    }

    func replyToThread(threadID: String, body: String) {
        guard let selectedTab else { return }
        guard let context = selectedTab.repositoryRoot.flatMap({ root in
            selectedTab.branchName.map { branch in
                TerminalRepositoryContext(
                    workingDirectory: selectedTab.workingDirectory ?? root,
                    repositoryRoot: root,
                    repositoryName: URL(fileURLWithPath: root).lastPathComponent,
                    branchName: branch
                )
            }
        }), let prNumber = selectedTab.pullRequestSummary?.number else { return }

        Task { [weak self] in
            guard let self else { return }
            do {
                try await repositoryService.replyToReviewThread(
                    for: context,
                    pullRequestNumber: prNumber,
                    commentID: threadID,
                    body: body
                )
                await MainActor.run {
                    self.refreshSelectedTabPullRequestFromUI()
                }
            } catch {
                // Errors are silently ignored for now; the refresh will show current state
            }
        }
    }

    func resolveThread(threadID: String, resolve: Bool) {
        guard let selectedTab else { return }
        guard let context = selectedTab.repositoryRoot.flatMap({ root in
            selectedTab.branchName.map { branch in
                TerminalRepositoryContext(
                    workingDirectory: selectedTab.workingDirectory ?? root,
                    repositoryRoot: root,
                    repositoryName: URL(fileURLWithPath: root).lastPathComponent,
                    branchName: branch
                )
            }
        }) else { return }

        Task { [weak self] in
            guard let self else { return }
            do {
                if resolve {
                    try await repositoryService.resolveReviewThread(for: context, threadID: threadID)
                } else {
                    try await repositoryService.unresolveReviewThread(for: context, threadID: threadID)
                }
                await MainActor.run {
                    self.refreshSelectedTabPullRequestFromUI()
                }
            } catch {
                // Errors are silently ignored; refresh shows current state
            }
        }
    }

    func mergePullRequest(method: TerminalMergeMethod) {
        guard let selectedTab else { return }
        guard let context = selectedTab.repositoryRoot.flatMap({ root in
            selectedTab.branchName.map { branch in
                TerminalRepositoryContext(
                    workingDirectory: selectedTab.workingDirectory ?? root,
                    repositoryRoot: root,
                    repositoryName: URL(fileURLWithPath: root).lastPathComponent,
                    branchName: branch
                )
            }
        }) else { return }

        selectedTab.mergeInProgress = true
        selectedTab.mergeError = nil
        objectWillChange.send()

        Task { [weak selectedTab, weak self] in
            guard let selectedTab, let self else { return }
            do {
                try await repositoryService.mergePullRequest(for: context, method: method)
                await MainActor.run {
                    selectedTab.mergeInProgress = false
                    selectedTab.mergeError = nil
                    self.objectWillChange.send()
                    // Refresh after merge
                    self.refreshSelectedTabPullRequestFromUI()
                }
            } catch {
                await MainActor.run {
                    selectedTab.mergeInProgress = false
                    selectedTab.mergeError = error.localizedDescription
                    self.objectWillChange.send()
                }
            }
        }
    }

    func sendReviewCommentsToChat() -> String? {
        guard let selectedTab else { return "No active tab." }
        guard let surface = focusedSurface, let surfaceModel = surface.surfaceModel else {
            return "No active terminal session. Open a terminal first."
        }

        let comments = selectedTab.localReviewComments
        guard !comments.isEmpty else { return "No review comments to send." }

        var message = "Please fix the following review comments:\n\n"
        for comment in comments {
            message += "File: \(comment.filePath)\n"
            if comment.startLine == comment.endLine {
                message += "Line \(comment.startLine) (\(comment.side) side)\n"
            } else {
                message += "Lines \(comment.startLine)-\(comment.endLine) (\(comment.side) side)\n"
            }
            message += "Comment: \(comment.text)\n\n"
        }

        surfaceModel.sendText(message)
        return nil
    }

    @discardableResult
    func presentPRReviewSheet() -> Bool {
        // Use repositoryRoot if available, otherwise fall back to workingDirectory or pwd
        let repoRoot = selectedTab?.repositoryRoot
            ?? selectedTab?.workingDirectory
            ?? selectedTab?.activeSurface?.pwd

        guard let repoRoot, !repoRoot.isEmpty else {
            return false
        }

        let model = TerminalPRReviewSheetModel(
            repositoryService: repositoryService,
            repositoryRoot: repoRoot
        ) { [weak self] selectedPR, resolvedRoot in
            guard let self else { return }
            self.openPRForReview(selectedPR, repositoryRoot: resolvedRoot)
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                self?.prReviewSheetModel = nil
            }
        }

        prReviewSheetModel = model
        return true
    }

    private func openPRForReview(_ pr: TerminalOpenPullRequest, repositoryRoot: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                // Fetch the remote branch first
                try await repositoryService.fetchRemoteBranch(
                    repositoryRoot: repositoryRoot,
                    branchName: pr.headRefName
                )

                // Create or reuse a worktree for the PR branch
                let remoteBranch = TerminalBranchDescriptor(
                    kind: .remote,
                    reference: "origin/\(pr.headRefName)",
                    name: pr.headRefName
                )
                let result = try await repositoryService.createOrReuseWorktree(
                    request: TerminalWorktreeRequest(
                        repositoryRoot: repositoryRoot,
                        selection: .existing(remoteBranch)
                    )
                )

                await MainActor.run {
                    self.prReviewSheetModel = nil

                    var config = Ghostty.SurfaceConfiguration()
                    config.workingDirectory = result.workingDirectory
                    if let newController = Self.newTab(
                        self.ghostty, from: self.window, withBaseConfig: config
                    ) {
                        // Mark the new tab as review mode
                        if let newTab = newController.selectedTab {
                            newTab.isReviewMode = true
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    if let model = self.prReviewSheetModel {
                        model.isOpening = false
                        model.errorMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    func submitReview(event: TerminalReviewEvent) {
        guard let selectedTab else { return }
        guard let nodeID = selectedTab.pullRequestSummary?.nodeID else { return }
        guard let context = selectedTab.repositoryRoot.flatMap({ root in
            selectedTab.branchName.map { branch in
                TerminalRepositoryContext(
                    workingDirectory: selectedTab.workingDirectory ?? root,
                    repositoryRoot: root,
                    repositoryName: URL(fileURLWithPath: root).lastPathComponent,
                    branchName: branch
                )
            }
        }) else { return }

        let body = selectedTab.reviewBodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        let comments = selectedTab.localReviewComments

        selectedTab.isSubmittingReview = true
        selectedTab.reviewSubmitError = nil
        objectWillChange.send()

        Task { [weak selectedTab, weak self] in
            guard let selectedTab, let self else { return }
            do {
                try await repositoryService.submitPullRequestReview(
                    for: context,
                    nodeID: nodeID,
                    event: event,
                    body: body.isEmpty ? nil : body,
                    comments: comments
                )
                await MainActor.run {
                    selectedTab.isSubmittingReview = false
                    selectedTab.reviewSubmitError = nil
                    selectedTab.clearReviewComments()
                    selectedTab.reviewBodyText = ""
                    self.objectWillChange.send()
                    self.refreshSelectedTabPullRequestFromUI()
                }
            } catch {
                await MainActor.run {
                    selectedTab.isSubmittingReview = false
                    selectedTab.reviewSubmitError = error.localizedDescription
                    self.objectWillChange.send()
                }
            }
        }
    }

    @discardableResult
    func presentWorktreeSheet() -> Bool {
        let initialRepositoryRoot = selectedTab?.repositoryRoot
        let initialBaseBranch = selectedTab?.branchName
        let model = TerminalWorktreeSheetModel(
            repositoryService: repositoryService,
            initialRepositoryRoot: initialRepositoryRoot,
            initialBaseBranchName: initialBaseBranch
        ) { [weak self] result in
            Task { @MainActor [weak self] in
                self?.worktreeSheetModel = nil
                guard let self else { return }

                var config = Ghostty.SurfaceConfiguration()
                config.workingDirectory = result.workingDirectory
                _ = Self.newTab(self.ghostty, from: self.window, withBaseConfig: config)
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                self?.worktreeSheetModel = nil
            }
        }

        worktreeSheetModel = model
        return true
    }

    // MARK: Tab State Synchronization

    private func syncSelectedTabStateFromController() {
        guard let selectedTab else { return }
        selectedTab.updateSurfaceTree(surfaceTree)
        selectedTab.setFocusedSurfaceID(focusedSurface?.id)
        selectedTab.setTitleOverride(titleOverride)
        if let window = window as? TerminalWindow {
            selectedTab.setTabColor(window.tabColor)
        }
    }

    private func applySelectedTabState(focus: Bool) {
        guard let selectedTab else { return }

        surfaceTree = selectedTab.surfaceTree
        titleOverride = selectedTab.titleOverride

        if let window = window as? TerminalWindow {
            window.tabColor = selectedTab.tabColor
            window.surfaceIsZoomed = surfaceTree.zoomed != nil
        }

        let focusTarget = surfaceTree.first(where: { $0.id == selectedTab.focusedSurfaceID }) ?? surfaceTree.first
        focusedSurface = focusTarget
        focusedSurfaceDidChange(to: focusTarget)
        relabelTabs()
        refreshSelectedTabRepositoryContextAndPullRequest()
        restartPullRequestRefreshTimer()

        if focus, let focusTarget {
            DispatchQueue.main.async {
                Ghostty.moveFocus(to: focusTarget)
                self.window?.makeKeyAndOrderFront(nil)
                if !NSApp.isActive {
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }
    }

    private func setCurrentTabTitleOverride(_ newValue: String?) {
        titleOverride = newValue
        selectedTab?.setTitleOverride(newValue)
        invalidateRestorableState()
    }

    func setCurrentTabTitleOverrideFromExternal(_ newValue: String?) {
        setCurrentTabTitleOverride(newValue)
    }

    func setCurrentTabColorFromExternal(_ newValue: TerminalTabColor) {
        if let window = window as? TerminalWindow {
            window.tabColor = newValue
        }
        selectedTab?.setTabColor(newValue)
        invalidateRestorableState()
    }

    func setTabTitleOverride(id: UUID, _ newValue: String?) {
        guard let tab = tabState(id: id) else { return }
        tab.setTitleOverride(newValue)
        if tab.id == selectedTabID {
            titleOverride = newValue
        }
        invalidateRestorableState()
    }

    func setTabColor(id: UUID, _ newValue: TerminalTabColor) {
        guard let tab = tabState(id: id) else { return }
        tab.setTabColor(newValue)
        if tab.id == selectedTabID, let window = window as? TerminalWindow {
            window.tabColor = newValue
        }
        invalidateRestorableState()
    }

    private func restoreTab(_ restorableState: TerminalTabRestorableState, at index: Int, select: Bool) {
        let tab = TerminalTabState(restorableState: restorableState)
        tabs.insert(tab, at: min(max(0, index), tabs.count))
        relabelTabs()
        invalidateRestorableState()
        if select {
            _ = selectTab(id: tab.id, focus: true)
        }
    }

    func restoreTabs(
        from states: [TerminalTabRestorableState],
        selectedTabID: UUID?,
        focus: Bool = false
    ) {
        tabs = states.map(TerminalTabState.init(restorableState:))
        relabelTabs()
        self.selectedTabID = selectedTabID ?? tabs.first?.id
        applySelectedTabState(focus: focus)
    }

    private func registerUndoForTreeChange(
        tabID: UUID,
        oldTree: SplitTree<Ghostty.SurfaceView>,
        oldFocusedSurfaceID: UUID?,
        newTree: SplitTree<Ghostty.SurfaceView>,
        newFocusedSurfaceID: UUID?,
        undoAction: String?
    ) {
        guard let undoManager else { return }
        if let undoAction {
            undoManager.setActionName(undoAction)
        }

        undoManager.registerUndo(
            withTarget: self,
            expiresAfter: undoExpiration
        ) { target in
            target.applyTabTreeState(
                tabID: tabID,
                tree: oldTree,
                focusedSurfaceID: oldFocusedSurfaceID
            )

            undoManager.registerUndo(
                withTarget: target,
                expiresAfter: target.undoExpiration
            ) { target in
                target.applyTabTreeState(
                    tabID: tabID,
                    tree: newTree,
                    focusedSurfaceID: newFocusedSurfaceID
                )
            }
        }
    }

    private func applyTabTreeState(
        tabID: UUID,
        tree: SplitTree<Ghostty.SurfaceView>,
        focusedSurfaceID: UUID?
    ) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        tab.updateSurfaceTree(tree)
        tab.setFocusedSurfaceID(focusedSurfaceID)
        _ = selectTab(id: tab.id, focus: true)
    }

    private func registerUndoForClosedTab(
        _ closedTab: ClosedTabUndoState,
        actionName: String = "Close Tab",
        registerRedo: Bool = true
    ) {
        guard let undoManager else { return }

        undoManager.setActionName(actionName)
        undoManager.registerUndo(
            withTarget: self,
            expiresAfter: undoExpiration
        ) { target in
            target.restoreTab(closedTab.state, at: closedTab.index, select: true)

            guard registerRedo else { return }
            undoManager.registerUndo(
                withTarget: target,
                expiresAfter: target.undoExpiration
            ) { target in
                target.closeTabImmediately(
                    tabID: closedTab.state.id,
                    registerUndo: false,
                    registerRedo: false
                )
            }
        }
    }

    private func registerUndoForClosedTabs(
        _ closedTabs: [ClosedTabUndoState],
        actionName: String,
        redo: @escaping (TerminalController) -> Void
    ) {
        guard let undoManager else { return }
        guard !closedTabs.isEmpty else { return }

        undoManager.setActionName(actionName)
        undoManager.registerUndo(
            withTarget: self,
            expiresAfter: undoExpiration
        ) { target in
            for closedTab in closedTabs.sorted(by: { $0.index < $1.index }) {
                target.restoreTab(closedTab.state, at: closedTab.index, select: false)
            }

            if let firstRestored = closedTabs.first {
                _ = target.selectTab(id: firstRestored.state.id, focus: true)
            }

            undoManager.registerUndo(
                withTarget: target,
                expiresAfter: target.undoExpiration
            ) { target in
                redo(target)
            }
        }
    }

    // MARK: Pull Request Refresh

    private func restartPullRequestRefreshTimer() {
        pullRequestRefreshTimer?.invalidate()

        guard window?.isKeyWindow ?? false else { return }
        guard selectedTab != nil else { return }

        pullRequestRefreshTimer = Timer.scheduledTimer(
            withTimeInterval: Self.pullRequestRefreshInterval,
            repeats: true
        ) { [weak self] _ in
            self?.refreshSelectedTabRepositoryContextAndPullRequest()
        }
    }

    private func refreshSelectedTabRepositoryContextAndPullRequest() {
        guard let selectedTab else { return }

        let workingDirectory = selectedTab.activeSurface?.pwd ?? selectedTab.workingDirectory
        selectedTab.setWorkingDirectory(workingDirectory)

        pullRequestRefreshTask?.cancel()
        pullRequestRefreshTask = Task { [weak selectedTab, weak self] in
            guard let selectedTab, let self else { return }

            await MainActor.run {
                selectedTab.setRefreshing(true)
            }
            defer {
                Task { @MainActor in
                    selectedTab.setRefreshing(false)
                }
            }

            let context: TerminalRepositoryContext
            do {
                context = try await repositoryService.resolveContext(for: workingDirectory)
            } catch let error as TerminalRepositoryServiceError {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    selectedTab.updateRepositoryContext(nil)
                    selectedTab.setWorkingDirectory(workingDirectory)
                    selectedTab.setPullRequestMessage(
                        error.localizedDescription,
                        clearContent: !selectedTab.hasPullRequestContent
                    )
                    selectedTab.setChangeSummaryMessage(
                        error.localizedDescription,
                        clearSummary: !selectedTab.hasChangeSummary
                    )
                }
                return
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    selectedTab.updateRepositoryContext(nil)
                    selectedTab.setWorkingDirectory(workingDirectory)
                    selectedTab.setPullRequestMessage(
                        error.localizedDescription,
                        clearContent: !selectedTab.hasPullRequestContent
                    )
                    selectedTab.setChangeSummaryMessage(
                        error.localizedDescription,
                        clearSummary: !selectedTab.hasChangeSummary
                    )
                }
                return
            }

            guard !Task.isCancelled else { return }
            await MainActor.run {
                selectedTab.updateRepositoryContext(context)
            }

            let refreshTime = Date()

            do {
                let summary = try await repositoryService.fetchPullRequestSummary(for: context)
                guard !Task.isCancelled else { return }

                async let checksResult = Self.captureResult {
                    try await self.repositoryService.fetchPullRequestChecks(for: context)
                }
                async let commentsResult = Self.captureResult {
                    try await self.repositoryService.fetchReviewThreads(
                        for: context,
                        pullRequestNumber: summary.number
                    )
                }
                async let changesResult = Self.captureResult {
                    try await self.repositoryService.fetchRepositoryChanges(
                        for: context,
                        preferredBaseBranch: summary.baseRefName
                    )
                }

                let (checks, comments, changes) = await (checksResult, commentsResult, changesResult)
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    switch (checks, comments) {
                    case let (.success(checks), .success(comments)):
                        selectedTab.replacePullRequestContent(
                            summary: summary,
                            checks: checks,
                            reviewThreads: comments,
                            fetchedAt: refreshTime
                        )
                    case let (.failure(error), _), let (_, .failure(error)):
                        selectedTab.setPullRequestMessage(
                            error.localizedDescription,
                            clearContent: !selectedTab.hasPullRequestContent
                        )
                    }

                    switch changes {
                    case let .success(changes):
                        selectedTab.replaceChangeSummary(changes)
                    case let .failure(error):
                        selectedTab.setChangeSummaryMessage(
                            error.localizedDescription,
                            clearSummary: !selectedTab.hasChangeSummary
                        )
                    }
                }
            } catch let error as TerminalRepositoryServiceError {
                guard !Task.isCancelled else { return }
                let changesResult = await Self.captureResult {
                    try await self.repositoryService.fetchRepositoryChanges(
                        for: context,
                        preferredBaseBranch: nil
                    )
                }

                guard !Task.isCancelled else { return }
                await MainActor.run {
                    selectedTab.setPullRequestMessage(
                        error.localizedDescription,
                        clearContent: !selectedTab.hasPullRequestContent
                    )

                    switch changesResult {
                    case let .success(changes):
                        selectedTab.replaceChangeSummary(changes)
                    case let .failure(changeError):
                        selectedTab.setChangeSummaryMessage(
                            changeError.localizedDescription,
                            clearSummary: !selectedTab.hasChangeSummary
                        )
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    selectedTab.setPullRequestMessage(
                        error.localizedDescription,
                        clearContent: !selectedTab.hasPullRequestContent
                    )
                }
            }
        }
    }

    private func clampRightSidebarSplit(_ proposed: CGFloat) -> CGFloat {
        guard let window else {
            return min(max(proposed, 0.3), 0.9)
        }

        let availableWidth = max(
            window.contentLayoutRect.width - leftSidebarWidth - 1,
            rightSidebarMinimumWidth + 320
        )
        let maxSplit = max(0.3, min(0.9, 1 - (rightSidebarMinimumWidth / availableWidth)))
        return min(max(proposed, 0.3), maxSplit)
    }

    static private func captureResult<T>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async -> Result<T, Error> {
        do {
            return .success(try await operation())
        } catch {
            return .failure(error)
        }
    }

    // MARK: Tab Labels

    func relabelTabs() {
        for (index, tab) in zip(1..., tabs) {
            guard index <= 9 else {
                tab.setKeyEquivalent(nil)
                continue
            }

            if let keyEquivalent = ghostty.config.keyboardShortcut(for: "goto_tab:\(index)") {
                tab.setKeyEquivalent("\(keyEquivalent)")
            } else {
                tab.setKeyEquivalent(nil)
            }
        }
    }

    // MARK: Tab Closing

    func closeTabImmediately(
        tabID: UUID? = nil,
        registerUndo: Bool = true,
        registerRedo: Bool = true
    ) {
        guard let closeTabID = tabID ?? selectedTabID else {
            closeWindowImmediately()
            return
        }

        guard tabs.count > 1 else {
            closeWindowImmediately()
            return
        }

        syncSelectedTabStateFromController()

        guard let index = tabs.firstIndex(where: { $0.id == closeTabID }) else { return }
        let removedTab = tabs.remove(at: index)
        let undoState = ClosedTabUndoState(index: index, state: removedTab.restorableState)

        let newSelectionIndex = min(index, max(0, tabs.count - 1))
        selectedTabID = tabs[newSelectionIndex].id
        applySelectedTabState(focus: true)
        invalidateRestorableState()

        if registerUndo {
            registerUndoForClosedTab(undoState, registerRedo: registerRedo)
        }
    }

    private func closeOtherTabsImmediately() {
        syncSelectedTabStateFromController()
        guard let selectedTabID else { return }

        let removedTabs = tabs.enumerated()
            .filter { $0.element.id != selectedTabID }
            .map { ClosedTabUndoState(index: $0.offset, state: $0.element.restorableState) }

        tabs.removeAll { $0.id != selectedTabID }
        relabelTabs()
        invalidateRestorableState()

        registerUndoForClosedTabs(removedTabs, actionName: "Close Other Tabs") { target in
            target.closeOtherTabsImmediately()
        }
    }

    private func closeTabsOnTheRightImmediately() {
        syncSelectedTabStateFromController()
        guard let selectedTabIndex else { return }

        let removedTabs = tabs.enumerated()
            .filter { $0.offset > selectedTabIndex }
            .map { ClosedTabUndoState(index: $0.offset, state: $0.element.restorableState) }

        guard !removedTabs.isEmpty else { return }

        tabs.removeSubrange((selectedTabIndex + 1)..<tabs.count)
        relabelTabs()
        invalidateRestorableState()

        registerUndoForClosedTabs(removedTabs, actionName: "Close Tabs to the Right") { target in
            target.closeTabsOnTheRightImmediately()
        }
    }

    func closeWindowImmediately() {
        guard let window else { return }
        guard let undoState = windowUndoState else {
            window.close()
            return
        }

        registerUndoForCloseWindow(undoState)
        window.close()
    }

    private func registerUndoForCloseWindow(_ undoState: WindowUndoState) {
        guard let undoManager, undoManager.isUndoRegistrationEnabled else { return }

        undoManager.setActionName("Close Window")
        undoManager.registerUndo(
            withTarget: ghostty,
            expiresAfter: undoExpiration
        ) { ghostty in
            let controller = TerminalController(ghostty, with: undoState)

            undoManager.registerUndo(
                withTarget: controller,
                expiresAfter: controller.undoExpiration
            ) { target in
                target.closeWindowImmediately()
            }
        }
    }

    static func closeAllWindows() {
        guard let confirmController = all.first(where: {
            $0.tabs.contains(where: { $0.surfaceTree.contains(where: { $0.needsConfirmQuit }) })
        }) else {
            closeAllWindowsImmediately()
            return
        }

        guard let confirmWindow = confirmController.window else {
            closeAllWindowsImmediately()
            return
        }

        let alert = NSAlert()
        alert.messageText = "Close All Windows?"
        alert.informativeText = "All terminal sessions will be terminated."
        alert.addButton(withTitle: "Close All Windows")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: confirmWindow) { response in
            if response == .alertFirstButtonReturn {
                alert.window.orderOut(nil)
                closeAllWindowsImmediately()
            }
        }
    }

    static private func closeAllWindowsImmediately() {
        let undoManager = (NSApp.delegate as? AppDelegate)?.undoManager
        undoManager?.beginUndoGrouping()
        all.forEach { $0.closeWindowImmediately() }
        undoManager?.setActionName("Close All Windows")
        undoManager?.endUndoGrouping()
    }

    convenience init(_ ghostty: Ghostty.App, with undoState: WindowUndoState) {
        precondition(!undoState.tabs.isEmpty, "window undo state must contain at least one tab")
        let firstState = undoState.tabs[0]

        self.init(ghostty, withSurfaceTree: firstState.surfaceTree)
        showWindow(nil)

        if let window {
            window.setFrame(undoState.frame, display: true)
        }

        restoreTabs(from: undoState.tabs, selectedTabID: undoState.selectedTabID)
    }

    // MARK: NSWindowController

    override func windowWillLoad() {
        shouldCascadeWindows = false
    }

    override func windowDidLoad() {
        super.windowDidLoad()
        guard let window else { return }

        let config = ghostty.config

        window.isRestorable = restorable
        if restorable {
            window.restorationClass = TerminalWindowRestoration.self
            window.identifier = .init(String(describing: TerminalWindowRestoration.self))
        }

        window.tabbingMode = .disallowed

        if case let .leaf(view) = surfaceTree.root {
            focusedSurface = view
            tabs.first?.setFocusedSurfaceID(view.id)
        }

        window.contentView = TerminalViewContainer {
            TerminalWindowView(controller: self)
        }

        if let defaultSize {
            switch defaultSize {
            case .frame:
                defaultSize.apply(to: window)
            case .contentIntrinsicSize:
                DispatchQueue.main.asyncAfter(deadline: .now() + .microseconds(10_000)) { [weak self, weak window] in
                    guard let self, let window else { return }
                    defaultSize.apply(to: window)
                    if let screen = window.screen ?? NSScreen.main {
                        let frame = self.adjustForWindowPosition(frame: window.frame, on: screen)
                        window.setFrameOrigin(frame.origin)
                    }
                }
            }
        }

        initialFrame = window.frame
        syncAppearance(.init(config))
        relabelTabs()
        applySelectedTabState(focus: false)
    }

    override func newWindowForTab(_ sender: Any?) {
        newTab(sender)
    }

    // MARK: NSWindowDelegate

    override func windowShouldClose(_ sender: NSWindow) -> Bool {
        closeWindow(nil)
        return false
    }

    override func windowWillClose(_ notification: Notification) {
        super.windowWillClose(notification)
        pullRequestRefreshTask?.cancel()
        pullRequestRefreshTimer?.invalidate()

        if let focusedWindow = NSApplication.shared.keyWindow, focusedWindow != window {
            let oldFrame = focusedWindow.frame
            Self.lastCascadePoint = focusedWindow.cascadeTopLeft(from: .zero)
            if focusedWindow.frame != oldFrame {
                focusedWindow.setFrame(oldFrame, display: true)
            }
            return
        }

        if let window {
            let frame = window.frame
            Self.lastCascadePoint = NSPoint(x: frame.minX, y: frame.maxY)
        }
    }

    override func windowDidBecomeKey(_ notification: Notification) {
        super.windowDidBecomeKey(notification)
        restartPullRequestRefreshTimer()
        refreshSelectedTabRepositoryContextAndPullRequest()
        terminalViewContainer?.updateGlassTintOverlay(isKeyWindow: true)
    }

    override func windowDidResignKey(_ notification: Notification) {
        super.windowDidResignKey(notification)
        pullRequestRefreshTimer?.invalidate()
        pullRequestRefreshTask?.cancel()
        terminalViewContainer?.updateGlassTintOverlay(isKeyWindow: false)
    }

    override func windowDidMove(_ notification: Notification) {
        super.windowDidMove(notification)

        if let window {
            LastWindowPosition.shared.save(window)
        }
    }

    override func windowDidResize(_ notification: Notification) {
        super.windowDidResize(notification)

        if let window {
            LastWindowPosition.shared.save(window)
        }
    }

    func windowDidBecomeMain(_ notification: Notification) {
        if let window {
            LastWindowPosition.shared.save(window)
        }

        Self.lastMain = self
    }

    func window(_ window: NSWindow, willEncodeRestorableState state: NSCoder) {
        syncSelectedTabStateFromController()
        let data = TerminalRestorableState(from: self)
        data.encode(with: state)
    }

    // MARK: First Responder

    @IBAction func newWindow(_ sender: Any?) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.newWindow(surface: surface)
    }

    @IBAction func newTab(_ sender: Any?) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.newTab(surface: surface)
    }

    @IBAction func closeTab(_ sender: Any?) {
        guard tabs.count > 1 else {
            closeWindow(sender)
            return
        }

        guard let selectedTab else { return }
        guard selectedTab.surfaceTree.contains(where: { $0.needsConfirmQuit }) else {
            closeTabImmediately()
            return
        }

        confirmClose(
            messageText: "Close Tab?",
            informativeText: "The terminal still has a running process. If you close the tab the process will be killed."
        ) {
            self.closeTabImmediately()
        }
    }

    @IBAction func closeOtherTabs(_ sender: Any?) {
        guard tabs.count > 1 else { return }

        let needsConfirm = tabs.contains { tab in
            guard tab.id != selectedTabID else { return false }
            return tab.surfaceTree.contains(where: { $0.needsConfirmQuit })
        }

        if !needsConfirm {
            closeOtherTabsImmediately()
            return
        }

        confirmClose(
            messageText: "Close Other Tabs?",
            informativeText: "At least one other tab still has a running process. If you close the tab the process will be killed."
        ) {
            self.closeOtherTabsImmediately()
        }
    }

    @IBAction func closeTabsOnTheRight(_ sender: Any?) {
        guard let selectedTabIndex else { return }
        let tabsToClose = tabs.dropFirst(selectedTabIndex + 1)
        guard !tabsToClose.isEmpty else { return }

        let needsConfirm = tabsToClose.contains { tab in
            tab.surfaceTree.contains(where: { $0.needsConfirmQuit })
        }

        if !needsConfirm {
            closeTabsOnTheRightImmediately()
            return
        }

        confirmClose(
            messageText: "Close Tabs on the Right?",
            informativeText: "At least one tab to the right still has a running process. If you close the tab the process will be killed."
        ) {
            self.closeTabsOnTheRightImmediately()
        }
    }

    @IBAction func returnToDefaultSize(_ sender: Any?) {
        guard let window, let defaultSize else { return }
        defaultSize.apply(to: window)
    }

    @IBAction override func closeWindow(_ sender: Any?) {
        guard let confirmTab = tabs.first(where: { $0.surfaceTree.contains(where: { $0.needsConfirmQuit }) }) else {
            closeWindowImmediately()
            return
        }

        if confirmTab.id != selectedTabID {
            _ = selectTab(id: confirmTab.id, focus: false)
        }

        confirmClose(
            messageText: "Close Window?",
            informativeText: "All terminal sessions in this window will be terminated."
        ) {
            self.closeWindowImmediately()
        }
    }

    @IBAction func toggleGhosttyFullScreen(_ sender: Any?) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.toggleFullscreen(surface: surface)
    }

    @IBAction func toggleTerminalInspector(_ sender: Any?) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.toggleTerminalInspector(surface: surface)
    }

    // MARK: TerminalViewDelegate

    override func focusedSurfaceDidChange(to: Ghostty.SurfaceView?) {
        super.focusedSurfaceDidChange(to: to)

        surfaceAppearanceCancellables.removeAll()

        selectedTab?.setFocusedSurfaceID(focusedSurface?.id)

        guard let focusedSurface else { return }
        syncAppearance(focusedSurface.derivedConfig)

        focusedSurface.$derivedConfig
            .sink { [weak self, weak focusedSurface] _ in
                self?.syncAppearanceOnPropertyChange(focusedSurface)
            }
            .store(in: &surfaceAppearanceCancellables)

        focusedSurface.$backgroundColor
            .sink { [weak self, weak focusedSurface] _ in
                self?.syncAppearanceOnPropertyChange(focusedSurface)
            }
            .store(in: &surfaceAppearanceCancellables)

        if let pwd = focusedSurface.pwd {
            pwdDidChange(to: URL(fileURLWithPath: pwd))
        }
    }

    private func syncAppearanceOnPropertyChange(_ surface: Ghostty.SurfaceView?) {
        guard let surface else { return }
        DispatchQueue.main.async { [weak self, weak surface] in
            guard let self, let surface else { return }
            guard self.focusedSurface == surface else { return }
            self.syncAppearance(surface.derivedConfig)
        }
    }

    // MARK: Notifications

    @objc private func ghosttyConfigDidChange(_ notification: Notification) {
        guard let config = notification.userInfo?[
            Notification.Name.GhosttyConfigChangeKey
        ] as? Ghostty.Config else { return }

        if notification.object == nil {
            self.derivedConfig = DerivedConfig(config)
            if surfaceTree.isEmpty {
                syncAppearance(.init(config))
            }
            return
        }
    }

    @objc private func onMoveTab(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard target == focusedSurface else { return }
        guard let action = notification.userInfo?[Notification.Name.GhosttyMoveTabKey] as? Ghostty.Action.MoveTab else { return }
        moveSelectedTab(by: action.amount)
    }

    @objc private func onGotoTab(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard target == focusedSurface else { return }
        guard let tabEnumAny = notification.userInfo?[Ghostty.Notification.GotoTabKey] else { return }
        guard let tabEnum = tabEnumAny as? ghostty_action_goto_tab_e else { return }

        let tabIndex = Int(tabEnum.rawValue)
        let finalIndex: Int

        if tabIndex <= 0 {
            guard let selectedTabIndex else { return }
            switch tabIndex {
            case Int(GHOSTTY_GOTO_TAB_PREVIOUS.rawValue):
                finalIndex = selectedTabIndex == 0 ? tabs.count - 1 : selectedTabIndex - 1
            case Int(GHOSTTY_GOTO_TAB_NEXT.rawValue):
                finalIndex = selectedTabIndex == tabs.count - 1 ? 0 : selectedTabIndex + 1
            case Int(GHOSTTY_GOTO_TAB_LAST.rawValue):
                finalIndex = tabs.count - 1
            default:
                return
            }
        } else {
            finalIndex = min(tabIndex - 1, tabs.count - 1)
        }

        guard tabs.indices.contains(finalIndex) else { return }
        _ = selectTab(id: tabs[finalIndex].id, focus: true)
    }

    @objc private func onCloseTab(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.contains(target) else { return }
        closeTab(self)
    }

    @objc private func onCloseOtherTabs(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.contains(target) else { return }
        closeOtherTabs(self)
    }

    @objc private func onCloseTabsOnTheRight(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.contains(target) else { return }
        closeTabsOnTheRight(self)
    }

    @objc private func onCloseWindow(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.contains(target) else { return }
        closeWindow(self)
    }

    @objc private func onResetWindowSize(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.contains(target) else { return }
        returnToDefaultSize(nil)
    }

    @objc private func onToggleFullscreen(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard target == focusedSurface else { return }

        guard let any = notification.userInfo?[Ghostty.Notification.FullscreenModeKey],
              let mode = any as? FullscreenMode else {
            Ghostty.logger.warning("no fullscreen mode specified or invalid mode, doing nothing")
            return
        }

        toggleFullscreen(mode: mode)
    }

    // MARK: Appearance

    override func syncAppearance() {
        guard let focusedSurface else { return }
        syncAppearance(focusedSurface.derivedConfig)
    }

    private func syncAppearance(_ surfaceConfig: Ghostty.SurfaceView.DerivedConfig) {
        guard let window = window as? TerminalWindow else { return }

        window.surfaceIsZoomed = surfaceTree.zoomed != nil

        if let titleFontName = surfaceConfig.windowTitleFontFamily {
            window.titlebarFont = NSFont(name: titleFontName, size: NSFont.systemFontSize)
        } else {
            window.titlebarFont = nil
        }

        if let selectedTab {
            window.tabColor = selectedTab.tabColor
        }

        window.syncAppearance(surfaceConfig)
        terminalViewContainer?.ghosttyConfigDidChange(
            ghostty.config,
            preferredBackgroundColor: window.preferredBackgroundColor
        )
    }

    func adjustForWindowPosition(frame: NSRect, on screen: NSScreen) -> NSRect {
        guard let x = derivedConfig.windowPositionX else { return frame }
        guard let y = derivedConfig.windowPositionY else { return frame }

        let origin = screen.origin(
            fromTopLeftOffsetX: CGFloat(x),
            offsetY: CGFloat(y),
            windowSize: frame.size
        )

        var safeOrigin = origin
        let visibleFrame = screen.visibleFrame
        safeOrigin.x = min(max(safeOrigin.x, visibleFrame.minX), visibleFrame.maxX - frame.width)
        safeOrigin.y = min(max(safeOrigin.y, visibleFrame.minY), visibleFrame.maxY - frame.height)

        var result = frame
        result.origin = safeOrigin
        return result
    }

    struct DerivedConfig {
        let backgroundColor: Color
        let macosWindowButtons: Ghostty.MacOSWindowButtons
        let macosTitlebarStyle: String
        let maximize: Bool
        let windowPositionX: Int16?
        let windowPositionY: Int16?

        init() {
            self.backgroundColor = Color(NSColor.windowBackgroundColor)
            self.macosWindowButtons = .visible
            self.macosTitlebarStyle = "system"
            self.maximize = false
            self.windowPositionX = nil
            self.windowPositionY = nil
        }

        init(_ config: Ghostty.Config) {
            self.backgroundColor = config.backgroundColor
            self.macosWindowButtons = config.macosWindowButtons
            self.macosTitlebarStyle = config.macosTitlebarStyle == "tabs" ? "transparent" : config.macosTitlebarStyle
            self.maximize = config.maximize
            self.windowPositionX = config.windowPositionX
            self.windowPositionY = config.windowPositionY
        }
    }
}

// MARK: NSMenuItemValidation

extension TerminalController {
    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(closeTabsOnTheRight):
            guard let selectedTabIndex else { return false }
            return tabs.indices.contains(where: { $0 > selectedTabIndex })

        case #selector(returnToDefaultSize):
            guard let window else { return false }

            if window.styleMask.contains(.fullScreen) {
                return false
            }

            if fullscreenStyle?.isFullscreen ?? false {
                return false
            }

            return defaultSize?.isChanged(for: window) ?? false

        default:
            return super.validateMenuItem(item)
        }
    }
}

// MARK: Default Size

extension TerminalController {
    enum DefaultSize {
        case frame(NSRect)
        case contentIntrinsicSize

        func isChanged(for window: NSWindow) -> Bool {
            switch self {
            case let .frame(rect):
                return window.frame != rect
            case .contentIntrinsicSize:
                guard let view = window.contentView else { return false }
                return view.frame.size != view.intrinsicContentSize
            }
        }

        func apply(to window: NSWindow) {
            switch self {
            case let .frame(rect):
                window.setFrame(rect, display: true)
            case .contentIntrinsicSize:
                guard let size = window.contentView?.intrinsicContentSize else { return }
                window.setContentSize(size)
                window.constrainToScreen()
            }
        }
    }

    private var defaultSize: DefaultSize? {
        if derivedConfig.maximize, let screen = window?.screen ?? NSScreen.main {
            return .frame(screen.visibleFrame)
        } else if focusedSurface?.initialSize != nil {
            return .contentIntrinsicSize
        } else if let initialFrame {
            return .frame(initialFrame)
        } else {
            return nil
        }
    }
}
